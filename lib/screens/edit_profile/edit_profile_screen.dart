import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pow_wow/app/services/firebase/auth_service.dart';
import 'package:pow_wow/app/services/firebase/firebase_storage_service.dart';
import 'package:pow_wow/app/utils/bootstrap_error_helper.dart';
import 'package:pow_wow/app/utils/retry_error_log_helper.dart';
import 'package:pow_wow/main.dart';
import 'package:pow_wow/screens/tribe_settings/tribe_settings_controller.dart';
import 'package:pow_wow/widgets/cached_avatar_image.dart';
import 'package:pow_wow/widgets/retry_error_view.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final AuthService _authService = Get.find<AuthService>();
  final FirebaseStorageService _firebaseStorage = FirebaseStorageService();

  File? _avatarFile;
  bool _isLoading = false;
  String? _blockingErrorMessage;
  bool _blockingIsNetworkError = false;

  String? get _currentAvatarUrl => _authService.myProfile?.avatarUrl;

  Future<void> _pickAvatar() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);

    if (image == null) {
      return;
    }

    setState(() {
      _avatarFile = File(image.path);
    });
  }

  Future<void> _saveProfile() async {
    if (_avatarFile == null) {
      Get.snackbar('Error', 'Choose a new photo');
      return;
    }

    final profile = _authService.myProfile;
    if (profile == null) {
      Get.snackbar('Error', 'Profile is not available');
      return;
    }

    final bool isRetryAttempt = _blockingErrorMessage != null;
    if (isRetryAttempt) {
      logRetryErrorTryAgainTapped(
        scope: 'EditProfileScreen',
        source: 'edit_profile',
      );
    }

    setState(() {
      _isLoading = true;
      _blockingErrorMessage = null;
      _blockingIsNetworkError = false;
    });

    try {
      await _firebaseStorage.deleteAvatar();
      final String avatarUrl = await _firebaseStorage.uploadAvatar(
        file: _avatarFile!,
      );

      _authService.updateMyProfile(profile.copyWith(avatarUrl: avatarUrl));

      if (Get.isRegistered<TribeSettingsController>()) {
        Get.find<TribeSettingsController>().update();
      }

      Get.back();
    } catch (e) {
      testPrintLS('EditProfileScreen:: save avatar error: $e');
      if (mounted) {
        final String message = bootstrapErrorMessage(e);
        final bool isNetworkError = isNetworkBootstrapError(e);
        setState(() {
          _blockingErrorMessage = message;
          _blockingIsNetworkError = isNetworkError;
        });
        logRetryErrorBannerShown(
          scope: 'EditProfileScreen',
          message: message,
          isNetworkError: isNetworkError,
          source: 'edit_profile_submit',
          layout: 'compact',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const double avatarSize = 120;

    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: <Widget>[
            if (_blockingErrorMessage != null) ...<Widget>[
              RetryErrorView(
                message: _blockingErrorMessage!,
                isNetworkError: _blockingIsNetworkError,
                isRetrying: _isLoading,
                layout: RetryErrorLayout.compact,
                onRetry: _saveProfile,
              ),
              const SizedBox(height: 16),
            ],
            GestureDetector(
              onTap: _pickAvatar,
              child: SizedBox(
                width: avatarSize,
                height: avatarSize,
                child: ClipOval(
                  child: _avatarFile != null
                      ? Image.file(
                          _avatarFile!,
                          fit: BoxFit.cover,
                          width: avatarSize,
                          height: avatarSize,
                        )
                      : (_currentAvatarUrl != null
                            ? CachedAvatarImage(
                                url: _currentAvatarUrl!,
                                size: avatarSize,
                              )
                            : ColoredBox(
                                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                child: const Icon(Icons.add_a_photo, size: 36),
                              )),
                ),
              ),
            ),
            const SizedBox(height: 24),
            ExcludeSemantics(
              child: Opacity(
                opacity: 0,
                child: IgnorePointer(
                  child: TextField(
                    decoration: const InputDecoration(
                      labelText: 'Member name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _isLoading || _avatarFile == null
                    ? null
                    : _saveProfile,
                child: _isLoading
                    ? const CircularProgressIndicator()
                    : const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
