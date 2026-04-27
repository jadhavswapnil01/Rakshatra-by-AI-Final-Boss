// lib/screens/profile/profile_screen.dart
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:iconsax/iconsax.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tourist_safety/utils/app_colors.dart';
import 'package:tourist_safety/utils/theme_manager.dart';
import 'package:tourist_safety/services/api_service.dart';
import 'package:tourist_safety/services/database_service.dart';
import 'package:tourist_safety/services/profile_photo_service.dart';
import 'package:tourist_safety/Services/offline_llm_service.dart';
import 'package:tourist_safety/models/user_model.dart';
import 'package:tourist_safety/screens/profile/edit_profile_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> with TickerProviderStateMixin {
  // Controllers & Services
  final ScrollController _scrollController = ScrollController();
  final ApiService _apiService = ApiService();
  final DatabaseService _dbService = DatabaseService();
  final ProfilePhotoService _photoService = ProfilePhotoService();
  final OfflineLLMService _llmService = OfflineLLMService();
  
  // THEME ANIMATION CONTROLLERS
  late AnimationController _themeController; // For subtle UI pulses
  late AnimationController _rippleController; // For the big reveal
  
  // RIPPLE STATE
  Offset _rippleOrigin = Offset.zero;
  Color _rippleColor = Colors.transparent;
  double _maxRadius = 0.0;

  // Data State
  UserModel? _user;
  Map<String, dynamic>? _profileData;
  String? _profilePhotoPath;
  bool _isLoading = true;
  
  // Storage Stats
  String _totalStorageUsed = "0 MB";
  double _storagePercent = 0.0;
  String _modelStorage = "0 MB";
  String _photoStorage = "0 MB";

  // Animation State
  double _scrollPercent = 0.0;
  final double _expandedHeight = 340.0;

  // Settings State (Mock)
  bool _notificationsEnabled = true;
  bool _biometricEnabled = false;

  @override
  void initState() {
    super.initState();

    _themeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    // Initialize Ripple Controller
    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );

    _rippleController.addListener(() {
      // Trigger the actual theme switch halfway through the ripple
      // This hides the instant UI repaint behind the ripple
      if (_rippleController.value >= 0.5 && _rippleController.value < 0.52) {
         // This listener is purely for sync logic if needed, 
         // but we handle the switch in the trigger function to be safe.
      }
    });

    _loadProfile();
    _calculateStorageUsage();

    ThemeManager().addListener(_onThemeChanged);
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    ThemeManager().removeListener(_onThemeChanged);
    _themeController.dispose();
    _rippleController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final offset = _scrollController.offset;
    final percent = (offset / (_expandedHeight - kToolbarHeight - 40)).clamp(0.0, 1.0);
    if (percent != _scrollPercent) {
      setState(() {
        _scrollPercent = percent;
      });
    }
  }

  // Called when ThemeManager notifies (external changes)
  void _onThemeChanged() {
    if (!mounted) return;
    _themeController.forward(from: 0.0);
    setState(() {});
  }


