// lib/screens/main_page_screens/home_screen.dart - UPDATED WITH HEADER

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:iconsax/iconsax.dart';
import 'package:file_picker/file_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:tourist_safety/Services/api_service.dart';
import 'package:tourist_safety/Services/foreground_service_handler.dart';
import 'package:tourist_safety/Services/safety_score_manager.dart';
import 'package:tourist_safety/models/safety_score_model.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:tourist_safety/utils/app_colors.dart';
import 'package:tourist_safety/services/medical_service.dart';
import 'package:tourist_safety/services/database_service.dart';
import 'package:tourist_safety/screens/medical/medical_records_screen.dart';
import 'package:tourist_safety/screens/profile/profile_screen.dart';
import 'package:tourist_safety/utils/theme_manager.dart';
import 'package:tourist_safety/widgets/medical_upload_progress_dialog.dart';
import 'package:tourist_safety/services/profile_photo_service.dart';
import 'package:tourist_safety/widgets/safety_service_control_widget.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback onSosPressed;
  
  const HomeScreen({super.key, required this.onSosPressed});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  bool _isScoreExpanded = false;
  int _currentAlertIndex = 0;
  int _currentChatbotActionIndex = 0;
  final ApiService _apiService = ApiService();

  late AnimationController _breathingController;
  late AnimationController _chatbotController;
  late AnimationController _scoreController;
  late AnimationController _headerController;
  late Animation<double> _chatbotFadeAnimation;
  late Animation<double> _scoreAnimation;
  late Animation<double> _headerFadeAnimation;
  late Animation<Offset> _headerSlideAnimation;
  late final PageController _alertsPageController;
  late ScrollController _mainScrollController;
  bool _showMiniScoreInHeader = false;
  final ProfilePhotoService _photoService = ProfilePhotoService();
  String? _profilePhotoPath;
  List<Map<String, dynamic>> _medicalRecords = [];
  bool _isLoadingMedical = false;
  String _userName = 'Tourist';
  String? _userInitials;
  final DatabaseService _dbService = DatabaseService();

  late final Stream<String> _realtimeAlertsStream;
  late final Stream<String> _chatbotStream;

  final List<String> _importantAlerts = [
    "🚨 High-Risk Zone near Hawa Mahal reported",
    "🌡️ Weather Update: High temperatures expected",
    "🎪 Local festival may cause heavy traffic",
    "💧 Stay hydrated: Drink plenty of water today"
  ];

  final List<Map<String, dynamic>> _chatbotActions = [
    {
      'message': 'Hello! I\'m your AI Safety Assistant. How can I help you today?',
      'actions': [
        {'text': 'I feel unsafe', 'color': Colors.orange, 'icon': Iconsax.danger, 'isPrimary': true},
        {'text': 'Share Location', 'color': Colors.blue, 'icon': Iconsax.location, 'isPrimary': false},
      ]
    },
    {
      'message': 'Nearby safe place: City Police Station — 600m away.',
      'actions': [
        {'text': 'Get Directions', 'color': Colors.green, 'icon': Iconsax.routing_2, 'isPrimary': true},
        {'text': 'Call Police', 'color': Colors.red, 'icon': Iconsax.call, 'isPrimary': false},
      ]
    },
  ];

@override
  void initState() {
    super.initState();
    ThemeManager().addListener(_onThemeChanged);
    _setupAnimations();
    _loadUserInfo();
    _loadMedicalRecords();
    _setupTimers();
    _setupStreams();

    // NEW: Initialize Scroll Controller with listener
    _mainScrollController = ScrollController();
    _mainScrollController.addListener(_handleScroll);
      _autoStartSafetyService();
  }


  Future<void> _autoStartSafetyService() async {
  // Wait for everything to settle
  await Future.delayed(const Duration(seconds: 2));
  
  try {
    final serviceHandler = ForegroundServiceHandler();
    if (!serviceHandler.isRunning) {
      final started = await serviceHandler.startService();
      if (started) {
        debugPrint('✅ Auto-started safety service');
        
        // Optional: Show a subtle notification
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Row(
                children: [
                  Icon(Icons.security, color: Colors.white, size: 20),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text('Safety tracking activated'),
                  ),
                ],
              ),
              backgroundColor: AppColors.success,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    }
  } catch (e) {
    debugPrint('⚠️ Failed to auto-start service: $e');
  }
}

  void _handleScroll() {
    // The threshold is approx height of score widget (220) + padding
    final threshold = 200.0; 
    if (_mainScrollController.offset > threshold && !_showMiniScoreInHeader) {
      setState(() => _showMiniScoreInHeader = true);
    } else if (_mainScrollController.offset <= threshold && _showMiniScoreInHeader) {
      setState(() => _showMiniScoreInHeader = false);
    }
  }

  void _setupAnimations() {
    _breathingController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);
    
    _chatbotController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    
    _scoreController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _headerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _chatbotFadeAnimation = CurvedAnimation(
      parent: _chatbotController,
      curve: Curves.easeInOut,
    );
    
    _scoreAnimation = CurvedAnimation(
      parent: _scoreController,
      curve: Curves.elasticOut,
    );

    _headerFadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _headerController, curve: Curves.easeIn),
    );

    _headerSlideAnimation = Tween<Offset>(
      begin: const Offset(0, -0.5),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _headerController, curve: Curves.easeOutCubic),
    );

    _chatbotController.forward();
    _scoreController.forward(from: 0.0);
    _headerController.forward();

    _alertsPageController = PageController(viewportFraction: 0.88);
  }

