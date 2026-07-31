/// Store product identifiers for PowWow IAP.
///
/// These constants are not used as the product-catalog fallback. The runtime
/// paywall product list comes from the backend catalog API
/// (`GET /api/v1/purchases/products`). The remaining constants support
/// purchase validation and store-specific labeling.
abstract final class SubscriptionProductIds {
  /// Android application ID, required by the backend validator alongside
  /// the purchase token (see `android/app/build.gradle.kts`).
  static const String androidPackageName = 'com.gys.powwow';

  // App Store — each plan is a separate product.
  static const String appStoreYear = 'com.gys.powwow.year';
  static const String appStoreMonth = 'com.gys.powwow.month';
  static const String appStoreWeek = 'com.gys.powwow.week';
  static const String appStoreLife = 'com.gys.powwow.life';

  static const Set<String> appStore = <String>{
    appStoreYear,
    appStoreMonth,
    appStoreWeek,
    appStoreLife,
  };

  // Google Play — subscription and one-time product IDs.
  static const String playSubscription = 'com.gys.powwow.subscription';
  static const String playOneTime = 'com.gys.powwow.one.time';

  /// Base plan / offer IDs inside [playSubscription].
  static const String playOfferYear = 'year';
  static const String playOfferMonthly = 'monthly';
  static const String playOfferWeekly = 'weekly';

  /// Offer ID inside [playOneTime].
  static const String playOfferLifeLong = 'life-long';

  static const Set<String> playStore = <String>{playSubscription, playOneTime};
}
