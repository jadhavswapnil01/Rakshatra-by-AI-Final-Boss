// lib/screens/main_page_screens/enhanced_map_view_screen.dart
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:iconsax/iconsax.dart';
import 'package:intl/intl.dart';
import 'package:tourist_safety/main_screen.dart';
import 'package:tourist_safety/utils/app_colors.dart';
import 'package:tourist_safety/services/api_service.dart';
import 'package:tourist_safety/services/database_service.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../../utils/theme_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tourist_safety/providers/sse_providers.dart';

// Enums
enum ViewMode { overview, editing, placeDetail, destinationDetail }

enum PlaceFilter { hotels, restaurants, attractions, hospitals }

// Models
class PlaceDetails {
  final String placeId;
  final String name;
  final String vicinity;
  final LatLng location;
  final double? rating;
  final List<String> types;
  final String? photoReference;

  PlaceDetails({
    required this.placeId,
    required this.name,
    required this.vicinity,
    required this.location,
    this.rating,
    required this.types,
    this.photoReference,
  });
}

class EnhancedMapViewScreen extends ConsumerStatefulWidget {
  const EnhancedMapViewScreen({super.key});

  @override
  ConsumerState<EnhancedMapViewScreen> createState() => _EnhancedMapViewScreenState();
}

class _EnhancedMapViewScreenState extends ConsumerState<EnhancedMapViewScreen>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  @override
  bool get wantKeepAlive => true;

  // Services
  final ApiService _apiService = ApiService();
  final DatabaseService _dbService = DatabaseService();

  // Controllers
  GoogleMapController? _mapController;
  final TextEditingController _searchController = TextEditingController();
  late AnimationController _cardAnimationController;
  Timer? _debounce;
  bool _isRefreshingSafety = false;

  // State
  String? _mapStyle;
  bool _isLoading = true;
  bool _isSearching = false;
  ViewMode _viewMode = ViewMode.overview;
  LatLng? _currentPosition;
  List<Map<String, dynamic>> _itinerary = [];
  int? _selectedDestinationIndex;
  PlaceDetails? _selectedPlace;
  List<Map<String, dynamic>> _searchSuggestions = [];
  final Set<PlaceFilter> _activeFilters = {};
  bool _isAddingDestination = false; // Track if we're adding a destination
  DateTimeRange? _selectedDateRange; // Store selected dates for new destination
  // bool _showNavBar = true; // Control navbar visibility
  bool _canShowLocation = false; // Add this
  // Geofence state
final Set<Circle> _geofenceCircles = {};
List<Map<String, dynamic>> _activeGeofences = [];
Timer? _geofenceRefreshTimer;
bool _isLoadingGeofences = false;
Map<String, dynamic>? _selectedGeofence;

  // Map Objects
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  final Map<PlaceFilter, List<PlaceDetails>> _cachedPlaces = {};

@override
void initState() {
  super.initState();
  _cardAnimationController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  
  _selectedDateRange = DateTimeRange(
    start: DateTime.now().add(const Duration(days: 7)),
    end: DateTime.now().add(const Duration(days: 14)),
  );
  
  ThemeManager().addListener(_onThemeChanged);
  _startGeofenceAutoRefresh(); // SSE handles this now
  _initialize();
}

  @override
  void dispose() {
    // ✅ ADD: Remove listener
    ThemeManager().removeListener(_onThemeChanged);
    
    _mapController?.dispose();
    _searchController.dispose();
    _cardAnimationController.dispose();
    _debounce?.cancel();
    _geofenceRefreshTimer?.cancel();
    super.dispose();
  }

  // ============================================================================
  // INITIALIZATION
  // ============================================================================

Future<void> _initialize() async {
  await _updateMapStyle();
  await _getCurrentLocation();
  await _loadItinerary(); // Now loads from cache first
  await _refreshGeofences();
  await _buildMapObjects();
  if (mounted) setState(() => _isLoading = false);
  
  Future.delayed(const Duration(milliseconds: 500), () => _zoomToFitAll());
}


void _onThemeChanged() {
    _updateMapStyle();
    if (mounted) setState(() {});
  }

  // ✅ ADD: New method to update style dynamically
  Future<void> _updateMapStyle() async {
    final isDarkMode = ThemeManager().isDarkMode;
    final stylePath = isDarkMode
        ? 'assets/map_style_dark.json'
        : 'assets/map_style.json';
        
    try {
      final style = await rootBundle.loadString(stylePath);
      // Apply to controller if it exists
      if (_mapController != null) {
        await _mapController!.setMapStyle(style);
      }
      // Update local state
      if (mounted) {
        setState(() {
          _mapStyle = style;
        });
      }
    } catch (e) {
      debugPrint("Error updating map style: $e");
    }
  }

  Future<void> _loadMapStyle() async {
    // Load different map styles based on theme
    final isDarkMode = ThemeManager().isDarkMode;
    final stylePath = isDarkMode
        ? 'assets/map_style_dark.json'
        : 'assets/map_style.json';
    final style = await rootBundle.loadString(stylePath);
    if (mounted) {
      setState(() {
        _mapStyle = style;
      });
    }
  }
Future<void> _getCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return;
      }

      if (permission == LocationPermission.deniedForever) return;

      // ✅ Permission granted, enable the blue dot
      if (mounted) {
        setState(() {
          _canShowLocation = true; 
        });
      }

      final position = await Geolocator.getCurrentPosition();
      if (mounted) {
        setState(() {
          _currentPosition = LatLng(position.latitude, position.longitude);
        });
      }
    } catch (e) {
      debugPrint('Location error: $e');
    }
  }

Future<void> _loadItinerary() async {
  try {
    // First, try to load from local cache (FAST)
    final user = await _dbService.getUserProfile();
    if (user?.id != null) {
      final localDest = await _dbService.getDestinations(user!.id!);
      if (mounted && localDest.isNotEmpty) {
        setState(() {
          _itinerary = localDest;
        });
        debugPrint('✅ Loaded ${localDest.length} destinations from cache');
      }
    }
    
    // Then, sync with server in background (NO BLOCKING)
    _syncItineraryInBackground();
    
  } catch (e) {
    debugPrint('Load itinerary error: $e');
  }
}

/// Sync itinerary with server in background
Future<void> _syncItineraryInBackground() async {
  try {
    final response = await _apiService.getItineraryDestinations();
    if (response['success'] == true) {
      final destinations = List<Map<String, dynamic>>.from(
        response['destinations'] ?? [],
      );

      if (mounted && destinations.isNotEmpty) {
        setState(() {
          _itinerary = destinations;
        });

        final user = await _dbService.getUserProfile();
        if (user?.id != null) {
          await _dbService.clearDestinations(user!.id!);
          for (int i = 0; i < destinations.length; i++) {
            final dest = destinations[i];
            await _dbService.saveDestination(
              id: dest['id'],
              userId: user.id!,
              name: dest['name'],
              latitude: dest['latitude']?.toDouble() ?? 0.0,
              longitude: dest['longitude']?.toDouble() ?? 0.0,
              dateRangeStart: dest['date_range_start'],
              dateRangeEnd: dest['date_range_end'],
              city: dest['city'],
              placeId: dest['place_id'],
              isAiSuggestion: dest['is_ai_suggestion'] ?? false,
              orderIndex: i,
              safetyScore: dest['safety_score'],
              safetyCategory: dest['safety_category'],
              safetyEmoji: dest['safety_emoji'],
              currentAqi: dest['current_aqi'],
              currentTemperature: dest['current_temperature']?.toDouble(),
            );
          }
          debugPrint('✅ Synced ${destinations.length} destinations to cache');
        }
      }
    }
  } catch (e) {
    debugPrint('Background sync failed: $e (using cached data)');
  }
}

Future<void> _refreshSafetyScores() async {
  setState(() => _isRefreshingSafety = true);
  
  try {
    final response = await _apiService.recalculateAllSafetyScores();
    
    if (response['success'] == true) {
      // Reload itinerary with new scores
      await _loadItinerary();
      await _buildMapObjects();
      
      _showSnackBar(
        'Safety scores updated for ${response['updated_count']} destinations',
        isError: false,
      );
    }
  } catch (e) {
    _showSnackBar('Failed to refresh safety scores: $e', isError: true);
  } finally {
    setState(() => _isRefreshingSafety = false);
  }
}

  // ============================================================================
  // MAP OBJECTS BUILDING
  // ============================================================================

Future<void> _buildMapObjects() async {
  _markers.clear();
  _polylines.clear();

  // Add destinations
  if (_itinerary.isNotEmpty) {
    for (int i = 0; i < _itinerary.length; i++) {
      final dest = _itinerary[i];
      final lat = dest['latitude']?.toDouble();
      final lon = dest['longitude']?.toDouble();

      if (lat == null || lon == null) continue;

      final marker = await _createDestinationMarker(
        position: LatLng(lat, lon),
        index: i,
        hasDate: dest['date_range_start'] != null,
      );

      _markers.add(marker);
    }

    // Draw route
    if (_itinerary.length > 1) {
      final points = _itinerary
          .where((d) => d['latitude'] != null && d['longitude'] != null)
          .map((d) => LatLng(d['latitude'].toDouble(), d['longitude'].toDouble()))
          .toList();

      if (points.length > 1) {
        _polylines.add(
          Polyline(
            polylineId: const PolylineId('route'),
            points: points,
            color: AppColors.primary,
            width: 4,
            patterns: [PatternItem.dash(20), PatternItem.gap(10)],
          ),
        );
      }
    }
    
    // ✅ NEW: Refresh geofences when itinerary changes
    await _refreshGeofences(silent: true);
  }

  // Add filtered places
  for (final filter in _activeFilters) {
    if (_cachedPlaces.containsKey(filter)) {
      for (final place in _cachedPlaces[filter]!) {
        final marker = await _createPlaceMarker(place, filter);
        _markers.add(marker);
      }
    }
  }

  if (mounted) setState(() {});
  // _startGeofenceAutoRefresh();
}

// ============================================================================
// GEOFENCE MANAGEMENT
// ============================================================================

void _startGeofenceAutoRefresh() {
  _geofenceRefreshTimer = Timer.periodic(const Duration(minutes: 1), (_) {
    if(_isAddingDestination){
      return; // Skip refresh while adding destination
    } else if (mounted) {
      _refreshGeofences(silent: true);
    }
  });
}