Future<void> _loadUserInfo() async {
  try {
    final user = await _dbService.getUserProfile();
    if (user != null && mounted) {
      setState(() {
        _userName = user.fullName ?? 'Tourist';
        _userInitials = _getInitials(_userName);
      });
      
      // Load profile photo
      if (user.id != null) {
        final photoPath = await _photoService.getCachedPhotoPath(user.id!);
        if (mounted) {
          setState(() => _profilePhotoPath = photoPath);
        }
      }
    }
  } catch (e) {
    debugPrint('Failed to load user info: $e');
  }
}

  String _getInitials(String name) {
    final parts = name.trim().split(' ');
    if (parts.isEmpty) return 'T';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
  }

  void _setupTimers() {
    Timer.periodic(const Duration(seconds: 6), (timer) {
      if (!mounted) return;
      _currentAlertIndex = (_currentAlertIndex + 1) % _importantAlerts.length;
      _alertsPageController.animateToPage(
        _currentAlertIndex,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOut,
      );
      setState(() {});
    });
    
    Timer.periodic(const Duration(seconds: 12), (timer) {
      if (mounted) {
        _chatbotController.reset();
        _chatbotController.forward();
        setState(() {
          _currentChatbotActionIndex = (_currentChatbotActionIndex + 1) % _chatbotActions.length;
        });
      }
    });
  }

  void _setupStreams() {
    _realtimeAlertsStream = Stream.periodic(
      const Duration(seconds: 6), 
      (c) => _importantAlerts[c % _importantAlerts.length],
    ).asBroadcastStream();
    
    _chatbotStream = Stream.periodic(
      const Duration(seconds: 12),
      (c) => _chatbotActions[c % _chatbotActions.length]['message'] as String,
    ).asBroadcastStream();
  }

  @override
  void dispose() {
    ThemeManager().removeListener(_onThemeChanged);
    _breathingController.dispose();
    _chatbotController.dispose();
    _scoreController.dispose();
    _headerController.dispose();
    _alertsPageController.dispose();
    _mainScrollController.dispose(); // NEW: Dispose controller
    super.dispose();
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadMedicalRecords() async {
    setState(() => _isLoadingMedical = true);
    try {
      final records = await MedicalService().getMyMedicalRecords();
      if (mounted) {
        setState(() {
          _medicalRecords = records;
          _isLoadingMedical = false;
        });
      }
    } catch (e) {
      debugPrint('Failed to load medical records: $e');
      if (mounted) {
        setState(() => _isLoadingMedical = false);
      }
    }
  }

  void _navigateToProfile() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const ProfileScreen(),
      ),
    );
    
    // Reload user info if profile was updated
    if (result == true) {
      _loadUserInfo();
    }
  }

