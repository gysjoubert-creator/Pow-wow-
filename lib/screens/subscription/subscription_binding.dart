import 'package:get/get.dart';

import '../../app/services/subscriptions/subscription_service.dart';

class SubscriptionBinding extends Bindings {
  @override
  void dependencies() {
    if (!Get.isRegistered<SubscriptionService>()) {
      Get.put<SubscriptionService>(SubscriptionService(), permanent: true);
    }
  }
}
