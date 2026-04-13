import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'style_utils.dart';

class LocationViewPage extends StatefulWidget {
  final double latitude;
  final double longitude;
  final String? profilePicture;
  final String userName;
  final bool isLive;
  final String? sharingId;

  const LocationViewPage({
    super.key,
    required this.latitude,
    required this.longitude,
    this.profilePicture,
    required this.userName,
    this.isLive = false,
    this.sharingId,
  });

  @override
  _LocationViewPageState createState() => _LocationViewPageState();
}

class _LocationViewPageState extends State<LocationViewPage> {
  late GoogleMapController _mapController;
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  final Set<Circle> _circles = {}; // Added for pulsing indicator
  List<LatLng> _pathPoints = [];
  List<LatLng> _rawPoints = []; // Store raw points for snapping
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _locationSubscription;
  BitmapDescriptor? _personIcon;
  bool _initialPositionSet = false;
  LatLng? _lastPosition;
  bool _isLocationAvailable = true;
  Timer? _snapTimer; // Timer for periodic snapping

  // Google Maps API key (replace with your key if different)
  static const String _googleApiKey = 'AIzaSyBWRGXCiqYgZWCuxwlnosDjtuHZAC7SZjg';

  @override
  void initState() {
    super.initState();
    _loadCustomMarker().then((_) {
      _initializeLocation();
    });
  }