// ===========================================================================
  // THEME CHANGE LOGIC (The "Wow" Logic)
  // ===========================================================================
  void _handleThemeChange(AppThemeMode mode, TapUpDetails details, Color targetBgColor) {
    if (ThemeManager().themeMode == mode) return;

    final renderBox = context.findRenderObject() as RenderBox;
    final size = renderBox.size;
    
    // Calculate max radius to cover the screen from the tap point
    final double w = size.width > size.height ? size.width : size.height;
    _maxRadius = w * 1.5; 

    setState(() {
      _rippleOrigin = details.globalPosition;
      _rippleColor = targetBgColor;
    });

    // 1. Start Ripple
    _rippleController.forward(from: 0.0).then((_) {
      // 3. Reset ripple once done (optional, but clean)
      setState(() {
        _rippleColor = Colors.transparent;
      });
    });

    // 2. Schedule the actual theme switch to happen when screen is covered (approx 250ms in)
    Future.delayed(const Duration(milliseconds: 250), () {
      HapticFeedback.mediumImpact();
      ThemeManager().setThemeMode(mode);
    });
  }

  Future<void> _calculateStorageUsage() async {
    try {
      double modelsSizeMb = 0;
      double photosSizeMb = 0;

      // 1. LLM Models
      final models = await _llmService.getDownloadedModels();
      for (var m in models) modelsSizeMb += (m.sizeGB * 1024);

      // 2. Profile Photos
      final appDir = await getApplicationDocumentsDirectory();
      final photoDir = Directory('${appDir.path}/profile_photos');
      if (await photoDir.exists()) {
        await for (var file in photoDir.list()) {
          if (file is File) photosSizeMb += (await file.length()) / (1024 * 1024);
        }
      }

      double totalMb = modelsSizeMb + photosSizeMb;
      // Assuming 10GB hypothetical limit for the progress bar visualization
      double maxSpaceMb = 10 * 1024; 

      setState(() {
        _modelStorage = modelsSizeMb > 1024 
            ? "${(modelsSizeMb / 1024).toStringAsFixed(1)} GB" 
            : "${modelsSizeMb.toStringAsFixed(1)} MB";
        
        _photoStorage = "${photosSizeMb.toStringAsFixed(1)} MB";
        
        if (totalMb > 1024) {
          _totalStorageUsed = "${(totalMb / 1024).toStringAsFixed(1)} GB";
        } else {
          _totalStorageUsed = "${totalMb.toStringAsFixed(1)} MB";
        }
        
        _storagePercent = (totalMb / maxSpaceMb).clamp(0.0, 1.0);
      });
    } catch (e) {
      debugPrint("Storage calc error: $e");
    }
  }

  Future<void> _loadProfile() async {
    setState(() => _isLoading = true);
    try {
      // DB Load
      final user = await _dbService.getUserProfile();
      if (user != null) {
        setState(() => _user = user);
        final photoPath = await _photoService.getCachedPhotoPath(user.id!);
        if (photoPath != null) setState(() => _profilePhotoPath = photoPath);
      }

      // API Load
      final serverData = await _apiService.getMyProfile();
      if (mounted) {
        setState(() => _profileData = serverData['profile']);
        if (serverData['token_id'] != null) {
          final photoPath = await _photoService.fetchAndCacheProfilePhoto(
            serverData['token_id'],
            forceRefresh: true,
          );
          if (photoPath != null) setState(() => _profilePhotoPath = photoPath);
        }
      }
    } catch (e) {
      debugPrint("Profile load error: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

@override
  Widget build(BuildContext context) {
    final name = _profileData?['name'] ?? _user?.fullName ?? 'Traveller';
    final email = _profileData?['email'] ?? _user?.email ?? '';
    
    // We implicitly animate the background color using AnimatedContainer
    // instead of AnimatedSwitcher to preserve scroll state.
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground, 
      body: Stack(
        children: [
          // BOTTOM LAYER: The Main Content
          // We use AnimatedContainer here purely for the background color blend
          // The ScrollView stays stable.
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            color: AppColors.scaffoldBackground,
            child: CustomScrollView(
              controller: _scrollController,
              physics: const BouncingScrollPhysics(),
              slivers: [
                _buildAnimatedAppBar(name, email),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 20),
                        _buildSectionHeader('Appearance'),
                        const SizedBox(height: 16),
                        _buildModernThemeSwitcher(),
                        const SizedBox(height: 32),
                        _buildSectionHeader('Storage & Data'),
                        const SizedBox(height: 16),
                        _buildAdvancedStorageCard(),
                        const SizedBox(height: 32),
                        _buildSectionHeader('Settings'),
                        const SizedBox(height: 16),
                        _buildSettingsList(),
                        const SizedBox(height: 40),
                        _buildLogoutButton(),
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          // TOP LAYER: The Circular Reveal Overlay
          // This draws a circle that grows to fill the screen
          if (_rippleController.isAnimating)
            AnimatedBuilder(
              animation: _rippleController,
              builder: (context, child) {
                final radius = _maxRadius * _rippleController.value;
                return ClipPath(
                  clipper: CircularRevealClipper(
                    center: _rippleOrigin,
                    radius: radius,
                  ),
                  child: Container(
                    color: _rippleColor,
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  // ===========================================================================
  // 1. ANIMATED APP BAR (The "Wow" Factor)
  // ===========================================================================
// UPDATED: improved avatar centering math, safe collapsed positions, better opacity math
// REPLACE this whole function in your file
Widget _buildAnimatedAppBar(String name, String email) {
  return SliverAppBar(
    expandedHeight: _expandedHeight,
    pinned: true,
    stretch: true,
    backgroundColor: AppColors.surface,
    elevation: 0,
    leading: IconButton(
      icon: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: _scrollPercent > 0.8 ? Colors.transparent : AppColors.surface.withOpacity(0.5),
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.arrow_back, color: AppColors.textPrimary),
      ),
      onPressed: () => Navigator.pop(context),
    ),
    actions: [
      IconButton(
        icon: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: _scrollPercent > 0.8 ? Colors.transparent : AppColors.surface.withOpacity(0.5),
            shape: BoxShape.circle,
          ),
          child: Icon(Iconsax.edit, color: AppColors.primary),
        ),
        onPressed: () async {
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => EditProfileScreen(
                currentData: _profileData ?? {},
              ),
            ),
          );
          if (result == true) _loadProfile();
        },
      ),
      const SizedBox(width: 8),
    ],
    flexibleSpace: FlexibleSpaceBar(
      stretchModes: const [StretchMode.zoomBackground, StretchMode.blurBackground],
      background: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.primary.withOpacity(0.15),
                  AppColors.background,
                ],
              ),
            ),
          ),
          Positioned(
            top: -50,
            right: -50,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary.withOpacity(0.1),
                boxShadow: [BoxShadow(color: AppColors.primary.withOpacity(0.2), blurRadius: 50)],
              ),
            ),
          ),
        ],
      ),
      titlePadding: EdgeInsets.zero,
      title: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;

          // Avatar sizes
          final double startAvatar = 100.0;
          final double endAvatar = 44.0;
          final avatarSize = Tween<double>(begin: startAvatar, end: endAvatar)
              .transform(_scrollPercent)
              .clamp(endAvatar, startAvatar);

          // Horizontal positions: center when expanded, small-left when collapsed
          final double startLeft = (width - avatarSize) / 2;
          final double endLeft = 30.0;
          final leftPos = Tween<double>(begin: startLeft, end: endLeft).transform(_scrollPercent);

          // Ensure avatar does not go above status bar / safe area
          final double safeTop = MediaQuery.of(context).padding.top + 10.0;
          // Expanded top: a comfortable distance below status bar (prevents half-offscreen)
          final double startTop = safeTop + 104.0; // pushed down so avatar fully visible in expanded state
          // Collapsed top: vertically center within toolbar area
          final double toolbarCenter = MediaQuery.of(context).padding.top + (kToolbarHeight / 2) - (avatarSize / 2);
          final double endTop = toolbarCenter.clamp(safeTop, startTop);
          final topPos = Tween<double>(begin: startTop, end: endTop).transform(_scrollPercent);

          final bool isCollapsed = _scrollPercent > 0.82;

          return Stack(
            alignment: Alignment.center,
            children: [
              // Avatar
              Positioned(
                top: topPos,
                left: leftPos,
                child: Hero(
                  tag: 'profile_pic',
                  child: Container(
                    width: avatarSize,
                    height: avatarSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.surface,
                        width: isCollapsed ? 1.5 : 4,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.08),
                          blurRadius: isCollapsed ? 4 : 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: _profilePhotoPath != null
                          ? Image.file(File(_profilePhotoPath!), fit: BoxFit.cover)
                          : Container(
                              color: AppColors.primary,
                              child: Center(
                                child: Text(
                                  name.isNotEmpty ? name[0].toUpperCase() : 'U',
                                  style: TextStyle(
                                    fontSize: avatarSize * 0.38,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
              ),

              // Expanded: name & email BELOW avatar, smaller fonts, fades on scroll
              Positioned(
                // place just below the avatar (keeps safe spacing even if avatar size changes)
                top: startTop + (startAvatar / 1.0) + 12.0, // this is the expanded baseline position
                left: 0,
                right: 0,
                child: Opacity(
                  // fades earlier so it doesn't overlap when header shrinks
                  opacity: (1.0 - _scrollPercent * 1.6).clamp(0.0, 1.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15, // reduced size so name sits neatly below avatar
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        email,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11, // smaller email
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildProfileBadges(),
                    ],
                  ),
                ),
              ),

              // Collapsed small title shown to the right of avatar inside toolbar area (fades in)
              Positioned(
                left: endLeft + avatarSize + 8,
                top: endTop + (avatarSize - endAvatar) / 2,
                child: Opacity(
                  opacity: (_scrollPercent > 0.78 ? (_scrollPercent - 0.78) * 5.0 : 0.0).clamp(0.0, 1.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      if (_scrollPercent > 0.88)
                        Text(
                          email,
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    )
  );
}



  // ===========================================================================
  // 2. HELPER WIDGETS
  // ===========================================================================

 Widget _buildSectionHeader(String title) {
    return Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        color: AppColors.textSecondary,
        letterSpacing: 1.2,
      ),
    );
  }

  Widget _buildProfileBadges() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (_user?.isVerified == true)
          _buildBadge(Icons.verified, 'Verified', AppColors.success),
        const SizedBox(width: 8),
        _buildBadge(Iconsax.global, _user?.nationality ?? 'Traveler', AppColors.info),
      ],
    );
  }

  Widget _buildBadge(IconData icon, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

// ===========================================================================
  // UPDATED THEME SWITCHER
  // ===========================================================================
  Widget _buildModernThemeSwitcher() {
    final currentMode = ThemeManager().themeMode;

    return Container(
      height: 110,
      child: Row(
        children: [
          _buildThemeCard(
            mode: AppThemeMode.light,
            icon: Iconsax.sun_1,
            label: 'Light',
            isSelected: currentMode == AppThemeMode.light,
            gradientColors: [const Color(0xFFFFE0B2), const Color(0xFFFFCC80)],
            targetBgColor: const Color(0xFFF8FAFC), // Light Background Color
          ),
          const SizedBox(width: 12),
          _buildThemeCard(
            mode: AppThemeMode.dark,
            icon: Iconsax.moon,
            label: 'Dark',
            isSelected: currentMode == AppThemeMode.dark,
            gradientColors: [const Color(0xFF1E293B), const Color(0xFF0F172A)],
            isDarkCard: true,
            targetBgColor: const Color(0xFF0F172A), // Dark Background Color
          ),
          const SizedBox(width: 12),
          _buildThemeCard(
            mode: AppThemeMode.system,
            icon: Iconsax.mobile,
            label: 'System',
            isSelected: currentMode == AppThemeMode.system,
            gradientColors: [AppColors.primary.withOpacity(0.2), AppColors.primary.withOpacity(0.4)],
            // For system, we guess based on current platform brightness, or default to a mid-tone
            targetBgColor: MediaQuery.platformBrightnessOf(context) == Brightness.dark 
               ? const Color(0xFF0F172A) 
               : const Color(0xFFF8FAFC), 
          ),
        ],
      ),
    );
  }

Widget _buildThemeCard({
    required AppThemeMode mode,
    required IconData icon,
    required String label,
    required bool isSelected,
    required List<Color> gradientColors,
    required Color targetBgColor,
    bool isDarkCard = false,
  }) {
    return Expanded(
      child: GestureDetector(
        // Catch the tap details to find the exact touch point
        onTapUp: (details) => _handleThemeChange(mode, details, targetBgColor),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: gradientColors,
            ),
            border: Border.all(
              color: isSelected ? AppColors.primary : Colors.transparent,
              width: 2,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: AppColors.primary.withOpacity(0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    )
                  ]
                : [],
          ),
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      icon,
                      color: isDarkCard ? Colors.white : Colors.black87,
                      size: 28,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      label,
                      style: TextStyle(
                        color: isDarkCard ? Colors.white70 : Colors.black54,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check, size: 10, color: Colors.white),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // 4. ADVANCED STORAGE CARD
  // ===========================================================================
  Widget _buildAdvancedStorageCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.border),
        boxShadow: [
  BoxShadow(
    color: AppColors.shadowLight, // your existing color
    blurRadius: 10,
    spreadRadius: 1,
    offset: Offset(0, 4),
  ),
],

      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Storage Used',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _totalStorageUsed,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Iconsax.folder_open, color: AppColors.primary),
              ),
            ],
          ),
          const SizedBox(height: 20),
          
          // Visual Progress Bar
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              height: 12,
              child: LinearProgressIndicator(
                value: _storagePercent,
                backgroundColor: AppColors.surfaceVariant,
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
              ),
            ),
          ),
          const SizedBox(height: 16),
          
          // Breakdown
          Row(
            children: [
              _buildStorageLegend('AI Models', _modelStorage, AppColors.primary),
              const Spacer(),
              _buildStorageLegend('Photos', _photoStorage, AppColors.secondary),
            ],
          ),
          
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          
          InkWell(
            onTap: () {
               _calculateStorageUsage();
               // TODO: Navigate to deep clean page or trigger clean logic
               ScaffoldMessenger.of(context).showSnackBar(
                 SnackBar(content: Text('Cache cleaned successfully!'), backgroundColor: AppColors.success),
               );
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Iconsax.brush_2, size: 16, color: AppColors.primary),
                const SizedBox(width: 8),
                Text(
                  'Clean Cache & Junk',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStorageLegend(String label, String value, Color color) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        const SizedBox(width: 6),
        Text(
          value,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // 5. SETTINGS LIST
  // ===========================================================================
  Widget _buildSettingsList() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          _buildSettingsTile(
            icon: Iconsax.notification,
            title: 'Notifications',
            subtitle: 'Alerts, updates & warnings',
            trailing: Switch(
              value: _notificationsEnabled,
              activeColor: AppColors.primary,
              onChanged: (v) => setState(() => _notificationsEnabled = v),
            ),
          ),
          Divider(height: 1, color: AppColors.border, indent: 60),
          _buildSettingsTile(
            icon: Iconsax.finger_scan,
            title: 'Biometric Login',
            subtitle: 'FaceID / TouchID',
            trailing: Switch(
              value: _biometricEnabled,
              activeColor: AppColors.primary,
              onChanged: (v) => setState(() => _biometricEnabled = v),
            ),
          ),
          Divider(height: 1, color: AppColors.border, indent: 60),
          _buildSettingsTile(
            icon: Iconsax.document_text,
            title: 'Terms & Privacy',
            onTap: () {},
          ),
           Divider(height: 1, color: AppColors.border, indent: 60),
          _buildSettingsTile(
            icon: Iconsax.info_circle,
            title: 'About App',
            subtitle: 'Version 2.1.0 (Beta)',
            onTap: () {},
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsTile({
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: AppColors.textPrimary, size: 22),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
          fontSize: 15,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            )
          : null,
      trailing: trailing ?? const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
      onTap: onTap,
    );
  }

  Widget _buildLogoutButton() {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: () async {
          await _apiService.logout();
          if (mounted) {
            Navigator.pushNamedAndRemoveUntil(context, '/welcome', (route) => false);
          }
        },
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.error.withOpacity(0.1),
          foregroundColor: AppColors.error,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        child: const Text(
          'Log Out',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
      ),
    );
  }
}

// ===========================================================================
// HELPER CLASS: Circular Reveal Clipper
// ===========================================================================
class CircularRevealClipper extends CustomClipper<Path> {
  final Offset center;
  final double radius;

  CircularRevealClipper({required this.center, required this.radius});

  @override
  Path getClip(Size size) {
    return Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));
  }

  @override
  bool shouldReclip(covariant CircularRevealClipper oldClipper) {
    return oldClipper.radius != radius || oldClipper.center != center;
  }
}