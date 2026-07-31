import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pow_wow/app/services/firebase/firebase_storage_service.dart';
import 'package:pow_wow/app/utils/bootstrap_error_helper.dart';
import 'package:pow_wow/app/utils/retry_error_log_helper.dart';
import 'package:pow_wow/widgets/retry_error_view.dart';
import 'package:pow_wow/main.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/routes/app_routes.dart';
import '../../app/services/firebase/auth_service.dart';
import '../../app/services/firebase/firestore_service.dart';
import '../../app/services/subscriptions/subscription_service.dart';

class CreateProfileScreen extends StatefulWidget {
  const CreateProfileScreen({super.key});

  @override
  State<CreateProfileScreen> createState() => _CreateProfileScreenState();
}

class _CreateProfileScreenState extends State<CreateProfileScreen> {
  final _authService = Get.find<AuthService>();
  final _firebaseStorage = FirebaseStorageService();
  final _firestoreService = FirestoreService();
  final TextEditingController _usernameController = TextEditingController();

  File? _avatarFile;
  bool _isLoading = false;
  String? _blockingErrorMessage;
  bool _blockingIsNetworkError = false;

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

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

  Future<void> _createProfile() async {
    final String username = _usernameController.text.trim();

    if (username.isEmpty) {
      Get.snackbar('Error', 'Enter username');
      return;
    }

    final bool isRetryAttempt = _blockingErrorMessage != null;
    if (isRetryAttempt) {
      logRetryErrorTryAgainTapped(
        scope: 'CreateProfileScreen',
        source: 'create_profile',
      );
    }

    setState(() {
      _isLoading = true;
      _blockingErrorMessage = null;
      _blockingIsNetworkError = false;
    });

    String? avatarUrl;

    try {
      if (_avatarFile != null) {
        avatarUrl = await _firebaseStorage.uploadAvatar(file: _avatarFile!);
      }

      final result = await _firestoreService.createProfile(
        username: username,
        avatarUrl: avatarUrl,
      );
      _authService.setUserProfile(result);
      await _routeAfterProfileCreated();
    } catch (e) {
      testPrintLS('CPS:: ❌ createProfile Error');
      if (mounted) {
        final String message = bootstrapErrorMessage(e);
        final bool isNetworkError = isNetworkBootstrapError(e);
        setState(() {
          _blockingErrorMessage = message;
          _blockingIsNetworkError = isNetworkError;
        });
        logRetryErrorBannerShown(
          scope: 'CreateProfileScreen',
          message: message,
          isNetworkError: isNetworkError,
          source: 'create_profile_submit',
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

  Future<void> _routeAfterProfileCreated() async {
    final SubscriptionService subscriptionService =
        Get.find<SubscriptionService>();
    await subscriptionService.prepareEntitlementGate(source: 'create_profile');
    if (!mounted) {
      return;
    }

    if (subscriptionService.hasActiveEntitlement) {
      testPrintLS(
        'CreateProfileScreen:: subscription_gate_decision: route=/dashboard, active=true',
      );
      Get.offAllNamed(AppRoutes.dashboard);
      return;
    }

    testPrintLS(
      'CreateProfileScreen:: subscription_gate_decision: route=/subscription, active=false',
    );
    Get.offAllNamed(
      AppRoutes.subscription,
      arguments: const <String, bool>{'blockingPaywall': true},
    );
  }

  @override
  Widget build(BuildContext context) {
    final double avatarSize = 120;

    return Scaffold(
      appBar: AppBar(title: const Text('Create profile')),
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
                onRetry: _createProfile,
              ),
              const SizedBox(height: 16),
            ],
            GestureDetector(
              onTap: _pickAvatar,
              child: CircleAvatar(
                radius: avatarSize / 2,
                backgroundImage: _avatarFile != null
                    ? FileImage(_avatarFile!)
                    : null,
                child: _avatarFile == null
                    ? const Icon(Icons.add_a_photo, size: 36)
                    : null,
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: 'Member name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _createProfile,
                child: _isLoading
                    ? const CircularProgressIndicator()
                    : const Text('Create'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
