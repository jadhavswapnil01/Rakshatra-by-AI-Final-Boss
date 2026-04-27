import 'dart:async';
import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:tourist_safety/screens/groups/group_settings_screen.dart';
import 'package:tourist_safety/utils/app_colors.dart';
import 'package:tourist_safety/services/api_service.dart';
import 'package:tourist_safety/services/database_service.dart';
import 'package:tourist_safety/services/ble_emergency_service.dart';
import 'package:tourist_safety/models/group_model.dart';
import 'package:tourist_safety/screens/groups/create_group_screen.dart';
import 'package:tourist_safety/screens/groups/group_detail_screen.dart';
import 'package:tourist_safety/screens/groups/qr_scanner_screen.dart';
import 'package:tourist_safety/screens/groups/ble_emergency_screen.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tourist_safety/main_screen.dart';
import 'package:tourist_safety/utils/theme_manager.dart';

class GroupsScreen extends StatefulWidget {
  const GroupsScreen({super.key});

  @override
  State<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends State<GroupsScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  final ApiService _apiService = ApiService();
  final DatabaseService _dbService = DatabaseService();
  final BleEmergencyService _bleService = BleEmergencyService();

  List<GroupModel> _activeGroups = [];
  List<GroupModel> _pastGroups = [];
  bool _isLoading = true;
  String? _errorMessage;
  String? _currentUserId;

  // BLE states
  bool _isBleSupported = false;
  bool _isBluetoothEnabled = false;
  bool _isBleScanning = false;
  bool _isBroadcasting = false;
  List<BleEmergencyMessage> _emergencyMessages = [];
  bool _offlineSosLoading = false;

  DateTime? _broadcastStartTime;
  Timer? _broadcastElapsedTimer;
  String _broadcastElapsedText = '00:00';
  bool _groupSosLoading = false;
  String? _loadingGroupId;
  ScrollController _scrollController = ScrollController(); // 1. Add ScrollController
  bool _showHeaderActions = false; // 2. Track header state

  @override
void initState() {
  
  super.initState();
  ThemeManager().addListener(_onThemeChanged);
  _setupAnimations();
  _loadGroups();
  _loadCurrentUserId();
  _initializeBle();
  
  // 3. Setup Scroll Listener
  _scrollController.addListener(() {
    // Threshold: when the Action Card (Create/Scan) scrolls out of view
    // Approx height of Action Card + margins is around 140px
    if (_scrollController.offset > 120 && !_showHeaderActions) {
      setState(() => _showHeaderActions = true);
    } else if (_scrollController.offset <= 120 && _showHeaderActions) {
      setState(() => _showHeaderActions = false);
    }
  });
}

  Future<void> _loadCurrentUserId() async {
    final user = await _dbService.getUserProfile();
    if (mounted && user != null) {
      setState(() {
        _currentUserId = user.id;
      });
    }
  }

  void _setupAnimations() {
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeIn),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.2),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOutCubic),
    );
    _animationController.forward();
  }

  Future<void> _initializeBle() async {
    try {
      await _bleService.initialize();

      final bleSupported = await _bleService.checkBleSupport();
      final bluetoothEnabled = await _bleService.isBluetoothEnabled();

      if (mounted) {
        setState(() {
          _isBleSupported = bleSupported;
          _isBluetoothEnabled = bluetoothEnabled;
        });
      }

      // Listen to BLE state changes
      _bleService.scanningStateStream.listen((scanning) {
        if (mounted) {
          setState(() {
            _isBleScanning = scanning;
          });
        }
      });

      _bleService.broadcastingStateStream.listen((broadcasting) {
        if (!mounted) return;
        setState(() {
          _isBroadcasting = broadcasting;
          if (broadcasting) {
            _broadcastStartTime = DateTime.now();
            // start elapsed timer
            _broadcastElapsedTimer?.cancel();
            _broadcastElapsedTimer = Timer.periodic(
              const Duration(seconds: 1),
              (_) {
                if (!mounted) return;
                final start = _broadcastStartTime;
                if (start == null) return;
                final diff = DateTime.now().difference(start);
                setState(() {
                  _broadcastElapsedText = _formatDuration(diff);
                });
              },
            );
          } else {
            // stopped
            _broadcastStartTime = null;
            _broadcastElapsedTimer?.cancel();
            _broadcastElapsedTimer = null;
            _broadcastElapsedText = '00:00';
          }
        });
      });

      // CRITICAL: Listen to Bluetooth state changes
      _bleService.bluetoothStateStream.listen((enabled) {
        if (mounted) {
          setState(() {
            _isBluetoothEnabled = enabled;
            // If Bluetooth is disabled, update scanning/broadcasting states
            if (!enabled) {
              _isBleScanning = false;
              _isBroadcasting = false;
            }
          });
        }
      });

      // Listen to emergency messages
      _bleService.messageStream.listen((message) {
        if (mounted) {
          setState(() {
            _emergencyMessages.insert(0, message);
            if (_emergencyMessages.length > 10) {
              _emergencyMessages = _emergencyMessages.take(10).toList();
            }
          });

          // Show urgent notifications for SOS messages
          if (message.messageType == BleEmergencyMessageType.sos ||
              message.messageType == BleEmergencyMessageType.groupSos) {
            _showEmergencyDialog(message);
          }
        }
      });
    } catch (e) {
      debugPrint('Failed to initialize BLE: $e');
    }
  }

  void _showEmergencyDialog(BleEmergencyMessage message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            backgroundColor: AppColors.error,
            title: Row(
              children: [
                const Icon(Iconsax.danger, color: Colors.white, size: 24),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'EMERGENCY ALERT',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message.messageType == BleEmergencyMessageType.groupSos
                      ? 'Group member needs help!'
                      : 'Tourist nearby needs help!',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Location: ${message.latitude.toStringAsFixed(6)}, ${message.longitude.toStringAsFixed(6)}',
                  style: const TextStyle(color: Colors.white70),
                ),
                Text(
                  'Distance: ${message.formattedDistance}',
                  style: const TextStyle(color: Colors.white70),
                ),
                Text(
                  'Time: ${_formatTime(message.timestamp)}',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK', style: TextStyle(color: Colors.white)),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder:
                          (context) => BleEmergencyScreen(message: message),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppColors.error,
                ),
                child: const Text('View Details'),
              ),
            ],
          ),
    );
  }

  String _formatTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else {
      return '${difference.inDays}d ago';
    }
  }

 @override
