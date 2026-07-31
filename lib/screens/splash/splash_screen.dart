import 'package:flutter/material.dart';
import 'package:pow_wow/main.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';

import '../../app/data/models/user_profile.dart';
import '../../app/routes/app_routes.dart';
import '../../app/services/firebase/auth_service.dart';
import '../../app/services/firebase/firestore_service.dart';
import '../../app/services/subscriptions/subscription_service.dart';
import '../../app/utils/bootstrap_error_helper.dart';
import '../../app/utils/retry_error_log_helper.dart';
import '../../widgets/retry_error_view.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final _authService = Get.find<AuthService>();
  final _firestoreService = FirestoreService();

  bool _isLoading = true;
  String? _errorMessage;
  bool _isNetworkError = false;
  bool _initInProgress = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (_initInProgress) {
      return;
    }

    final bool isRetryAttempt = _errorMessage != null;
    _initInProgress = true;
    if (isRetryAttempt) {
      logRetryErrorTryAgainTapped(scope: 'SplashScreen', source: 'bootstrap');
    }
    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
        _isNetworkError = false;
      });
    }

    try {
      await _authService.signInAnonymousIfNeeded();

      final String? currentUid = _authService.uid;
      if (currentUid == null) {
        throw StateError(
          'Auth succeeded but uid is null — unexpected Firebase state',
        );
      }
      final String? savedUid = GetStorage().read<String>('lastKnownUid');
      GetStorage().write('lastKnownUid', currentUid);

      if (_authService.uid != null && tokenFcmOrVoIP != null) {
        if (GetPlatform.isAndroid) {
          await _firestoreService.setTokenFCM(
            token: tokenFcmOrVoIP!,
            userId: _authService.uid!,
          );
        } else {
          await _firestoreService.setTokenVoIP(
            token: tokenFcmOrVoIP!,
            userId: _authService.uid!,
          );
        }
      }

      UserProfile? profile;

      final bool authSessionLost = savedUid != null && savedUid != currentUid;

      if (authSessionLost) {
        profile = await _recoverProfile(
          savedUid: savedUid,
          currentUid: currentUid,
        );
      }

      profile ??= await _firestoreService.getMyProfile();
      testPrintLS('SplashScreen:: init: myProfile = ${profile?.toMap()}');

      if (!mounted) {
        return;
      }

      if (profile == null) {
        Get.offAllNamed(AppRoutes.createProfile);
        return;
      }

      _authService.setUserProfile(profile);
      await _routeAfterProfileLoaded();
    } catch (e) {
      testPrintLS('SplashScreen:: INIT: ❌ error = $e');
      if (mounted) {
        final String message = bootstrapErrorMessage(e);
        final bool isNetworkError = isNetworkBootstrapError(e);
        setState(() {
          _isNetworkError = isNetworkError;
          _errorMessage = message;
        });
        logRetryErrorBannerShown(
          scope: 'SplashScreen',
          message: message,
          isNetworkError: isNetworkError,
          source: 'bootstrap_init',
          layout: 'fullscreen',
        );
      }
    } finally {
      _initInProgress = false;
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _routeAfterProfileLoaded() async {
    final SubscriptionService subscriptionService =
        Get.find<SubscriptionService>();
    await subscriptionService.prepareEntitlementGate(source: 'splash');
    if (!mounted) {
      return;
    }

    if (subscriptionService.hasActiveEntitlement) {
      testPrintLS(
        'SplashScreen:: subscription_gate_decision: route=/dashboard, active=true',
      );
      Get.offAllNamed(AppRoutes.dashboard);
      return;
    }

    testPrintLS(
      'SplashScreen:: subscription_gate_decision: route=/subscription, active=false',
    );
    Get.offAllNamed(
      AppRoutes.subscription,
      arguments: const <String, bool>{'blockingPaywall': true},
    );
  }

  /// Firebase Auth lost the persisted session (common on Android with
  /// EncryptedSharedPreferences / Keystore issues). We look up the old profile
  /// in Firestore by [savedUid] and re-write it under [currentUid] so the user
  /// doesn't have to go through registration again.
  Future<UserProfile?> _recoverProfile({
    required String savedUid,
    required String currentUid,
  }) async {
    testPrintLS(
      'SplashScreen:: auth_session_lost: savedUid=$savedUid, currentUid=$currentUid',
    );

    try {
      final Map<String, dynamic>? raw = await _firestoreService
          .getRawProfileByUid(savedUid);

      if (raw == null) {
        testPrintLS('SplashScreen:: recovery: no profile found for savedUid');
        return null;
      }

      // Shared room id must survive auth uid changes. Default tribeId is often
      // the creator's uid (same as savedUid) — do not remap it to currentUid.
      final String tribeId = raw['tribeId'] as String? ?? savedUid;

      // Remap allTribes entries that matched the old UID.
      List<dynamic>? allTribes;
      final dynamic rawAllTribes = raw['allTribes'];
      if (rawAllTribes is List) {
        allTribes = rawAllTribes
            .map((e) => e == savedUid ? currentUid : e)
            .toList();
      }

      final Map<String, dynamic> migrated = {
        ...raw,
        'uid': currentUid,
        'tribeId': tribeId,
      };
      if (allTribes != null) {
        migrated['allTribes'] = allTribes;
      }

      await _firestoreService.writeProfileForUid(currentUid, migrated);

      testPrintLS('SplashScreen:: recovery: ✅ profile migrated to $currentUid');

      if (savedUid != currentUid) {
        try {
          await _firestoreService.deleteProfileByUid(savedUid);
          testPrintLS(
            'SplashScreen:: recovery: stale profile deleted ($savedUid)',
          );
        } catch (e) {
          testPrintLS(
            'SplashScreen:: recovery: stale profile delete failed ($savedUid): $e',
          );
        }
      }

      return UserProfile.fromMap(migrated);
    } catch (e) {
      testPrintLS('SplashScreen:: recovery: ❌ error = $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(padding: const EdgeInsets.all(24), child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const CircularProgressIndicator();
    }

    if (_errorMessage != null) {
      return RetryErrorView(
        message: _errorMessage!,
        isNetworkError: _isNetworkError,
        isRetrying: _initInProgress,
        onRetry: _init,
      );
    }

    return const CircularProgressIndicator();
  }
}
