import 'subscription_entitlement.dart';
import 'subscription_purchase.dart';
import 'subscription_store_gateway.dart';

enum SubscriptionServicePhase {
  idle,
  loadingProducts,
  loadingEntitlement,
  purchasePending,
  verifyingPurchase,
  restoring,
  error,
}

const Object _unchanged = Object();

class SubscriptionState {
  final bool productsConfigured;
  final bool backendConfigured;
  final bool storeAvailable;
  final List<SubscriptionProduct> products;
  final Set<String> notFoundProductIds;
  final SubscriptionEntitlement? entitlement;
  final SubscriptionServicePhase phase;
  final String? errorMessage;
  final SubscriptionPurchaseDetails? pendingVerificationPurchase;

  const SubscriptionState({
    required this.productsConfigured,
    required this.backendConfigured,
    required this.storeAvailable,
    required this.products,
    required this.notFoundProductIds,
    required this.entitlement,
    required this.phase,
    required this.errorMessage,
    required this.pendingVerificationPurchase,
  });

  factory SubscriptionState.initial({
    bool productsConfigured = false,
    bool backendConfigured = false,
  }) {
    return SubscriptionState(
      productsConfigured: productsConfigured,
      backendConfigured: backendConfigured,
      storeAvailable: false,
      products: const <SubscriptionProduct>[],
      notFoundProductIds: const <String>{},
      entitlement: null,
      phase: SubscriptionServicePhase.idle,
      errorMessage: null,
      pendingVerificationPurchase: null,
    );
  }

  bool get purchaseValidationReady => backendConfigured;

  bool get isBusy {
    return phase == SubscriptionServicePhase.loadingProducts ||
        phase == SubscriptionServicePhase.loadingEntitlement ||
        phase == SubscriptionServicePhase.purchasePending ||
        phase == SubscriptionServicePhase.verifyingPurchase ||
        phase == SubscriptionServicePhase.restoring;
  }

  bool get hasActiveEntitlement => entitlement?.hasAccess ?? false;

  bool get isUnavailable {
    return !productsConfigured || !storeAvailable || !purchaseValidationReady;
  }

  bool get canPurchase {
    return productsConfigured &&
        purchaseValidationReady &&
        storeAvailable &&
        products.isNotEmpty &&
        !isBusy;
  }

  bool get canRestore {
    return productsConfigured &&
        purchaseValidationReady &&
        storeAvailable &&
        !isBusy;
  }

  bool get needsVerificationRetry => pendingVerificationPurchase != null;

  SubscriptionState copyWith({
    bool? productsConfigured,
    bool? backendConfigured,
    bool? storeAvailable,
    List<SubscriptionProduct>? products,
    Set<String>? notFoundProductIds,
    Object? entitlement = _unchanged,
    SubscriptionServicePhase? phase,
    Object? errorMessage = _unchanged,
    Object? pendingVerificationPurchase = _unchanged,
  }) {
    return SubscriptionState(
      productsConfigured: productsConfigured ?? this.productsConfigured,
      backendConfigured: backendConfigured ?? this.backendConfigured,
      storeAvailable: storeAvailable ?? this.storeAvailable,
      products: products ?? this.products,
      notFoundProductIds: notFoundProductIds ?? this.notFoundProductIds,
      entitlement: identical(entitlement, _unchanged)
          ? this.entitlement
          : entitlement as SubscriptionEntitlement?,
      phase: phase ?? this.phase,
      errorMessage: identical(errorMessage, _unchanged)
          ? this.errorMessage
          : errorMessage as String?,
      pendingVerificationPurchase:
          identical(pendingVerificationPurchase, _unchanged)
          ? this.pendingVerificationPurchase
          : pendingVerificationPurchase as SubscriptionPurchaseDetails?,
    );
  }
}