  Future<void> _loadCustomMarker() async {
    try {
      _personIcon = await BitmapDescriptor.fromAssetImage(
        const ImageConfiguration(size: Size(48, 48)),
        'assets/car_marker.png',
      );
    } catch (e) {
      print('Error loading custom marker: $e');
      _personIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue);
    }
  }

  @override
  void dispose() {
    _locationSubscription?.cancel();
    _snapTimer?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  void _initializeLocation() {
    LatLng? initialPosition;
    if (widget.latitude != 0 || widget.longitude != 0) {
      initialPosition = LatLng(widget.latitude, widget.longitude);
      _lastPosition = initialPosition;
    } else {
      _lastPosition = null; // Don't set to 0,0 for live tracking
    }

    _pathPoints.clear();
    _rawPoints.clear();
    _markers.clear();
    _polylines.clear();
    _circles.clear();

    if (initialPosition != null) {
      _addMarker(initialPosition);
      _updateCamera(initialPosition);
    }

    if (widget.isLive && widget.sharingId != null) {
      _startLiveTracking();
      // Start timer to snap points to roads every 10 seconds
      _snapTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        if (_rawPoints.length >= 2) {
          _snapToRoads();
        }
      });
    }
  }

  void _addMarker(LatLng position, [double? heading, String? dynamicName]) {
    setState(() {
      _markers.clear();
      _circles.clear(); // Clear previous circles
      _markers.add(
        Marker(
          markerId: const MarkerId('userLocation'),
          position: position,
          infoWindow: InfoWindow(title: dynamicName ?? widget.userName),
          icon: _personIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          rotation: heading ?? 0,
          anchor: const Offset(0.5, 0.5),
          zIndex: 2,
          flat: false,
        ),
      );
      if (widget.isLive) {
        // Add pulsing circle for live indicator
        _circles.add(
          Circle(
            circleId: const CircleId('liveIndicator'),
            center: position,
            radius: 12,
            fillColor: AppColors.primary.withOpacity(0.2),
            strokeColor: AppColors.primary,
            strokeWidth: 2,
            zIndex: 1,
          ),
        );
      }
    });
  }

  void _updateCamera(LatLng position) {
    if (!_initialPositionSet) {
      _mapController.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: position,
            zoom: 18,
            tilt: 60,
            bearing: 30,
          ),
        ),
      );
      _initialPositionSet = true;
    } else {
      _mapController.animateCamera(
        CameraUpdate.newLatLng(position),
      );
    }
  }

  void _updatePolyline() {
    setState(() {
      _polylines.clear();
      if (_pathPoints.length >= 2) {
        _polylines.add(
          Polyline(
            polylineId: const PolylineId('userPath'),
            points: _pathPoints,
            color: AppColors.primary.withOpacity(0.8),
            width: 8,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
            zIndex: 1,
          ),
        );
      }
    });
  }

  Future<void> _snapToRoads() async {
    if (_rawPoints.isEmpty) return;

    // Prepare path string for API (lat,lng|lat,lng|...)
    final path = _rawPoints
        .map((point) => '${point.latitude},${point.longitude}')
        .join('|');

    final url = Uri.parse(
      'https://roads.googleapis.com/v1/snapToRoads?path=$path&interpolate=true&key=$_googleApiKey',
    );

    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final snappedPoints = data['snappedPoints'] as List<dynamic>;

        final newPathPoints = <LatLng>[];
        for (var point in snappedPoints) {
          final location = point['location'];
          newPathPoints.add(LatLng(
            location['latitude'] as double,
            location['longitude'] as double,
          ));
        }

        setState(() {
          _pathPoints = newPathPoints;
          _updatePolyline();
        });
      } else {
        print('Snap to Roads API error: ${response.statusCode}');
      }
    } catch (e) {
      print('Error snapping to roads: $e');
    }
  }

  void _startLiveTracking() {
    _locationSubscription?.cancel();
    // Listen to PRIMARY project (Unified)
    _locationSubscription = FirebaseFirestore.instance
        .collection('liveLocations')
        .doc(widget.sharingId)
        .snapshots()
        .listen((snapshot) {
      if (snapshot.exists && snapshot.data() != null) {
        _processLocationSnapshot(snapshot.data());
      }
    });


    // Use a timer to show 'unavailable' if NO live updates are received
    Future.delayed(const Duration(seconds: 10), () {
      if (mounted && _rawPoints.isEmpty) {
        // We only show unavailable if we haven't received ANY live movement updates
        // BUT we still have the initial marker from the QR code.
        setState(() => _isLocationAvailable = false);
      }
    });
  }


  void _reconnect() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Attempting to reconnect...'), duration: Duration(seconds: 1)),
    );
    setState(() {
      _isLocationAvailable = true; // Temporary reset
    });
    _startLiveTracking();
    _fetchInitialPosition();
  }

  Future<void> _fetchInitialPosition() async {
    try {
      // Primary Project Fetch
      var doc = await FirebaseFirestore.instance.collection('liveLocations').doc(widget.sharingId).get();
      if (doc.exists && doc.data() != null) {
        _processLocationSnapshot(doc.data());
      }
    } catch (e) {
      debugPrint('Initial position fetch error: $e');
    }
  }

  void _processLocationSnapshot(Map<String, dynamic>? data) {
    if (data == null || !mounted) return;
    
    final lat = data['latitude'] is int ? (data['latitude'] as int).toDouble() : data['latitude'] as double?;
    final lng = data['longitude'] is int ? (data['longitude'] as int).toDouble() : data['longitude'] as double?;
    final heading = data['heading'] is int ? (data['heading'] as int).toDouble() : data['heading'] as double?;

    if (lat != null && lng != null && (lat != 0 || lng != 0)) {
      final newPosition = LatLng(lat, lng);
      
      // Update userName if provided dynamically from the stream
      if (data.containsKey('userName') && data['userName'] != 'Unknown') {
        // Fallback or update if the widget passed 'Unknown' originally
      }

      double distance = 100; // Force update if no last position
      if (_lastPosition != null) {
        distance = Geolocator.distanceBetween(
          _lastPosition!.latitude,
          _lastPosition!.longitude,
          newPosition.latitude,
          newPosition.longitude,
        );
      }

      // Always update the marker and camera to the newest point immediately
      setState(() {
        _lastPosition = newPosition;
        
        final displayName = (widget.userName == 'Unknown User' || widget.userName == 'Unknown') && data['userName'] != null
            ? data['userName']
            : widget.userName;
            
        _addMarker(newPosition, heading, displayName);
        _isLocationAvailable = true;
      });
      _updateCamera(newPosition);

      // Only add to the drawn path if we moved more than 0.5 meters
      if (distance > 0.5 || _rawPoints.isEmpty) {
        setState(() {
          _rawPoints.add(newPosition);
          _pathPoints.add(newPosition);
          _updatePolyline();
        });
      }
    } else {
      setState(() {
        _isLocationAvailable = false;
      });
    }
  }

  void _showUserProfile() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.profilePicture != null)
              CircleAvatar(
                backgroundImage: NetworkImage(widget.profilePicture!),
                radius: 45,
                backgroundColor: Colors.white10,
              ),
            const SizedBox(height: 20),
            Text(
              widget.userName.toUpperCase(),
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: Colors.white,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: _isLocationAvailable ? AppColors.primary.withOpacity(0.1) : Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _isLocationAvailable
                    ? (widget.isLive ? 'LIVE TRACKING ACTIVE' : 'LOCATION SYNCED')
                    : 'SIGNAL LOST',
                style: TextStyle(
                  color: _isLocationAvailable ? AppColors.primary : Colors.redAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          widget.userName,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w900,
            color: Colors.white,
          ),
        ),
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.white10)),
          ),
        ),
        actions: [
          if (widget.profilePicture != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: CircleAvatar(
                  backgroundImage: NetworkImage(widget.profilePicture!),
                  radius: 16,
                ),
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: LatLng(widget.latitude, widget.longitude),
              zoom: 18,
              tilt: 60,
            ),
            mapType: MapType.normal,
            markers: _markers,
            polylines: _polylines,
            circles: _circles, // Added for pulsing indicator
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            compassEnabled: true,
            mapToolbarEnabled: false,
            zoomControlsEnabled: false,
            buildingsEnabled: true,
            rotateGesturesEnabled: true,
            onMapCreated: (controller) {
              _mapController = controller;
              _setDetailedMapStyle();
              if (!widget.isLive) {
                _updateCamera(LatLng(widget.latitude, widget.longitude));
              }
            },
          ),
          if (!_isLocationAvailable && widget.isLive)
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(8),
                color: Colors.red.withOpacity(0.8),
                child: const Text(
                  'Live location temporarily unavailable',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          if (widget.isLive && _markers.isEmpty && _isLocationAvailable)
            const Center(
              child: CircularProgressIndicator(),
            ),
          Positioned(
            right: 16,
            bottom: 40,
            child: Column(
              children: [
                _buildMapFab(
                  icon: Icons.refresh,
                  onPressed: _reconnect,
                ),
                const SizedBox(height: 12),
                _buildMapFab(
                  icon: Icons.gps_fixed,
                  onPressed: () {
                    if (_markers.isNotEmpty) {
                      _mapController.animateCamera(
                        CameraUpdate.newCameraPosition(
                          CameraPosition(
                            target: _markers.first.position,
                            zoom: 18,
                            tilt: 60,
                            bearing: _markers.first.rotation,
                          ),
                        ),
                      );
                    }
                  },
                ),
                const SizedBox(height: 12),
                _buildMapFab(
                  icon: Icons.add,
                  onPressed: () => _mapController.animateCamera(CameraUpdate.zoomIn()),
                ),
                const SizedBox(height: 12),
                _buildMapFab(
                  icon: Icons.remove,
                  onPressed: () => _mapController.animateCamera(CameraUpdate.zoomOut()),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: GestureDetector(
              onTap: _showUserProfile,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white10),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 15, offset: const Offset(0, 5)),
                  ],
                ),
                child: Row(
                  children: [
                    if (widget.profilePicture != null)
                      CircleAvatar(
                        backgroundImage: NetworkImage(widget.profilePicture!),
                        radius: 24,
                        backgroundColor: Colors.white10,
                      ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.userName,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white),
                          ),
                          Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: _isLocationAvailable ? AppColors.primary : Colors.red,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _isLocationAvailable
                                    ? (widget.isLive ? 'Live Tracking' : 'Last Seen')
                                    : 'Offline',
                                style: const TextStyle(color: Colors.white54, fontSize: 13),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.expand_less, color: Colors.white24),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMapFab({required IconData icon, required VoidCallback onPressed}) {
    return FloatingActionButton(
      heroTag: null,
      mini: true,
      backgroundColor: AppColors.surface,
      elevation: 4,
      onPressed: onPressed,
      child: Icon(icon, color: AppColors.primary, size: 20),
    );
  }

  Future<void> _setDetailedMapStyle() async {
    String style = '''
      [
        {
          "elementType": "geometry",
          "stylers": [
            {
              "color": "#f5f5f5"
            }
          ]
        },
        {
          "elementType": "labels.text.fill",
          "stylers": [
            {
              "color": "#616161"
            }
          ]
        },
        {
          "elementType": "labels.text.stroke",
          "stylers": [
            {
              "color": "#f5f5f5"
            }
          ]
        },
        {
          "featureType": "administrative",
          "elementType": "geometry.stroke",
          "stylers": [
            {
              "color": "#c9b2a6"
            }
          ]
        },
        {
          "featureType": "administrative.land_parcel",
          "elementType": "geometry.stroke",
          "stylers": [
            {
              "color": "#dcd2be"
            }
          ]
        },
        {
          "featureType": "administrative.land_parcel",
          "elementType": "labels.text.fill",
          "stylers": [
            {
              "color": "#ae9e90"
            }
          ]
        },
        {
          "featureType": "landscape.natural",
          "elementType": "geometry",
          "stylers": [
            {
              "color": "#dfe7e2"
            }
          ]
        },
        {
          "featureType": "poi",
          "elementType": "geometry",
          "stylers": [
            {
              "color": "#dfe7e2"
            }
          ]
        },
        {
          "featureType": "poi",
          "elementType": "labels.text.fill",
          "stylers": [
            {
              "color": "#93817c"
            }
          ]
        },
        {
          "featureType": "poi.park",
          "elementType": "geometry.fill",
          "stylers": [
            {
              "color": "#a5b076"
            }
          ]
        },
        {
          "featureType": "poi.park",
          "elementType": "labels.text.fill",
          "stylers": [
            {
              "color": "#447530"
            }
          ]
        },
        {
          "featureType": "road",
          "elementType": "geometry",
          "stylers": [
            {
              "color": "#ffffff"
            }
          ]
        },
        {
          "featureType": "road.arterial",
          "elementType": "geometry",
          "stylers": [
            {
              "color": "#fdfcf8"
            }
          ]
        },
        {
          "featureType": "road.highway",
          "elementType": "geometry",
          "stylers": [
            {
              "color": "#f8c967"
            }
          ]
        },
        {
          "featureType": "road.highway",
          "elementType": "geometry.stroke",
          "stylers": [
            {
              "color": "#e9bc62"
            }
          ]
        },
        {
          "featureType": "road.highway.controlled_access",
          "elementType": "geometry",
          "stylers": [
            {
              "color": "#e98d58"
            }
          ]
        },
        {
          "featureType": "road.highway.controlled_access",
          "elementType": "geometry.stroke",
          "stylers": [
            {
              "color": "#db8555"
            }
          ]
        },
        {
          "featureType": "road.local",
          "elementType": "labels.text.fill",
          "stylers": [
            {
              "color": "#806b63"
            }
          ]
        },
        {
          "featureType": "transit.line",
          "elementType": "geometry",
          "stylers": [
            {
              "color": "#dfd2ae"
            }
          ]
        },
        {
          "featureType": "transit.line",
          "elementType": "labels.text.fill",
          "stylers": [
            {
              "color": "#8f7d77"
            }
          ]
        },
        {
          "featureType": "transit.line",
          "elementType": "labels.text.stroke",
          "stylers": [
            {
              "color": "#ebe3cd"
            }
          ]
        },
        {
          "featureType": "transit.station",
          "elementType": "geometry",
          "stylers": [
            {
              "color": "#dfd2ae"
            }
          ]
        },
        {
          "featureType": "water",
          "elementType": "geometry.fill",
          "stylers": [
            {
              "color": "#b9d3c2"
            }
          ]
        },
        {
          "featureType": "water",
          "elementType": "labels.text.fill",
          "stylers": [
            {
              "color": "#92998d"
            }
          ]
        }
      ]
    ''';

    await _mapController.setMapStyle(style);
  }
}