void dispose() {
  ThemeManager().removeListener(_onThemeChanged);
  _animationController.dispose();
  _bleService.dispose();
  _broadcastElapsedTimer?.cancel();
  _scrollController.dispose(); // 4. Dispose controller
  super.dispose();
}
void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      final hours = d.inHours.toString().padLeft(2, '0');
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  Future<void> _loadGroups() async {
    try {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });

      final groups = await _apiService.getMyGroups();

      // Separate active and past groups
      final activeGroups = <GroupModel>[];
      final pastGroups = <GroupModel>[];

      for (final groupData in groups) {
        final group = GroupModel.fromJson(groupData);

        // Save to local database for offline access
        await _dbService.saveGroup(group);

        // Categorize groups (you can add logic for expired groups)
        if (group.expiresAt == null ||
            DateTime.now().millisecondsSinceEpoch < group.expiresAt!) {
          activeGroups.add(group);
        } else {
          pastGroups.add(group);
        }
      }

      setState(() {
        _activeGroups = activeGroups;
        _pastGroups = pastGroups;
        _isLoading = false;
      });
    } catch (e) {
      // Try to load from local database as fallback
      try {
        final localGroups = await _dbService.getAllGroups();
        setState(() {
          _activeGroups =
              localGroups
                  .where(
                    (g) =>
                        g.expiresAt == null ||
                        DateTime.now().millisecondsSinceEpoch < g.expiresAt!,
                  )
                  .toList();
          _pastGroups =
              localGroups
                  .where(
                    (g) =>
                        g.expiresAt != null &&
                        DateTime.now().millisecondsSinceEpoch >= g.expiresAt!,
                  )
                  .toList();
          _isLoading = false;
          _errorMessage = 'Using offline data. Check your connection.';
        });
      } catch (localError) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load groups: $e';
        });
      }
    }
  }

  Future<void> _createGroup() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const CreateGroupScreen()),
    );

    if (result == true) {
      _loadGroups(); // Refresh the groups list
    }
  }

  Future<void> _scanQRCode() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const QRScannerScreen()),
    );

    if (result == true) {
      _loadGroups(); // Refresh the groups list
    }
  }

  Future<void> _toggleBleScanning() async {
    if (!_isBleSupported) {
      _showSnackBar('BLE is not supported on this device', isError: true);
      return;
    }

    // Check Bluetooth status first
    final bluetoothEnabled = await _bleService.isBluetoothEnabled();

    if (!bluetoothEnabled) {
      // Show dialog to enable Bluetooth
      final shouldEnable = await showDialog<bool>(
        context: context,
        builder:
            (context) => AlertDialog(
              backgroundColor: AppColors.surface,
              title:  Row(
                children: [
                  Icon(Iconsax.bluetooth, color: AppColors.primary),
                  SizedBox(width: 8),
                  Text('Bluetooth Required'),
                ],
              ),
              content: const Text(
                'Emergency scanner requires Bluetooth to be enabled. Would you like to enable it now?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Enable'),
                ),
              ],
            ),
      );

      if (shouldEnable == true) {
        await _bleService.enableBluetooth();
        // Wait for Bluetooth to be enabled
        await Future.delayed(const Duration(seconds: 2));

        // Check again
        final nowEnabled = await _bleService.isBluetoothEnabled();
        if (!nowEnabled) {
          _showSnackBar('Please enable Bluetooth from settings', isError: true);
          return;
        }

        setState(() {
          _isBluetoothEnabled = true;
        });
      } else {
        return;
      }
    }

    // Check permissions
    final hasPermissions = await _bleService.checkPermissions();
    if (!hasPermissions) {
      await _bleService.requestPermissions();
      // Wait a bit for permissions dialog
      await Future.delayed(const Duration(milliseconds: 500));

      // Check again
      final nowHasPermissions = await _bleService.checkPermissions();
      if (!nowHasPermissions) {
        _showSnackBar('Bluetooth permissions are required', isError: true);
        return;
      }
    }

    if (_isBleScanning) {
      await _bleService.stopEmergencyScanning();
      _showSnackBar('Emergency scanning stopped', isError: false);
    } else {
      final success = await _bleService.startEmergencyScanning();
      if (success) {
        _showSnackBar(
          'Emergency scanning started - listening for nearby emergencies',
          isError: false,
        );
      } else {
        _showSnackBar('Failed to start emergency scanning', isError: true);
      }
    }
  }

  Future<void> _triggerOfflineSOS({String? groupId}) async {
    if (_offlineSosLoading) return; // Prevent double-tap

    if (!_isBleSupported) {
      _showSnackBar(
        'BLE not supported - cannot broadcast offline SOS',
        isError: true,
      );
      return;
    }

    // Check Bluetooth
    if (!_isBluetoothEnabled) {
      final shouldEnable = await showDialog<bool>(
        context: context,
        builder:
            (context) => AlertDialog(
              backgroundColor: AppColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Row(
                children: [
                  Icon(Iconsax.bluetooth, color: AppColors.primary, size: 24),
                  const SizedBox(width: 8),
                   Text('Bluetooth Required', style: TextStyle(color: AppColors.textPrimary),),
                ],
              ),
              content:  Text(
                'Offline SOS requires Bluetooth to broadcast emergency signals. Would you like to enable it?',
                style: TextStyle(color: AppColors.textSecondary)
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Enable'),
                ),
              ],
            ),
      );

      if (shouldEnable != true) return;

      await _bleService.enableBluetooth();
      await Future.delayed(const Duration(seconds: 2));

      final nowEnabled = await _bleService.isBluetoothEnabled();
      if (!nowEnabled) {
        _showSnackBar('Please enable Bluetooth from settings', isError: true);
        return;
      }

      setState(() {
        _isBluetoothEnabled = true;
      });
    }

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: AppColors.error,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Row(
              children: [
                Icon(Iconsax.danger, color: Colors.white, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Offline SOS',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This will broadcast an emergency signal via Bluetooth.',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha:0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'How it works:',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _buildInfoRow('Your signal will broadcast via BLE'),
                      _buildInfoRow('Nearby users will receive your alert'),
                      _buildInfoRow(
                        'Users with internet will relay to authorities',
                      ),
                      _buildInfoRow('Works even without internet'),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Cancel', style: TextStyle(color: Colors.white)),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppColors.error,
                ),
                child: const Text('Start Broadcasting'),
              ),
            ],
          ),
    );

    if (confirmed != true) return;

    // Show loading overlay
    setState(() {
      _offlineSosLoading = true;
    });

    bool success = false;
    String? errorMessage;

    try {

      if (_isBleScanning) {
      debugPrint("Stopping scanner before broadcast...");
      await _bleService.stopEmergencyScanning();
      
      // 2. WAIT 500ms
      await Future.delayed(const Duration(milliseconds: 500));
    }
      // Get current location with timeout
      double latitude;
      double longitude;

      try {
        final serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) {
          throw Exception('Location services disabled. Enable GPS.');
        }

        LocationPermission permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          throw Exception('Location permission denied.');
        }

        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 10),
        );

        latitude = position.latitude;
        longitude = position.longitude;
      } catch (e) {
        throw Exception('Failed to get location: $e');
      }

      // Determine message type
      final messageType =
          groupId != null
              ? BleEmergencyMessageType.groupSos
              : BleEmergencyMessageType.sos;

      // Start BLE broadcast
      success = await _bleService.startEmergencyBroadcast(
        messageType: messageType,
        groupId: groupId,
        latitude: latitude,
        longitude: longitude,
      );

      // Try to send to server if online (don't block on failure)
      if (success) {
        _trySendToServer(
          messageType: messageType.value,
          groupId: groupId,
          latitude: latitude,
          longitude: longitude,
        );
      }
    } catch (e) {
      debugPrint('[Offline SOS] Error: $e');
      errorMessage = e.toString();
      success = false;
    } finally {
      setState(() {
        _offlineSosLoading = false;
      });
    }

    // Show result
    if (success) {
      _showSnackBar(
        'Broadcasting emergency via BLE - nearby devices will relay',
        isError: false,
      );
    } else {
      _showSnackBar(
        errorMessage ?? 'Failed to start emergency broadcast',
        isError: true,
      );
    }
  }

  // PATCH 3.1: Helper to build info rows in dialog
  Widget _buildInfoRow(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '• ',
            style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.5),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // PATCH 3.2: Background server sync (non-blocking)
