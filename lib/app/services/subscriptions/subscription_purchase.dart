import 'subscription_product_config.dart';

enum SubscriptionPurchaseStatus {
  pending,
  purchased,
  restored,
  error,
  canceled,
}

class SubscriptionVerificationData {
  final String source;
  final String localVerificationData;
  final String serverVerificationData;

  const SubscriptionVerificationData({
    required this.source,
    required this.localVerificationData,
    required this.serverVerificationData,
  });
}

class SubscriptionPurchaseDetails {
  final SubscriptionStoreKind store;
  final String productId;
  final String? purchaseId;
  final String? transactionDate;
  final SubscriptionPurchaseStatus status;
  final SubscriptionVerificationData verificationData;
  final bool pendingCompletePurchase;
  final String? errorMessage;
  final Object? storeObject;

  const SubscriptionPurchaseDetails({
    required this.store,
    required this.productId,
    required this.purchaseId,
    required this.transactionDate,
    required this.status,
    required this.verificationData,
    required this.pendingCompletePurchase,
    this.errorMessage,
    this.storeObject,
  });

  bool get isTerminalPurchase {
    return status == SubscriptionPurchaseStatus.purchased ||
        status == SubscriptionPurchaseStatus.restored;
  }
}
