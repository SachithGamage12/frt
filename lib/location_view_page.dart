import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

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
  static const String _googleApiKey = 'AIzaSyD5IB_VkfMz3avSYzIoS-UbcvNpt7cZD7M';

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
    final initialPosition = LatLng(widget.latitude, widget.longitude);
    _lastPosition = initialPosition;

    _pathPoints.clear();
    _rawPoints.clear();
    _markers.clear();
    _polylines.clear();
    _circles.clear();

    if (!widget.isLive) {
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

  void _addMarker(LatLng position, [double? heading]) {
    setState(() {
      _markers.clear();
      _circles.clear(); // Clear previous circles
      _markers.add(
        Marker(
          markerId: const MarkerId('userLocation'),
          position: position,
          infoWindow: InfoWindow(title: widget.userName),
          icon: _personIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
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
            radius: 10,
            fillColor: Colors.purple.withOpacity(0.3),
            strokeColor: Colors.purple,
            strokeWidth: 1,
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
            color: Colors.purple, // Changed to purple
            width: 6,
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
    _locationSubscription = FirebaseFirestore.instance
        .collection('liveLocations')
        .doc(widget.sharingId)
        .snapshots()
        .listen((snapshot) {
      if (snapshot.exists && mounted) {
        final data = snapshot.data();
        final lat = data?['latitude'] as double?;
        final lng = data?['longitude'] as double?;
        final heading = data?['heading'] as double? ?? 0;

        if (lat != null && lng != null) {
          print('Received update: lat=$lat, lng=$lng, heading=$heading');
          final newPosition = LatLng(lat, lng);

          double distance = 0;
          if (_lastPosition != null) {
            distance = Geolocator.distanceBetween(
              _lastPosition!.latitude,
              _lastPosition!.longitude,
              newPosition.latitude,
              newPosition.longitude,
            );
          }

          if (distance > 5 || _rawPoints.isEmpty) {
            setState(() {
              _rawPoints.add(newPosition); // Store raw point for snapping
              _pathPoints.add(newPosition); // Add to path for immediate drawing
              _lastPosition = newPosition;
              _addMarker(newPosition, heading);
              _isLocationAvailable = true;
              _updatePolyline(); // Update polyline with new point
            });

            _updateCamera(newPosition);
          }
        } else {
          setState(() {
            _isLocationAvailable = false;
          });
        }
      } else {
        setState(() {
          _isLocationAvailable = false;
        });
      }
    }, onError: (e) {
      print('Firestore listener error: $e');
      setState(() {
        _isLocationAvailable = false;
      });
    });
  }

  void _showUserProfile() {
    showModalBottomSheet(
      context: context,
      builder: (context) => Container(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.profilePicture != null)
              CircleAvatar(
                backgroundImage: NetworkImage(widget.profilePicture!),
                radius: 40,
              ),
            const SizedBox(height: 16),
            Text(
              widget.userName,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _isLocationAvailable
                  ? (widget.isLive ? 'Sharing live location' : 'Location shared')
                  : 'Location unavailable',
              style: TextStyle(
                color: _isLocationAvailable ? Colors.grey[600] : Colors.red,
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Tracking ${widget.userName}',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: Colors.white,
        elevation: 1,
        iconTheme: const IconThemeData(color: Colors.black),
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
            myLocationEnabled: true,
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
            bottom: 100,
            child: Column(
              children: [
                FloatingActionButton(
                  heroTag: 'center',
                  mini: true,
                  backgroundColor: Colors.white,
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
                  child: const Icon(Icons.gps_fixed, size: 20, color: Colors.black),
                ),
                const SizedBox(height: 8),
                FloatingActionButton(
                  heroTag: 'zoomIn',
                  mini: true,
                  backgroundColor: Colors.white,
                  onPressed: () {
                    _mapController.animateCamera(CameraUpdate.zoomIn());
                  },
                  child: const Icon(Icons.add, size: 20, color: Colors.black),
                ),
                const SizedBox(height: 8),
                FloatingActionButton(
                  heroTag: 'zoomOut',
                  mini: true,
                  backgroundColor: Colors.white,
                  onPressed: () {
                    _mapController.animateCamera(CameraUpdate.zoomOut());
                  },
                  child: const Icon(Icons.remove, size: 20, color: Colors.black),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: GestureDetector(
              onTap: _showUserProfile,
              child: Container(
                height: 80,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 8,
                      offset: const Offset(0, -2),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    if (widget.profilePicture != null)
                      CircleAvatar(
                        backgroundImage: NetworkImage(widget.profilePicture!),
                        radius: 20,
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.userName,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            _isLocationAvailable
                                ? (widget.isLive ? 'Live location sharing' : 'Location shared')
                                : 'Location unavailable',
                            style: TextStyle(
                              color: _isLocationAvailable ? Colors.grey[600] : Colors.red,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      _isLocationAvailable
                          ? (widget.isLive ? Icons.location_on : Icons.location_history)
                          : Icons.location_off,
                      color: _isLocationAvailable ? Colors.blue : Colors.red,
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