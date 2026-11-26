import 'package:get/get.dart';

import '../../main.dart';
import '../routes/app_routes.dart';
import 'first_run_access.dart';
import 'invite_link_service.dart';
import 'subscriptions/subscription_service.dart';

/// Where a signed-in user with a profile goes next.
enum FirstRunDestination { dashboard, inviteStep, paywall }

/// Pure routing rule, kept separate so it can be unit tested.
FirstRunDestination decideFirstRunDestination({
  required bool hasEntitlement,
  required bool paywallDeferred,
  required bool joinedViaInvite,
  required bool inviteStepSeen,
  required bool isNewProfile,
}) {
  if (hasEntitlement || paywallDeferred || joinedViaInvite) {
    return FirstRunDestination.dashboard;
  }
  if (isNewProfile && !inviteStepSeen) {
    return FirstRunDestination.inviteStep;
  }
  return FirstRunDestination.paywall;
}

/// Routes after the profile is loaded (splash) or created (create profile).
///
/// An invite link that launched the app is recorded first, so invited family
/// members go straight to Home instead of the paywall.
Future<void> routeAfterProfile({
  required String source,
  required bool isNewProfile,
  String? ownUid,
}) async {
  final FirstRunAccess access = FirstRunAccess();

  try {
    final String? inviteRoomId = await InviteLinkService().getInitalTribeId();
    if (inviteRoomId != null) {
      final bool recorded = await access.recordInvite(
        inviteRoomId,
        ownUid: ownUid,
      );
      testPrintLS(
        'FirstRunRouter:: [$source] launch invite=$inviteRoomId recorded=$recorded',
      );
    }
  } catch (e) {
    testPrintLS('FirstRunRouter:: [$source] reading launch invite failed: $e');
  }

  final SubscriptionService subscriptionService =
      Get.find<SubscriptionService>();
  await subscriptionService.prepareEntitlementGate(source: source);

  final FirstRunDestination destination = decideFirstRunDestination(
    hasEntitlement: subscriptionService.hasActiveEntitlement,
    paywallDeferred: access.paywallDeferred,
    joinedViaInvite: access.joinedViaInvite,
    inviteStepSeen: access.inviteStepSeen,
    isNewProfile: isNewProfile,
  );

  testPrintLS(
    'FirstRunRouter:: [$source] subscription_gate_decision: '
    'route=${destination.name}, active=${subscriptionService.hasActiveEntitlement}',
  );

  switch (destination) {
    case FirstRunDestination.dashboard:
      Get.offAllNamed(AppRoutes.dashboard);
    case FirstRunDestination.inviteStep:
      Get.offAllNamed(AppRoutes.inviteFamily);
    case FirstRunDestination.paywall:
      Get.offAllNamed(
        AppRoutes.subscription,
        arguments: const <String, bool>{'blockingPaywall': true},
      );
  }
}

/// Called when an invite link arrives while the user is still on the invite
/// step or the paywall: join them to that family and open Home.
Future<void> handleInviteBeforeHome(String roomId, {String? ownUid}) async {
  final bool recorded = await FirstRunAccess().recordInvite(
    roomId,
    ownUid: ownUid,
  );
  testPrintLS(
    'FirstRunRouter:: invite before home roomId=$roomId recorded=$recorded',
  );
  if (recorded) {
    Get.offAllNamed(AppRoutes.dashboard);
  }
}
