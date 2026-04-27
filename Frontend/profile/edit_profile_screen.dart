// lib/screens/profile/edit_profile_screen.dart

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tourist_safety/utils/app_colors.dart';
import 'package:tourist_safety/services/api_service.dart';
import 'package:tourist_safety/services/database_service.dart';
import 'package:tourist_safety/services/profile_photo_service.dart';

class EditProfileScreen extends StatefulWidget {
  final Map<String, dynamic> currentData;

  const EditProfileScreen({super.key, required this.currentData});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final ApiService _apiService = ApiService();
  final DatabaseService _dbService = DatabaseService();
  
  late TextEditingController _nameController;
  late TextEditingController _emailController;
  late TextEditingController _nationalityController;
  final ProfilePhotoService _photoService = ProfilePhotoService();

  
  String? _selectedGender;
  File? _newProfilePhoto;
  bool _isSaving = false;
  bool _photoChanged = false;
  
  final List<String> _genderOptions = ['Male', 'Female', 'Other', 'Prefer not to say'];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.currentData['name'] ?? '');
    _emailController = TextEditingController(text: widget.currentData['email'] ?? '');
    _nationalityController = TextEditingController(text: widget.currentData['nationality'] ?? '');
    _selectedGender = widget.currentData['gender'];
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _nationalityController.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(
      source: source,
      imageQuality: 80,
      maxWidth: 1024,
      maxHeight: 1024,
    );

    if (image != null) {
      setState(() {
        _newProfilePhoto = File(image.path);
        _photoChanged = true;
      });
      Navigator.of(context).pop();
    }
  }

  Future<void> _showImageSourceDialog() async {
    return showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(25.0)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
             Text(
              'Update Profile Photo',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildImageSourceOption(
                  icon: Iconsax.gallery,
                  label: 'Gallery',
                  onTap: () => _pickImage(ImageSource.gallery),
                ),
                _buildImageSourceOption(
                  icon: Iconsax.camera,
                  label: 'Camera',
                  onTap: () => _pickImage(ImageSource.camera),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageSourceOption({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 32, color: AppColors.primary),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style:  TextStyle(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

Future<void> _saveProfile() async {
  if (!_formKey.currentState!.validate()) return;

  setState(() => _isSaving = true);

  try {
    // Upload new photo if changed
    if (_photoChanged && _newProfilePhoto != null) {
      _showSnackBar('Uploading photo...', isError: false);
      
      final photoResponse = await _apiService.uploadProfilePhoto(_newProfilePhoto!);
      
      if (photoResponse['success'] != true) {
        throw Exception('Failed to upload photo');
      }
      
      _showSnackBar('Photo uploaded successfully', isError: false);
      
      // ✅ ADD: Fetch and cache the new photo
      try {
        final user = await _dbService.getUserProfile();
        if (user?.id != null) {
          await _photoService.fetchAndCacheProfilePhoto(
            user!.id!,
            forceRefresh: true,
          );
          debugPrint('✅ Profile photo cached after upload');
        }
      } catch (photoError) {
        debugPrint('⚠️ Failed to cache photo: $photoError');
        // Don't block save if caching fails
      }
    }
    
    // Update profile data
    final updates = <String, dynamic>{};
    
    if (_nameController.text != widget.currentData['name']) {
      updates['name'] = _nameController.text;
    }
    
    if (_emailController.text != widget.currentData['email']) {
      updates['email'] = _emailController.text;
    }
    
    if (_nationalityController.text != widget.currentData['nationality']) {
      updates['nationality'] = _nationalityController.text;
    }
    
    if (_selectedGender != widget.currentData['gender']) {
      updates['gender'] = _selectedGender;
    }

    if (updates.isNotEmpty) {
      await _apiService.updateMyProfileToNew(updates);
      _showSnackBar('Profile updated successfully');
    } else if (!_photoChanged) {
      _showSnackBar('No changes to save');
    }
    
    // Sync local database
    await _apiService.syncUserDataFromServer();
    
    if (mounted) {
      Navigator.pop(context, true);
    }
  } catch (e) {
    if (mounted) {
      _showSnackBar('Failed to update profile: $e', isError: true);
    }
  } finally {
    if (mounted) {
      setState(() => _isSaving = false);
    }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: const Text('Edit Profile'),
        elevation: 0,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const SizedBox(height: 8),
            
            // Profile Photo Section
            Center(
              child: Column(
                children: [
                  GestureDetector(
                    onTap: _showImageSourceDialog,
                    child: Stack(
                      children: [
                        Container(
                          width: 120,
                          height: 120,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: AppColors.primary,
                              width: 3,
                            ),
                          ),
                          child: ClipOval(
                            child: _newProfilePhoto != null
                                ? Image.file(
                                    _newProfilePhoto!,
                                    fit: BoxFit.cover,
                                  )
                                : Icon(
                                    Iconsax.user,
                                    size: 60,
                                    color: AppColors.primary.withOpacity(0.5),
                                  ),
                          ),
                        ),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppColors.background,
                                width: 2,
                              ),
                            ),
                            child: const Icon(
                              Iconsax.camera,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap to change photo',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  if (_photoChanged)
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.success.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppColors.success,
                        ),
                      ),
                      child: const Text(
                        'Photo will be updated',
                        style: TextStyle(
                          color: AppColors.success,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            
            const SizedBox(height: 32),
            
            // Name Field
            _buildTextField(
              controller: _nameController,
              label: 'Full Name',
              icon: Iconsax.user,
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter your name';
                }
                return null;
              },
            ),
            
            const SizedBox(height: 16),
            
            // Email Field
            _buildTextField(
              controller: _emailController,
              label: 'Email Address',
              icon: Iconsax.sms,
              keyboardType: TextInputType.emailAddress,
              validator: (value) {
                if (value != null && value.isNotEmpty) {
                  if (!value.contains('@')) {
                    return 'Please enter a valid email';
                  }
                }
                return null;
              },
            ),
            
            const SizedBox(height: 16),
            
            // Gender Dropdown
            _buildDropdownField(
              label: 'Gender',
              icon: Iconsax.personalcard,
              value: _selectedGender,
              items: _genderOptions,
              onChanged: (value) {
                setState(() {
                  _selectedGender = value;
                });
              },
            ),
            
            const SizedBox(height: 16),
            
            // Nationality Field
            _buildTextField(
              controller: _nationalityController,
              label: 'Nationality',
              icon: Iconsax.global,
            ),
            
            const SizedBox(height: 32),
            
            // Save Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isSaving ? null : _saveProfile,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isSaving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        'Save Changes',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ),
            
            const SizedBox(height: 16),
            
            // Cancel Button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                  side: BorderSide(color: AppColors.border),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      validator: validator,
      style: TextStyle(color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: AppColors.primary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.primary, width: 2),
        ),
        filled: true,
        fillColor: AppColors.surface,
      ),
    );
  }

  Widget _buildDropdownField({
    required String label,
    required IconData icon,
    required String? value,
    required List<String> items,
    required void Function(String?) onChanged,
  }) {
    return DropdownButtonFormField<String>(
      value: value,
      
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: AppColors.textSecondary),
        prefixIcon: Icon(icon, color: AppColors.primary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.primary, width: 2),
        ),
        filled: true,
        fillColor: AppColors.surface,
      ),
      items: items.map((String item) {
        return DropdownMenuItem<String>(
          value: item,
          child: Text(item),
        );
      }).toList(),
      onChanged: onChanged,
    );
  }
}