Future<void> _refreshGeofences({bool silent = false}) async {
  if (!silent) {
    setState(() => _isLoadingGeofences = true);
  }
  
  try {
    // Extract unique cities from itinerary
    final cities = _itinerary
        .where((dest) => dest['city'] != null)
        .map((dest) => (dest['city'] as String).trim()) 
        .toSet()
        .toList();

    if (cities.isEmpty) {
      // Load from cache even if no cities
      final cachedGeofences = await _dbService.getAllGeofences();
      if (mounted) {
        setState(() {
          _activeGeofences = cachedGeofences;
          _isLoadingGeofences = false;
        });
      }
      await _buildGeofenceCircles();
      return;
    }
    
    // First, load from cache (FAST)
    final cachedGeofences = await _dbService.getGeofencesByCities(cities);
    if (mounted && cachedGeofences.isNotEmpty) {
      setState(() {
        _activeGeofences = cachedGeofences;
      });
      await _buildGeofenceCircles();
      debugPrint('✅ Loaded ${cachedGeofences.length} geofences from cache');
    }
    
    // Then, sync with server in background (if not silent)
    if (!silent) {
      _syncGeofencesInBackground(cities);
    }
    
  } catch (e) {
    debugPrint('Failed to refresh geofences: $e');
  } finally {
    if (!silent && mounted) {
      setState(() => _isLoadingGeofences = false);
    }
  }
}

/// Sync geofences with server in background
Future<void> _syncGeofencesInBackground(List<String> cities) async {
  try {
    final geofences = await _apiService.getGeofencesByCities(cities);
    
    // Save to cache
    for (final geofence in geofences) {
      await _dbService.saveGeofence(
        id: geofence['id'].toString(),
        title: geofence['title'],
        description: geofence['description'],
        latitude: geofence['lat']?.toDouble() ?? 0.0,
        longitude: geofence['lng']?.toDouble() ?? 0.0,
        radius: geofence['radius'] ?? 100,
        severityScore: geofence['severity_score']?.toDouble() ?? 0.0,
        riskLevel: geofence['risk_level'] ?? 'MEDIUM',
        category: geofence['category'] ?? 'unknown',
        city: geofence['city'],
        reasoning: geofence['reasoning'],
        createdAt: geofence['created_at'],
        expiresAt: geofence['expires_at'],
      );
    }
    
    if (mounted) {
      setState(() {
        _activeGeofences = geofences;
      });
      await _buildGeofenceCircles();
      debugPrint('✅ Synced ${geofences.length} geofences from server');
    }
  } catch (e) {
    debugPrint('Background geofence sync failed: $e (using cached data)');
  }
}


void _setupSSEListeners(WidgetRef ref) {
  // Listen for new geofences from SSE
  ref.listen(geofenceStreamProvider, (previous, next) {
    next.whenData((geofence) async {
      // Add to local state
      if (mounted) {
        setState(() {
          _activeGeofences = [..._activeGeofences, geofence];
        });
        await _buildGeofenceCircles();
        
        _showSnackBar(
          '⚠️ New danger zone: ${geofence['title']}',
          isError: true,
        );
      }
    });
  });
  
  // Listen for authority alerts from SSE
  ref.listen(authorityAlertStreamProvider, (previous, next) {
    next.whenData((alert) async {
      if (alert['event'] == 'deleted') {
        // Remove from local state
        if (mounted) {
          setState(() {
            _activeGeofences = _activeGeofences
                .where((g) => g['id'].toString() != alert['alert_id'].toString())
                .toList();
          });
          await _buildGeofenceCircles();
        }
      } else {
        // Add new authority alert
        if (mounted) {
          setState(() {
            _activeGeofences = [..._activeGeofences, alert];
          });
          await _buildGeofenceCircles();
          
          _showSnackBar(
            '🚨 Authority Alert: ${alert['title']}',
            isError: true,
          );
        }
      }
    });
  });
  
  // Listen for SSE connection state
  ref.listen(sseConnectionProvider, (previous, next) {
    next.whenData((isConnected) {
      if (!isConnected) {
        debugPrint('⚠️ SSE disconnected - using cached data');
      } else {
        debugPrint('✅ SSE connected - live updates enabled');
      }
    });
  });
}

Future<void> _buildGeofenceCircles() async {
    _geofenceCircles.clear();

    for (final geofence in _activeGeofences) {
      // ✅ FIX 2: Handle both 'lat' (API/SSE) and 'latitude' (Database) keys
      final lat = (geofence['lat'] ?? geofence['latitude'])?.toDouble();
      final lng = (geofence['lng'] ?? geofence['longitude'])?.toDouble();
      
      final radius = geofence['radius']?.toDouble();

      if (lat == null || lng == null || radius == null) {
        // Debug print to help identify bad data
        // debugPrint('⚠️ Skipping geofence due to missing coords: ${geofence['title']}');
        continue;
      }

      // Color based on risk level
      Color circleColor;
      final riskLevel = geofence['risk_level'] as String?;

      if (riskLevel == 'CRITICAL') {
        circleColor = Colors.red;
      } else if (riskLevel == 'MEDIUM') {
        circleColor = Colors.orange;
      } else {
        circleColor = Colors.yellow;
      }

      _geofenceCircles.add(
        Circle(
          circleId: CircleId('geofence_${geofence['id']}'),
          center: LatLng(lat, lng),
          radius: radius,
          fillColor: circleColor.withOpacity(0.2),
          strokeColor: circleColor,
          strokeWidth: 2,
          consumeTapEvents: true,
          onTap: () => _showGeofenceDetails(geofence),
        ),
      );
    }

    if (mounted) setState(() {});
  }

void _showGeofenceDetails(Map<String, dynamic> geofence) {
  setState(() {
    _selectedGeofence = geofence;
    _viewMode = ViewMode.placeDetail; // Reuse existing mode
  });
  _cardAnimationController.forward(from: 0.0);
  DashboardScreen.isNavBarVisible.value = false;
  
  final lat = geofence['lat']?.toDouble();
  final lng = geofence['lng']?.toDouble();
  
  if (lat != null && lng != null) {
    _mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(LatLng(lat, lng), 15),
    );
  }
}

Future<Marker> _createDestinationMarker({
    required LatLng position,
    required int index,
    required bool hasDate,
  }) async {
    BitmapDescriptor icon;

    // Use custom asset for 1-25
    if (index < 25) {
      // 85 is the "Sweet Spot". 
      // If it is still too big, try 70. If too small/blurry, try 100.
      icon = await _createResizedMarkerIcon(
        'assets/icons/itinerary/${index + 1}.png',
        logicalWidth: 44.0, 
      );
    } else {
      // Fallback for > 25 (Canvas)
      icon = await _createNumberedMarkerIcon(index + 1, hasDate);
    }

    return Marker(
      markerId: MarkerId('dest_$index'),
      position: position,
      icon: icon,
      // Important: If your pins have a "pointy" bottom, use (0.5, 1.0).
      // If they are circles/squares, use (0.5, 0.5).
      anchor: const Offset(0.5, 1.0), 
      onTap: () => _selectDestination(index),
    );
  }

Future<BitmapDescriptor> _createNumberedMarkerIcon(
    int number,
    bool hasDate,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    
    // 1. Get the screen density (Pixel Ratio)
    // If context is unavailable here, hardcode to 3.0
    final double deviceRatio = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 3.0;
    
    // 2. Define logical size (Standard pin size)
    const logicalSize = Size(35, 48); 
    
    // 3. Scale the canvas (This draws High Quality vectors)
    canvas.scale(deviceRatio, deviceRatio);

    // --- DRAWING LOGIC STARTS ---
    final path = Path();
    path.moveTo(logicalSize.width / 2, logicalSize.height);
    path.quadraticBezierTo(0, logicalSize.height * 0.6, logicalSize.width / 2, 0);
    path.quadraticBezierTo(
      logicalSize.width,
      logicalSize.height * 0.6,
      logicalSize.width / 2,
      logicalSize.height,
    );

    canvas.drawPath(
      path,
      Paint()..color = hasDate ? AppColors.primary : AppColors.warning,
    );

    canvas.drawCircle(
      Offset(logicalSize.width / 2, logicalSize.width / 2 - 2),
      logicalSize.width * 0.3, 
      Paint()..color = Colors.white,
    );

    final textPainter = TextPainter(
      text: TextSpan(
        text: number.toString(),
        style: TextStyle(
          fontSize: 13, 
          fontWeight: FontWeight.bold,
          color: hasDate ? AppColors.primary : AppColors.warning,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(
        logicalSize.width / 2 - textPainter.width / 2,
        logicalSize.width / 2 - textPainter.height / 2 - 2,
      ),
    );
    // --- DRAWING LOGIC ENDS ---

    // 4. Render at High Resolution (Physical Pixels)
    final img = await recorder.endRecording().toImage(
      (logicalSize.width * deviceRatio).toInt(),
      (logicalSize.height * deviceRatio).toInt(),
    );
    
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(data!.buffer.asUint8List());
  }

Future<BitmapDescriptor> _createResizedMarkerIcon(
  String assetPath, {
  required double logicalWidth, // pass logical width (e.g. 50)
}) async {
  try {
    final double deviceRatio =
        MediaQuery.maybeOf(context)?.devicePixelRatio ?? 3.0;

    // targetWidth = logical width * device pixel ratio (physical pixels)
    final int targetWidth = (logicalWidth * deviceRatio).round();

    final ByteData data = await rootBundle.load(assetPath);
    final Uint8List bytes = data.buffer.asUint8List();

    // instantiateImageCodec will decode & scale to targetWidth (high quality)
    final ui.Codec codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: targetWidth,
    );

    final ui.FrameInfo frameInfo = await codec.getNextFrame();
    final ByteData? byteData = await frameInfo.image.toByteData(
      format: ui.ImageByteFormat.png,
    );

    return BitmapDescriptor.fromBytes(byteData!.buffer.asUint8List());
  } catch (e) {
    debugPrint('Error loading asset $assetPath: $e');
    return BitmapDescriptor.defaultMarker;
  }
}

Future<Marker> _createPlaceMarker(
    PlaceDetails place,
    PlaceFilter filter,
  ) async {
    // Places are smaller (60px) to differentiate from Itinerary (85px)
    final icon = await _createResizedMarkerIcon(
      _getFilterAssetPath(filter),
      logicalWidth: 39,
    );

    return Marker(
      markerId: MarkerId('place_${place.placeId}'),
      position: place.location,
      icon: icon,
      anchor: const Offset(0.5, 0.5), // Places are usually centered dots
      onTap: () => _selectPlace(place),
    );
  }


String _getFilterAssetPath(PlaceFilter filter) {
  switch (filter) {
    case PlaceFilter.hotels:
      return 'assets/icons/hotel.png';
    case PlaceFilter.restaurants:
      return 'assets/icons/restaurant.png';
    case PlaceFilter.attractions:
      return 'assets/icons/attraction.png';
    case PlaceFilter.hospitals:
      return 'assets/icons/hospital.png';
  }
}



void _zoomToFitAll() {
    // FIX 4: Safety checks
    _refreshGeofences(silent: true);
    if (_mapController == null || !mounted) return;

    final points = <LatLng>[];

    if (_currentPosition != null) {
      points.add(_currentPosition!);
    }

    for (final dest in _itinerary) {
      final lat = dest['latitude']?.toDouble();
      final lon = dest['longitude']?.toDouble();
      if (lat != null && lon != null) {
        points.add(LatLng(lat, lon));
      }
    }

    if (points.isEmpty) return;

    try {
      if (points.length == 1) {
        _mapController!.animateCamera(
          CameraUpdate.newLatLngZoom(points.first, 14.0),
        );
        return;
      }

      final bounds = LatLngBounds(
        southwest: LatLng(
          points.map((p) => p.latitude).reduce(math.min),
          points.map((p) => p.longitude).reduce(math.min),
        ),
        northeast: LatLng(
          points.map((p) => p.latitude).reduce(math.max),
          points.map((p) => p.longitude).reduce(math.max),
        ),
      );

      _mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 80));
    } catch (e) {
      debugPrint("Error animating camera: $e");
    }

  }
  // ============================================================================
  // PLACE SEARCH & FILTERS
  // ============================================================================

  void _onSearchChanged(String value) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();

    _debounce = Timer(const Duration(milliseconds: 500), () async {
      if (value.isEmpty) {
        setState(() {
          _searchSuggestions = [];
          _isSearching = false;
        });
        return;
      }

      setState(() => _isSearching = true);

      try {
        final apiKey = "AIzaSyB4Lz0NVE0oWEv-iyFBzOHEbfjTg91wWQg";
        final url =
            'https://maps.googleapis.com/maps/api/place/autocomplete/json'
            '?input=$value'
            '&key=$apiKey';

        final response = await http.get(Uri.parse(url));
        final data = json.decode(response.body);

        if (data['status'] == 'OK') {
          setState(() {
            _searchSuggestions = List<Map<String, dynamic>>.from(
              data['predictions'] ?? [],
            );
            _isSearching = false;
          });
        }
      } catch (e) {
        debugPrint('Search error: $e');
        setState(() => _isSearching = false);
      }
    });
  }