void _trySendToServer({
  required String messageType,
  String? groupId,
  required double latitude,
  required double longitude,
}) async {
  try {
    final user = await _dbService.getUserProfile();
    if (user?.id == null) return;

    // ✅ FIX: Determine correct identifier to send
    // If we have a specific BLE hash, use it. Otherwise use the ID.
    // The backend expects the ID containing the hash, OR just the hash.
    String identifierToSend = user!.id!;
    
    // If the local ID is a timestamp (digits only, > 10 chars), 
    // and we have a stored BLE hash, send the hash instead.
    bool isTimestampId = RegExp(r'^\d{10,}$').hasMatch(identifierToSend);
    
    if (isTimestampId && user.bleHash != null && user.bleHash!.isNotEmpty) {
       identifierToSend = user.bleHash!;
    }

    await _apiService.relayBleEmergency(
      messageType: messageType,
      userId: identifierToSend, // Sending "24BDFF" works better than a timestamp
      groupId: groupId,
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

      debugPrint('[Offline SOS] Successfully synced to server');

      // Show success notification
      if (mounted) {
        _showSnackBar('Emergency synced to authorities', isError: false);
      }
    } catch (e) {
      debugPrint('[Offline SOS] Server sync failed (expected if offline): $e');
      // Don't show error - this is expected when offline
    }
  }

  void _showBleEmergencyHistory() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) =>
                BleEmergencyHistoryScreen(messages: _emergencyMessages),
      ),
    );
  }

  void _showGroupInviteQR(GroupModel group) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Container(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Invite to ${group.name}',
                  style:  TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 16),
                FutureBuilder<String>(
                  future: _generateInviteToken(group.groupId),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const CircularProgressIndicator();
                    } else if (snapshot.hasError) {
                      return Text(
                        'Error generating invite',
                        style: TextStyle(color: AppColors.error),
                      );
                    } else if (snapshot.hasData) {
                      return Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceVariant,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: QrImageView(
                              data: snapshot.data!,
                              version: QrVersions.auto,
                              size: 200,
                              backgroundColor: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Scan this QR code to join the group',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      );
                    }
                    return const SizedBox();
                  },
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          // TODO: Share invite link functionality
                          Navigator.pop(context);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Share Link'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<String> _generateInviteToken(String groupId) async {
    try {
      final response = await _apiService.createGroupInvite(groupId);
      return response['invite_token'];
    } catch (e) {
      throw Exception('Failed to generate invite: $e');
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppColors.error : AppColors.success,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // inside _GroupsScreenState

@override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          // 1. Scrollable Content (Bottom Layer)
          Positioned.fill(
            child: RefreshIndicator(
              onRefresh: _loadGroups,
              edgeOffset: 100, // Show refresh indicator below header
              child: SingleChildScrollView(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                // Add Top Padding for Header
                padding: const EdgeInsets.fromLTRB(16.0, 110.0, 16.0, 16.0), 
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: SlideTransition(
                    position: _slideAnimation,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_errorMessage != null)
                          Container(
                            margin: const EdgeInsets.only(bottom: 16),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.error.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.error.withOpacity(0.3)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Iconsax.warning_2, color: AppColors.error, size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(_errorMessage!,
                                      style: const TextStyle(color: AppColors.error, fontSize: 14)),
                                ),
                              ],
                            ),
                          ),

                        _buildSectionTitle('Actions'),
                        _buildActionCard(),
                        const SizedBox(height: 16),

                        if (_isBleSupported) _buildBleEmergencyCard(),
                        const SizedBox(height: 24),

                        if (_isLoading)
                          const Center(
                              child: Padding(
                                  padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
                        else ...[
                          if (_activeGroups.isNotEmpty) ...[
                            _buildSectionTitle('Active Groups (${_activeGroups.length})'),
                            ..._activeGroups.map((group) => Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _buildActiveGroupCard(group))),
                            const SizedBox(height: 24),
                          ],
                          if (_pastGroups.isNotEmpty) ...[
                            _buildSectionTitle('Past Groups (${_pastGroups.length})'),
                            ..._pastGroups.map((group) => Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _buildPastGroupCard(group))),
                          ],
                          if (_activeGroups.isEmpty && _pastGroups.isEmpty) _buildEmptyState(),
                        ],
                        const SizedBox(height: 90), // Bottom spacer for Nav Bar
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 2. Floating Header (Top Layer)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: _buildFloatingHeader(),
            ),
          ),
        ],
      ),
    );
  }

  
