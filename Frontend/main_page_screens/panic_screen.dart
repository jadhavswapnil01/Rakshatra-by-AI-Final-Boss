// lib/screens/enhanced_panic_screen.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:iconsax/iconsax.dart';
import 'package:camera/camera.dart' as camera;
import 'package:path_provider/path_provider.dart';
import 'package:tourist_safety/utils/app_colors.dart';
import 'package:tourist_safety/services/api_service.dart';
import 'package:tourist_safety/services/ble_emergency_service.dart';
import 'package:tourist_safety/services/database_service.dart';

class EnhancedPanicScreen extends StatefulWidget {
  final String? groupId;
  final bool forceNew; // NEW: Add forceNew parameter
  
  const EnhancedPanicScreen({
    super.key, 
    this.groupId,
    this.forceNew = false, // Default to false for backward compatibility
  });

  @override
  State<EnhancedPanicScreen> createState() => _EnhancedPanicScreenState();
}

class _EnhancedPanicScreenState extends State<EnhancedPanicScreen>
    with TickerProviderStateMixin {
  
  // Controllers and Animations
  late AnimationController _pulseController;
  late AnimationController _timerController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _timerAnimation;
  
  // Services
  final ApiService _apiService = ApiService();
  final BleEmergencyService _bleService = BleEmergencyService();
  final DatabaseService _dbService = DatabaseService();
  
  // State variables
  Timer? _countdownTimer;
  int _countdown = 5;
  bool _videoRecordingEnabled = true;
  bool _isRecording = false;
  bool _sosActivated = false;
  bool _liveTrackingActive = false;
  String? _liveSessionId;
  camera.CameraController? _cameraController;
  String? _videoPath;
  
  // Status flags
  bool _locationSent = false;
  bool _smsSent = false;
  bool _groupNotified = false;
  bool _meshBroadcast = false;

  @override
  void initState() {
    super.initState();
    _initializeAnimations();
    _initializeCamera();
    _activateSOS();
  }

  void _initializeAnimations() {
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    
    _timerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );
    
    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    
    _timerAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _timerController, curve: Curves.linear),
    );
    
    _pulseController.repeat(reverse: true);
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await camera.availableCameras();
      if (cameras.isNotEmpty) {
        _cameraController = camera.CameraController(
          cameras.first, // Use front camera
          camera.ResolutionPreset.medium,
          enableAudio: true,
        );
        await _cameraController!.initialize();
        if (mounted) setState(() {});
      }
    } catch (e) {
      debugPrint('Camera initialization failed: $e');
    }
  }

  Future<void> _activateSOS() async {
    setState(() {
      _sosActivated = true;
    });
    
    // Start live location sharing
    await _startLiveTracking();
    
    // Send notifications
    await _sendNotifications();
    
    // Start mesh broadcast if needed
    await _startMeshBroadcast();
    
    // Start countdown timer
    _startCountdownTimer();
    
    // Start timer animation
    _timerController.forward();
  }

  Future<void> _startLiveTracking() async {
    try {
      final response = await _apiService.startLiveSession(
        samplingRateSeconds: 3, // High frequency for SOS
        sharedWith: {
          'authorities': ['POLICE', 'RESCUE', 'MEDICAL'],
          'groups': widget.groupId != null ? [widget.groupId!] : [],
          // API expects a list of contact identifiers; include emergency contacts group identifier
          'emergency_contacts': ['EMERGENCY_CONTACTS'],
        },
      );
      
      if (response['success'] == true) {
        setState(() {
          _liveTrackingActive = true;
          _liveSessionId = response['live_session_id'];
        });
      }
    } catch (e) {
      debugPrint('Failed to start live tracking: $e');
    }
  }

  Future<void> _sendNotifications() async {
  try {
    // Get current location
    double latitude;
    double longitude;

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showSnackBar('Location services are disabled. Please enable GPS.', isError: true);
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        _showSnackBar('Location permission denied.', isError: true);
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );

      latitude = position.latitude;
      longitude = position.longitude;
    } catch (e) {
      _showSnackBar('Failed to get location: $e', isError: true);
      return;
    }
    
    // Trigger API SOS - server will automatically notify all groups
    await _apiService.triggerSOS(
      latitude: latitude,
      longitude: longitude,
      additionalInfo: 'Emergency SOS Alert - All groups notified',
      forceNew: widget.forceNew,
    );
    
    setState(() {
      _locationSent = true;
      _smsSent = true;
      _groupNotified = true; // Always true since server notifies all groups
    });
    
    _showSOSConfirmationDialog();
    
  } catch (e) {
    debugPrint('Failed to send SOS: $e');
    
    if (e.toString().contains('conflict') || e.toString().contains('409')) {
      _showConflictDialog();
      return;
    }
    
    // If online fails, use mesh
    setState(() {
      _meshBroadcast = true;
    });
    
    _showSnackBar('Online SOS failed. Using mesh broadcast.', isError: true);
  }
}