Future<void> _selectSearchSuggestion(Map<String, dynamic> prediction) async {
    try {
      final apiKey = "AIzaSyB4Lz0NVE0oWEv-iyFBzOHEbfjTg91wWQg";
      final placeId = prediction['place_id'];
      
      // FIX 1: Add 'address_components' to fields
      final url =
          'https://maps.googleapis.com/maps/api/place/details/json'
          '?place_id=$placeId'
          '&fields=name,geometry,formatted_address,rating,address_components' 
          '&key=$apiKey';

      final response = await http.get(Uri.parse(url));
      final data = json.decode(response.body);

      if (data['status'] == 'OK') {
        final result = data['result'];
        final location = result['geometry']['location'];

        // FIX 2: Extract City from address_components
        String? extractedCity;
        if (result['address_components'] != null) {
          final components = result['address_components'] as List;
          for (var c in components) {
            final types = List<String>.from(c['types']);
            if (types.contains('locality')) {
              extractedCity = c['long_name'];
              break;
            }
          }
          // Fallback: If no locality, try administrative_area_level_2 (District)
          if (extractedCity == null) {
            for (var c in components) {
              final types = List<String>.from(c['types']);
              if (types.contains('administrative_area_level_2')) {
                extractedCity = c['long_name'];
                break;
              }
            }
          }
        }

        // Show date picker
        final dateRange = await showDateRangePicker(
          context: context,
          firstDate: DateTime.now(),
          lastDate: DateTime(2030),
          initialDateRange: _selectedDateRange,
          builder: (context, child) => Theme(
            data: ThemeData.light().copyWith(
              colorScheme: ColorScheme.light(
                primary: AppColors.primary,
                onPrimary: Colors.white,
              ),
            ),
            child: child!,
          ),
        );

        if (dateRange != null) {
          setState(() {
            _selectedDateRange = dateRange;
          });

          await _addDestination(
            name: result['name'],
            latitude: location['lat'],
            longitude: location['lng'],
            placeId: placeId,
            city: extractedCity, // FIX 3: Pass the extracted city
            dateRangeStart: dateRange.start.toIso8601String(),
            dateRangeEnd: dateRange.end.toIso8601String(),
          );

          _searchController.clear();
          setState(() {
            _searchSuggestions = [];
            _isAddingDestination = false;
          });
        }
      }
    } catch (e) {
      _showSnackBar('Failed to add location: $e', isError: true);
    }
  }

// 1. Action for "Add Place" button (Search Only)
  void _startAddingPlace() {
    setState(() {
      _isAddingDestination = true; // Show Search Bar
      _viewMode = ViewMode.overview; // Keep logic in overview (Hides the List Card)
      _selectedDestinationIndex = null;
      _selectedPlace = null;
    });
    // HIDE the bottom card (Itinerary List) so it doesn't build up
    _cardAnimationController.reverse(); 
    DashboardScreen.isNavBarVisible.value = false;
  }

 void _toggleFilter(PlaceFilter filter) async {
  setState(() {
    if (_activeFilters.contains(filter)) {
      _activeFilters.remove(filter);
    } else {
      _activeFilters.add(filter);
    }
  });

  if (_activeFilters.contains(filter) && !_cachedPlaces.containsKey(filter)) {
    await _fetchNearbyPlaces(filter); // This calls _buildMapObjects internally if you modify it, or we call it after
  } else {
    await _buildMapObjects();
  }

  // NEW LOGIC: Decide how to zoom based on state
  if (_activeFilters.isNotEmpty) {
    _zoomToRefinedFilters(); // The new "1/3" zoom
  } else {
    _zoomToFitAll(); // Reset to overview if no filters are active
  }
}
void _zoomToRefinedFilters() {
  if (_mapController == null || !mounted) return;

  final points = <LatLng>[];

  // 1. Collect all points from active filters
  for (final filter in _activeFilters) {
    if (_cachedPlaces.containsKey(filter)) {
      for (final place in _cachedPlaces[filter]!) {
        points.add(place.location);
      }
    }
  }

  // 2. If no filter results, fall back to itinerary or current location
  if (points.isEmpty) {
    if (_itinerary.isNotEmpty) {
      _zoomToFitAll();
    } else if (_currentPosition != null) {
      _mapController!.animateCamera(CameraUpdate.newLatLngZoom(_currentPosition!, 13.5));
    }
    return;
  }

  // 3. Calculate the center (Centroid) of the points
  double sumLat = 0;
  double sumLng = 0;
  for (final point in points) {
    sumLat += point.latitude;
    sumLng += point.longitude;
  }
  
  final center = LatLng(sumLat / points.length, sumLng / points.length);

  // 4. Animate to the center with "Mid-Range" zoom
  // Zoom 10-11 = City Overview (_zoomToFitAll)
  // Zoom 16-17 = Specific Place Detail
  // Zoom 13.5 = The "1/3" sweet spot you requested
  _mapController!.animateCamera(
    CameraUpdate.newLatLngZoom(center, 13.5), 
  );
}
  Future<void> _fetchNearbyPlaces(PlaceFilter filter) async {
    if (_currentPosition == null) return;

    try {
      final apiKey = "AIzaSyB4Lz0NVE0oWEv-iyFBzOHEbfjTg91wWQg";
      final type = _getFilterTypeKeyword(filter);
      final url =
          'https://maps.googleapis.com/maps/api/place/nearbysearch/json'
          '?location=${_currentPosition!.latitude},${_currentPosition!.longitude}'
          '&radius=5000'
          '&type=$type'
          '&key=$apiKey';

      final response = await http.get(Uri.parse(url));
      final data = json.decode(response.body);

      if (data['status'] == 'OK') {
        final places = <PlaceDetails>[];

        for (final result in data['results']) {
          final location = result['geometry']['location'];
          places.add(
            PlaceDetails(
              placeId: result['place_id'],
              name: result['name'],
              vicinity: result['vicinity'] ?? '',
              location: LatLng(location['lat'], location['lng']),
              rating: (result['rating'] as num?)?.toDouble(),
              types: List<String>.from(result['types'] ?? []),
              photoReference: result['photos']?[0]?['photo_reference'],
            ),
          );
        }

        _cachedPlaces[filter] = places;
        await _buildMapObjects();
      }
    } catch (e) {
      debugPrint('Fetch places error: $e');
    }
  }

  String _getFilterTypeKeyword(PlaceFilter filter) {
    switch (filter) {
      case PlaceFilter.hotels:
        return 'lodging';
      case PlaceFilter.restaurants:
        return 'restaurant';
      case PlaceFilter.attractions:
        return 'tourist_attraction';
      case PlaceFilter.hospitals:
        return 'hospital';
    }
  }


  // ============================================================================
  // DESTINATION MANAGEMENT
  // ============================================================================

