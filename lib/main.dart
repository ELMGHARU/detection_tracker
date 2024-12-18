import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'dart:math' show pi;
import 'package:flutter/foundation.dart' show kIsWeb;


void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Navigation Map',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const MapScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // Controllers
  final MapController _mapController = MapController();
  final TextEditingController _originController = TextEditingController();
  final TextEditingController _destinationController = TextEditingController();

  // Collections
  final List<Marker> _markers = [];
  final List<LatLng> _navigationTrack = [];
  List<LatLng> _routePoints = [];
  List<LatLng> _remainingRoute = [];
  List<Map<String, dynamic>> _searchSuggestions = [];
  List<Map<String, dynamic>> _navigationSteps = [];

  // Position related
  LatLng? _currentPosition;
  LatLng? _destination;
  LatLng? _snappedPosition;
  Position? _lastPosition;

  // Navigation state
  bool _isLoading = false;
  bool _isNavigating = false;
  int _currentStepIndex = 0;
  int _lastRouteIndex = 0;
  double _bearing = 0.0;
  double _distanceToDestination = 0.0;
  String _nextInstruction = '';
  Duration _estimatedTime = Duration.zero;
  StreamSubscription<Position>? _positionStreamSubscription;
  bool _isLoggingPosition = true;

  @override
  void initState() {
    super.initState();
    _initializeLocation();
  }

  @override
  void dispose() {
    _stopNavigation();
    _originController.dispose();
    _destinationController.dispose();
    super.dispose();
  }
  Future<void> _initializeLocation() async {
    if (kIsWeb) {
      // For web, just get the location directly
      _getCurrentLocation();
    } else {
      // For mobile platforms, check permissions first
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showError('Les services de localisation sont désactivés');
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _showError('Permission de localisation refusée');
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _showError('Les permissions de localisation sont définitivement refusées');
        return;
      }

      _getCurrentLocation();
    }
  }

  Future<void> _getCurrentLocation() async {
    setState(() {
      _isLoading = true;
    });

    try {
      if (kIsWeb) {
        // Mock location for web testing
        setState(() {
          _currentPosition = LatLng(31.7917, -7.0926);
          _updateMarkers();
          _mapController.move(_currentPosition!, 16.0);
        });
        
        if (_isLoggingPosition) {
          print('\n=== Initial Position (Web Mock) ===');
          print('Position: ${_currentPosition!.latitude}, ${_currentPosition!.longitude}');
          print('====================\n');
        }
      } else {
        Position position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.bestForNavigation
        );

        if (_isLoggingPosition) {
          print('\n=== Initial Position ===');
          print('Position: ${position.latitude}, ${position.longitude}');
          print('Accuracy: ${position.accuracy} meters');
          print('Altitude: ${position.altitude} meters');
          print('Speed: ${position.speed} m/s');
          print('====================\n');
        }

        if (!mounted) return;
        
        setState(() {
          _currentPosition = LatLng(position.latitude, position.longitude);
          _lastPosition = position;
          _updateMarkers();
          _mapController.move(_currentPosition!, 16.0);
        });
      }

      await _updateOriginAddress();
    } catch (e) {
      if (!mounted) return;
      print('Location Error: $e');
      _showError('Erreur de localisation: $e');
    } finally {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    }
  }

