import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'dart:convert';
import 'dart:async';

// Internal Project Imports
import 'user_details_page.dart';
import 'location_view_page.dart';
import 'call_page.dart';
import 'style_utils.dart';

class InterfacePage extends StatefulWidget {
  final String userId;

  const InterfacePage({super.key, required this.userId});

  @override
  _InterfacePageState createState() => _InterfacePageState();
}

class _InterfacePageState extends State<InterfacePage>
    with WidgetsBindingObserver {
  Map<String, dynamic>? _userData;
  bool _isLoading = true;
  bool _showPopup = false;
  bool _showScanner = false;
  String? _locationData;
  MobileScannerController? _mobileScannerController;
  Position? _currentPosition;
  StreamSubscription<Position>? _positionStream;
  Timer? _locationUpdateTimer;
  bool _isSharingLiveLocation = false;
  String? _liveLocationSharingId;
  List<Map<String, dynamic>> _familyMembers = [];
  StreamSubscription<DocumentSnapshot>? _callSubscription;
  bool _isCallDialogShowing = false;

  bool _isHandlingQr = false;
  int _tourStep = 0;
  bool _showTour = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initForegroundTask();
    _fetchUserData();
    _checkLocationPermission();
    _loadFamilyMembers();
    _requestBatteryOptimization();
    _resumeLiveLocationSharing();
    _listenForIncomingCalls();
    _checkFirstTime();
  }

  Future<void> _checkFirstTime() async {
    final prefs = await SharedPreferences.getInstance();
    bool hasSeenTour = prefs.getBool('hasSeenTour') ?? false;
    if (!hasSeenTour) {
      setState(() {
        _showTour = true;
        _tourStep = 1;
      });
    }
  }

  Future<void> _completeTour() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('hasSeenTour', true);
    setState(() {
      _showTour = false;
    });
  }

  void _listenForIncomingCalls() {
    _callSubscription = FirebaseFirestore.instance
        .collection('calls')
        .doc(widget.userId)
        .snapshots()
        .listen((snapshot) {
      if (snapshot.exists) {
        final data = snapshot.data();
        if (data != null && !_isCallDialogShowing) {
          _isCallDialogShowing = true;
          _showIncomingCallDialog(data);
        }
      } else {
        // Call document deleted (Hangup)
        if (_isCallDialogShowing && mounted) {
          Navigator.of(context, rootNavigator: true).pop(); // Dismiss dialog
          _isCallDialogShowing = false;
        }
        FlutterRingtonePlayer().stop();
      }
    });
  }

  void _showIncomingCallDialog(Map<String, dynamic> callData) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('Incoming Call from ${callData['callerName'] ?? 'Unknown'}'),
        content: const Text('Do you want to accept this call?'),
        actions: [
          TextButton(
            onPressed: () async {
              // Decline
              try { await FirebaseFirestore.instance.collection('calls').doc(widget.userId).delete(); } catch(_) {}
              if (mounted) {
                Navigator.pop(context);
              }
              _isCallDialogShowing = false;
            },
            child: const Text('Decline', style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _isCallDialogShowing = false;
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => CallPage(
                    channelName: callData['channelName'],
                    callerId: callData['callerId'],
                    calleeId: widget.userId,
                    isCaller: false,
                  ),
                ),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Accept', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _initiateCall(String targetUserId, String targetUserName) async {
    final channelName = 'room_${widget.userId}_$targetUserId';
    
    // Create ringing doc for target
    final callData = {
      'callerId': widget.userId,
      'callerName': _userData?['name'] ?? 'Family Member',
      'channelName': channelName,
      'timestamp': FieldValue.serverTimestamp(),
    };

    try { await FirebaseFirestore.instance.collection('calls').doc(targetUserId).set(callData); } catch(_) {}

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => CallPage(
            channelName: channelName,
            callerId: widget.userId,
            calleeId: targetUserId,
            isCaller: true,
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mobileScannerController?.dispose();
    _positionStream?.cancel();
    _locationUpdateTimer?.cancel();
    _stopLiveLocationSharing();
    FlutterForegroundTask.stopService();
    _callSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _isSharingLiveLocation) {
      _startForegroundTask(); // keeps app alive via notification
    } else if (state == AppLifecycleState.resumed) {
      // Restart the position update timer when app comes to foreground
      if (_isSharingLiveLocation && _liveLocationSharingId != null) {
        _startLocationUpdateTimer(_liveLocationSharingId!);
      }
    }
  }

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'location_channel',
        channelName: 'Location Updates',
        channelDescription:
            'This notification keeps the app running for live location sharing.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 5000,
        autoRunOnBoot: false,
        allowWifiLock: true,
      ),
    );
  }

  Future<void> _requestBatteryOptimization() async {
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }

  Future<void> _startForegroundTask() async {
    if (_isSharingLiveLocation && _liveLocationSharingId != null) {
      await FlutterForegroundTask.startService(
        notificationTitle: 'Sharing Live Location',
        notificationText: 'Your location is being shared with family members.',
        callback: startLocationUpdates,
      );
    }
  }

  Future<void> _fetchUserData() async {
    try {
      final DocumentSnapshot userDoc =
          await FirebaseFirestore.instance
              .collection('users')
              .doc(widget.userId)
              .get();

      if (userDoc.exists) {
        setState(() {
          _userData = userDoc.data() as Map<String, dynamic>?;
          _isLoading = false;

          // Check for first login after approval
          if (_userData?['isFirstLoginAfterApprove'] == true) {
            _showApprovalWelcomePopup(_userData?['promoCode'] ?? 'N/A');
            // Reset flag
            FirebaseFirestore.instance
                .collection('users')
                .doc(widget.userId)
                .update({'isFirstLoginAfterApprove': false});
          }
        });
      } else {
        setState(() {
          _isLoading = false;
        });
        if (mounted) {
          AppAlerts.show(context, 'User not found', isError: true);
        }
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        AppAlerts.show(context, 'Error fetching user data: $e', isError: true);
      }
    }
  }

  Future<void> _loadFamilyMembers() async {
    try {
      final snapshot =
          await FirebaseFirestore.instance
              .collection('users')
              .doc(widget.userId)
              .collection('familyMembers')
              .orderBy('timestamp', descending: true)
              .get();

      setState(() {
        _familyMembers =
            snapshot.docs.map((doc) {
              final data = doc.data();
              return {
                'id': doc.id,
                'userId': data['userId'],
                'name': data['name'],
                'profilePicture': data['profilePicture'],
                'locationData': data['locationData'],
                'timestamp': data['timestamp'],
              };
            }).toList();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading family members: $e')),
        );
      }
    }
  }

  Future<void> _saveFamilyMember(Map<String, dynamic> userData) async {
    try {
      final userId = userData['userId'];
      if (userId == null) return;

      final exists = _familyMembers.any((member) => member['userId'] == userId);

      if (!exists) {
        final connectionData = {
          'userId': userId,
          'name': userData['name'],
          'profilePicture': userData['profilePicture'],
          'locationData': userData['locationData'],
          'timestamp': FieldValue.serverTimestamp(),
        };

        await FirebaseFirestore.instance
            .collection('users')
            .doc(widget.userId)
            .collection('familyMembers')
            .doc(userId)
            .set(connectionData);

        await _loadFamilyMembers();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving family member: $e')),
        );
      }
    }
  }

  Future<bool> _checkLocationPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Location services are disabled. Please enable them.',
            ),
            action: SnackBarAction(
              label: 'Settings',
              onPressed: Geolocator.openLocationSettings,
            ),
          ),
        );
      }
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Location permission denied.'),
              action: SnackBarAction(
                label: 'Settings',
                onPressed: Geolocator.openLocationSettings,
              ),
            ),
          );
        }
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Location permissions are permanently denied. Please enable them in settings.',
            ),
            action: SnackBarAction(
              label: 'Settings',
              onPressed: Geolocator.openLocationSettings,
            ),
          ),
        );
      }
      return false;
    }

    if (permission == LocationPermission.whileInUse) {
      permission = await Geolocator.requestPermission();
      if (permission != LocationPermission.always) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Background location permission required for live tracking. Please allow "Always".',
              ),
              action: SnackBarAction(
                label: 'Settings',
                onPressed: Geolocator.openLocationSettings,
              ),
            ),
          );
        }
        return false;
      }
    }

    return true;
  }

  Future<void> _fetchLocation() async {
    if (!await _checkLocationPermission()) return;

    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
      );

      setState(() {
        _currentPosition = position;
        _locationData = _encodeLocationData(
          position.latitude,
          position.longitude,
          isLive: false,
        );
        _showPopup = true;
        _showScanner = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error getting location: $e')));
      }
    }
  }

  /// Starts a reliable Timer that writes location to Firestore every 5 seconds.
  /// Uses getLastKnownPosition (instant) as primary, getCurrentPosition as fallback.
  void _startLocationUpdateTimer(String sharingId) {
    _locationUpdateTimer?.cancel();
    _positionStream?.cancel();

    _locationUpdateTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!_isSharingLiveLocation || !mounted) {
        timer.cancel();
        return;
      }
      try {
        // ALWAYS fetch a fresh position. getLastKnownPosition is often stale/inaccurate.
        Position position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.best,
          timeLimit: const Duration(seconds: 8),
        );

        // Accuracy Gating: Ignore positions that are too inaccurate (e.g., cell tower only)
        // This prevents the "Wrong Location" (1km offset) issue.
        if (position.accuracy > 50) {
          debugPrint('Skipping low accuracy update: ${position.accuracy}m');
          return;
        }

        final lat = position.latitude;
        final lng = position.longitude;
        final heading = position.heading;
        final speed = position.speed;

        await FirebaseFirestore.instance.collection('liveLocations').doc(sharingId).set({
          'userId': widget.userId,
          'latitude': lat,
          'longitude': lng,
          'heading': heading,
          'speed': speed,
          'timestamp': FieldValue.serverTimestamp(),
          'userName': _userData?['name'] ?? 'Unknown',
          'profilePicture': _userData?['profilePicture'],
        });
      } catch (e) {
        debugPrint('Location update error: $e');
      }
    });
  }

  Future<void> _resumeLiveLocationSharing() async {
    final userDoc =
        await FirebaseFirestore.instance
            .collection('users')
            .doc(widget.userId)
            .collection('liveSharing')
            .doc('current')
            .get();

    if (userDoc.exists && userDoc.data()?['sharingId'] != null) {
      final sharingId = userDoc.data()!['sharingId'] as String;
      setState(() {
        _isSharingLiveLocation = true;
        _liveLocationSharingId = sharingId;
        _locationData = _encodeLocationData(0, 0, isLive: true, sharingId: sharingId);
      });
      _startLocationUpdateTimer(sharingId);
      await _startForegroundTask();
    }
  }

  Future<void> _startLiveLocationSharing() async {
    if (!await _checkLocationPermission()) return;

    String? sharingId;

    final userDoc = await FirebaseFirestore.instance
        .collection('users').doc(widget.userId)
        .collection('liveSharing').doc('current').get();

    if (userDoc.exists && userDoc.data()?['sharingId'] != null) {
      sharingId = userDoc.data()!['sharingId'] as String;
    } else {
      sharingId = FirebaseFirestore.instance.collection('liveLocations').doc().id;
      await FirebaseFirestore.instance
          .collection('users').doc(widget.userId)
          .collection('liveSharing').doc('current')
          .set({'sharingId': sharingId, 'createdAt': FieldValue.serverTimestamp()});
    }

    setState(() {
      _isSharingLiveLocation = true;
      _liveLocationSharingId = sharingId;
    });

    // Save foreground task data
    await FlutterForegroundTask.saveData(key: 'sharingId', value: sharingId);
    await FlutterForegroundTask.saveData(key: 'userId', value: widget.userId);
    await FlutterForegroundTask.saveData(key: 'userName', value: _userData?['name'] ?? 'Unknown');
    await FlutterForegroundTask.saveData(key: 'profilePicture', value: _userData?['profilePicture'] ?? '');

    // Write one immediate position to Firestore
    try {
      final pos = await Geolocator.getLastKnownPosition() 
          ?? await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high, timeLimit: const Duration(seconds: 15));
      final lat = pos.latitude.isNaN ? 0.0 : pos.latitude;
      final lng = pos.longitude.isNaN ? 0.0 : pos.longitude;
      if (lat != 0.0 || lng != 0.0) {
        await FirebaseFirestore.instance.collection('liveLocations').doc(sharingId).set({
          'userId': widget.userId, 'latitude': lat, 'longitude': lng,
          'heading': pos.heading.isNaN ? 0.0 : pos.heading,
          'speed': pos.speed.isNaN ? 0.0 : pos.speed,
          'timestamp': FieldValue.serverTimestamp(),
          'userName': _userData?['name'] ?? 'Unknown',
          'profilePicture': _userData?['profilePicture'],
        });
      }
    } catch (e) { debugPrint('Initial write error: $e'); }

    // Start the reliable Timer to keep updating Firestore every 5 seconds
    _startLocationUpdateTimer(sharingId!);
    await _startForegroundTask();

    setState(() {
      _locationData = _encodeLocationData(0, 0, isLive: true, sharingId: sharingId);
      _showPopup = true;
    });
  }

  String _encodeLocationData(
    double lat,
    double lng, {
    bool isLive = false,
    String? sharingId,
  }) {
    if (isLive && sharingId != null) {
      return jsonEncode({
        'type': 'live',
        'sharingId': sharingId,
        'latitude': lat,
        'longitude': lng,
        'userId': widget.userId,
        'userName': _userData?['name'] ?? 'Unknown',
        'profilePicture': _userData?['profilePicture'],
        'timestamp': DateTime.now().toIso8601String(),
        'platform': Platform.isAndroid ? 'android' : 'ios',
      });
    } else {
      return jsonEncode({
        'type': 'static',
        'latitude': lat,
        'longitude': lng,
        'userId': widget.userId,
        'userName': _userData?['name'] ?? 'Unknown',
        'profilePicture': _userData?['profilePicture'],
        'timestamp': DateTime.now().toIso8601String(),
        'platform': Platform.isAndroid ? 'android' : 'ios',
      });
    }
  }

  Future<void> _stopLiveLocationSharing() async {
    if (_liveLocationSharingId != null) {
      try { await FirebaseFirestore.instance.collection('liveLocations').doc(_liveLocationSharingId).delete(); } catch(_) {}
      
      // Clear the stored sharingId
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.userId)
          .collection('liveSharing')
          .doc('current')
          .delete();
    }

    _positionStream?.cancel();
    await FlutterForegroundTask.stopService();

    setState(() {
      _isSharingLiveLocation = false;
      _liveLocationSharingId = null;
      _showPopup = false;
    });
  }

  void _navigateToUserDetails() {
    if (_userData == null) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (context) =>
                UserDetailsPage(userData: _userData!, userId: widget.userId),
      ),
    );
  }

  void _togglePopup() async {
    setState(() {
      _showPopup = !_showPopup;
      if (_showPopup) {
        _showScanner = false;
      }
    });

    if (_showPopup) {
      if (_isSharingLiveLocation && _liveLocationSharingId != null) {
        Position pos = await Geolocator.getCurrentPosition();
        setState(() {
          _locationData = _encodeLocationData(
            pos.latitude,
            pos.longitude,
            isLive: true,
            sharingId: _liveLocationSharingId,
          );
        });
      } else {
        await _fetchLocation();
      }
    }
  }

  void _toggleScanner() {
    setState(() {
      _showScanner = !_showScanner;
      if (_showScanner) {
        _showPopup = false;
        _mobileScannerController = MobileScannerController();
      } else {
        _mobileScannerController?.dispose();
        _mobileScannerController = null;
      }
    });
  }

  void _viewMyLocation() {
    if (_currentPosition != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder:
              (context) => LocationViewPage(
                latitude: _currentPosition!.latitude,
                longitude: _currentPosition!.longitude,
                profilePicture: _userData?['profilePicture'],
                userName: _userData?['name'] ?? 'You',
                isLive: _isSharingLiveLocation,
                sharingId: _liveLocationSharingId,
              ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No location data available. Please fetch your location first.',
          ),
        ),
      );
    }
  }

  Future<void> _handleScannedCode(String code) async {
    if (_isHandlingQr) return;
    setState(() => _isHandlingQr = true);

    try {
      final decodedData = jsonDecode(code);
      String? sharingId;
      String? userName;
      String? profilePicture;
      String? userId;

      if (decodedData['sharingId'] != null) {
        sharingId = decodedData['sharingId'];
        userName = decodedData['userName'] ?? decodedData['user']?['name'];
        profilePicture = decodedData['profilePicture'] ?? decodedData['user']?['profilePicture'];
        userId = decodedData['userId'] ?? decodedData['user']?['userId'];
      } else if (decodedData['user'] != null) {
        // Universal fallback for older or different formatted codes
        userName = decodedData['user']['name'];
        profilePicture = decodedData['user']['profilePicture'];
        userId = decodedData['user']['userId'];
        sharingId = decodedData['sharingId'];
      }

      if (sharingId != null || (decodedData['type'] == 'static' && decodedData['latitude'] != null)) {
        final displayName = userName ?? 'Unknown User';
        
        // Confirmation dialog
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: const Text('New Connection', style: TextStyle(color: Colors.white)),
            content: Text(
              'View live location of $displayName?',
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
                child: const Text('View', style: TextStyle(color: Colors.black)),
              ),
            ],
          ),
        );

        if (confirmed == true && mounted) {
          // Save and Navigate
          _saveFamilyMember({
            'userId': userId ?? 'unknown_${DateTime.now().millisecondsSinceEpoch}',
            'name': displayName,
            'profilePicture': profilePicture,
            'locationData': code,
          });

          _navigateToLocationView(
            code,
            displayName,
            profilePicture,
          );
        }
      }
    } catch (e) {
      debugPrint('QR Code Decode Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read QR code. Pleast try again.')),
        );
      }
    } finally {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _isHandlingQr = false);
      });
    }
  }

  void _navigateToLocationView(
    String locationData,
    String userName,
    String? profilePicture,
  ) {
    try {
      final decodedData = jsonDecode(locationData);
      if (decodedData is Map<String, dynamic>) {
        if (decodedData['type'] == 'live') {
          final sharingId = decodedData['sharingId'] as String?;
          if (sharingId != null) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder:
                    (context) => LocationViewPage(
                      latitude: 0,
                      longitude: 0,
                      profilePicture: profilePicture,
                      userName: userName,
                      isLive: true,
                      sharingId: sharingId,
                    ),
              ),
            );
            return;
          }
        } else if (decodedData['type'] == 'static') {
          final lat = decodedData['latitude'] as double?;
          final lng = decodedData['longitude'] as double?;
          if (lat != null && lng != null) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder:
                    (context) => LocationViewPage(
                      latitude: lat,
                      longitude: lng,
                      profilePicture: profilePicture,
                      userName: userName,
                    ),
              ),
            );
            return;
          }
        }
      }
    } catch (e) {
      if (locationData.startsWith('live:')) {
        final sharingId = locationData.substring(5);
        Navigator.of(context).push(
          MaterialPageRoute(
            builder:
                (context) => LocationViewPage(
                  latitude: 0,
                  longitude: 0,
                  profilePicture: profilePicture,
                  userName: userName,
                  isLive: true,
                  sharingId: sharingId,
                ),
          ),
        );
      } else {
        final locationParts = locationData.split(',');
        if (locationParts.length == 2) {
          final lat = double.tryParse(locationParts[0]);
          final lng = double.tryParse(locationParts[1]);
          if (lat != null && lng != null) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder:
                    (context) => LocationViewPage(
                      latitude: lat,
                      longitude: lng,
                      profilePicture: profilePicture,
                      userName: userName,
                    ),
              ),
            );
          }
        }
      }
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Column(
          children: [
            Text(
              'FRT Tracking Hub',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            Text(
              'Live Secure Connection',
              style: TextStyle(fontSize: 10, color: Colors.white54, letterSpacing: 1.2),
            ),
          ],
        ),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            color: Colors.black,
            border: Border(bottom: BorderSide(color: Colors.white10)),
          ),
        ),
        actions: [
          if (_userData != null && _userData!['profilePicture'] != null)
            IconButton(
              icon: CircleAvatar(
                backgroundImage: NetworkImage(_userData!['profilePicture']),
                radius: 20,
              ),
              onPressed: _navigateToUserDetails,
            ),
        ],
      ),
      body: Stack(
        children: [
          if (_isLoading)
            const Center(child: CircularProgressIndicator())
          else if (_userData == null)
            const Center(child: Text('No user data found'))
          else
            Column(
              children: [
                // Active Sharing Status Bar
                if (_isSharingLiveLocation)
                  _buildLiveStatusBar(),
                
                const SizedBox(height: 10),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  child: Row(
                    children: [
                      Text(
                        "Tracked Circles",
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      Spacer(),
                      Icon(Icons.people_outline, color: Colors.white70),
                    ],
                  ),
                ),
                if (_familyMembers.isNotEmpty)
                  Expanded(
                    child: ListView.builder(
                      itemCount: _familyMembers.length,
                      itemBuilder: (context, index) {
                        final member = _familyMembers[index];
                        return _buildFamilyMemberCard(member, index);
                      },
                    ),
                  )
                else
                  const Expanded(
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                            Text(
                              'Scan QR codes to add family members',
                              style: TextStyle(fontSize: 16, color: Colors.white54),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          // App Tour Overlay
          if (_showTour)
            _buildTourOverlay(),
          Positioned(
            bottom: 20,
            right: 20,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_showPopup || _showScanner)
                  FloatingActionButton(
                    backgroundColor: Colors.red,
                    mini: true,
                    onPressed: () {
                      setState(() {
                        _showPopup = false;
                        _showScanner = false;
                        _mobileScannerController?.dispose();
                        _mobileScannerController = null;
                      });
                    },
                    child: const Icon(Icons.close),
                  ),
                const SizedBox(height: 10),
                FloatingActionButton(
                  backgroundColor: Colors.green,
                  onPressed: () {
                    showModalBottomSheet(
                      context: context,
                      builder:
                          (context) => Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ListTile(
                                leading: const Icon(Icons.qr_code_scanner),
                                title: const Text('Scan QR Code'),
                                onTap: () {
                                  Navigator.pop(context);
                                  _toggleScanner();
                                },
                              ),
                              if (!_isSharingLiveLocation)
                                ListTile(
                                  leading: const Icon(Icons.location_searching),
                                  title: const Text('Share Live Location'),
                                  onTap: () {
                                    Navigator.pop(context);
                                    _startLiveLocationSharing();
                                  },
                                ),
                              if (_isSharingLiveLocation)
                                ListTile(
                                  leading: const Icon(Icons.location_off),
                                  title: const Text(
                                    'Stop Sharing Live Location',
                                  ),
                                  onTap: () {
                                    Navigator.pop(context);
                                    _stopLiveLocationSharing();
                                  },
                                ),
                            ],
                          ),
                    );
                  },
                  child: const Icon(Icons.add),
                ),
              ],
            ),
          ),
          if (_showPopup)
            Center(
              child: Container(
                width: MediaQuery.of(context).size.width * 0.85,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: AppColors.primary.withOpacity(0.3)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.5),
                      blurRadius: 30,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.1),
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
                      ),
                      child: const Column(
                        children: [
                          Icon(Icons.qr_code_2, color: AppColors.primary, size: 40),
                          SizedBox(height: 8),
                          Text(
                            'Share Connection',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        children: [
                          if (_locationData != null)
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: QrImageView(
                                data: _locationData!,
                                version: QrVersions.auto,
                                size: 200.0,
                                eyeStyle: const QrEyeStyle(
                                  eyeShape: QrEyeShape.square,
                                  color: Colors.black,
                                ),
                                dataModuleStyle: const QrDataModuleStyle(
                                  dataModuleShape: QrDataModuleShape.square,
                                  color: Colors.black,
                                ),
                              ),
                            )
                          else
                            const SizedBox(
                              height: 200,
                              child: Center(child: CircularProgressIndicator(color: AppColors.primary)),
                            ),
                          const SizedBox(height: 24),
                          Text(
                            _isSharingLiveLocation
                                ? 'Scanning this code will track your live location in real-time.'
                                : 'Generic location sharing. Active sharing is currently OFF.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70, fontSize: 13),
                          ),
                          const SizedBox(height: 24),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: () => setState(() => _showPopup = false),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              ),
                              child: const Text('Close Portal', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_showScanner)
            Center(
              child: Container(
                width: MediaQuery.of(context).size.width * 0.9,
                height: MediaQuery.of(context).size.height * 0.7,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(32),
                  border: Border.all(color: Colors.white10),
                  boxShadow: [
                    BoxShadow(color: AppColors.primary.withOpacity(0.1), blurRadius: 40),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(30),
                  child: Stack(
                    children: [
                      MobileScanner(
                        controller: _mobileScannerController,
                        onDetect: (capture) {
                          final List<Barcode> barcodes = capture.barcodes;
                          for (final barcode in barcodes) {
                            final String? code = barcode.rawValue;
                            if (code != null && !_isHandlingQr) {
                              _handleScannedCode(code);
                            }
                          }
                        },
                      ),
                      // Scanner Overlay
                      CustomPaint(
                        painter: ScannerOverlayPainter(),
                        child: Container(),
                      ),
                      Positioned(
                        top: 20,
                        right: 20,
                        child: IconButton(
                          icon: const Icon(Icons.close, color: Colors.white, size: 30),
                          onPressed: () => setState(() => _showScanner = false),
                        ),
                      ),
                      const Positioned(
                        bottom: 40,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Text(
                            'Align QR code within the frame',
                            style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w500),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLiveStatusBar() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.primary.withOpacity(0.15), AppColors.primary.withOpacity(0.05)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.primary.withOpacity(0.3)),
        boxShadow: [
          BoxShadow(color: AppColors.primary.withOpacity(0.05), blurRadius: 20, spreadRadius: 5),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.satellite_alt, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Sharing Live Location",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
                Text(
                  "Background tracking active",
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () => setState(() => _showPopup = true),
            icon: const Icon(Icons.qr_code, size: 18, color: AppColors.primary),
            label: const Text("Show QR", style: TextStyle(color: AppColors.primary)),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteFamilyMember(int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Delete Connection', style: TextStyle(color: Colors.white)),
        content: Text(
          'Are you sure you want to remove ${_familyMembers[index]['name']}?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final memberToDelete = _familyMembers[index];
      setState(() {
        _familyMembers.removeAt(index);
      });
      
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(widget.userId)
            .collection('familyMembers')
            .doc(memberToDelete['userId'])
            .delete();
      } catch (e) {
        debugPrint('Error deleting connection from Firestore: $e');
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('family_members', jsonEncode(_familyMembers));
    }
  }

  Widget _buildFamilyMemberCard(Map<String, dynamic> member, int index) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white.withOpacity(0.08), Colors.transparent],
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () {
            if (member['locationData'] != null) {
              _navigateToLocationView(
                member['locationData'],
                member['name'] ?? 'Unknown',
                member['profilePicture'],
              );
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Stack(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(colors: [AppColors.primary, AppColors.secondary]),
                      ),
                      child: CircleAvatar(
                        backgroundImage: NetworkImage(member['profilePicture'] ?? ''),
                        radius: 30,
                        backgroundColor: AppColors.surface,
                      ),
                    ),
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: const Color(0xFF00C853),
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.background, width: 2),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        member['name'] ?? 'Unknown',
                        style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.link, size: 12, color: AppColors.primary.withOpacity(0.7)),
                          const SizedBox(width: 4),
                          const Text(
                            'Secure Connection',
                            style: TextStyle(color: Colors.black54, fontSize: 11),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.call_outlined, color: AppColors.primary),
                    onPressed: () => _initiateCall(member['userId'], member['name'] ?? 'Unknown'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                  onPressed: () => _deleteFamilyMember(index),
                ),
                const Icon(Icons.chevron_right, color: Colors.white24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showApprovalWelcomePopup(String promoCode) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: AppColors.primary.withOpacity(0.2)),
            boxShadow: [
              BoxShadow(color: AppColors.primary.withOpacity(0.1), blurRadius: 40, spreadRadius: 10),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.card_giftcard, color: AppColors.primary, size: 40),
              ),
              const SizedBox(height: 20),
              const Text(
                'Account Approved!',
                style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text(
                'As a welcome gift, we\'ve issued a connection code for you to gift to a family member.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      promoCode,
                      style: const TextStyle(
                        color: AppColors.primary,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Valid for 30 days • One-time use',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
              const SizedBox(height: 30),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Text('Start Tracking', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTourOverlay() {
    String title = "";
    String description = "";
    Alignment alignment = Alignment.center;

    switch (_tourStep) {
      case 1:
        title = "Welcome to FRT!";
        description = "Let's take a quick look at how to secure your family.";
        alignment = Alignment.center;
        break;
      case 2:
        title = "Share Your Location";
        description = "Tap the Green button below to generate your QR code and start sharing live.";
        alignment = Alignment.bottomRight;
        break;
      case 3:
        title = "Scan Connections";
        description = "Tap 'Scan QR Code' from the menu to add family members to your circles.";
        alignment = Alignment.bottomCenter;
        break;
      case 4:
        title = "Track Circles";
        description = "Your added family members will appear here. Tap any card to view them on the map.";
        alignment = Alignment.center;
        break;
      case 5:
        title = "Manage Profile";
        description = "Tap your avatar at the top right to manage your subscription and settings.";
        alignment = Alignment.topRight;
        break;
    }

    return GestureDetector(
      onTap: () {
        if (_tourStep < 5) {
          setState(() => _tourStep++);
        } else {
          _completeTour();
        }
      },
      child: Container(
        color: Colors.black.withOpacity(0.85),
        child: Stack(
          children: [
            Align(
              alignment: alignment,
              child: Padding(
                padding: const EdgeInsets.all(40.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_tourStep > 1)
                      const Icon(Icons.arrow_upward, color: AppColors.primary, size: 40),
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: AppColors.primary.withOpacity(0.3)),
                        boxShadow: [
                          BoxShadow(color: AppColors.primary.withOpacity(0.2), blurRadius: 30),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            description,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70, fontSize: 15),
                          ),
                          const SizedBox(height: 24),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              TextButton(
                                onPressed: _completeTour,
                                child: const Text("End Tour", style: TextStyle(color: Colors.white38)),
                              ),
                              ElevatedButton(
                                onPressed: () {
                                  if (_tourStep < 5) {
                                    setState(() => _tourStep++);
                                  } else {
                                    _completeTour();
                                  }
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primary,
                                  foregroundColor: Colors.black,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                child: Text(_tourStep == 5 ? "Finish" : "Next"),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void startLocationUpdates() async {
  LocationPermission permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    permission = await Geolocator.requestPermission();
  }

  final sharingId =
      await FlutterForegroundTask.getData(key: 'sharingId') as String?;
  final userId = await FlutterForegroundTask.getData(key: 'userId') as String?;
  final userName =
      await FlutterForegroundTask.getData(key: 'userName') as String? ??
      'Unknown';
  final profilePicture =
      await FlutterForegroundTask.getData(key: 'profilePicture') as String?;

  if (sharingId == null || userId == null) {
    FlutterForegroundTask.stopService();
    return;
  }

  // Monitor Calls in Background
  _startBackgroundCallMonitor(userId);

  Timer.periodic(const Duration(seconds: 5), (timer) async {
    try {
      // FORCE fresh GPS check in background to prevent stale data
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
        timeLimit: const Duration(seconds: 8),
      );

      // Only write if we have decent GPS lock (< 50m accuracy)
      if (position.accuracy <= 50) {
        final locData = {
          'userId': userId,
          'latitude': position.latitude,
          'longitude': position.longitude,
          'heading': position.heading,
          'speed': position.speed,
          'timestamp': FieldValue.serverTimestamp(),
          'userName': userName,
          'profilePicture': profilePicture,
        };

        await FirebaseFirestore.instance
            .collection('liveLocations')
            .doc(sharingId)
            .set(locData);

        FlutterForegroundTask.updateService(
          notificationTitle: 'FRT: Sharing Location',
          notificationText: 'Family members can see your live position.',
        );
      }
    } catch (e) {
      debugPrint('Background location refresh error: $e');
    }
  });

  FlutterForegroundTask.setOnLockScreenVisibility(true);
}

void _startBackgroundCallMonitor(String userId) {
  // Local Notifications Initialization
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/launcher_icon');
  const InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
  flutterLocalNotificationsPlugin.initialize(initializationSettings);

  FirebaseFirestore.instance
      .collection('calls')
      .where('receiverId', isEqualTo: userId)
      .snapshots()
      .listen((snapshot) {
    for (var change in snapshot.docChanges) {
      if (change.type == DocumentChangeType.added) {
        final data = change.doc.data();
        if (data != null && data['status'] == 'ringing') {
          // Play Ringtone
          FlutterRingtonePlayer().playRingtone();
          
          // Show Local Notification
          const AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
            'call_channel', 'Incoming Calls',
            importance: Importance.max,
            priority: Priority.high,
            fullScreenIntent: true,
          );
          const NotificationDetails platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);
          flutterLocalNotificationsPlugin.show(
            0, 'Incoming Call', 'Someone is calling you in FRT...',
            platformChannelSpecifics,
          );
        }
      } else if (change.type == DocumentChangeType.modified || change.type == DocumentChangeType.removed) {
        FlutterRingtonePlayer().stop();
      }
    }
  });
}

class ScannerOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black54
      ..style = PaintingStyle.fill;

    final rectPath = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    final scanWidth = size.width * 0.7;
    final scanHeight = size.width * 0.7;
    final scanRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: scanWidth,
      height: scanHeight,
    );

    final scanPath = Path()..addRRect(RRect.fromRectAndRadius(scanRect, const Radius.circular(20)));

    final combinedPath = Path.combine(PathOperation.difference, rectPath, scanPath);
    canvas.drawPath(combinedPath, paint);

    final borderPaint = Paint()
      ..color = AppColors.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    canvas.drawRRect(RRect.fromRectAndRadius(scanRect, const Radius.circular(20)), borderPaint);
    
    // Corner marks
    final markSize = 40.0;
    final markPaint = Paint()
      ..color = AppColors.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0;

    // Top Left
    canvas.drawPath(
      Path()
        ..moveTo(scanRect.left, scanRect.top + markSize)
        ..lineTo(scanRect.left, scanRect.top)
        ..lineTo(scanRect.left + markSize, scanRect.top),
      markPaint,
    );
    // Top Right
    canvas.drawPath(
      Path()
        ..moveTo(scanRect.right - markSize, scanRect.top)
        ..lineTo(scanRect.right, scanRect.top)
        ..lineTo(scanRect.right, scanRect.top + markSize),
      markPaint,
    );
    // Bottom Left
    canvas.drawPath(
      Path()
        ..moveTo(scanRect.left, scanRect.bottom - markSize)
        ..lineTo(scanRect.left, scanRect.bottom)
        ..lineTo(scanRect.left + markSize, scanRect.bottom),
      markPaint,
    );
    // Bottom Right
    canvas.drawPath(
      Path()
        ..moveTo(scanRect.right - markSize, scanRect.bottom)
        ..lineTo(scanRect.right, scanRect.bottom)
        ..lineTo(scanRect.right, scanRect.bottom - markSize),
      markPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