Future<void> _addDestination({
    required String name,
    required double latitude,
    required double longitude,
    String? placeId,
    String? city, // FIX 4: Add parameter
    String? dateRangeStart,
    String? dateRangeEnd,
  }) async {
    try {
      setState(() {
        _isAddingDestination = true;
      });

      final response = await _apiService.addItineraryDestination(
        name: name,
        latitude: latitude,
        longitude: longitude,
        placeId: placeId,
        city: city, // FIX 5: Pass to API
        dateRangeStart: dateRangeStart,
        dateRangeEnd: dateRangeEnd,
      );

      if (response['success'] == true) {
        final safetyWarning = response['safety_warning'] as String?;
        if (safetyWarning != null) {
          _showSafetyWarningDialog(safetyWarning);
        }

        await _loadItinerary();
        await _buildMapObjects();

        final newDest = _itinerary.last;
        if (newDest['latitude'] != null && newDest['longitude'] != null) {
          final lat = newDest['latitude'].toDouble();
          final lon = newDest['longitude'].toDouble();
          await _mapController?.animateCamera(
            CameraUpdate.newLatLngZoom(LatLng(lat, lon), 14),
          );
        }
        
        _showSnackBar('Destination added successfully', isError: false);
      }
    } catch (e) {
      _showSnackBar('Failed to add: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isAddingDestination = false;
        });
      }
    }
  }

// ADD this method after _addDestination:

void _showSafetyWarningDialog(String warning) {
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          Icon(
            Iconsax.warning_2,
            color: AppColors.warning,
            size: 28,
          ),
          const SizedBox(width: 12),
          const Text('Safety Notice'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            warning,
            style: TextStyle(
              fontSize: 15,
              height: 1.4,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.info.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.info.withOpacity(0.3),
              ),
            ),
            child: Row(
              children: [
                Icon(Iconsax.info_circle, color: AppColors.info, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'You can refresh safety scores anytime to get updated information.',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Got it',
            style: TextStyle(color: AppColors.primary),
          ),
        ),
      ],
    ),
  );
}

  Future<void> _updateDestination(
    int index,
    Map<String, dynamic> updates,
  ) async {
    try {
      final destId = _itinerary[index]['id'];

      await _apiService.updateItineraryDestination(
        destinationId: destId,
        name: updates['name'],
        dateRangeStart: updates['date_range_start'],
        dateRangeEnd: updates['date_range_end'],
      );

      setState(() {
        _itinerary[index] = {..._itinerary[index], ...updates};
      });

      await _buildMapObjects();
      _showSnackBar('Updated successfully', isError: false);
    } catch (e) {
      _showSnackBar('Update failed: $e', isError: true);
    }
  }

Future<void> _deleteDestination(int index) async {
    final destination = _itinerary[index];
    final String? destinationId = destination['id'];

    if (destinationId == null) {
      _showSnackBar('Error: Invalid destination ID', isError: true);
      return;
    }

    // Show Confirmation Dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Iconsax.warning_2, color: AppColors.error, size: 24),
            SizedBox(width: 10),
            Text('Delete Destination?'),
          ],
        ),
        content: Text(
          'Are you sure you want to remove "${destination['name']}" from your itinerary?',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child:  Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

if (confirmed == true) {
      try {
        final result = await _apiService.deleteItineraryDestination(destinationId);

        if (!mounted) return;

        if (result['success'] == true) {
          setState(() {
            _itinerary.removeAt(index);
            
            // --- FIX START: Reset Selection Logic ---
            // If we deleted the currently viewed item, close the detail card
            if (_selectedDestinationIndex == index) {
               _selectedDestinationIndex = null;
               _viewMode = ViewMode.overview;
               _cardAnimationController.reverse();
               DashboardScreen.isNavBarVisible.value = true;
            } 
            // If we deleted an item BEFORE the selected one, shift the index down
            else if (_selectedDestinationIndex != null && index < _selectedDestinationIndex!) {
               _selectedDestinationIndex = _selectedDestinationIndex! - 1;
            }


            // If list empty, force exit
            if (_itinerary.isEmpty) {
              _exitEditMode();
            }else {
              // Otherwise, stay in overview mode
              _zoomToFitAll();
            }
            // --- FIX END ---
          });

          await _buildMapObjects();
          _showSnackBar('Destination removed successfully', isError: false);
        }
      } catch (e) {
        if (mounted) {
          _showSnackBar('Failed to delete: $e', isError: true);
        }
      }
    }
}

void _selectDestination(int index) {
    setState(() {
      _selectedDestinationIndex = index;
      _viewMode = ViewMode.destinationDetail;
      _selectedPlace = null;
      _isAddingDestination = false;
    });
    _cardAnimationController.forward(from: 0.0);
    DashboardScreen.isNavBarVisible.value = false;

    final dest = _itinerary[index];
    final lat = dest['latitude']?.toDouble();
    final lon = dest['longitude']?.toDouble();
    if (lat != null && lon != null) {
      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(lat, lon), 15),
      );
    }
  }

void _selectPlace(PlaceDetails place) {
    setState(() {
      _selectedPlace = place;
      _selectedDestinationIndex = null;
      _viewMode = ViewMode.placeDetail;
      _isAddingDestination = false;
    });
    _cardAnimationController.forward(from: 0.0);
    DashboardScreen.isNavBarVisible.value = false;

    _mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(place.location, 16),
    );
  }


// Inside _EnhancedMapViewScreenState

  void _clearSelection() {
    setState(() {
      _selectedDestinationIndex = null;
      _selectedPlace = null;
      _viewMode = ViewMode.overview;
      _isAddingDestination = false;
    });
    _cardAnimationController.reverse();
    DashboardScreen.isNavBarVisible.value = true;
    _searchController.clear();
    
    
    // ADD THIS LINE to zoom out when closing
    if (_activeFilters.isNotEmpty) {
    _zoomToRefinedFilters(); // The new "1/3" zoom
  } else {
    _zoomToFitAll(); // Reset to overview if no filters are active
  } 
  }


void _exitEditMode() {
    setState(() {
      _viewMode = ViewMode.overview;
      _isAddingDestination = false;
      _searchController.clear();
      _searchSuggestions = [];
    });
    _cardAnimationController.reverse(); // Hide cards
    DashboardScreen.isNavBarVisible.value = true;
    
    // Unfocus keyboard
    FocusScope.of(context).unfocus();
    _zoomToFitAll();
  }

  void _showSnackBar(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppColors.error : AppColors.success,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: isError ? 3 : 2),
      ),
    );
  }

  // ============================================================================
  // UI BUILD
  // ============================================================================

// Update the build method in EnhancedMapViewScreen
@override
Widget build(BuildContext context) {
    super.build(context);
    _setupSSEListeners(ref);
    // Calculate vertical position for the buttons (StatusBar + Header Height + Padding)
    final double headerHeight = 100.0; 
    final double buttonTopPosition = MediaQuery.of(context).padding.top + headerHeight;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // 1. Map Layer
          Positioned.fill(
            child: _isLoading
                ?  Center(child: CircularProgressIndicator(color: AppColors.primary))
                : GoogleMap(
                      onMapCreated: (controller) {
                        _mapController = controller;
                        if (_mapStyle != null) _mapController?.setMapStyle(_mapStyle);
                      },
                      initialCameraPosition: CameraPosition(
                        target: _currentPosition ?? const LatLng(28.6139, 77.2090),
                        zoom: 14,
                      ),
                      markers: _markers,
                      polylines: _polylines,
                      circles: _geofenceCircles, // ✅ NEW
                      myLocationEnabled: _canShowLocation,
                      myLocationButtonEnabled: false,
                      zoomControlsEnabled: false,
                      compassEnabled: false,
                      mapToolbarEnabled: false,
                      onTap: (_) => _clearSelection(),
                      padding: EdgeInsets.only(
                        top: _isAddingDestination ? 180 : 100,
                        bottom: _isAddingDestination ? 0 : 100,
                      ),
                    ),
          ),

          // 2. Black Overlay (Fixed Blinking)
          // Always present in the tree, but ignores touches and is invisible until needed
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_isAddingDestination, // Allow clicks to pass through when not adding
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 300),
                // Only show black tint if we are adding AND (typing or showing suggestions)
                opacity: (_isAddingDestination && (_searchController.text.isNotEmpty || _searchSuggestions.isNotEmpty)) 
                    ? 0.4 
                    : 0.0,
                child: Container(color: Colors.black),
              ),
            ),
          ),

          // 3. Top Header (Your Journey / Add Place)
          // We wrap in AnimatedOpacity to fade it out when searching
          AnimatedOpacity(
            duration: const Duration(milliseconds: 300),
            opacity: _isAddingDestination ? 0.0 : 1.0,
            child: IgnorePointer(
              ignoring: _isAddingDestination,
              child: _buildTopControls(),
            ),
          ),

          // 4. Search Bar (Visible only when adding)
          if (_isAddingDestination)
            Positioned(
              top: 0, left: 0, right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: _SearchBar(
                    controller: _searchController,
                    onChanged: _onSearchChanged,
                    isSearching: _isSearching,
                    suggestions: _searchSuggestions,
                    onSuggestionTap: _selectSearchSuggestion,
                    onCancel: _exitEditMode,
                  ),
                ),
              ),
            ),

          // 5. Floating Action Buttons (Fixed Positioning)
          // Positioned is now the Top-Level widget here to ensure 'right: 16' works
          const SizedBox(height: 4),
          if (!_isLoading)
            Positioned(
              top: buttonTopPosition, 
              right: 16, // STRICTLY RIGHT
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 300),
                opacity: _isAddingDestination ? 0.0 : 1.0,
                child: IgnorePointer(
                  ignoring: _isAddingDestination,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Filter Button
                      FloatingActionButton(
                        mini: true,
                        heroTag: 'filter',
                        backgroundColor: Colors.white,
                        elevation: 4,
                        onPressed: _showFilterDialog,
                        child:  Icon(Iconsax.setting_4, color: AppColors.primary),
                      ),
                      const SizedBox(height: 12),
                      // My Location
                      FloatingActionButton(
                        mini: true,
                        heroTag: 'location',
                        backgroundColor: Colors.white,
                        elevation: 4,
                        onPressed: () {
                          if (_currentPosition != null) {
                            _mapController?.animateCamera(
                              CameraUpdate.newLatLngZoom(_currentPosition!, 15),
                            );
                          }
                        },
                        child:  Icon(Icons.my_location, color: AppColors.primary),
                      ),
                      const SizedBox(height: 12),
                      // Fit All
                      FloatingActionButton(
                        mini: true,
                        heroTag: 'fit',
                        backgroundColor: Colors.white,
                        elevation: 4,
                        onPressed: _zoomToFitAll,
                        child:  Icon(Iconsax.maximize_4, color: AppColors.primary),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // 6. Bottom Info Cards
          if (!_isLoading) _buildBottomCards(),
        ],
      ),
    );
  }