Future<void> _getCurrentPositionFallback() async {
    try {
      if (kIsWeb) {
        // Mock position for web
        _handlePositionUpdate(
          Position(
            latitude: 31.7917,
            longitude: -7.0926,
            timestamp: DateTime.now(),
            accuracy: 0,
            altitude: 0,
            heading: 0,
            speed: 0,
            speedAccuracy: 0,
            altitudeAccuracy: 0,
            headingAccuracy: 0,
          ),
        );
        return;
      }

      Position? position = await Geolocator.getLastKnownPosition();
      position ??= await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
        timeLimit: const Duration(seconds: 30),
      );

      if (!mounted) return;

      bool hasMoved = true;
      if (_lastPosition != null) {
        double distance = Geolocator.distanceBetween(
          _lastPosition!.latitude,
          _lastPosition!.longitude,
          position.latitude,
          position.longitude,
        );
        hasMoved = distance > 5; // Only update if moved more than 5 meters
      }

      if (hasMoved) {
        _handlePositionUpdate(position);
      }
    } catch (e) {
      if (!mounted) return;
      print('Fallback Position Error: \$e');
      _showError('Erreur de localisation: \$e');
    }
  }

  Future<void> _startNavigation() async {
    if (!mounted) return;

    setState(() {
      _isNavigating = true;
      _navigationTrack.clear();
      _currentStepIndex = 0;
      _lastRouteIndex = 0;
      _remainingRoute = List.from(_routePoints);
    });

    final locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 5, // Only update if moved 5 meters
    );

    try {
      _positionStreamSubscription = Geolocator.getPositionStream(
        locationSettings: locationSettings,
      ).listen(
        (Position position) {
          if (!mounted) return;

          // Calculate movement
          bool hasMoved = true;
          if (_lastPosition != null) {
            double distance = Geolocator.distanceBetween(
              _lastPosition!.latitude,
              _lastPosition!.longitude,
              position.latitude,
              position.longitude,
            );
            hasMoved = distance > 5; // Only consider movement if more than 5 meters
          }

          if (hasMoved) {
            _handlePositionUpdate(position);
          }
        },
        onError: (error) {
          print('Position Stream Error: $error');
          _getCurrentPositionFallback();
        },
        cancelOnError: false,
      );
    } catch (e) {
      if (!mounted) return;
      print('Navigation Error: $e');
      _showError('Erreur lors du démarrage de la navigation: $e');
      _stopNavigation();
    }
  }

  void _handlePositionUpdate(Position position) {
    LatLng realPosition = LatLng(position.latitude, position.longitude);
    _snappedPosition = _snapToRoute(realPosition);
    _calculateBearing();

    // Log position data
    if (_isLoggingPosition) {
      print('\n=== Position Update ===');
      print('Raw Position: ${position.latitude}, ${position.longitude}');
      print('Snapped Position: ${_snappedPosition!.latitude}, ${_snappedPosition!.longitude}');
      print('Speed: ${position.speed} m/s');
      print('Accuracy: ${position.accuracy} meters');
      print('Altitude: ${position.altitude} meters');
      if (_destination != null) {
        print('Distance to destination: ${_distanceToDestination.toStringAsFixed(2)} meters');
      }
      print('Bearing: $_bearing degrees');
      print('====================\n');
    }

    setState(() {
      _currentPosition = _snappedPosition;
      _lastPosition = position;
      _navigationTrack.add(_currentPosition!);
      _updateMarkers();

      if (_destination != null) {
        _distanceToDestination = _calculateRouteDistance(
          _currentPosition!,
          _destination!,
        );
        _estimatedTime = Duration(
          seconds: (_distanceToDestination / (position.speed > 0 ? position.speed : 5)).round()
        );
      }

      _mapController.moveAndRotate(
        _currentPosition!,
        _mapController.zoom,
        _bearing,
      );
    });

    _updateNavigationInstructions();
  }
  Future<void> _updateOriginAddress() async {
    if (_currentPosition == null) return;

    String url = 'https://nominatim.openstreetmap.org/reverse?format=json'
        '&lat=${_currentPosition!.latitude}'
        '&lon=${_currentPosition!.longitude}';

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'NavigationApp/1.0'},
      );
      if (response.statusCode == 200) {
        var data = json.decode(response.body);
        if (!mounted) return;
        setState(() {
          _originController.text = data['display_name'];
        });
      }
    } catch (e) {
      if (!mounted) return;
      _showError('Erreur lors de la récupération de l\'adresse');
    }
  }

  Future<void> _searchSuggestion(String query) async {
    if (query.length < 3) {
      setState(() {
        _searchSuggestions = [];
      });
      return;
    }

    try {
      String url = 'https://nominatim.openstreetmap.org/search?'
          'format=json&q=$query&limit=5&accept-language=fr';

      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'NavigationApp/1.0'},
      );
      
      if (response.statusCode == 200) {
        List<dynamic> data = json.decode(response.body);
        if (!mounted) return;
        setState(() {
          _searchSuggestions = data.map<Map<String, dynamic>>((place) => {
            'name': place['display_name'],
            'lat': double.parse(place['lat']),
            'lon': double.parse(place['lon']),
          }).toList();
        });
      }
    } catch (e) {
      if (!mounted) return;
      _showError('Erreur lors de la recherche');
    }
  }

  Future<void> _getRoute() async {
    if (_currentPosition == null || _destination == null) return;

    setState(() {
      _isLoading = true;
    });

    try {
      String url = 'https://router.project-osrm.org/route/v1/driving/'
          '${_currentPosition!.longitude},${_currentPosition!.latitude};'
          '${_destination!.longitude},${_destination!.latitude}'
          '?overview=full&geometries=geojson&steps=true';

      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        var data = json.decode(response.body);
        List<dynamic> coordinates = data['routes'][0]['geometry']['coordinates'];
        List<dynamic> steps = data['routes'][0]['legs'][0]['steps'];

        if (!mounted) return;

        setState(() {
          _routePoints = coordinates
              .map((coord) => LatLng(coord[1].toDouble(), coord[0].toDouble()))
              .toList();

          _remainingRoute = List.from(_routePoints);
          _lastRouteIndex = 0;

          _navigationSteps = steps.map<Map<String, dynamic>>((step) {
            return {
              'instruction': step['maneuver']['type'],
              'location': step['maneuver']['location'],
              'distance': step['distance'],
            };
          }).toList();

          _updateMarkers();
        });

        _fitRoute();
      }
    } catch (e) {
      if (!mounted) return;
      _showError('Erreur lors du calcul de l\'itinéraire');
    } finally {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    }
  }

  double _calculateRouteDistance(LatLng start, LatLng end) {
    if (_remainingRoute.isEmpty) {
      return Geolocator.distanceBetween(
        start.latitude,
        start.longitude,
        end.latitude,
        end.longitude,
      );
    }

    double totalDistance = 0;
    LatLng previousPoint = start;

    for (var point in _remainingRoute) {
      totalDistance += Geolocator.distanceBetween(
        previousPoint.latitude,
        previousPoint.longitude,
        point.latitude,
        point.longitude,
      );
      previousPoint = point;
    }

    return totalDistance;
  }

  void _calculateBearing() {
    if (_remainingRoute.length > 1) {
      _bearing = Geolocator.bearingBetween(
        _snappedPosition!.latitude,
        _snappedPosition!.longitude,
        _remainingRoute[1].latitude,
        _remainingRoute[1].longitude,
      );
      _mapController.rotate(_bearing);
    }
  }

  LatLng _snapToRoute(LatLng position) {
    if (_routePoints.isEmpty) return position;

    double minDistance = double.infinity;
    LatLng closestPoint = position;
    int closestIndex = _lastRouteIndex;

    for (int i = _lastRouteIndex; i < _routePoints.length; i++) {
      double distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        _routePoints[i].latitude,
        _routePoints[i].longitude,
      );

      if (distance < minDistance) {
        minDistance = distance;
        closestPoint = _routePoints[i];
        closestIndex = i;
      }
    }

    if (closestIndex >= _lastRouteIndex) {
      _lastRouteIndex = closestIndex;
      setState(() {
        _remainingRoute = _routePoints.sublist(closestIndex);
      });
    }

    return closestPoint;
  }
  void _updateNavigationInstructions() {
    if (_navigationSteps.isEmpty || _currentPosition == null || _destination == null) return;

    double minDistance = double.infinity;
    int nearestIndex = _currentStepIndex;

    for (int i = _currentStepIndex; i < _navigationSteps.length; i++) {
      var step = _navigationSteps[i];
      var stepLocation = LatLng(step['location'][0], step['location'][1]);

      double distance = Geolocator.distanceBetween(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
        stepLocation.latitude,
        stepLocation.longitude,
      );

      if (distance < minDistance) {
        minDistance = distance;
        nearestIndex = i;
      }
    }

    if (minDistance < 30 && nearestIndex > _currentStepIndex) {
      setState(() {
        _currentStepIndex = nearestIndex;
        _nextInstruction = _navigationSteps[_currentStepIndex]['instruction'];
      });
    }
  }

  void _updateMarkers() {
    setState(() {
      _markers.clear();
      if (_currentPosition != null) {
        _markers.add(
          Marker(
            width: 60,
            height: 60,
            point: _currentPosition!,
            child: Transform.rotate(
              angle: _bearing * (pi / 180),
              child: const Icon(
                Icons.navigation,
                color: Colors.blue,
                size: 50,
              ),
            ),
          ),
        );
      }
      if (_destination != null) {
        _markers.add(
          Marker(
            width: 40,
            height: 40,
            point: _destination!,
            child: const Icon(Icons.location_on, color: Colors.red, size: 40),
          ),
        );
      }
    });
  }

  void _fitRoute() {
    if (_routePoints.isEmpty) return;

    var bounds = LatLngBounds.fromPoints(_routePoints);
    _mapController.fitBounds(
      bounds,
      options: const FitBoundsOptions(padding: EdgeInsets.all(50.0)),
    );
  }

  void _clearRoute() {
    setState(() {
      _destination = null;
      _routePoints.clear();
      _remainingRoute.clear();
      _lastRouteIndex = 0;
      _updateMarkers();
      _destinationController.clear();
      _searchSuggestions.clear();
      if (_isNavigating) {
        _stopNavigation();
      }
    });
  }

  void _stopNavigation() {
    _positionStreamSubscription?.cancel();
    setState(() {
      _isNavigating = false;
      _navigationTrack.clear();
      _nextInstruction = '';
      _navigationSteps.clear();
      _currentStepIndex = 0;
      _lastRouteIndex = 0;
      _remainingRoute.clear();
      _mapController.rotate(0);
    });
  }

  void _togglePositionLogging() {
    setState(() {
      _isLoggingPosition = !_isLoggingPosition;
      print('Position logging ${_isLoggingPosition ? 'enabled' : 'disabled'}');
    });
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Widget _buildNavigationOverlay() {
    return Positioned(
      top: 100,
      left: 20,
      right: 20,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              spreadRadius: 2,
              blurRadius: 5,
            ),
          ],
        ),
        child: Column(
          children: [
            Text(
              _nextInstruction.isEmpty ? 'Suivez la route' : _nextInstruction,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Distance restante:',
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                    Text(
                      _distanceToDestination >= 1000
                          ? '${(_distanceToDestination / 1000).toStringAsFixed(1)} km'
                          : '${_distanceToDestination.toStringAsFixed(0)} m',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'Temps estimé:',
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                    Text(
                      '${_estimatedTime.inMinutes} min',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Search Bar Container
          Container(
            padding: const EdgeInsets.fromLTRB(16, 40, 16, 16),
            color: Colors.white,
            child: Column(
              children: [
                // Origin TextField
                TextField(
                  controller: _originController,
                  decoration: InputDecoration(
                    hintText: 'Position actuelle',
                    prefixIcon: const Icon(Icons.my_location),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: _getCurrentLocation,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    fillColor: Colors.grey[100],
                    filled: true,
                  ),
                  readOnly: true,
                ),
                const SizedBox(height: 8),
                // Destination TextField
                TextField(
                  controller: _destinationController,
                  decoration: InputDecoration(
                    hintText: 'Chercher une destination',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _destinationController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: _clearRoute,
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    fillColor: Colors.grey[100],
                    filled: true,
                  ),
                  onChanged: _searchSuggestion,
                ),
                // Search Suggestions
                if (_searchSuggestions.isNotEmpty)
                  Container(
                    constraints: const BoxConstraints(maxHeight: 200),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.grey.withOpacity(0.3),
                          spreadRadius: 1,
                          blurRadius: 5,
                        ),
                      ],
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _searchSuggestions.length,
                      itemBuilder: (context, index) {
                        final suggestion = _searchSuggestions[index];
                        return ListTile(
                          leading: const Icon(Icons.location_on),
                          title: Text(
                            suggestion['name'],
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            setState(() {
                              _destination = LatLng(
                                suggestion['lat'],
                                suggestion['lon'],
                              );
                              _destinationController.text = suggestion['name'];
                              _searchSuggestions = [];
                            });
                            _getRoute();
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          // Map and Navigation Controls
          Expanded(
            child: Stack(
              children: [
                // Map
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: LatLng(31.7917, -7.0926),
                    initialZoom: 16.0,
                    initialRotation: _isNavigating ? _bearing : 0,
                  ),
                  children: [
                    // Map Tiles
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.app',
                    ),
                    // Route Lines
                    PolylineLayer(
                      polylines: [
                        if (_routePoints.isNotEmpty)
                          Polyline(
                            points: _routePoints,
                            color: Colors.grey.withOpacity(0.5),
                            strokeWidth: 4.0,
                          ),
                        if (_remainingRoute.isNotEmpty)
                          Polyline(
                            points: _remainingRoute,
                            color: Colors.blue,
                            strokeWidth: 5.0,
                          ),
                        if (_navigationTrack.isNotEmpty)
                          Polyline(
                            points: _navigationTrack,
                            color: Colors.green,
                            strokeWidth: 4.0,
                          ),
                      ],
                    ),
                    // Markers
                    MarkerLayer(markers: _markers),
                  ],
                ),
                // Navigation Overlay
                if (_isNavigating) _buildNavigationOverlay(),
                // Loading Indicator
                if (_isLoading)
                  Container(
                    color: Colors.black.withOpacity(0.3),
                    child: const Center(
                      child: CircularProgressIndicator(),
                    ),
                  ),
                // Navigation Button
                if (_destination != null && _routePoints.isNotEmpty)
                  Positioned(
                    bottom: 16,
                    left: 16,
                    right: 70,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                        backgroundColor: _isNavigating ? Colors.red : Colors.blue,
                      ),
                      onPressed: () {
                        if (_isNavigating) {
                          _stopNavigation();
                        } else {
                          _startNavigation();
                        }
                      },
                      icon: Icon(_isNavigating ? Icons.stop : Icons.navigation),
                      label: Text(_isNavigating ? 'Arrêter' : 'Commencer la navigation'),
                    ),
                  ),
                // Location Button
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: FloatingActionButton(
                    onPressed: _getCurrentLocation,
                    child: const Icon(Icons.my_location),
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.blue,
                  ),
                ),
                // Logging Toggle Button
                Positioned(
                  right: 16,
                  bottom: 80,
                  child: FloatingActionButton(
                    onPressed: _togglePositionLogging,
                    child: Icon(_isLoggingPosition ? Icons.speaker_notes : Icons.speaker_notes_off),
                    backgroundColor: Colors.white,
                    foregroundColor: _isLoggingPosition ? Colors.green : Colors.grey,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}