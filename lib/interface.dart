import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
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
  bool _isSharingLiveLocation = false;
  String? _liveLocationSharingId;
  List<Map<String, dynamic>> _familyMembers = [];
  StreamSubscription<DocumentSnapshot>? _callSubscription;
  bool _isCallDialogShowing = false;

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
              await FirebaseFirestore.instance.collection('calls').doc(widget.userId).delete().catchError((e){});
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
    await FirebaseFirestore.instance.collection('calls').doc(targetUserId).set({
      'callerId': widget.userId,
      'callerName': _userData?['name'] ?? 'Family Member',
      'channelName': channelName,
      'timestamp': FieldValue.serverTimestamp(),
    });

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
    _stopLiveLocationSharing();
    FlutterForegroundTask.stopService();
    _callSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _isSharingLiveLocation) {
      _startForegroundTask();
    } else if (state == AppLifecycleState.resumed) {
      FlutterForegroundTask.stopService();
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
        await FirebaseFirestore.instance
            .collection('users')
            .doc(widget.userId)
            .collection('familyMembers')
            .doc(userId)
            .set({
              'userId': userId,
              'name': userData['name'],
              'profilePicture': userData['profilePicture'],
              'locationData': userData['locationData'],
              'timestamp': FieldValue.serverTimestamp(),
            });

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
        _locationData = _encodeLocationData(
          0,
          0,
          isLive: true,
          sharingId: sharingId,
        );
      });
      await _startForegroundTask();
    }
  }

  Future<void> _startLiveLocationSharing() async {
    if (!await _checkLocationPermission()) return;

    String? sharingId;

    // Check if there's an existing sharingId in Firestore
    final userDoc =
        await FirebaseFirestore.instance
            .collection('users')
            .doc(widget.userId)
            .collection('liveSharing')
            .doc('current')
            .get();

    if (userDoc.exists && userDoc.data()?['sharingId'] != null) {
      sharingId = userDoc.data()!['sharingId'] as String;
    } else {
      // Generate a new sharingId if none exists
      sharingId =
          FirebaseFirestore.instance.collection('liveLocations').doc().id;
      // Save the new sharingId to Firestore
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.userId)
          .collection('liveSharing')
          .doc('current')
          .set({
            'sharingId': sharingId,
            'createdAt': FieldValue.serverTimestamp(),
          });
    }

    setState(() {
      _isSharingLiveLocation = true;
      _liveLocationSharingId = sharingId;
    });

    // Save data for foreground task
    await FlutterForegroundTask.saveData(key: 'sharingId', value: sharingId);
    await FlutterForegroundTask.saveData(key: 'userId', value: widget.userId);
    await FlutterForegroundTask.saveData(
      key: 'userName',
      value: _userData?['name'] ?? 'Unknown',
    );
    await FlutterForegroundTask.saveData(
      key: 'profilePicture',
      value: _userData?['profilePicture'] ?? '',
    );

    // Get initial position and save to Firestore
    Position initialPosition = await Geolocator.getCurrentPosition();
    await FirebaseFirestore.instance
        .collection('liveLocations')
        .doc(sharingId)
        .set({
          'userId': widget.userId,
          'latitude': initialPosition.latitude,
          'longitude': initialPosition.longitude,
          'heading': initialPosition.heading,
          'speed': initialPosition.speed,
          'timestamp': FieldValue.serverTimestamp(),
          'userName': _userData?['name'] ?? 'Unknown',
          'profilePicture': _userData?['profilePicture'],
        });

    // Start position stream
    _positionStream?.cancel();
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 5,
      ),
    ).listen(
      (Position position) async {
        await FirebaseFirestore.instance
            .collection('liveLocations')
            .doc(sharingId)
            .set({
              'userId': widget.userId,
              'latitude': position.latitude,
              'longitude': position.longitude,
              'heading': position.heading,
              'speed': position.speed,
              'timestamp': FieldValue.serverTimestamp(),
              'userName': _userData?['name'] ?? 'Unknown',
              'profilePicture': _userData?['profilePicture'],
            });
      },
      onError: (e) {
        print('Position stream error: $e');
      },
    );

    await _startForegroundTask();

    setState(() {
      _locationData = _encodeLocationData(
        0,
        0,
        isLive: true,
        sharingId: sharingId,
      );
      _showPopup = true;
    });
  }

  String _encodeLocationData(
    double lat,
    double lng, {
    bool isLive = false,
    String? sharingId,
  }) {
    final userData = {
      'userId': widget.userId,
      'name': _userData?['name'] ?? 'Unknown',
      'profilePicture': _userData?['profilePicture'],
      'phone': _userData?['phone'],
      'email': _userData?['email'],
    };

    if (isLive && sharingId != null) {
      return jsonEncode({
        'type': 'live',
        'sharingId': sharingId,
        'user': userData,
        'timestamp': DateTime.now().toIso8601String(),
      });
    } else {
      return jsonEncode({
        'type': 'static',
        'latitude': lat,
        'longitude': lng,
        'user': userData,
        'timestamp': DateTime.now().toIso8601String(),
      });
    }
  }

  Future<void> _stopLiveLocationSharing() async {
    if (_liveLocationSharingId != null) {
      await FirebaseFirestore.instance
          .collection('liveLocations')
          .doc(_liveLocationSharingId)
          .delete();
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
        setState(() {
          _locationData = _encodeLocationData(
            0,
            0,
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

  void _handleScannedCode(String code) {
    try {
      final decodedData = jsonDecode(code);
      if (decodedData is Map<String, dynamic>) {
        final userData = decodedData['user'] as Map<String, dynamic>?;
        final userName = userData?['name'] ?? 'Unknown';
        final profilePicture = userData?['profilePicture'];
        final userId = userData?['userId'];

        if (userId != null && userData != null) {
          _saveFamilyMember({
            'userId': userId,
            'name': userName,
            'profilePicture': profilePicture,
            'locationData': code,
          });
        }

        _showScannedUserProfile(
          userName: userName,
          profilePicture: profilePicture,
          locationData: code,
          userId: userId,
        );
      }
    } catch (e) {
      if (code.startsWith('live:')) {
        _showScannedUserProfile(userName: 'Unknown User', locationData: code);
      } else {
        _showScannedUserProfile(
          userName: 'Unknown Location',
          locationData: code,
        );
      }
    }
  }

  void _showScannedUserProfile({
    required String userName,
    String? profilePicture,
    required String locationData,
    String? userId,
  }) {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            contentPadding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (profilePicture != null)
                  Container(
                    height: 200,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(16),
                      ),
                      image: DecorationImage(
                        image: NetworkImage(profilePicture),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Text(
                        userName,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Tap to view location',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () {
                          Navigator.pop(context);
                          _navigateToLocationView(
                            locationData,
                            userName,
                            profilePicture,
                          );
                        },
                        child: const Text('VIEW LOCATION'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
    );
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
      appBar: AppBar(
        title: const Text(
          'FRT Tracking Hub',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.black),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
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
                      Icon(Icons.people_outline, color: AppColors.primary),
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
                          Icon(Icons.qr_code_2, size: 80, color: Colors.white24),
                          SizedBox(height: 16),
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
                width: MediaQuery.of(context).size.width * 0.8,
                height: MediaQuery.of(context).size.height * 0.4,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 10,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_locationData != null)
                      QrImageView(
                        data: _locationData!,
                        version: QrVersions.auto,
                        size: 200.0,
                      )
                    else
                      const CircularProgressIndicator(),
                    const SizedBox(height: 20),
                    Text(
                      _isSharingLiveLocation
                          ? 'Scan this QR code to track my live location'
                          : 'Scan this QR code to fetch my location',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          if (_showScanner)
            Center(
              child: Container(
                width: MediaQuery.of(context).size.width * 0.8,
                height: MediaQuery.of(context).size.height * 0.6,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 10,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text(
                        'Scan a QR Code',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Expanded(
                      child: MobileScanner(
                        controller: _mobileScannerController,
                        onDetect: (capture) {
                          final List<Barcode> barcodes = capture.barcodes;
                          for (final barcode in barcodes) {
                            final String? code = barcode.rawValue;
                            if (code != null) {
                              _handleScannedCode(code);
                              break;
                            }
                          }
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: ElevatedButton(
                        onPressed: () {
                          setState(() {
                            _showScanner = false;
                          });
                        },
                        child: const Text('Cancel'),
                      ),
                    ),
                  ],
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
        color: AppColors.primary.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.primary.withOpacity(0.3)),
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

  Widget _buildFamilyMemberCard(Map<String, dynamic> member, int index) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Stack(
          children: [
            CircleAvatar(
              backgroundImage: NetworkImage(member['profilePicture'] ?? ''),
              radius: 28,
              backgroundColor: Colors.white10,
            ),
            Positioned(
              right: 2,
              bottom: 2,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.background, width: 2),
                ),
              ),
            ),
          ],
        ),
        title: Text(
          member['name'] ?? 'Unknown',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        subtitle: const Text(
          'Connected • Tap to track',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        trailing: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: IconButton(
            icon: const Icon(Icons.call, color: AppColors.primary, size: 20),
            onPressed: () => _initiateCall(member['userId'], member['name'] ?? 'Unknown'),
          ),
        ),
        onTap: () {
          if (member['locationData'] != null) {
            _navigateToLocationView(
              member['locationData'],
              member['name'] ?? 'Unknown',
              member['profilePicture'],
            );
          }
        },
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

  StreamSubscription<Position>? positionStream;
  positionStream = Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 5,
    ),
  ).listen(
    (Position position) async {
      await FirebaseFirestore.instance
          .collection('liveLocations')
          .doc(sharingId)
          .set({
            'userId': userId,
            'latitude': position.latitude,
            'longitude': position.longitude,
            'heading': position.heading,
            'speed': position.speed,
            'timestamp': FieldValue.serverTimestamp(),
            'userName': userName,
            'profilePicture': profilePicture,
          });

      FlutterForegroundTask.updateService(
        notificationTitle: 'Sharing Live Location',
        notificationText: 'Your location is being shared with family members.',
      );
    },
    onError: (e) {
      print('Foreground position stream error: $e');
      positionStream?.cancel();
    },
  );

  FlutterForegroundTask.setOnLockScreenVisibility(true);
}
