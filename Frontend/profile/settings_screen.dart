// lib/screens/profile/settings_screen.dart

import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import 'package:tourist_safety/utils/app_colors.dart';
import 'package:tourist_safety/services/database_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final DatabaseService _dbService = DatabaseService();
  
  bool _notificationsEnabled = true;
  bool _locationTracking = true;
  bool _autoShareSOS = true;
  bool _darkMode = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    // Load settings from database
    final notifications = await _dbService.getSetting('notifications_enabled');
    final location = await _dbService.getSetting('location_tracking');
    final autoSOS = await _dbService.getSetting('auto_share_sos');
    final dark = await _dbService.getSetting('dark_mode');

    if (mounted) {
      setState(() {
        _notificationsEnabled = notifications == 'true';
        _locationTracking = location != 'false';
        _autoShareSOS = autoSOS != 'false';
        _darkMode = dark == 'true';
      });
    }
  }

  Future<void> _saveSetting(String key, bool value) async {
    await _dbService.saveSetting(key, value.toString());
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: const Text('Settings'),
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Notifications Section
          _buildSectionTitle('Notifications'),
          const SizedBox(height: 12),
          _buildSettingCard(
            icon: Iconsax.notification,
            title: 'Push Notifications',
            subtitle: 'Receive emergency alerts and updates',
            value: _notificationsEnabled,
            onChanged: (value) {
              setState(() => _notificationsEnabled = value);
              _saveSetting('notifications_enabled', value);
              _showSnackBar(
                value ? 'Notifications enabled' : 'Notifications disabled',
              );
            },
          ),

          const SizedBox(height: 24),

          // Safety Section
          _buildSectionTitle('Safety & Privacy'),
          const SizedBox(height: 12),
          _buildSettingCard(
            icon: Iconsax.location,
            title: 'Location Tracking',
            subtitle: 'Allow app to track your location for safety',
            value: _locationTracking,
            onChanged: (value) {
              setState(() => _locationTracking = value);
              _saveSetting('location_tracking', value);
              _showSnackBar(
                value
                    ? 'Location tracking enabled'
                    : 'Location tracking disabled',
              );
            },
          ),
          const SizedBox(height: 8),
          _buildSettingCard(
            icon: Iconsax.danger,
            title: 'Auto-Share SOS',
            subtitle: 'Automatically share SOS with groups',
            value: _autoShareSOS,
            onChanged: (value) {
              setState(() => _autoShareSOS = value);
              _saveSetting('auto_share_sos', value);
              _showSnackBar(
                value ? 'Auto-share SOS enabled' : 'Auto-share SOS disabled',
              );
            },
          ),

          const SizedBox(height: 24),

          // Appearance Section
          _buildSectionTitle('Appearance'),
          const SizedBox(height: 12),
          _buildSettingCard(
            icon: Iconsax.moon,
            title: 'Dark Mode',
            subtitle: 'Use dark theme for the app',
            value: _darkMode,
            onChanged: (value) {
              setState(() => _darkMode = value);
              _saveSetting('dark_mode', value);
              _showSnackBar(
                value ? 'Dark mode enabled (Coming soon!)' : 'Light mode enabled',
              );
            },
          ),

          const SizedBox(height: 24),

          // Data & Storage
          _buildSectionTitle('Data & Storage'),
          const SizedBox(height: 12),
          _buildActionCard(
            icon: Iconsax.refresh_2,
            title: 'Clear Cache',
            subtitle: 'Free up storage space',
            onTap: () async {
              final confirmed = await _showConfirmDialog(
                'Clear Cache',
                'This will clear temporary files and cached data. Are you sure?',
              );
              
              if (confirmed == true) {
                // TODO: Implement cache clearing
                _showSnackBar('Cache cleared successfully');
              }
            },
          ),
          const SizedBox(height: 8),
          _buildActionCard(
            icon: Iconsax.export,
            title: 'Export Data',
            subtitle: 'Download your personal data',
            onTap: () {
              // TODO: Implement data export
              _showSnackBar('Data export feature coming soon');
            },
          ),
          const SizedBox(height: 8),
          _buildActionCard(
            icon: Iconsax.trash,
            title: 'Delete Account',
            subtitle: 'Permanently delete your account',
            color: AppColors.error,
            onTap: () async {
              final confirmed = await _showConfirmDialog(
                'Delete Account',
                'This action cannot be undone. All your data will be permanently deleted. Are you sure?',
                confirmText: 'Delete',
                isDestructive: true,
              );
              
              if (confirmed == true) {
                // TODO: Implement account deletion
                _showSnackBar('Account deletion feature coming soon');
              }
            },
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style:  TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: AppColors.textPrimary,
      ),
    );
  }

  Widget _buildSettingCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required void Function(bool) onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: AppColors.primary, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style:  TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style:  TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: AppColors.primary,
          ),
        ],
      ),
    );
  }

  Widget _buildActionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color? color,
  }) {
    final cardColor = color ?? AppColors.textPrimary;
    
    return Card(
      elevation: 0,
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.border.withValues(alpha: 0.5)),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cardColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: cardColor, size: 20),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: cardColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style:  TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Iconsax.arrow_right_3,
                color: AppColors.textHint,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool?> _showConfirmDialog(
    String title,
    String message, {
    String confirmText = 'Confirm',
    bool isDestructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: isDestructive ? AppColors.error : AppColors.primary,
              foregroundColor: Colors.white,
            ),
            child: Text(confirmText),
          ),
        ],
      ),
    );
  }
}