Widget _buildTopControls() {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              // padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: AppColors.surface, 
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: AppColors.border.withOpacity(0.5),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.shadowDark,
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  // ONLY view itinerary if we aren't already editing
                  onTap: _viewMode == ViewMode.editing ? null : _viewItinerary, 
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child:  Icon(
                            Iconsax.map,
                            color: AppColors.primary,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                               Text(
                                'Your Journey',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: AppColors.textPrimary
                                ),
                              ),
                              Text(
                                '${_itinerary.length} destination${_itinerary.length != 1 ? 's' : ''} • Tap to view',
                                style:  TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // LOGIC CHANGE HERE
                        if (_viewMode == ViewMode.editing)
                          TextButton.icon(
                            onPressed: _exitEditMode,
                            icon: const Icon(Icons.check, size: 18),
                            label: const Text('Done'),
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.success,
                              backgroundColor: AppColors.success.withOpacity(0.1),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          )
                        else
                          ElevatedButton.icon(
                            // USE THE NEW METHOD HERE
                            onPressed: _startAddingPlace, 
                            icon: const Icon(Iconsax.add_circle, size: 18),
                            label: const Text('Add Place'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              elevation: 0,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }


Widget _buildBottomCards() {
  return AnimatedBuilder(
    animation: _cardAnimationController,
    builder: (context, child) {
      if ((_viewMode == ViewMode.overview && _cardAnimationController.isDismissed) ||
          _isAddingDestination) {
        return const SizedBox.shrink();
      }

      Widget card;
      double bottomMargin = 24;

      if (_viewMode == ViewMode.editing) {
        card = _ItineraryListCard(
          itinerary: _itinerary,
          onEdit: (index) => _showEditSheet(index),
          onDelete: _deleteDestination,
          onTap: _selectDestination,
          onRefreshScores: _refreshSafetyScores,
          isRefreshing: _isRefreshingSafety,
        );
      } else if (_selectedGeofence != null) {
        // ✅ NEW: Show geofence details
        card = _GeofenceDetailCard(
          geofence: _selectedGeofence!,
          onClose: () {
            setState(() => _selectedGeofence = null);
            _clearSelection();
          },
        );
      } else if (_viewMode == ViewMode.placeDetail && _selectedPlace != null) {
        card = _PlaceDetailCard(
          place: _selectedPlace!,
          onClose: _clearSelection,
          onAddToItinerary: () async {
            final dateRange = await showDateRangePicker(
              context: context,
              firstDate: DateTime.now(),
              lastDate: DateTime(2030),
              initialDateRange: _selectedDateRange,
            );
            if (dateRange != null) {
              await _addDestination(
                name: _selectedPlace!.name,
                latitude: _selectedPlace!.location.latitude,
                longitude: _selectedPlace!.location.longitude,
                placeId: _selectedPlace!.placeId,
                dateRangeStart: dateRange.start.toIso8601String(),
                dateRangeEnd: dateRange.end.toIso8601String(),
              );
              _clearSelection();
            }
          },
        );
      } else if (_viewMode == ViewMode.destinationDetail &&
          _selectedDestinationIndex != null) {
        
        if (_selectedDestinationIndex! >= _itinerary.length) {
          return const SizedBox.shrink();
        }
        
        card = _buildDestinationDetailCard(
          destination: _itinerary[_selectedDestinationIndex!],
          index: _selectedDestinationIndex!,
          onClose: _clearSelection,
          onEdit: () => _showEditSheet(_selectedDestinationIndex!),
          onDelete: () => _deleteDestination(_selectedDestinationIndex!),
        );
      } else {
        return const SizedBox.shrink();
      }

      return Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            bottom: bottomMargin,
          ),
          child: Transform.translate(
            offset: Offset(
              0,
              100 * (1 - Curves.easeOut.transform(_cardAnimationController.value)),
            ),
            child: Opacity(
              opacity: _cardAnimationController.value,
              child: card,
            ),
          ),
        ),
      );
    },
  );
}

  void _showFilterDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder:
          (context) => _FilterSheet(
            activeFilters: _activeFilters,
            onToggle: (filter) {
              _toggleFilter(filter);
              Navigator.pop(context);
            },
          ),
    );
  }

  Future<void> _showEditSheet(int index) async {
    final dest = _itinerary[index];

    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _EditDestinationSheet(destination: dest),
    );

    if (result != null) {
      await _updateDestination(index, result);
    }
  }



void _viewItinerary() {
    setState(() {
      _viewMode = ViewMode.editing; // Show Itinerary List Card
      _isAddingDestination = false; // Hide Search Bar
      _selectedDestinationIndex = null;
      _selectedPlace = null;
    });
    // SHOW the bottom card
    _cardAnimationController.forward(from: 0.0);
    DashboardScreen.isNavBarVisible.value = false;
  }


