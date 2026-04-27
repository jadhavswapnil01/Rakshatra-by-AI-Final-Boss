import 'dart:io';
import 'package:flutter/material.dart';
// import 'package:file_picker/file_picker.dart';
import '../../models/user_model.dart';
import '../../utils/app_colors.dart';
import '../../utils/constants.dart';
import '../../utils/validators.dart';
import '../../widgets/custom_button.dart';
import '../../widgets/custom_text_field.dart';
import '../../widgets/step_indicator.dart';
import 'package:image_picker/image_picker.dart';

class RegistrationStep1 extends StatefulWidget {
  final UserModel userModel;
  final VoidCallback onNext;

  const RegistrationStep1({
    Key? key,
    required this.userModel,
    required this.onNext,
  }) : super(key: key);

  @override
  State<RegistrationStep1> createState() => _RegistrationStep1State();
}

class _RegistrationStep1State extends State<RegistrationStep1> with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  
  File? _selectedImage;
  bool _isLoading = false;
  bool _showAdditionalFields = false;
  late AnimationController _animationController;
  late Animation<Offset> _slideAnimation;
  
  // Additional field controllers and values
  String? _selectedGender;
  String? _selectedAgeGroup;
  String? _selectedTourType;
  String? _selectedNationality;

  // Options for dropdowns
  final List<String> _genders = ['Male', 'Female', 'Other', 'Prefer not to say'];
  final List<String> _ageGroups = ['18-25', '26-35', '36-45', '46-55', '56-65', '65+'];
  final List<String> _tourTypes = ['Individual', 'Family', 'Tour Operator'];
  final List<String> _nationalities = [
    'Indian', 'American', 'British', 'Canadian', 'Australian', 'German', 
    'French', 'Japanese', 'Chinese', 'Other'
  ];

  @override
  void initState() {
    super.initState();
    // Pre-populate fields if user model has data
    _nameController.text = widget.userModel.fullName ?? '';
    _emailController.text = widget.userModel.email ?? '';
    _phoneController.text = widget.userModel.phoneNumber ?? '';
    _selectedGender = widget.userModel.gender;
    _selectedAgeGroup = widget.userModel.ageGroup;
    _selectedTourType = widget.userModel.tourType;
    _selectedNationality = widget.userModel.nationality;
    
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    
    _slideAnimation = Tween<Offset>(
      begin: const Offset(1.0, 0.0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    ));

    // Listen to form changes
    _nameController.addListener(_checkBasicFieldsCompletion);
    _emailController.addListener(_checkBasicFieldsCompletion);
    _phoneController.addListener(_checkBasicFieldsCompletion);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  void _checkBasicFieldsCompletion() {
    final nameValid = _nameController.text.trim().length >= 2;
    final emailValid = _emailController.text.trim().contains('@') && 
                      _emailController.text.trim().contains('.');
    final phoneValid = _phoneController.text.trim().length >= 10;
    
    final isBasicComplete = nameValid && emailValid && phoneValid && _selectedImage != null;
    
    if (isBasicComplete && !_showAdditionalFields) {
      setState(() {
        _showAdditionalFields = true;
      });
      _animationController.forward();
    } else if (!isBasicComplete && _showAdditionalFields) {
      _animationController.reverse().then((_) {
        if (mounted) {
          setState(() {
            _showAdditionalFields = false;
          });
        }
      });
    }
  }

  Future<void> _showImageSourceDialog() async {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          decoration:  BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
          ),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 24),
              
               Text(
                'Select Profile Photo',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
               Text(
                'Choose how you want to add your photo',
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 32),
              
              Row(
                children: [
                  Expanded(
                    child: _buildImageSourceOption(
                      icon: Icons.photo_library_outlined,
                      label: 'Gallery',
                      subtitle: 'Choose from gallery',
                      onTap: () => _pickImageFromGallery(),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _buildImageSourceOption(
                      icon: Icons.camera_alt_outlined,
                      label: 'Camera',
                      subtitle: 'Take new photo',
                      onTap: () => _pickImageFromCamera(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  Widget _buildImageSourceOption({
    required IconData icon,
    required String label,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border, width: 1.5),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                gradient: AppColors.primaryGradient,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 24, color: Colors.white),
            ),
            const SizedBox(height: 12),
            Text(
              label,
              style:  TextStyle(
                fontSize: 16,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style:  TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickImageFromGallery() async {
    Navigator.pop(context); // Close the bottom sheet first
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80, // Compress image slightly
    );

    if (image != null) {
      setState(() {
        _selectedImage = File(image.path);
      });
      _checkBasicFieldsCompletion();
    }
  }

  Future<void> _pickImageFromCamera() async {
    Navigator.pop(context); // Close the bottom sheet first
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 80,
      preferredCameraDevice: CameraDevice.front, // Ask for front camera
    );

    if (image != null) {
      setState(() {
        _selectedImage = File(image.path);
      });
      _checkBasicFieldsCompletion();
    }
  }

  Widget _buildPhotoUploadWidget() {
    return GestureDetector(
      onTap: _showImageSourceDialog,
      child: Container(
        width: 120,
        height: 120,
        decoration: BoxDecoration(
          color: _selectedImage != null ? null : AppColors.background,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _selectedImage != null ? AppColors.primary : AppColors.border,
            width: 2,
          ),
          boxShadow: _selectedImage != null ? [
            BoxShadow(
              color: AppColors.primary.withValues(alpha:0.1),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ] : null,
        ),
        child: _selectedImage != null
            ? Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Image.file(
                      _selectedImage!,
                      width: 120,
                      height: 120,
                      fit: BoxFit.cover,
                    ),
                  ),
                  Positioned(
                    bottom: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.edit,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ],
              )
            :  Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 36,
                    color: AppColors.textHint,
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Upload Photo',
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.textHint,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    'Tap to select',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textHint,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildDropdownField({
    required String hint,
    required IconData icon,
    required String? value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButtonFormField<String>(
        value: value,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle:  TextStyle(color: AppColors.textHint),
          prefixIcon: Icon(icon, color: AppColors.textHint, size: 20),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
        items: items.map((String item) {
          return DropdownMenuItem<String>(
            value: item,
            child: Text(
              item,
              style:  TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
              ),
            ),
          );
        }).toList(),
        onChanged: onChanged,
        dropdownColor: AppColors.surface,
        icon:  Icon(Icons.keyboard_arrow_down, color: AppColors.textHint),
      ),
    );
  }

  bool _isBasicFormValid() {
    return _nameController.text.trim().length >= 2 &&
        _emailController.text.trim().contains('@') &&
        _emailController.text.trim().contains('.') &&
        _phoneController.text.trim().length >= 10 &&
        _selectedImage != null;
  }

  bool _isFormComplete() {
    final basicComplete = _isBasicFormValid();
    
    if (!_showAdditionalFields) {
      return basicComplete;
    }
    
    final additionalComplete = _selectedGender != null &&
        _selectedAgeGroup != null &&
        _selectedTourType != null &&
        _selectedNationality != null;
    
    return basicComplete && additionalComplete;
  }

  void _handleNext() async {
    if (!_isFormComplete()) {
      String message = 'Please complete all required fields';
      if (_selectedImage == null) {
        message = 'Please upload a profile photo';
      } else if (_showAdditionalFields) {
        message = 'Please fill all additional information';
      }
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: AppColors.warning,
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    if (_formKey.currentState?.validate() != true) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    // Simulate API call delay
    await Future.delayed(const Duration(milliseconds: 1500));

    // Update user model
    widget.userModel.fullName = _nameController.text.trim();
    widget.userModel.email = _emailController.text.trim();
    widget.userModel.phoneNumber = _phoneController.text.trim();
    widget.userModel.profileImagePath = _selectedImage?.path;
    widget.userModel.gender = _selectedGender;
    widget.userModel.ageGroup = _selectedAgeGroup;
    widget.userModel.tourType = _selectedTourType;
    widget.userModel.nationality = _selectedNationality;

    setState(() {
      _isLoading = false;
    });

    widget.onNext();
  }

  String get _buttonText {
    if (_isLoading) return 'Processing...';
    if (!_showAdditionalFields) return 'Complete Basic Info';
    return 'Next: Verify Identity';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Header - Reduced padding
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon:  Icon(Icons.arrow_back_ios, color: AppColors.textPrimary, size: 20),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Step 1 of 5: Personal Info',
                      style:  TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(width: 36),
                ],
              ),
            ),
            
            // Step Indicator - Reduced padding
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: StepIndicator(currentStep: 0, totalSteps: 5),
            ),
            
            const SizedBox(height: 16),
            
            // Form Content - Using available height
            Expanded(
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha:0.08),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Form(
                  key: _formKey,
                  child: SingleChildScrollView(
                  child: Column(
                    children: [
                      // Logo and Title - Reduced
                      Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              gradient: AppColors.primaryGradient,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.shield_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  AppConstants.appName,
                                  style:  TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                Text(
                                  AppConstants.tagline,
                                  style:  TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textSecondary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      
                      const SizedBox(height: 20),
                      
                      // Photo Upload
                      _buildPhotoUploadWidget(),
                      
                      const SizedBox(height: 20),
                      
                      // Form Fields Container
                      
                      Stack(
                          children: [
                            // Basic Fields
                            if (!_showAdditionalFields)
                              Column(
                                children: [
                                  CustomTextField(
                                    hintText: 'Full Name',
                                    prefixIcon: Icons.person_outline,
                                    controller: _nameController,
                                    keyboardType: TextInputType.name,
                                    validator: Validators.validateName,
                                  ),
                                  const SizedBox(height: 16),
                                  CustomTextField(
                                    hintText: 'Mobile Number',
                                    prefixIcon: Icons.phone_outlined,
                                    controller: _phoneController,
                                    keyboardType: TextInputType.phone,
                                    validator: Validators.validatePhoneNumber,
                                  ),
                                  const SizedBox(height: 16),
                                  CustomTextField(
                                    hintText: 'Email ID',
                                    prefixIcon: Icons.email_outlined,
                                    controller: _emailController,
                                    keyboardType: TextInputType.emailAddress,
                                    validator: Validators.validateEmail,
                                  ),
                                ],
                              ),
                            
                            // Additional Fields (Sliding)
                            if (_showAdditionalFields)
                              SlideTransition(
                                position: _slideAnimation,
                                child: Container(
                                  color: AppColors.surface,
                                  child: SingleChildScrollView(
                                    child: Column(
                                      children: [
                                        _buildDropdownField(
                                          hint: 'Select Gender',
                                          icon: Icons.person,
                                          value: _selectedGender,
                                          items: _genders,
                                          onChanged: (value) => setState(() => _selectedGender = value),
                                        ),
                                        _buildDropdownField(
                                          hint: 'Select Age Group',
                                          icon: Icons.cake_outlined,
                                          value: _selectedAgeGroup,
                                          items: _ageGroups,
                                          onChanged: (value) => setState(() => _selectedAgeGroup = value),
                                        ),
                                        _buildDropdownField(
                                          hint: 'Select Tour Type',
                                          icon: Icons.group_outlined,
                                          value: _selectedTourType,
                                          items: _tourTypes,
                                          onChanged: (value) => setState(() => _selectedTourType = value),
                                        ),
                                        _buildDropdownField(
                                          hint: 'Select Nationality',
                                          icon: Icons.flag_outlined,
                                          value: _selectedNationality,
                                          items: _nationalities,
                                          onChanged: (value) => setState(() => _selectedNationality = value),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      
                      
                      const SizedBox(height: 20),
                      
                      // Next Button
                      CustomButton(
                        text: _buttonText,
                        onPressed: _isFormComplete() ? _handleNext : null,
                        isLoading: _isLoading,
                        isEnabled: _isFormComplete(),
                        height: 52,
                      ),
                    ],
                  ),
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