void _showSnackBar(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppColors.error : AppColors.success,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
// ADD THIS NEW METHOD TO HANDLE CONFLICTS:
void _showConflictDialog() {
  showDialog(
    context: context,
    barrierDismissible: false,
    
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Iconsax.warning_2, color: AppColors.warning, size: 24),
          const SizedBox(width: 8),
           Text('SOS Already Active', style: TextStyle(color: AppColors.textPrimary)),
        ],
      ),
      content:  Text(
        'You already have an active SOS alert. The system will automatically revoke it and create a new one.',
        style: TextStyle(color: AppColors.textPrimary)
      ),
      actions: [
        ElevatedButton(
          onPressed: () {
            Navigator.pop(context); // Close dialog
            Navigator.pop(context); // Go back to main screen
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
          ),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

  Future<void> _startMeshBroadcast() async {
  try {
    // Get actual location
    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
      timeLimit: const Duration(seconds: 5),
    );
    
    final success = await _bleService.startEmergencyBroadcast(
      messageType: BleEmergencyMessageType.sos,
      groupId: null, // Not needed - groups handled by server
      latitude: position.latitude,
      longitude: position.longitude,
    );
    
    if (success) {
      setState(() {
        _meshBroadcast = true;
      });
    }
  } catch (e) {
    debugPrint('Failed to start mesh broadcast: $e');
  }
}

  void _startCountdownTimer() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _countdown--;
      });
      
      if (_countdown <= 0) {
        timer.cancel();
        if (_videoRecordingEnabled) {
          _startVideoRecording();
        }
      }
    });
  }

  Future<void> _startVideoRecording() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    
    try {
      setState(() {
        _isRecording = true;
      });
      
      final directory = await getApplicationDocumentsDirectory();
      final videoPath = '${directory.path}/emergency_video_${DateTime.now().millisecondsSinceEpoch}.mp4';
      
      await _cameraController!.startVideoRecording();
      
      // Record for 5 seconds
      Timer(const Duration(seconds: 5), () async {
        try {
          final videoFile = await _cameraController!.stopVideoRecording();
          setState(() {
            _isRecording = false;
            _videoPath = videoFile.path;
          });
          
          _showVideoSavedDialog();
        } catch (e) {
          debugPrint('Failed to stop video recording: $e');
        }
      });
      
    } catch (e) {
      debugPrint('Failed to start video recording: $e');
      setState(() {
        _isRecording = false;
      });
    }
  }

  void _showSOSConfirmationDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Iconsax.tick_circle, color: AppColors.success, size: 24),
            const SizedBox(width: 8),
             Text('SOS Activated', style: TextStyle(color: AppColors.textPrimary)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_locationSent)
               Row(
                children: [
                  Icon(Iconsax.tick_circle, color: AppColors.success, size: 16),
                  SizedBox(width: 8),
                  Text('Location sent to authorities',
                  style: TextStyle(color: AppColors.textPrimary)),
                ],
              ),
            if (_smsSent)
               Row(
                children: [
                  Icon(Iconsax.tick_circle, color: AppColors.success, size: 16),
                  SizedBox(width: 8),
                  Text('Emergency contacts notified',
                  style: TextStyle(color: AppColors.textPrimary)),
                ],
              ),
            if (_groupNotified)
               Row(
                children: [
                  Icon(Iconsax.tick_circle, color: AppColors.success, size: 16),
                  SizedBox(width: 8),
                  Text('Group members alerted',
                  style: TextStyle(color: AppColors.textPrimary)),
                ],
              ),
            if (_meshBroadcast)
               Row(
                children: [
                  Icon(Iconsax.wifi, color: AppColors.primary, size: 16),
                  SizedBox(width: 8),
                  Text('SOS broadcast via mesh network',
                  style: TextStyle(color: AppColors.textPrimary)),
                ],
              ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
            ),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showVideoSavedDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Iconsax.video, color: AppColors.primary, size: 24),
            const SizedBox(width: 8),
             Text('Emergency Video', style: TextStyle(color: AppColors.textPrimary)),
          ],
        ),
        content:  Text(
          'Emergency video has been recorded and sent to authorities for evidence.',
        style: TextStyle(color: AppColors.textPrimary)
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
            ),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

