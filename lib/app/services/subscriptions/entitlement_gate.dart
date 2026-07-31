import 'package:get/get.dart';

import 'subscription_service.dart';

enum EntitlementRequirement { activeSubscription }

class EntitlementGate {
  EntitlementGate({SubscriptionService? subscriptionService})
    : _subscriptionService =
          subscriptionService ?? Get.find<SubscriptionService>();

  final SubscriptionService _subscriptionService;

  bool canUse(EntitlementRequirement requirement) {
    return switch (requirement) {
      EntitlementRequirement.activeSubscription =>
        _subscriptionService.hasActiveEntitlement,
    };
  }
}