Widget _buildDestinationDetailCard({
  required Map<String, dynamic> destination,
  required int index,
  required VoidCallback onClose,
  required VoidCallback onEdit,
  required VoidCallback onDelete,
}) {
  final hasDate = destination['date_range_start'] != null;
  final safetyScore = destination['safety_score'] as int?;
  final safetyCategory = destination['safety_category'] as String?;
  final safetyEmoji = destination['safety_emoji'] as String?;
  final currentAqi = destination['current_aqi'] as int?;
  final currentTemp = destination['current_temperature'] as double?;

  return Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(24),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.1),
          blurRadius: 30,
          offset: const Offset(0, 10),
        ),
      ],
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header Row
        Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: hasDate ? AppColors.primary : AppColors.warning,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: (hasDate ? AppColors.primary : AppColors.warning)
                        .withOpacity(0.4),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    destination['name'] ?? 'Destination',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  if (destination['city'] != null)
                    Text(
                      destination['city'],
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              onPressed: onClose,
              style: IconButton.styleFrom(
                backgroundColor: Colors.grey.shade100,
                padding: const EdgeInsets.all(8),
              ),
              icon: const Icon(Icons.close, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // SAFETY SCORE SECTION (NEW)
        if (safetyScore != null) _buildSafetyScoreSection(
          score: safetyScore,
          category: safetyCategory ?? 'Unknown',
          emoji: safetyEmoji ?? '⚪',
          aqi: currentAqi,
          temperature: currentTemp,
        ),

        const SizedBox(height: 16),

        // Dates Info
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: hasDate
                ? AppColors.primary.withOpacity(0.05)
                : AppColors.warning.withOpacity(0.05),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: hasDate
                  ? AppColors.primary.withOpacity(0.1)
                  : AppColors.warning.withOpacity(0.1),
            ),
          ),
          child: Row(
            children: [
              Icon(
                Iconsax.calendar_1,
                color: hasDate ? AppColors.primary : AppColors.warning,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hasDate ? 'Scheduled Visit' : 'Planning Pending',
                      style: TextStyle(
                        color: hasDate ? AppColors.primary : AppColors.warning,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatDateRange(
                        destination['date_range_start'],
                        destination['date_range_end'],
                      ),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Action Buttons Row
        Row(
          children: [
            // Refresh Safety Score Button (NEW)
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isRefreshingSafety ? null : _refreshSafetyScores,
                icon: _isRefreshingSafety
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
                label: const Text('Refresh'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: BorderSide(color: AppColors.primary),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            
            // Edit Button
            Expanded(
              child: ElevatedButton.icon(
                onPressed: onEdit,
                icon: const Icon(Iconsax.edit_2, size: 18),
                label: const Text('Edit'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Delete Button
            Container(
              decoration: BoxDecoration(
                color: AppColors.error.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: IconButton(
                onPressed: onDelete,
                icon: const Icon(Iconsax.trash, color: AppColors.error),
                padding: const EdgeInsets.all(14),
                tooltip: 'Delete',
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

Widget _buildSafetyScoreSection({
  required int score,
  required String category,
  required String emoji,
  int? aqi,
  double? temperature,
}) {
  // Determine colors based on score
  Color scoreColor;
  Color bgColor;
  Color borderColor;
  
  if (score >= 85) {
    scoreColor = Colors.green;
    bgColor = Colors.green.withOpacity(0.1);
    borderColor = Colors.green.withOpacity(0.3);
  } else if (score >= 70) {
    scoreColor = Colors.amber;
    bgColor = Colors.amber.withOpacity(0.1);
    borderColor = Colors.amber.withOpacity(0.3);
  } else if (score >= 50) {
    scoreColor = Colors.orange;
    bgColor = Colors.orange.withOpacity(0.1);
    borderColor = Colors.orange.withOpacity(0.3);
  } else {
    scoreColor = AppColors.error;
    bgColor = AppColors.error.withOpacity(0.1);
    borderColor = AppColors.error.withOpacity(0.3);
  }

  return Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: bgColor,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: borderColor, width: 2),
    ),
    child: Column(
      children: [
        // Score Display
        Row(
          children: [
            // Score Circle
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: scoreColor.withOpacity(0.2),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  emoji,
                  style: const TextStyle(fontSize: 28),
                ),
              ),
            ),
            const SizedBox(width: 16),
            
            // Score Details
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Safety Score',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scoreColor.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          category.toUpperCase(),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: scoreColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$score / 100',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: scoreColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        
        // Environmental Data
        if (aqi != null || temperature != null) ...[
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),
          
          Row(
            children: [
              if (aqi != null) ...[
                Expanded(
                  child: _buildEnvironmentalStat(
                    icon: Iconsax.wind_2,
                    label: 'Air Quality',
                    value: 'AQI $aqi',
                    color: _getAqiColor(aqi),
                  ),
                ),
              ],
              if (aqi != null && temperature != null)
                Container(
                  width: 1,
                  height: 40,
                  color: AppColors.border,
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                ),
              if (temperature != null) ...[
                Expanded(
                  child: _buildEnvironmentalStat(
                    icon: Iconsax.sun_1,
                    label: 'Temperature',
                    value: '${temperature.toInt()}°C',
                    color: _getTempColor(temperature),
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    ),
  );
}


Widget _buildEnvironmentalStat({
  required IconData icon,
  required String label,
  required String value,
  required Color color,
}) {
  return Column(
    children: [
      Icon(icon, size: 20, color: color),
      const SizedBox(height: 4),
      Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: AppColors.textSecondary,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        value,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    ],
  );
}

Color _getAqiColor(int aqi) {
  if (aqi <= 50) return Colors.green;
  if (aqi <= 100) return Colors.amber;
  if (aqi <= 150) return Colors.orange;
  return AppColors.error;
}

Color _getTempColor(double temp) {
  if (temp < 10) return Colors.blue;
  if (temp < 25) return Colors.green;
  if (temp < 35) return Colors.amber;
  return AppColors.error;
}

String _formatDateRange(String? start, String? end) {
  if (start == null) return 'No dates selected';
  try {
    final startDate = DateTime.parse(start);
    final formatter = DateFormat('MMM d, yyyy');
    if (end == null) return formatter.format(startDate);
    final endDate = DateTime.parse(end);
    return '${DateFormat('MMM d').format(startDate)} - ${formatter.format(endDate)}';
  } catch (e) {
    return 'Invalid date';
  }
}
}



class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final bool isSearching;
  final List<Map<String, dynamic>> suggestions;
  final ValueChanged<Map<String, dynamic>> onSuggestionTap;
  final VoidCallback onCancel; // Add this callback

  const _SearchBar({
    required this.controller,
    required this.onChanged,
    required this.isSearching,
    required this.suggestions,
    required this.onSuggestionTap,
    required this.onCancel, // Add this
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    // 1. BACK BUTTON TO CANCEL SEARCH
                    IconButton(
                      icon:  Icon(Icons.arrow_back, color: AppColors.textPrimary),
                      onPressed: onCancel,
                    ),
                    Expanded(
                      child: TextField(
                        controller: controller,
                        onChanged: onChanged,
                        autofocus: true,
                        style:  TextStyle(
                          fontSize: 16,
                          color: AppColors.textPrimary,
                        ),
                        decoration:  InputDecoration(
                          hintText: 'Search places...',
                          hintStyle: TextStyle(
                            color: AppColors.textHint,
                            fontSize: 16,
                          ),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    if (isSearching)
                      const SizedBox(
                        width: 40,
                        height: 40,
                        child: Center(
                          child: SizedBox(
                            width: 20, 
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    else if (controller.text.isNotEmpty)
                      IconButton(
                        icon:  Icon(Icons.close, color: AppColors.textSecondary),
                        onPressed: () {
                          controller.clear();
                          onChanged('');
                        },
                      ),
                  ],
                ),
              ),
              
              // Suggestions list
              if (suggestions.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxHeight: 300),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: AppColors.border.withOpacity(0.3),
                      ),
                    ),
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: suggestions.length,
                    itemBuilder: (context, index) {
                      final suggestion = suggestions[index];
                      final mainText = suggestion['structured_formatting']
                          ['main_text'] ?? '';
                      final secondaryText = suggestion['structured_formatting']
                          ['secondary_text'] ?? '';
                      
                      return Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => onSuggestionTap(suggestion),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: AppColors.primary.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child:  Icon(
                                    Iconsax.location,
                                    color: AppColors.primary,
                                    size: 18,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        mainText,
                                        style:  TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 15,
                                          color: AppColors.textPrimary,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (secondaryText.isNotEmpty) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          secondaryText,
                                          style:  TextStyle(
                                            fontSize: 13,
                                            color: AppColors.textSecondary,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                 Icon(
                                  Icons.arrow_forward_ios,
                                  size: 14,
                                  color: AppColors.textSecondary,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
        
        // Helper text
        if (controller.text.isEmpty && suggestions.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Icon(
                    Iconsax.info_circle,
                    color: AppColors.primary,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Search for a place, then select dates to add to your itinerary',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _ItineraryListCard extends StatelessWidget {
  final List<Map<String, dynamic>> itinerary;
  final ValueChanged<int> onEdit;
  final ValueChanged<int> onDelete;
  final ValueChanged<int> onTap;
  final VoidCallback? onRefreshScores; // NEW
  final bool isRefreshing; // NEW

  const _ItineraryListCard({
    required this.itinerary,
    required this.onEdit,
    required this.onDelete,
    required this.onTap,
    this.onRefreshScores, // NEW
    this.isRefreshing = false, // NEW
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.5,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag Handle
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Your Itinerary",
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "${itinerary.length} destination${itinerary.length != 1 ? 's' : ''}",
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                
                // Refresh Button (NEW)
                if (onRefreshScores != null)
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: IconButton(
                      onPressed: isRefreshing ? null : onRefreshScores,
                      icon: isRefreshing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(Icons.refresh, color: AppColors.primary),
                      tooltip: 'Refresh Safety Scores',
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),

          // List content
          Flexible(
            child: itinerary.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(40.0),
                    child: Column(
                      children: [
                        Icon(Iconsax.map_1, size: 64, color: AppColors.border),
                        const SizedBox(height: 16),
                        const Text(
                          "Your journey starts here.",
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "Tap 'Add Place' above to search for destinations.",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey.shade500),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    shrinkWrap: true,
                    itemCount: itinerary.length,
                    itemBuilder: (context, index) {
                      final dest = itinerary[index];
                      final isLast = index == itinerary.length - 1;
                      final hasDate = dest['date_range_start'] != null;
                      final safetyScore = dest['safety_score'] as int?;
                      final safetyEmoji = dest['safety_emoji'] as String?;

                      return IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Timeline Logic
                            SizedBox(
                              width: 30,
                              child: Column(
                                children: [
                                  if (index != 0)
                                    Container(width: 2, height: 15, color: AppColors.border)
                                  else
                                    const SizedBox(height: 15),

                                  // Dot
                                  Container(
                                    width: 24,
                                    height: 24,
                                    decoration: BoxDecoration(
                                      color: hasDate ? AppColors.primary : Colors.white,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: hasDate ? AppColors.primary : AppColors.warning,
                                        width: 2,
                                      ),
                                    ),
                                    child: Center(
                                      child: Text(
                                        "${index + 1}",
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: hasDate ? Colors.white : AppColors.warning,
                                        ),
                                      ),
                                    ),
                                  ),

                                  // Bottom line
                                  Expanded(
                                    child: isLast
                                        ? const SizedBox()
                                        : Container(width: 2, color: AppColors.border),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),

                            // Card Content
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: InkWell(
                                  onTap: () => onTap(index),
                                  borderRadius: BorderRadius.circular(16),
                                  child: Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: AppColors.surfaceVariant,
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(color: AppColors.border),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    dest['name'] ?? 'Unknown',
                                                    style: const TextStyle(
                                                      fontWeight: FontWeight.bold,
                                                      fontSize: 15,
                                                    ),
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Row(
                                                    children: [
                                                      Icon(
                                                        Iconsax.calendar_1,
                                                        size: 12,
                                                        color: hasDate
                                                            ? AppColors.primary
                                                            : AppColors.warning,
                                                      ),
                                                      const SizedBox(width: 4),
                                                      Text(
                                                        hasDate
                                                            ? _formatDate(dest['date_range_start'])
                                                            : 'No date',
                                                        style: TextStyle(
                                                          fontSize: 12,
                                                          color: Colors.grey.shade600,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ],
                                              ),
                                            ),
                                            
                                            // Safety Score Badge (NEW)
                                            if (safetyScore != null) ...[
                                              const SizedBox(width: 8),
                                              Container(
                                                padding: const EdgeInsets.symmetric(
                                                  horizontal: 8,
                                                  vertical: 4,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: _getSafetyColor(safetyScore)
                                                      .withOpacity(0.15),
                                                  borderRadius: BorderRadius.circular(8),
                                                  border: Border.all(
                                                    color: _getSafetyColor(safetyScore)
                                                        .withOpacity(0.3),
                                                  ),
                                                ),
                                                child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Text(
                                                      safetyEmoji ?? '⚪',
                                                      style: const TextStyle(fontSize: 12),
                                                    ),
                                                    const SizedBox(width: 4),
                                                    Text(
                                                      '$safetyScore',
                                                      style: TextStyle(
                                                        fontSize: 11,
                                                        fontWeight: FontWeight.bold,
                                                        color: _getSafetyColor(safetyScore),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        
                                        // Action Buttons
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.end,
                                          children: [
                                            IconButton(
                                              icon: const Icon(Iconsax.edit, size: 18),
                                              color: Colors.grey.shade400,
                                              onPressed: () => onEdit(index),
                                              padding: EdgeInsets.zero,
                                              constraints: const BoxConstraints(),
                                            ),
                                            const SizedBox(width: 8),
                                            IconButton(
                                              icon: const Icon(Iconsax.trash, size: 18),
                                              color: AppColors.error,
                                              onPressed: () => onDelete(index),
                                              padding: EdgeInsets.zero,
                                              constraints: const BoxConstraints(),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _formatDate(String? start) {
    if (start == null) return '';
    try {
      return DateFormat('MMM d').format(DateTime.parse(start));
    } catch (e) {
      return '';
    }
  }
  
  Color _getSafetyColor(int score) {
    if (score >= 85) return Colors.green;
    if (score >= 70) return Colors.amber;
    if (score >= 50) return Colors.orange;
    return AppColors.error;
  }
}

class _PlaceDetailCard extends StatelessWidget {
  final PlaceDetails place;
  final VoidCallback onClose;
  final VoidCallback onAddToItinerary;
  const _PlaceDetailCard({
    required this.place,
    required this.onClose,
    required this.onAddToItinerary,
  });
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        margin: const EdgeInsets.only(left: 16, right: 16, bottom: 120),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 20),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child:  Icon(Iconsax.location, color: AppColors.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        place.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (place.rating != null)
                        Row(
                          children: [
                            const Icon(
                              Icons.star,
                              color: Colors.amber,
                              size: 16,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              place.rating.toString(),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              place.vicinity,
              style:  TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onAddToItinerary,
                icon: const Icon(Iconsax.add_circle, size: 18),
                label: const Text('Add to Itinerary'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// class _DestinationDetailCard extends StatelessWidget {
//   final Map<String, dynamic> destination;
//   final int index;
//   final VoidCallback onClose;
//   final VoidCallback onEdit;
//   final VoidCallback onDelete; // Added callback

//   const _DestinationDetailCard({
//     required this.destination,
//     required this.index,
//     required this.onClose,
//     required this.onEdit,
//     required this.onDelete, // Required
//   });

//   @override
//   Widget build(BuildContext context) {
//   final hasDate = destination['date_range_start'] != null;
//   final safetyScore = destination['safety_score'] as int?;
//   final safetyCategory = destination['safety_category'] as String?;
//   final safetyEmoji = destination['safety_emoji'] as String?;
//   final currentAqi = destination['current_aqi'] as int?;
//   final currentTemp = destination['current_temperature'] as double?;

//   return Container(
//     padding: const EdgeInsets.all(24),
//     decoration: BoxDecoration(
//       color: AppColors.surface,
//       borderRadius: BorderRadius.circular(24),
//       boxShadow: [
//         BoxShadow(
//           color: Colors.black.withOpacity(0.1),
//           blurRadius: 30,
//           offset: const Offset(0, 10),
//         ),
//       ],
//     ),
//     child: Column(
//       mainAxisSize: MainAxisSize.min,
//       crossAxisAlignment: CrossAxisAlignment.start,
//       children: [
//         // Header Row
//         Row(
//           children: [
//             Container(
//               width: 46,
//               height: 46,
//               decoration: BoxDecoration(
//                 color: hasDate ? AppColors.primary : AppColors.warning,
//                 shape: BoxShape.circle,
//                 boxShadow: [
//                   BoxShadow(
//                     color: (hasDate ? AppColors.primary : AppColors.warning)
//                         .withOpacity(0.4),
//                     blurRadius: 10,
//                     offset: const Offset(0, 4),
//                   ),
//                 ],
//               ),
//               child: Center(
//                 child: Text(
//                   '${index + 1}',
//                   style: const TextStyle(
//                     fontWeight: FontWeight.bold,
//                     fontSize: 18,
//                     color: Colors.white,
//                   ),
//                 ),
//               ),
//             ),
//             const SizedBox(width: 16),
//             Expanded(
//               child: Column(
//                 crossAxisAlignment: CrossAxisAlignment.start,
//                 children: [
//                   Text(
//                     destination['name'] ?? 'Destination',
//                     style: TextStyle(
//                       fontSize: 18,
//                       fontWeight: FontWeight.w800,
//                       color: AppColors.textPrimary,
//                     ),
//                   ),
//                   if (destination['city'] != null)
//                     Text(
//                       destination['city'],
//                       style: TextStyle(
//                         color: AppColors.textSecondary,
//                         fontSize: 13,
//                       ),
//                     ),
//                 ],
//               ),
//             ),
//             IconButton(
//               onPressed: onClose,
//               style: IconButton.styleFrom(
//                 backgroundColor: Colors.grey.shade100,
//                 padding: const EdgeInsets.all(8),
//               ),
//               icon: const Icon(Icons.close, size: 20),
//             ),
//           ],
//         ),
//         const SizedBox(height: 20),

//         // SAFETY SCORE SECTION (NEW)
//         if (safetyScore != null) _buildSafetyScoreSection(
//           score: safetyScore,
//           category: safetyCategory ?? 'Unknown',
//           emoji: safetyEmoji ?? '⚪',
//           aqi: currentAqi,
//           temperature: currentTemp,
//         ),

//         const SizedBox(height: 16),

//         // Dates Info
//         Container(
//           padding: const EdgeInsets.all(16),
//           decoration: BoxDecoration(
//             color: hasDate
//                 ? AppColors.primary.withOpacity(0.05)
//                 : AppColors.warning.withOpacity(0.05),
//             borderRadius: BorderRadius.circular(16),
//             border: Border.all(
//               color: hasDate
//                   ? AppColors.primary.withOpacity(0.1)
//                   : AppColors.warning.withOpacity(0.1),
//             ),
//           ),
//           child: Row(
//             children: [
//               Icon(
//                 Iconsax.calendar_1,
//                 color: hasDate ? AppColors.primary : AppColors.warning,
//               ),
//               const SizedBox(width: 12),
//               Expanded(
//                 child: Column(
//                   crossAxisAlignment: CrossAxisAlignment.start,
//                   children: [
//                     Text(
//                       hasDate ? 'Scheduled Visit' : 'Planning Pending',
//                       style: TextStyle(
//                         color: hasDate ? AppColors.primary : AppColors.warning,
//                         fontSize: 11,
//                         fontWeight: FontWeight.bold,
//                       ),
//                     ),
//                     const SizedBox(height: 2),
//                     Text(
//                       _formatDateRange(
//                         destination['date_range_start'],
//                         destination['date_range_end'],
//                       ),
//                       style: const TextStyle(
//                         fontWeight: FontWeight.w600,
//                         fontSize: 14,
//                       ),
//                     ),
//                   ],
//                 ),
//               ),
//             ],
//           ),
//         ),
//         const SizedBox(height: 20),

//         // Action Buttons Row
//         Row(
//           children: [
//             // Refresh Safety Score Button (NEW)
//             Expanded(
//               child: OutlinedButton.icon(
//                 onPressed: _isRefreshingSafety ? null : _refreshSafetyScores,
//                 icon: _isRefreshingSafety
//                     ? const SizedBox(
//                         width: 16,
//                         height: 16,
//                         child: CircularProgressIndicator(strokeWidth: 2),
//                       )
//                     : const Icon(Icons.refresh, size: 18),
//                 label: const Text('Refresh'),
//                 style: OutlinedButton.styleFrom(
//                   foregroundColor: AppColors.primary,
//                   side: BorderSide(color: AppColors.primary),
//                   padding: const EdgeInsets.symmetric(vertical: 14),
//                   shape: RoundedRectangleBorder(
//                     borderRadius: BorderRadius.circular(12),
//                   ),
//                 ),
//               ),
//             ),
//             const SizedBox(width: 8),
            
//             // Edit Button
//             Expanded(
//               child: ElevatedButton.icon(
//                 onPressed: onEdit,
//                 icon: const Icon(Iconsax.edit_2, size: 18),
//                 label: const Text('Edit'),
//                 style: ElevatedButton.styleFrom(
//                   backgroundColor: AppColors.primary,
//                   foregroundColor: Colors.white,
//                   padding: const EdgeInsets.symmetric(vertical: 14),
//                   elevation: 0,
//                   shape: RoundedRectangleBorder(
//                     borderRadius: BorderRadius.circular(12),
//                   ),
//                 ),
//               ),
//             ),
//             const SizedBox(width: 8),

//             // Delete Button
//             Container(
//               decoration: BoxDecoration(
//                 color: AppColors.error.withOpacity(0.1),
//                 borderRadius: BorderRadius.circular(12),
//               ),
//               child: IconButton(
//                 onPressed: onDelete,
//                 icon: const Icon(Iconsax.trash, color: AppColors.error),
//                 padding: const EdgeInsets.all(14),
//                 tooltip: 'Delete',
//               ),
//             ),
//           ],
//         ),
//       ],
//     ),
//   );
// }


// Widget _buildSafetyScoreSection({
//   required int score,
//   required String category,
//   required String emoji,
//   int? aqi,
//   double? temperature,
// }) {
//   // Determine colors based on score
//   Color scoreColor;
//   Color bgColor;
//   Color borderColor;
  
//   if (score >= 85) {
//     scoreColor = Colors.green;
//     bgColor = Colors.green.withOpacity(0.1);
//     borderColor = Colors.green.withOpacity(0.3);
//   } else if (score >= 70) {
//     scoreColor = Colors.amber;
//     bgColor = Colors.amber.withOpacity(0.1);
//     borderColor = Colors.amber.withOpacity(0.3);
//   } else if (score >= 50) {
//     scoreColor = Colors.orange;
//     bgColor = Colors.orange.withOpacity(0.1);
//     borderColor = Colors.orange.withOpacity(0.3);
//   } else {
//     scoreColor = AppColors.error;
//     bgColor = AppColors.error.withOpacity(0.1);
//     borderColor = AppColors.error.withOpacity(0.3);
//   }

//   return Container(
//     padding: const EdgeInsets.all(16),
//     decoration: BoxDecoration(
//       color: bgColor,
//       borderRadius: BorderRadius.circular(16),
//       border: Border.all(color: borderColor, width: 2),
//     ),
//     child: Column(
//       children: [
//         // Score Display
//         Row(
//           children: [
//             // Score Circle
//             Container(
//               width: 60,
//               height: 60,
//               decoration: BoxDecoration(
//                 color: scoreColor.withOpacity(0.2),
//                 shape: BoxShape.circle,
//               ),
//               child: Center(
//                 child: Text(
//                   emoji,
//                   style: const TextStyle(fontSize: 28),
//                 ),
//               ),
//             ),
//             const SizedBox(width: 16),
            
//             // Score Details
//             Expanded(
//               child: Column(
//                 crossAxisAlignment: CrossAxisAlignment.start,
//                 children: [
//                   Row(
//                     children: [
//                       Text(
//                         'Safety Score',
//                         style: TextStyle(
//                           fontSize: 12,
//                           color: AppColors.textSecondary,
//                           fontWeight: FontWeight.w500,
//                         ),
//                       ),
//                       const SizedBox(width: 8),
//                       Container(
//                         padding: const EdgeInsets.symmetric(
//                           horizontal: 8,
//                           vertical: 2,
//                         ),
//                         decoration: BoxDecoration(
//                           color: scoreColor.withOpacity(0.2),
//                           borderRadius: BorderRadius.circular(8),
//                         ),
//                         child: Text(
//                           category.toUpperCase(),
//                           style: TextStyle(
//                             fontSize: 10,
//                             fontWeight: FontWeight.bold,
//                             color: scoreColor,
//                           ),
//                         ),
//                       ),
//                     ],
//                   ),
//                   const SizedBox(height: 4),
//                   Text(
//                     '$score / 100',
//                     style: TextStyle(
//                       fontSize: 24,
//                       fontWeight: FontWeight.bold,
//                       color: scoreColor,
//                     ),
//                   ),
//                 ],
//               ),
//             ),
//           ],
//         ),
        
//         // Environmental Data
//         if (aqi != null || temperature != null) ...[
//           const SizedBox(height: 12),
//           const Divider(height: 1),
//           const SizedBox(height: 12),
          
//           Row(
//             children: [
//               if (aqi != null) ...[
//                 Expanded(
//                   child: _buildEnvironmentalStat(
//                     icon: Iconsax.wind_2,
//                     label: 'Air Quality',
//                     value: 'AQI $aqi',
//                     color: _getAqiColor(aqi),
//                   ),
//                 ),
//               ],
//               if (aqi != null && temperature != null)
//                 Container(
//                   width: 1,
//                   height: 40,
//                   color: AppColors.border,
//                   margin: const EdgeInsets.symmetric(horizontal: 12),
//                 ),
//               if (temperature != null) ...[
//                 Expanded(
//                   child: _buildEnvironmentalStat(
//                     icon: Iconsax.sun_1,
//                     label: 'Temperature',
//                     value: '${temperature.toInt()}°C',
//                     color: _getTempColor(temperature),
//                   ),
//                 ),
//               ],
//             ],
//           ),
//         ],
//       ],
//     ),
//   );
// }


// Widget _buildEnvironmentalStat({
//   required IconData icon,
//   required String label,
//   required String value,
//   required Color color,
// }) {
//   return Column(
//     children: [
//       Icon(icon, size: 20, color: color),
//       const SizedBox(height: 4),
//       Text(
//         label,
//         style: TextStyle(
//           fontSize: 10,
//           color: AppColors.textSecondary,
//         ),
//       ),
//       const SizedBox(height: 2),
//       Text(
//         value,
//         style: TextStyle(
//           fontSize: 14,
//           fontWeight: FontWeight.bold,
//           color: color,
//         ),
//       ),
//     ],
//   );
// }

// Color _getAqiColor(int aqi) {
//   if (aqi <= 50) return Colors.green;
//   if (aqi <= 100) return Colors.amber;
//   if (aqi <= 150) return Colors.orange;
//   return AppColors.error;
// }

// Color _getTempColor(double temp) {
//   if (temp < 10) return Colors.blue;
//   if (temp < 25) return Colors.green;
//   if (temp < 35) return Colors.amber;
//   return AppColors.error;
// }

// String _formatDateRange(String? start, String? end) {
//   if (start == null) return 'No dates selected';
//   try {
//     final startDate = DateTime.parse(start);
//     final formatter = DateFormat('MMM d, yyyy');
//     if (end == null) return formatter.format(startDate);
//     final endDate = DateTime.parse(end);
//     return '${DateFormat('MMM d').format(startDate)} - ${formatter.format(endDate)}';
//   } catch (e) {
//     return 'Invalid date';
//   }
// }
  
//   // Keep your existing _formatDateRange method inside the class or globally
//   // String _formatDateRange(String? start, String? end) {
//   //   if (start == null) return 'No dates selected';
//   //   try {
//   //     final startDate = DateTime.parse(start);
//   //     final formatter = DateFormat('MMM d, yyyy');
//   //     if (end == null) return formatter.format(startDate);
//   //     final endDate = DateTime.parse(end);
//   //     return '${DateFormat('MMM d').format(startDate)} - ${formatter.format(endDate)}';
//   //   } catch (e) {
//   //     return 'Invalid date';
//   //   }
//   // }
// }

class _FilterSheet extends StatelessWidget {
  final Set<PlaceFilter> activeFilters;
  final ValueChanged<PlaceFilter> onToggle;
  const _FilterSheet({required this.activeFilters, required this.onToggle});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration:  BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Show on Map',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              _FilterChip(
                filter: PlaceFilter.hotels,
                label: 'Hotels',
                icon: Iconsax.building,
                isActive: activeFilters.contains(PlaceFilter.hotels),
                onTap: () => onToggle(PlaceFilter.hotels),
              ),
              _FilterChip(
                filter: PlaceFilter.restaurants,
                label: 'Restaurants',
                icon: Iconsax.cup,
                isActive: activeFilters.contains(PlaceFilter.restaurants),
                onTap: () => onToggle(PlaceFilter.restaurants),
              ),
              _FilterChip(
                filter: PlaceFilter.attractions,
                label: 'Attractions',
                icon: Iconsax.camera,
                isActive: activeFilters.contains(PlaceFilter.attractions),
                onTap: () => onToggle(PlaceFilter.attractions),
              ),
              _FilterChip(
                filter: PlaceFilter.hospitals,
                label: 'Hospitals',
                icon: Iconsax.hospital,
                isActive: activeFilters.contains(PlaceFilter.hospitals),
                onTap: () => onToggle(PlaceFilter.hospitals),
              ),
            ],
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final PlaceFilter filter;
  final String label;
  final IconData icon;
  final bool isActive;
  final VoidCallback onTap;
  const _FilterChip({
    required this.filter,
    required this.label,
    required this.icon,
    required this.isActive,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final color = _getColor();
    return FilterChip(
      label: Text(label),
      avatar: Icon(icon, color: isActive ? Colors.white : color, size: 18),
      selected: isActive,
      onSelected: (_) => onTap(),
      selectedColor: color,
      checkmarkColor: Colors.white,
      labelStyle: TextStyle(
        color: isActive ? Colors.white : AppColors.textPrimary,
        fontWeight: FontWeight.w600,
      ),
      backgroundColor: AppColors.surfaceVariant,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    );
  }

  Color _getColor() {
    switch (filter) {
      case PlaceFilter.hotels:
        return AppColors.primary;
      case PlaceFilter.restaurants:
        return AppColors.success;
      case PlaceFilter.attractions:
        return AppColors.warning;
      case PlaceFilter.hospitals:
        return AppColors.error;
    }
  }
}

class _EditDestinationSheet extends StatefulWidget {
  final Map<String, dynamic> destination;
  const _EditDestinationSheet({required this.destination});
  @override
  State<_EditDestinationSheet> createState() => _EditDestinationSheetState();
}

class _EditDestinationSheetState extends State<_EditDestinationSheet> {
  late TextEditingController _nameController;
  DateTime? _startDate;
  DateTime? _endDate;
  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.destination['name']);
    if (widget.destination['date_range_start'] != null) {
      _startDate = DateTime.parse(widget.destination['date_range_start']);
    }
    if (widget.destination['date_range_end'] != null) {
      _endDate = DateTime.parse(widget.destination['date_range_end']);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _selectDateRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDateRange:
          _startDate != null && _endDate != null
              ? DateTimeRange(start: _startDate!, end: _endDate!)
              : null,
      builder:
          (context, child) => Theme(
            data: ThemeData.light().copyWith(
              colorScheme:  ColorScheme.light(
                primary: AppColors.primary,
                onPrimary: Colors.white,
              ),
            ),
            child: child!,
          ),
    );
    if (range != null) {
      setState(() {
        _startDate = range.start;
        _endDate = range.end;
      });
    }
  }

  void _save() {
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please enter a name')));
      return;
    }
    Navigator.pop(context, {
      'name': _nameController.text.trim(),
      'date_range_start': _startDate?.toIso8601String(),
      'date_range_end': _endDate?.toIso8601String(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        left: 24,
        right: 24,
        top: 20,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Edit Destination',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 20),
          TextField(
  controller: _nameController,
  decoration: InputDecoration(
    labelText: 'Destination Name',
    labelStyle: TextStyle(color: AppColors.textSecondary), // ADDED
    prefixIcon: const Icon(Iconsax.location),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: AppColors.border), // ADDED
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: AppColors.border), // ADDED
    ),
  ),
  style: TextStyle(color: AppColors.textPrimary), // ADDED
),
          const SizedBox(height: 16),
          InkWell(
            onTap: _selectDateRange,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                   Icon(Iconsax.calendar, color: AppColors.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _startDate != null
                          ? '${DateFormat('MMM d, yyyy').format(_startDate!)} - ${DateFormat('MMM d, yyyy').format(_endDate!)}'
                          : 'Select dates',
                      style: TextStyle(
                        color:
                            _startDate != null
                                ? AppColors.textPrimary
                                : AppColors.textHint,
                      ),
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios, size: 16),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                'Save Changes',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
// ============================================================================
// GEOFENCE DETAIL CARD
// ============================================================================

class _GeofenceDetailCard extends StatelessWidget {
  final Map<String, dynamic> geofence;
  final VoidCallback onClose;

  const _GeofenceDetailCard({
    required this.geofence,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final riskLevel = geofence['risk_level'] as String? ?? 'LOW';
    final severityScore = (geofence['severity_score']?.toDouble() ?? 0.0) * 100;
    final reasoning = geofence['reasoning'] as String? ?? 'No details available';
    final city = geofence['city'] as String? ?? 'Unknown';
    final createdAt = geofence['created_at'] as String?;
    
    Color riskColor;
    IconData riskIcon;
    
    if (riskLevel == 'CRITICAL') {
      riskColor = AppColors.error;
      riskIcon = Iconsax.danger;
    } else if (riskLevel == 'MEDIUM') {
      riskColor = AppColors.warning;
      riskIcon = Iconsax.warning_2;
    } else {
      riskColor = AppColors.info;
      riskIcon = Iconsax.info_circle;
    }

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 30,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: riskColor.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(riskIcon, color: riskColor, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      geofence['title'] ?? 'Danger Zone',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '$city • ${riskLevel} Risk',
                      style: TextStyle(
                        color: riskColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onClose,
                icon: const Icon(Icons.close),
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.surfaceVariant,
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 20),
          
          // Severity Score
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: riskColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: riskColor.withOpacity(0.3),
                width: 2,
              ),
            ),
            child: Row(
              children: [
                CircularProgressIndicator(
                  value: severityScore / 100,
                  backgroundColor: riskColor.withOpacity(0.2),
                  valueColor: AlwaysStoppedAnimation(riskColor),
                  strokeWidth: 6,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Severity Score',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${severityScore.toInt()}%',
                        style: TextStyle(
                          color: riskColor,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 20),
          
          // Reasoning
          Text(
            'Why this zone was created:',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              reasoning,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ),
          
          if (createdAt != null) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  Iconsax.clock,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Created: ${_formatDate(createdAt)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ],
          
          const SizedBox(height: 20),
          
          // Actions
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('Close'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: BorderSide(color: AppColors.border),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    // Navigate away or get directions
                    onClose();
                  },
                  icon: const Icon(Iconsax.routing, size: 18),
                  label: const Text('Avoid'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: riskColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
  
  String _formatDate(String isoDate) {
    try {
      final date = DateTime.parse(isoDate);
      final now = DateTime.now();
      final diff = now.difference(date);
      
      if (diff.inMinutes < 60) {
        return '${diff.inMinutes}m ago';
      } else if (diff.inHours < 24) {
        return '${diff.inHours}h ago';
      } else {
        return '${diff.inDays}d ago';
      }
    } catch (e) {
      return 'Recently';
    }
  }
}