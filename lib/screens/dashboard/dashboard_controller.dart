import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:pow_wow/main.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';

import '../../app/routes/app_routes.dart';
import '../../app/services/first_run_access.dart';
import '../../app/services/subscriptions/subscription_service.dart';
import '../../test_screen/test_log_helper.dart';

class DashboardController extends GetxController {
  static const String _iosNotificationPermissionPromptedKey =
      'iosNotificationPermissionPrompted';

  var tabIndex = 0;
  bool canShowDashboard = false;
  final Set<int> visitedTabs = <int>{0};
  bool _redirectingToSubscription = false;

  @override
  void onReady() {
    super.onReady();
    unawaited(_start());
  }

  Future<void> _start() async {
    final bool canUseDashboard = await _ensureEntitled();
    if (!canUseDashboard) {
      return;
    }

    canShowDashboard = true;
    update();
    await _requestNotificationPermission();
  }

  Future<bool> _ensureEntitled() async {
    if (!Get.isRegistered<SubscriptionService>()) {
      return true;
    }

    final SubscriptionService subscriptionService =
        Get.find<SubscriptionService>();
    await subscriptionService.prepareEntitlementGate(source: 'dashboard_guard');
    if (FirstRunAccess().canEnterApp(
      hasEntitlement: subscriptionService.hasActiveEntitlement,
    )) {
      testPrintLS(
        'DashboardController:: subscription_gate_decision: allow_dashboard=true',
      );
      return true;
    }

    if (_redirectingToSubscription) {
      return false;
    }

    _redirectingToSubscription = true;
    testPrintLS(
      'DashboardController:: subscription required — opening paywall',
    );
    Get.offAllNamed(
      AppRoutes.subscription,
      arguments: const <String, bool>{'blockingPaywall': true},
    );
    return false;
  }

  void changeTabIndex(int index) {
    if (tabIndex == index) {
      testPrintLS(
        DiagnosticLog.ui(
          'DashboardController',
          'tab_tapped_same',
          data: {'index': index},
        ),
      );
      return;
    }

    final previousIndex = tabIndex;
    tabIndex = index;
    visitedTabs.add(index);
    testPrintLS(
      DiagnosticLog.flow(
        'DashboardController',
        'tab_switched',
        data: {'from': previousIndex, 'to': index},
      ),
    );
    update();
  }

  Future<void> _requestNotificationPermission() async {
    if (GetPlatform.isIOS) {
      final storage = GetStorage();
      final settings = await FirebaseMessaging.instance
          .getNotificationSettings();
      if (settings.authorizationStatus != AuthorizationStatus.notDetermined) {
        await storage.write(_iosNotificationPermissionPromptedKey, true);
        testPrintLS(
          'DC:: requestNotificationPermission: skipped on iOS (${settings.authorizationStatus.name})',
        );
        return;
      }

      final hasPrompted =
          storage.read<bool>(_iosNotificationPermissionPromptedKey) ?? false;
      if (hasPrompted) {
        testPrintLS('DC:: requestNotificationPermission: skipped on iOS');
        return;
      }
      await storage.write(_iosNotificationPermissionPromptedKey, true);
    }

    final res = await FlutterCallkitIncoming.requestNotificationPermission({
      "title": "Notification Permission",
      "rationaleMessagePermission":
          "Notification permission is required, to show notification.",
      "postNotificationMessageRequired":
          "Notification permission is required, Please allow notification permission from setting.",
    });

    testPrintLS('DC:: requestNotificationPermission: res = $res');
  }
}