@override
Widget build(BuildContext context) {
  final double headerHeightOffset = MediaQuery.of(context).padding.top + 100.0;
  return Scaffold(
    backgroundColor: AppColors.background,
    body: Stack(
      children: [
        // Main Content
        SingleChildScrollView(
          controller: _mainScrollController,
          padding: EdgeInsets.only(top: headerHeightOffset),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 10),
                
                // Safety Score Widget (your existing big score)
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 300),
                  opacity: _showMiniScoreInHeader ? 0.0 : 1.0,
                  child: _buildEnhancedSafetyScore(),
                ),
                
                const SizedBox(height: 28),
                
                // Your existing widgets continue below...
                Text(
                  "🔴 Live Alerts",
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 14),
                _buildEnhancedAlertsCarousel(),
                const SizedBox(height: 24),
                _buildEnhancedChatbot(),
                const SizedBox(height: 24),
                _buildMedicalRecordsCard(),
                const SizedBox(height: 24),
                _buildEnhancedGroupStatus(),
                const SizedBox(height: 24),
                _buildQuickActionsCard(),
                const SizedBox(height: 140),
              ],
            ),
          ),
        ),

        // 2. Floating Header (Fixed at top)
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _buildHeader(),
        ),
      ],
    )
    );
  }

Widget _buildHeader() {
  return FadeTransition(
    opacity: _headerFadeAnimation,
    child: SlideTransition(
      position: _headerSlideAnimation,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Left Side
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    transitionBuilder: (Widget child, Animation<double> animation) {
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0.0, 0.5),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      );
                    },
                    child: _showMiniScoreInHeader
                        ? _buildMiniScoreHeader()
                        : _buildUserGreetingHeader(),
                  ),
                ),

                // Right Side: Profile Button
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _navigateToProfile,
                    borderRadius: BorderRadius.circular(30),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceVariant,
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Profile Photo or Initials
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.primary.withOpacity(0.2),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: ClipOval(
                              child: _profilePhotoPath != null
                                  ? Image.file(
                                      File(_profilePhotoPath!),
                                      fit: BoxFit.cover,
                                      errorBuilder: (context, error, stackTrace) {
                                        return _buildInitialsWidget();
                                      },
                                    )
                                  : _buildInitialsWidget(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Iconsax.arrow_right_3,
                            size: 14,
                            color: AppColors.textSecondary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

// ADD this helper method:
Widget _buildInitialsWidget() {
  return Center(
    child: Text(
      _userInitials ?? 'T',
      style: TextStyle(
        color: AppColors.surface,
        fontSize: 12,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}


  // Helper: The original greeting row extracted
  Widget _buildUserGreetingHeader() {
    return Row(
      key: const ValueKey('greeting'),
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.primary.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child:  Icon(Iconsax.security_safe, color: AppColors.primary, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    _getGreeting(),
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Iconsax.sun_1, size: 12, color: Colors.orange.shade300),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                _userName,
                style:  TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Helper: The new Mini Score widget for the header
  Widget _buildMiniScoreHeader() {
    // You can dynamically get this color/score from your state logic
    final score = 85; 
    final color = Colors.green;

    return Row(
      key: const ValueKey('score'),
      children: [
        // Mini Circular Indicator
        SizedBox(
          width: 40,
          height: 40,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: score / 100,
                strokeWidth: 4,
                backgroundColor: color.withOpacity(0.1),
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
              Text(
                "$score",
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
             Text(
              "Safety Score",
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
            Row(
              children: [
                Text(
                  "EXCELLENT",
                  style: TextStyle(
                    color: color,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Iconsax.tick_circle, size: 14, color: color),
              ],
            ),
          ],
        ),
      ],
    );
  }
  
  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

    void _navigateToMedicalRecords() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const MedicalRecordsScreen(),
      ),
    ).then((_) {
      // Refresh records when coming back
      _loadMedicalRecords();
    });
  }

// REPLACE _buildMedicalRecordsCard in home_screen.dart with this:

Widget _buildMedicalRecordsCard() {
  return Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
  gradient: LinearGradient(
    colors: [
      // Check theme manager logic or simpler: use a tertiary color or conditional
      // Assuming you have access to check brightness, or use a safe transparent blue
      AppColors.primary.withOpacity(0.1), 
      AppColors.surface,
    ],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  ),
  borderRadius: BorderRadius.circular(24),
  boxShadow: [
    BoxShadow(
      color: Colors.black.withOpacity(0.04), // Changed withValues to withOpacity for safety
      blurRadius: 15,
      offset: const Offset(0, 5),
    ),
  ],
),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // --- Header Section ---
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.medical_information_outlined,
                color: Colors.blue.shade700,
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
             Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Medical Records',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.psychology, size: 14, color: Colors.purple),
                      SizedBox(width: 4),
                      Text(
                        'AI-powered analysis',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20), // Increased spacing slightly for breathability

        // --- Content Section (Loading / Empty / List) ---
        if (_isLoadingMedical)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(16.0),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else if (_medicalRecords.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.blue.shade200,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.add_circle_outline,
                  color: Colors.blue.shade700,
                  size: 20,
                ),
                const SizedBox(width: 12),
                 Expanded(
                  child: Text(
                    'Upload your first medical document',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.blue.shade100,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.description_outlined,
                  color: Colors.blue.shade700,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${_medicalRecords.length} document${_medicalRecords.length != 1 ? 's' : ''} stored',
                    style:  TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.verified,
                        size: 14,
                        color: Colors.green.shade700,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Analyzed',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

        const SizedBox(height: 20),

        // --- Action Buttons Row ---
        SizedBox(
          height: 48, // Fixed height ensures all buttons align perfectly
          child: Row(
            children: [
              // 1. View All Button (Primary)
              Expanded(
                flex: 3,
                child: ElevatedButton.icon(
                  onPressed: _navigateToMedicalRecords,
                  icon: const Icon(Icons.visibility_outlined, size: 18),
                  label: const Text('View'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade700,
                    foregroundColor: AppColors.surface,
                    elevation: 0,
                    padding: EdgeInsets.zero, // Optimize space
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),

              // 2. Add New Button (Secondary)
              Expanded(
                flex: 3,
                child: OutlinedButton.icon(
                  onPressed: _uploadMedicalDocument,
                  icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                  label: const Text('Add'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.blue.shade700,
                    side: BorderSide(color: Colors.blue.shade200),
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),

              // 3. Share Button (Tertiary - Icon Only)
              // Using AspectRatio ensures it's a perfect square matching height
              AspectRatio(
                aspectRatio: 1,
                child: OutlinedButton(
                  onPressed: _showShareDialog,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.blue.shade700,
                    side: BorderSide(color: Colors.blue.shade200),
                    padding: EdgeInsets.zero, // Center the icon
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Icon(Icons.share_outlined, size: 20),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

Future<void> _uploadMedicalDocument() async {
  try {
    // 1. Pick the file (Same as your original code)
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf', 'doc', 'docx'],
    );

    if (result == null || result.files.single.path == null) return;

    // 2. Retrieve Token
    // The new dialog requires a token passed explicitly. 
    // Replace this line with however you normally get your JWT/Auth token.
    // final String token ;
     try {
    final token = await _dbService.getValidAuthToken();
    if (token == null) {
      throw Exception('No authentication token');
    }
    
    if (token.isEmpty) throw Exception('Authentication token not found');

    // 3. Format data for the new Dialog
    // The dialog expects a List<Map>, so we wrap the single file.
    final List<Map<String, dynamic>> documentList = [{
      'file_name': result.files.single.name,
      'file_path': result.files.single.path,
      'record_type': 'medical_record',
    }];

    if (!mounted) return;

    // 4. Show the MedicalUploadProgressDialog
    // We await this. The code execution pauses here until the dialog is closed.
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => WillPopScope(
        onWillPop: () async => false,
        child: MedicalUploadProgressDialog(
          documents: documentList,
          token: token,
        ),
      ),
    );

    // 5. Handle Success / Navigation
    // Once the progress dialog closes (pops), we show the "View Analysis" option.
    if (!mounted) return;

    final shouldNavigate = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green.shade700),
            const SizedBox(width: 12),
            const Text('Analysis Ready'),
          ],
        ),
        content: const Text(
          'Your document has been uploaded and analyzed. Would you like to view the results?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Later'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
            child: const Text('View Now'),
          ),
        ],
      ),
    );

    if (shouldNavigate == true) {
      _navigateToMedicalRecords();
    } else {
      _loadMedicalRecords(); // Refresh list to show new item
    }
    } catch (e) {
      throw Exception('Failed to retrieve auth token: $e');
    } 

  } catch (e) {
    debugPrint("Upload Error: $e");
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error initiating upload: ${e.toString()}'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

  void _showShareDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _ShareMedicalRecordsSheet(
        records: _medicalRecords,
      ),
    );
  }



Widget _buildEnhancedSafetyScore() {
  return Center(
    child: StreamBuilder<SafetyScore>(
      stream: SafetyScoreManager().scoreStream,
      initialData: SafetyScoreManager().currentScore,
      builder: (context, snapshot) {
        final score = snapshot.data;
        final hasScore = score != null && !score.isExpired();
        
        return GestureDetector(
          onTap: () {
            if (hasScore) {
              _showSafetyScoreDetails(score);
            }
          },
          child: AnimatedBuilder(
            animation: Listenable.merge([_breathingController, _scoreAnimation]),
            builder: (context, child) {
              final shadowIntensity = 0.1 + (_breathingController.value * 0.15);
              final scoreValue = hasScore ? score.score : 0;
              final scoreColor = hasScore ? score.getRiskColor() : Colors.grey;
              final riskLevel = hasScore ? score.getRiskLevel() : 'UNKNOWN';
              
              return Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: scoreColor.withOpacity(0.3),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: scoreColor.withOpacity(shadowIntensity),
                      blurRadius: 20,
                      spreadRadius: 3,
                      offset: const Offset(0, 3),
                    ),
                    BoxShadow(
                      color: AppColors.shadowLight,
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    // Score Circle
                    SizedBox(
                      height: 180,
                      width: 180,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          CustomPaint(
                            painter: CircularScorePainter(
                              score: _scoreAnimation.value * scoreValue,
                            ),
                            size: const Size(180, 180),
                          ),
                          Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                hasScore ? "$scoreValue" : "--",
                                style: TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              Text(
                                "Safety Score",
                                style: TextStyle(
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: scoreColor.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: scoreColor.withOpacity(0.3),
                                  ),
                                ),
                                child: Text(
                                  riskLevel,
                                  style: TextStyle(
                                    color: scoreColor,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 9,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    
                    const SizedBox(height: 16),
                    
                    // Last Updated & Refresh
                    if (hasScore) ...[
                      Text(
                        'Updated ${_formatTime(score.timestamp)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    
                    // Control Buttons Row
                    Row(
                      children: [
                        // Service Control
                        Expanded(
                          child: StreamBuilder<bool>(
                            stream: Stream.periodic(
                              const Duration(seconds: 1),
                              (_) => ForegroundServiceHandler().isRunning,
                            ),
                            initialData: ForegroundServiceHandler().isRunning,
                            builder: (context, serviceSnapshot) {
                              final isRunning = serviceSnapshot.data ?? false;
                              
                              return OutlinedButton.icon(
                                onPressed: () async {
                                  final handler = ForegroundServiceHandler();
                                  if (isRunning) {
                                    await handler.stopService();
                                  } else {
                                    await handler.startService();
                                  }
                                },
                                icon: Icon(
                                  isRunning ? Iconsax.pause : Iconsax.play,
                                  size: 16,
                                ),
                                label: Text(isRunning ? 'Stop' : 'Start'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: isRunning 
                                      ? AppColors.error 
                                      : AppColors.success,
                                  side: BorderSide(
                                    color: isRunning 
                                        ? AppColors.error 
                                        : AppColors.success,
                                  ),
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        
                        const SizedBox(width: 12),
                        
                        // Refresh Button
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _refreshSafetyScore,
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('Refresh'),
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
                    
                    // Tap to View Details
                    if (hasScore) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Tap for detailed breakdown',
                        style: TextStyle(
                          fontSize: 10,
                          color: AppColors.textHint,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        );
      },
    ),
  );
}


Future<void> _refreshSafetyScore() async {
  try {
    final handler = ForegroundServiceHandler();
    final location = await handler.getCurrentLocation();
    
    if (location != null) {
      await SafetyScoreManager().refreshScore(location);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 12),
                Text('Safety score refreshed'),
              ],
            ),
            backgroundColor: AppColors.success,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } else {
      throw Exception('Could not get current location');
    }
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to refresh: $e'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

String _formatTime(DateTime time) {
  final now = DateTime.now();
  final diff = now.difference(time);
  
  if (diff.inSeconds < 60) {
    return 'just now';
  } else if (diff.inMinutes < 60) {
    return '${diff.inMinutes}m ago';
  } else {
    return '${diff.inHours}h ago';
  }
}

void _showSafetyScoreDetails(SafetyScore score) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          
          // Header
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: score.getRiskColor().withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Iconsax.health,
                    color: score.getRiskColor(),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Safety Score Breakdown',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        'Score: ${score.score} • ${score.getRiskLevel()}',
                        style: TextStyle(
                          fontSize: 14,
                          color: score.getRiskColor(),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          const Divider(height: 1),
          
          // Content
          Expanded(
            child: FutureBuilder<Map<String, dynamic>>(
              future: _fetchDetailedHealthScore(score.latitude, score.longitude),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Center(
                    child: CircularProgressIndicator(
                      color: AppColors.primary,
                    ),
                  );
                }
                
                if (snapshot.hasError) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Iconsax.info_circle, size: 48, color: AppColors.textHint),
                        const SizedBox(height: 16),
                        Text(
                          'Could not load details',
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  );
                }
                
                final data = snapshot.data!;
                final healthReasons = List<String>.from(
                  data['health_reasons'] ?? []
                );
                final geofenceReasons = List<String>.from(
                  data['geofence_reasons'] ?? []
                );
                final recommendations = List<String>.from(
                  data['overall_recommendations'] ?? []
                );
                
                return ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    // Health Factors
                    _buildDetailSection(
                      'Health Factors',
                      Iconsax.heart,
                      AppColors.error,
                      healthReasons.isEmpty 
                          ? ['No health concerns detected']
                          : healthReasons,
                    ),
                    
                    const SizedBox(height: 20),
                    
                    // Environmental Factors
                    if (geofenceReasons.isNotEmpty) ...[
                      _buildDetailSection(
                        'Danger Zones',
                        Iconsax.danger,
                        AppColors.warning,
                        geofenceReasons,
                      ),
                      const SizedBox(height: 20),
                    ],
                    
                    // Recommendations
                    if (recommendations.isNotEmpty) ...[
                      _buildDetailSection(
                        'Recommendations',
                        Iconsax.lamp_on,
                        AppColors.success,
                        recommendations,
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

Widget _buildDetailSection(
  String title,
  IconData icon,
  Color color,
  List<String> items,
) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      ...items.map((item) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: color.withOpacity(0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: color.withOpacity(0.2),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(top: 6),
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item,
                  style: TextStyle(
                    fontSize: 14,
                    color: AppColors.textPrimary,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      )).toList(),
    ],
  );
}

Future<Map<String, dynamic>> _fetchDetailedHealthScore(
  double latitude,
  double longitude,
) async {
  try {
    return await _apiService.calculateSafetyScore(
      latitude: latitude,
      longitude: longitude,
    );
  } catch (e) {
    debugPrint('Failed to fetch health score details: $e');
    return {};
  }
}

  Widget _buildScoreDetails() {
    return Padding(
      padding: const EdgeInsets.only(top: 16.0, bottom: 8.0),
      child: Column(
        children: [
          _buildScoreDetailItem(
            Iconsax.battery_charging,
            "Battery Level",
            "18% - Consider charging",
            Colors.orange,
            0.18,
          ),
          const SizedBox(height: 12),
          _buildScoreDetailItem(
            Iconsax.moon,
            "Time of Day",
            "Evening - Be cautious",
            Colors.purple,
            0.7,
          ),
          const SizedBox(height: 12),
          _buildScoreDetailItem(
            Iconsax.location,
            "Area Safety",
            "Safe zone detected",
            Colors.green,
            0.9,
          ),
        ],
      ),
    );
  }

  Widget _buildScoreDetailItem(
    IconData icon,
    String title,
    String subtitle,
    Color color,
    double progress,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha:0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha:0.1)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha:0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: progress,
                  backgroundColor: color.withValues(alpha:0.1),
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                  minHeight: 4,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEnhancedAlertsCarousel() {
  return SizedBox(
    height: 140,
    child: PageView.builder(
      controller: _alertsPageController,
      itemCount: _importantAlerts.length,
      padEnds: false,
      itemBuilder: (context, index) {
        final subtitle = _importantAlerts[index];
        // You can vary color/gradient per index if you want; below keeps your cards similar
        final card = _buildEnhancedAlertCard(
          icon: index == 0 ? Iconsax.danger : (index == 1 ? Iconsax.sun_1 : Iconsax.people),
          title: index == 0 ? "High-Risk Zone" : (index == 1 ? "Weather Alert" : "Event Nearby"),
          subtitle: subtitle,
          color: index == 0 ? Colors.red : (index == 1 ? Colors.orange : Colors.purple),
          gradient: LinearGradient(
            colors: [
              (index == 0 ? Colors.red : (index == 1 ? Colors.orange : Colors.purple)).withValues(alpha:0.1),
              (index == 0 ? Colors.red : (index == 1 ? Colors.orange : Colors.purple)).withValues(alpha:0.05)
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        );
        return Padding(
          padding: const EdgeInsets.only(right: 12.0),
          child: card,
        );
      },
    ),
  );
}


  Widget _buildEnhancedAlertCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required Gradient gradient,
  }) {
    return Container(
      width: 240,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha:0.2)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha:0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha:0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha:0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child:  Text(
                  "LIVE",
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: color,
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade700,
                height: 1.3,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEnhancedChatbot() {
    final currentAction = _chatbotActions[_currentChatbotActionIndex];
    return FadeTransition(
      opacity: _chatbotFadeAnimation,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha:0.04),
              blurRadius: 15,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha:0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Iconsax.message_programming,
                    color: Colors.blue,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AI Safety Assistant',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: AppColors.textPrimary
                        ),
                      ),
                      const Text(
                        'Your personal guide',
                        style: TextStyle(
                          color: Colors.grey,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.1),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: Container(
                key: ValueKey(currentAction['message']),
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.inputBackground,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  currentAction['message'],
                  style:  TextStyle(
                    color: AppColors.textPrimary,
                    height: 1.4,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              child: Row(
                key: ValueKey(_currentChatbotActionIndex),
                children: (currentAction['actions'] as List).map<Widget>((action) {
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4.0),
                      child: _buildChatbotActionButton(
                        action['text'],
                        action['color'],
                        action['icon'],
                        action['isPrimary'],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatbotActionButton(String text, Color color, IconData icon, bool isPrimary) {
    return ElevatedButton.icon(
      onPressed: () {
        if (text.toLowerCase().contains('unsafe')) {
          widget.onSosPressed();
        }
      },
      icon: Icon(icon, size: 16),
      label: Text(
        text,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: isPrimary ? color : AppColors.surface,
        foregroundColor: isPrimary ? AppColors.surface : color,
        side: isPrimary ? null : BorderSide(color: color.withValues(alpha:0.5)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(vertical: 12),
        elevation: isPrimary ? 2 : 0,
        shadowColor: color.withValues(alpha:0.2),
      ),
    );
  }

  Widget _buildEnhancedGroupStatus() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient:  LinearGradient(
          colors: [
      AppColors.surface, 
      AppColors.background // Use background instead of hardcoded light grey
    ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha:0.04),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.green.withValues(alpha:0.15),
                  Colors.green.withValues(alpha:0.05),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Iconsax.shield_tick, color: Colors.green, size: 28),
          ),
          const SizedBox(width: 16),
           Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Group Status: Safe Zone",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16,color: AppColors.textPrimary),
                ),
                SizedBox(height: 6),
                Text(
                  "Next: Visit Hawa Mahal at 4:30 PM • 3 members online",
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha:0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Iconsax.arrow_right_3, color: Colors.grey, size: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActionsCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha:0.04),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
           Text(
            'Quick Actions',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildQuickActionButton(
                  icon: Iconsax.danger,
                  label: 'Emergency SOS',
                  color: AppColors.error,
                  onPressed: widget.onSosPressed,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildQuickActionButton(
                  icon: Iconsax.location,
                  label: 'Share Location',
                  color: AppColors.primary,
                  onPressed: () {},
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildQuickActionButton(
                  icon: Iconsax.call,
                  label: 'Emergency Call',
                  color: AppColors.warning,
                  onPressed: () {},
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildQuickActionButton(
                  icon: Iconsax.people,
                  label: 'Find Groups',
                  color: AppColors.success,
                  onPressed: () {},
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: color.withValues(alpha:0.1),
        foregroundColor: color,
        elevation: 0,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: color.withValues(alpha:0.2)),
        ),
      ),
      child: Column(
        children: [
          Icon(icon, size: 24),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class CircularScorePainter extends CustomPainter {
  final double score;
  CircularScorePainter({required this.score});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 20;
    
    final backgroundPaint = Paint()
      ..color = AppColors.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 16
      ..strokeCap = StrokeCap.round;
    
    canvas.drawCircle(center, radius, backgroundPaint);
    
    final progressPaint = Paint()
      ..shader = SweepGradient(
        startAngle: -math.pi / 2,
        colors: _getGradientColors(score),
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 16
      ..strokeCap = StrokeCap.round;
    
    final sweepAngle = math.max((score / 100) * 2 * math.pi, 0.02);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      sweepAngle,
      false,
      progressPaint,
    );
    
    final glowPaint = Paint()
      ..color = _getScoreColor(score).withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 24
      ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 8);
    
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      sweepAngle,
      false,
      glowPaint,
    );
  }

  List<Color> _getGradientColors(double score) {
    if (score >= 80) {
      return [Colors.green.shade300, Colors.green.shade500, Colors.green.shade700];
    } else if (score >= 60) {
      return [Colors.orange.shade300, Colors.orange.shade500, Colors.orange.shade700];
    } else {
      return [Colors.red.shade300, Colors.red.shade500, Colors.red.shade700];
    }
  }

  Color _getScoreColor(double score) {
    if (score >= 80) return Colors.green;
    if (score >= 60) return Colors.orange;
    return Colors.red;
  }

  @override
  bool shouldRepaint(covariant CircularScorePainter oldDelegate) {
    return oldDelegate.score != score;
  }
}

class _ShareMedicalRecordsSheet extends StatefulWidget {
  final List<Map<String, dynamic>> records;

  const _ShareMedicalRecordsSheet({required this.records});

  @override
  State<_ShareMedicalRecordsSheet> createState() => _ShareMedicalRecordsSheetState();
}

class _ShareMedicalRecordsSheetState extends State<_ShareMedicalRecordsSheet> {
  final Set<String> _selectedHashes = {};
  bool _isCreatingBundle = false;
  String? _accessToken;
  bool _showQR = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration:  BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_accessToken == null) ...[
                       Text(
                        'Share Medical Records',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                       Text(
                        'Select records to share with medical professionals',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 20),
                      
                      // Records selection
                      ...widget.records.map((record) {
                        final hash = record['file_hash'] ?? '';
                        final isSelected = _selectedHashes.contains(hash);
                        
                        return CheckboxListTile(
                          value: isSelected,
                          onChanged: (value) {
                            setState(() {
                              if (value == true) {
                                _selectedHashes.add(hash);
                              } else {
                                _selectedHashes.remove(hash);
                              }
                            });
                          },
                          title: Text(
                            record['filename'] ?? 'Document',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            record['record_type'] ?? 'Medical Record',
                            style: const TextStyle(fontSize: 12),
                          ),
                          controlAffinity: ListTileControlAffinity.leading,
                        );
                      }).toList(),
                      
                      const SizedBox(height: 16),
                      
                      // Create share button
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _selectedHashes.isEmpty || _isCreatingBundle
                              ? null
                              : _createShareBundle,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: _isCreatingBundle
                              ?  SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    color: AppColors.surface,
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(
                                  'Create Share Link (${_selectedHashes.length} selected)',
                                  style:  TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.surface,
                                  ),
                                ),
                        ),
                      ),
                    ] else ...[
                      // Show QR and token after creation
                       Text(
                        'Share Link Created',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                       Text(
                        'Share this token with medical professionals',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 24),
                      
                      // QR Code / Token toggle
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(
                                value: false,
                                label: Text('Token'),
                                icon: Icon(Icons.text_fields, size: 18),
                              ),
                              ButtonSegment(
                                value: true,
                                label: Text('QR Code'),
                                icon: Icon(Icons.qr_code, size: 18),
                              ),
                            ],
                            selected: {_showQR},
                            onSelectionChanged: (Set<bool> selected) {
                              setState(() => _showQR = selected.first);
                            },
                          ),
                        ],
                      ),
                      
                      const SizedBox(height: 24),
                      
                      if (_showQR) ...[
                        // QR Code
                        Center(
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.grey.shade300, width: 2),
                            ),
                            child: QrImageView(
                              data: _accessToken!,
                              version: QrVersions.auto,
                              size: 200,
                            ),
                          ),
                        ),
                      ] else ...[
                        // Token text
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: SelectableText(
                            _accessToken!,
                            style: const TextStyle(
                              fontSize: 13,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w500,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                      
                      const SizedBox(height: 16),
                      
                      // Copy button
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _accessToken!));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Token copied to clipboard'),
                                backgroundColor: AppColors.success,
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                          icon: const Icon(Icons.copy),
                          label: const Text('Copy Token'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                      
                      const SizedBox(height: 12),
                      
                      // Info
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline, color: Colors.orange.shade700, size: 20),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text(
                                'Token expires in 24 hours',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _createShareBundle() async {
    setState(() => _isCreatingBundle = true);

    try {
      final result = await MedicalService().createSharingBundle(
        bundleName: 'Medical Records - ${DateTime.now().toString().split(' ')[0]}',
        recordHashes: _selectedHashes.toList(),
        expiresHours: 24,
      );

      if (mounted) {
        setState(() {
          _isCreatingBundle = false;
          _accessToken = result['access_token'] ?? '';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isCreatingBundle = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to create share link: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }
}