Widget _buildFloatingHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Container(
        height: 60, 
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        // padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
        child: Row(
          children: [
            // Left: Title
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child:  Icon(Iconsax.people, color: AppColors.primary, size: 20),
            ),
            const SizedBox(width: 12),
            
             Text(
              'My Groups',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),

            // Scanner Indicator (Minimalistic)
            if (_isBleScanning) ...[
              const SizedBox(width: 8),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.0, end: 1.0),
                duration: const Duration(seconds: 2),
                builder: (context, value, child) {
                  return Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: AppColors.success.withOpacity(1.0 - value),
                      shape: BoxShape.circle,
                    ),
                  );
                },
                onEnd: () => setState(() {}), // Loop animation
              ),
            ],

            const Spacer(),

            // Right: Dynamic Actions
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              reverseDuration: const Duration(milliseconds: 250),
              // FIX 1: Use specific layout builder to anchor items to the Right
              layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
                return Stack(
                  alignment: Alignment.centerRight,
                  children: <Widget>[
                    ...previousChildren,
                    if (currentChild != null) currentChild,
                  ],
                );
              },
              // FIX 2: Remove ScaleTransition, use only Fade
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: child, 
              ),
              child: _showHeaderActions
                  ? Row(
                      key: const ValueKey('actions'),
                      mainAxisSize: MainAxisSize.min, // Important for alignment
                      children: [
                        // Mini Create Button
                        IconButton(
                          onPressed: _createGroup,
                          icon:  Icon(Iconsax.add_square, color: AppColors.primary),
                          tooltip: 'Create Group',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                        const SizedBox(width: 16),
                        // Mini Scan Button
                        IconButton(
                          onPressed: _scanQRCode,
                          icon:  Icon(Iconsax.scan, color: AppColors.primary),
                          tooltip: 'Scan QR',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    )
                  : // Default State: Notifications & Refresh
                    Row(
                      key: const ValueKey('default'),
                      mainAxisSize: MainAxisSize.min, // Important for alignment
                      children: [
                        if (_emergencyMessages.isNotEmpty)
                          IconButton(
                            onPressed: _showBleEmergencyHistory,
                            icon: Badge(
                              label: Text('${_emergencyMessages.length}'),
                              child:  Icon(Iconsax.notification, color: AppColors.textSecondary),
                            ),
                          ),
                        IconButton(
                          onPressed: _loadGroups,
                          icon: Icon(
                            Iconsax.refresh, 
                            color: _isLoading ? AppColors.textHint : AppColors.textSecondary
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBleEmergencyCard() {
return Card(
    elevation: 0, // Removed elevation for cleaner look
    // FIX: Ensure this doesn't turn black. Use explicit colors.
    color: _isBleScanning
        ? const Color(0xFFF0FDF4) // Very light green (Tailwind Green-50 equivalent)
        : AppColors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20), // Matching other cards
      side: BorderSide(
        color: _isBleScanning
            ? AppColors.success.withValues(alpha: 0.3)
            : AppColors.border.withValues(alpha: 0.3),
        width: 1,
      ),
    ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header Row
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (_isBleScanning
                            ? AppColors.success
                            : AppColors.primary)
                        .withValues(alpha:0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Iconsax.radar_2,
                    color:
                        _isBleScanning ? AppColors.success : AppColors.primary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Emergency Scanner',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                          color:
                              _isBleScanning
                                  ? AppColors.success
                                  : AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _isBleScanning
                            ? 'Listening for nearby emergencies'
                            : _isBluetoothEnabled
                            ? 'Tap to scan for offline emergencies'
                            : 'Enable Bluetooth to scan',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),

                // Toggle/Enable Button
                if (!_isBluetoothEnabled)
                  _buildEnableBluetoothButton()
                else
                  _buildScanToggle(),
              ],
            ),

            // Broadcasting Status (if active)
            if (_isBroadcasting) ...[
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
              _buildBroadcastingStatus(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEnableBluetoothButton() {
    return ElevatedButton.icon(
      onPressed: _toggleBleScanning,
      icon: const Icon(Iconsax.bluetooth, size: 14),
      label: const Text('Enable', style: TextStyle(fontSize: 12)),
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: Size.zero,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  // PATCH 2.2: Scan Toggle Switch
  Widget _buildScanToggle() {
    return Transform.scale(
      scale: 0.85,
      child: Switch(
        value: _isBleScanning,
        onChanged: (_) => _toggleBleScanning(),
        activeColor: AppColors.success,
        activeTrackColor: AppColors.success.withValues(alpha:0.3),
        inactiveThumbColor: AppColors.textHint,
        inactiveTrackColor: AppColors.textHint.withValues(alpha:0.2),
      ),
    );
  }

  // PATCH 2.3: Broadcasting Status Widget
  Widget _buildBroadcastingStatus() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha:0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.error.withValues(alpha:0.2), width: 1),
      ),
      child: Row(
        children: [
          // Animated indicator
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 1000),
            builder: (context, value, child) {
              return Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha:value),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.error.withValues(alpha:0.5 * value),
                      blurRadius: 8 * value,
                      spreadRadius: 2 * value,
                    ),
                  ],
                ),
              );
            },
            onEnd: () {
              // Restart animation
              if (mounted && _isBroadcasting) {
                setState(() {});
              }
            },
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Offline SOS Broadcasting',
                      style: TextStyle(
                        color: AppColors.error,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'LIVE',
                      style: TextStyle(
                        color: AppColors.error,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _broadcastElapsedText.isEmpty
                      ? '00:00'
                      : _broadcastElapsedText,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          // Stop button
          TextButton(
            onPressed: () async {
              await _bleService.stopEmergencyBroadcast();
              _showSnackBar('Emergency broadcast stopped', isError: false);
            },
            style: TextButton.styleFrom(
              backgroundColor: AppColors.error.withValues(alpha:0.15),
              foregroundColor: AppColors.error,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: Size.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            child: const Text(
              'STOP',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Text(
        title,
        style:  TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }

  Widget _buildActionCard() {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border.withValues(alpha:0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Iconsax.add_square, size: 20),
              label: const Text('Create'),
              onPressed: _createGroup,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side:  BorderSide(color: AppColors.primary),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: ElevatedButton.icon(
              icon: const Icon(Iconsax.scan, size: 20),
              label: const Text('Scan QR'),
              onPressed: _scanQRCode,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 2,
                shadowColor: AppColors.primary.withValues(alpha:0.4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveGroupCard(GroupModel group) {
    return Card(
      elevation: 2,
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppColors.success.withValues(alpha:0.3), width: 1.5),
      ),
      child: InkWell(
        onTap: () async {
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => GroupDetailScreen(group: group),
            ),
          );
          if (result == true) _loadGroups();
        },
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header Row
              Row(
                children: [
                  // Group Avatar
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          AppColors.primary.withValues(alpha:0.8),
                          AppColors.primary,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha:0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Iconsax.people,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Group Info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                group.name,
                                style:  TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 17,
                                  color: AppColors.textPrimary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (group.myRole == 'ADMIN') ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.primary.withValues(alpha:0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  'ADMIN',
                                  style: TextStyle(
                                    color: AppColors.primary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Iconsax.user,
                              size: 14,
                              color: AppColors.textSecondary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${group.memberCount} members',
                              style:  TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              width: 3,
                              height: 3,
                              decoration:  BoxDecoration(
                                color: AppColors.textHint,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              group.visibility,
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // Menu Button
                  PopupMenuButton<String>(
                    color: AppColors.surface,
                    icon: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: AppColors.textHint.withValues(alpha:0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Iconsax.more,
                        size: 18,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    offset: const Offset(0, 40),
                    onSelected: (value) {
                      switch (value) {
                        case 'invite':
                          _showGroupInviteQR(group);
                          break;
                        case 'settings':
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder:
                                  (context) =>
                                      GroupSettingsScreen(group: group),
                            ),
                          ).then((result) {
                            if (result == true) {
                              setState(() {});
                              _loadGroups();
                            }
                          });
                          break;
                        case 'leave':
                          _confirmLeaveGroup(group);
                          break;
                      }
                    },
                    itemBuilder:
                        (context) => [
                          if (group.myRole == 'ADMIN') ...[
                            PopupMenuItem(
                              value: 'invite',
                              child: Row(
                                children: [
                                  Icon(
                                    Iconsax.share,
                                    size: 18,
                                    color: AppColors.primary,
                                  ),
                                  const SizedBox(width: 12),
                                   Text('Invite Members'
                                  , style: TextStyle(color: AppColors.textPrimary)),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'settings',
                              child: Row(
                                children: [
                                  Icon(
                                    Iconsax.setting_2,
                                    size: 18,
                                    color: AppColors.textPrimary,
                                  ),
                                  const SizedBox(width: 12),
                                   Text('Group Settings', style: TextStyle(color: AppColors.textPrimary)),
                                ],
                              ),
                            ),
                            const PopupMenuDivider(),
                          ],
                          PopupMenuItem(
                            value: 'leave',
                            child: Row(
                              children: [
                                Icon(
                                  group.ownerId == _currentUserId
                                      ? Iconsax.trash
                                      : Iconsax.logout,
                                  size: 18,
                                  color: AppColors.error,
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  group.ownerId == _currentUserId
                                      ? 'Delete Group'
                                      : 'Leave Group',
                                  style: TextStyle(color: AppColors.error),
                                ),
                              ],
                            ),
                          ),
                        ],
                  ),
                ],
              ),

              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),

              // Action Buttons Row
              Row(
                children: [
                  // Time Info
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          Iconsax.clock,
                          size: 14,
                          color: AppColors.textSecondary,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            _formatCreatedAt(group.createdAt),
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 8),

                  // Offline SOS Button
                  Expanded(
                    child: _buildCompactButton(
                      label: 'Offline',
                      icon: Iconsax.wifi_square,
                      color: AppColors.warning,
                      onPressed:
                          () => _triggerOfflineSOS(groupId: group.groupId),
                    ),
                  ),

                  const SizedBox(width: 8),

                  // Group SOS Button
                  Expanded(
                    child: _buildCompactButton(
                      label: 'SOS',
                      icon: Iconsax.danger,
                      color: AppColors.error,
                      groupId: group.groupId, // Add this
                      onPressed: () async {
                        await _triggerGroupSOS(group);
                        final dashboardState =
                            context
                                .findAncestorStateOfType<
                                  DashboardScreenState
                                >();
                        if (dashboardState != null) {
                          await dashboardState.checkActiveSOS();
                        }
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // PATCH 1.1: Compact Button Widget
  // Add this helper method to the _GroupsScreenState class

  Widget _buildCompactButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
    String? groupId, // Add this parameter
  }) {
    // Check if this specific button is loading
    final isLoading = _groupSosLoading && _loadingGroupId == groupId;

    return Material(
      color: color.withValues(alpha:0.1),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: isLoading ? null : onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLoading)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                )
              else
                Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPastGroupCard(GroupModel group) {
    return Card(
      elevation: 0,
      color: AppColors.surfaceVariant,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: AppColors.textHint.withValues(alpha:0.2),
            child: Icon(
              Iconsax.archive_1,
              color: AppColors.textSecondary,
              size: 20,
            ),
          ),
          title: Text(
            group.name,
            style:  TextStyle(
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
          subtitle: Text(
            '${group.memberCount} members • Ended ${_formatCreatedAt(group.expiresAt ?? group.createdAt)}',
            style:  TextStyle(color: AppColors.textHint),
          ),
          trailing:  Icon(
            Iconsax.archive_1,
            color: AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          children: [
            Icon(Iconsax.people, size: 64, color: AppColors.textHint),
            const SizedBox(height: 16),
            Text(
              'No Groups Yet',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Create a group or scan a QR code to join one',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textHint, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  String _formatCreatedAt(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays > 0) {
      return '${difference.inDays} days ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours} hours ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes} minutes ago';
    } else {
      return 'Just now';
    }
  }

  Future<void> _triggerGroupSOS(GroupModel group) async {
    if (_groupSosLoading) return; // Prevent double-tap

    // Check for active SOS first
    try {
      setState(() {
        _groupSosLoading = true;
        _loadingGroupId = group.groupId;
      });

      final user = await _dbService.getUserProfile();
      if (user != null) {
        final activeSession = await _dbService.getActiveLiveSession(user.id!);
        if (activeSession != null) {
          setState(() {
            _groupSosLoading = false;
            _loadingGroupId = null;
          });

          // SOS already active - ask to revoke
          final shouldRevoke = await showDialog<bool>(
            context: context,
            builder:
                (context) => AlertDialog(
                  backgroundColor: AppColors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  title: Row(
                    children: [
                      Icon(
                        Iconsax.warning_2,
                        color: AppColors.warning,
                        size: 24,
                      ),
                      const SizedBox(width: 8),
                      const Text('SOS Already Active'),
                    ],
                  ),
                  content: const Text(
                    'You have an active SOS alert. Would you like to revoke it and create a new one for this group?',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.error,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Revoke & Continue'),
                    ),
                  ],
                ),
          );

          if (shouldRevoke != true) return;

          // Revoke existing SOS
          setState(() {
            _groupSosLoading = true;
          });

          await _apiService.stopLiveSession(activeSession.sessionId);
          await _bleService.stopEmergencyBroadcast();
        }
      }
    } catch (e) {
      debugPrint('[Group SOS] Error checking active SOS: $e');
    }

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Row(
              children: [
                Icon(Iconsax.danger, color: AppColors.error, size: 24),
                const SizedBox(width: 8),
                const Text('Group SOS Alert'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This will send an emergency alert to all members of "${group.name}" and authorities.',
                  style: const TextStyle(fontSize: 15),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha:0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.error.withValues(alpha:0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Iconsax.info_circle,
                            size: 16,
                            color: AppColors.error,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'What happens:',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: AppColors.error,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _buildActionItem('Notifies all group members'),
                      _buildActionItem('Alerts local authorities'),
                      _buildActionItem('Starts live location sharing'),
                      _buildActionItem('Begins offline mesh broadcast'),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.error,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                ),
                child: const Text(
                  'Send SOS',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
    );

    if (confirmed != true) {
      setState(() {
        _groupSosLoading = false;
        _loadingGroupId = null;
      });
      return;
    }

    // Execute SOS
    try {
      // Get location
      double latitude;
      double longitude;

      try {
        final serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) {
          throw Exception('Location services disabled');
        }

        LocationPermission permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          throw Exception('Location permission denied');
        }

        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 10),
        );

        latitude = position.latitude;
        longitude = position.longitude;
      } catch (e) {
        setState(() {
          _groupSosLoading = false;
          _loadingGroupId = null;
        });
        _showSnackBar('Failed to get location: $e', isError: true);
        return;
      }

      // Send SOS to server
      await _apiService.triggerSOS(
        latitude: latitude,
        longitude: longitude,
        additionalInfo: 'Group SOS from "${group.name}"',
      );

      // Start BLE broadcast in parallel (don't wait)
      _bleService
          .startEmergencyBroadcast(
            messageType: BleEmergencyMessageType.groupSos,
            groupId: group.groupId,
            latitude: latitude,
            longitude: longitude,
          )
          .then((success) {
            if (success) {
              debugPrint('[Group SOS] BLE broadcast started');
            }
          });

      setState(() {
        _groupSosLoading = false;
        _loadingGroupId = null;
      });

      _showSnackBar('SOS alert sent to group members', isError: false);
    } catch (e) {
      setState(() {
        _groupSosLoading = false;
        _loadingGroupId = null;
      });
      _showSnackBar('Failed to send SOS: $e', isError: true);
    }
  }

  // PATCH 4.1: Helper widget for action items
  Widget _buildActionItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(Iconsax.tick_circle, size: 14, color: AppColors.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: AppColors.error.withValues(alpha:0.9),
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmLeaveGroup(GroupModel group) async {
    if (_currentUserId == null) {
      _showSnackBar(
        'Could not verify your identity. Please try again.',
        isError: true,
      );
      return;
    }

    // final isOwner = group.ownerId == _currentUserId;

    if (group.myRole == 'ADMIN') {
      // Owner must delete the group, not leave
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (context) => AlertDialog(
              backgroundColor: AppColors.surface,
              title: const Text('Delete Group'),
              content: Text(
                'As the owner, you cannot leave this group. You must delete it instead.\n\n'
                'Are you sure you want to delete "${group.name}"? This action cannot be undone and will remove all members.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.error,
                  ),
                  child: const Text(
                    'Delete Group',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
      );

      if (confirmed == true) {
        try {
          await _apiService.deleteGroup(group.groupId);
          _showSnackBar('Group deleted successfully', isError: false);
          _loadGroups();
        } catch (e) {
          _showSnackBar('Failed to delete group: $e', isError: true);
        }
      }
    } else {
      // Regular member can leave
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (context) => AlertDialog(
              backgroundColor: AppColors.surface,
              title: const Text('Leave Group'),
              content: Text('Are you sure you want to leave "${group.name}"?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.error,
                  ),
                  child: const Text(
                    'Leave',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
      );

      if (confirmed == true) {
        try {
          await _apiService.leaveGroup(group.groupId);
          _showSnackBar('Left group successfully', isError: false);
          _loadGroups();
        } catch (e) {
          _showSnackBar('Failed to leave group: $e', isError: true);
        }
      }
    }
  }
}

// BLE Emergency History Screen
class BleEmergencyHistoryScreen extends StatelessWidget {
  final List<BleEmergencyMessage> messages;

  const BleEmergencyHistoryScreen({Key? key, required this.messages})
    : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Emergency History'),
        backgroundColor: AppColors.background,
        elevation: 0,
        foregroundColor: AppColors.textPrimary,
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: messages.length,
        itemBuilder: (context, index) {
          final message = messages[index];
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            color: AppColors.surface,
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: _getMessageColor(
                  message.messageType,
                ).withValues(alpha:0.1),
                child: Icon(
                  _getMessageIcon(message.messageType),
                  color: _getMessageColor(message.messageType),
                ),
              ),
              title: Text(_getMessageTitle(message.messageType)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('From: ${message.userId}'),
                  Text('Distance: ${message.formattedDistance}'),
                  Text('Time: ${_formatTime(message.timestamp)}'),
                ],
              ),
              trailing: IconButton(
                icon: const Icon(Iconsax.location),
                onPressed: () {
                  // TODO: Show location on map
                },
              ),
            ),
          );
        },
      ),
    );
  }

  Color _getMessageColor(BleEmergencyMessageType type) {
    switch (type) {
      case BleEmergencyMessageType.sos:
      case BleEmergencyMessageType.groupSos:
        return AppColors.error;
      case BleEmergencyMessageType.sosResolved:
        return AppColors.success;
    }
  }

  IconData _getMessageIcon(BleEmergencyMessageType type) {
    switch (type) {
      case BleEmergencyMessageType.sos:
      case BleEmergencyMessageType.groupSos:
        return Iconsax.danger;
      case BleEmergencyMessageType.sosResolved:
        return Iconsax.tick_circle;
    }
  }

  String _getMessageTitle(BleEmergencyMessageType type) {
    switch (type) {
      case BleEmergencyMessageType.sos:
        return 'Emergency SOS';
      case BleEmergencyMessageType.groupSos:
        return 'Group Emergency';
      case BleEmergencyMessageType.sosResolved:
        return 'Emergency Resolved';
    }
  }

  String _formatTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else {
      return '${difference.inDays}d ago';
    }
  }
}