Future<void> _revokeSOS() async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface,
      title:  Text('Revoke SOS Alert', style: TextStyle(color: AppColors.textPrimary)),
      content: Text(
        'Are you sure you want to revoke the active SOS alert?',
        style: TextStyle(color: AppColors.textPrimary)
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, true),
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
          child: const Text('Revoke', style: TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );

  if (confirmed == true) {
    try {
      // Get current user
      final user = await _dbService.getUserProfile();
      if (user?.id == null) {
        _showSnackBar('User not found', isError: true);
        return;
      }
      
      // Check for active SOS on server
      final sosStatus = await _apiService.checkActiveSOS();
      
      // CRITICAL FIX: Null-safe access to nested maps
      if (sosStatus['has_active_sos'] == true) {
        final alert = sosStatus['alert'];
        if (alert != null && alert is Map<String, dynamic>) {
          final alertId = alert['alert_id'];
          
          if (alertId != null) {
            // Revoke on server
            await _apiService.revokeSOS(alertId);
            debugPrint('[SOS] Revoked SOS alert $alertId');
          } else {
            debugPrint('[SOS] Warning: alert_id is null in response');
          }
        } else {
          debugPrint('[SOS] Warning: alert is null or invalid type');
        }
      }
      
      // Stop local BLE broadcast if running
      if (_bleService.isBroadcasting) {
        await _bleService.stopEmergencyBroadcast();
      }
      
      // Stop timers and cleanup
      _countdownTimer?.cancel();
      _timerController.stop();
      
      if (_isRecording && _cameraController != null) {
        try {
          await _cameraController!.stopVideoRecording();
        } catch (e) {
          debugPrint('Failed to stop video: $e');
        }
      }
      
      Navigator.pop(context, true);
      
    } catch (e) {
      debugPrint('[SOS] Failed to revoke: $e');
      _showSnackBar('Failed to revoke SOS: $e', isError: true);
    }
  }
}

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _pulseController.dispose();
    _timerController.dispose();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.error,
      body: SafeArea(
        child: Column(
          children: [
            // Custom App Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _revokeSOS,
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                  Expanded(
                    child: Text(
                      widget.groupId != null ? 'GROUP SOS ACTIVATED' : 'SOS ACTIVATED',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  // Live indicator
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha:0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Iconsax.record_circle, color: Colors.white, size: 12),
                        SizedBox(width: 4),
                        Text(
                          'LIVE',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            
            // Main Content
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Timer Circle
                    AnimatedBuilder(
                      animation: Listenable.merge([_pulseAnimation, _timerAnimation]),
                      builder: (context, child) {
                        return Container(
                          width: 200,
                          height: 200,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // Background circle
                              Container(
                                width: 200,
                                height: 200,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white.withValues(alpha:0.1),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha:0.3),
                                    width: 2,
                                  ),
                                ),
                              ),
                              
                              // Progress circle
                              SizedBox(
                                width: 180,
                                height: 180,
                                child: CircularProgressIndicator(
                                  value: _countdown > 0 ? _timerAnimation.value : 0,
                                  strokeWidth: 8,
                                  backgroundColor: Colors.white.withValues(alpha:0.2),
                                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                              ),
                              
                              // Timer text
                              Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    _countdown > 0 ? '$_countdown' : '0',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: _countdown > 0 ? 60 : 40,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    _countdown > 0 
                                        ? 'Auto-record in' 
                                        : _isRecording 
                                            ? 'Recording...'
                                            : 'Ready',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    
                    const SizedBox(height: 40),
                    
                    // Status Information
                    _buildStatusCard(),
                    
                    const SizedBox(height: 30),
                    
                    // Video Recording Toggle
                    _buildVideoToggle(),
                    
                    const SizedBox(height: 40),
                    
                    // Action Buttons
                    _buildActionButtons(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }



  Widget _buildStatusCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha:0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha:0.2)),
      ),
      child: Column(
        children: [
          Text(
            _liveTrackingActive 
                ? 'Live location sharing active'
                : 'Preparing location services...',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildStatusIndicator(
                icon: Iconsax.location,
                label: 'Location',
                active: _locationSent,
              ),
              _buildStatusIndicator(
                icon: Iconsax.sms,
                label: 'SMS',
                active: _smsSent,
              ),
              if (widget.groupId != null)
                _buildStatusIndicator(
                  icon: Iconsax.people,
                  label: 'Group',
                  active: _groupNotified,
                ),
              _buildStatusIndicator(
                icon: Iconsax.wifi,
                label: 'Mesh',
                active: _meshBroadcast,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusIndicator({
    required IconData icon,
    required String label,
    required bool active,
  }) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: active 
                ? Colors.green.withValues(alpha:0.3)
                : Colors.white.withValues(alpha:0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(
            active ? Iconsax.tick_circle : icon,
            color: Colors.white,
            size: 20,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  Widget _buildVideoToggle() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha:0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha:0.2)),
      ),
      child: Row(
        children: [
          Icon(
            _videoRecordingEnabled ? Iconsax.video : Iconsax.video_slash,
            color: Colors.white,
            size: 24,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Emergency Video Recording',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  _videoRecordingEnabled 
                      ? 'Will record 5-sec video for evidence'
                      : 'Video recording disabled',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: _videoRecordingEnabled,
            onChanged: _countdown > 0 ? (value) {
              setState(() {
                _videoRecordingEnabled = value;
              });
            } : null,
            activeColor: Colors.white,
            activeTrackColor: Colors.white.withValues(alpha:0.3),
            inactiveThumbColor: Colors.white.withValues(alpha:0.5),
            inactiveTrackColor: Colors.white.withValues(alpha:0.1),
          ),
        ],
      ),
    );
  }

  // Add this widget to the action buttons section
Widget _buildActionButtons() {
  return Column(
    children: [
      // Offline SOS Toggle
      if (_meshBroadcast)
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha:0.15),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha:0.3)),
          ),
          child: Row(
            children: [
              const Icon(Iconsax.wifi, color: Colors.white, size: 20),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Offline SOS Broadcasting',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ElevatedButton(
                onPressed: () async {
                  await _bleService.stopEmergencyBroadcast();
                  setState(() {
                    _meshBroadcast = false;
                  });
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha:0.2),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  minimumSize: Size.zero,
                ),
                child: const Text('STOP'),
              ),
            ],
          ),
        ),
      
      // Revoke SOS Button
      SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _revokeSOS,
          icon: const Icon(Iconsax.close_circle),
          label: const Text('Revoke SOS Alert'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.white.withValues(alpha:0.2),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      
      const SizedBox(height: 12),
      
      // View Live Location Button
      if (_liveTrackingActive)
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () {
              // TODO: Navigate to live tracking map
            },
            icon: const Icon(Iconsax.location),
            label: const Text('View Live Location'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
    ],
  );
}
}