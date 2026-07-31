import 'package:get/get.dart';

enum SubscriptionStoreKind {
  appStore('app_store'),
  playStore('play_store'),
  unknown('unknown');

  const SubscriptionStoreKind(this.apiValue);

  final String apiValue;

  static SubscriptionStoreKind fromValue(Object? value) {
    final String normalized = value?.toString().trim().toLowerCase() ?? '';
    return switch (normalized) {
      'app_store' || 'appstore' || 'ios' || 'apple' => appStore,
      'play_store' || 'playstore' || 'android' || 'google_play' => playStore,
      _ => unknown,
    };
  }
}

class SubscriptionProductConfig {
  static const String iosProductIdsCsv = String.fromEnvironment(
    'POWWOW_IOS_SUBSCRIPTION_PRODUCT_IDS',
  );
  static const String androidProductIdsCsv = String.fromEnvironment(
    'POWWOW_ANDROID_SUBSCRIPTION_PRODUCT_IDS',
  );

  final SubscriptionStoreKind store;
  final Set<String> productIds;

  const SubscriptionProductConfig({
    required this.store,
    required this.productIds,
  });

  factory SubscriptionProductConfig.forCurrentStore() {
    if (GetPlatform.isIOS) {
      return SubscriptionProductConfig(
        store: SubscriptionStoreKind.appStore,
        productIds: parseProductIds(iosProductIdsCsv),
      );
    }

    if (GetPlatform.isAndroid) {
      return SubscriptionProductConfig(
        store: SubscriptionStoreKind.playStore,
        productIds: parseProductIds(androidProductIdsCsv),
      );
    }

    return const SubscriptionProductConfig(
      store: SubscriptionStoreKind.unknown,
      productIds: <String>{},
    );
  }

  bool get hasProducts => productIds.isNotEmpty;

  static Set<String> parseProductIds(String csv) {
    return csv
        .split(',')
        .map((String id) => id.trim())
        .where((String id) => id.isNotEmpty)
        .toSet();
  }
}
