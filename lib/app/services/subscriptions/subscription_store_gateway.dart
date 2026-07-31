import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_wrappers.dart';

import 'subscription_product_config.dart';
import 'subscription_product_ids.dart';
import 'subscription_purchase.dart';

class SubscriptionProduct {
  final String id;
  final String title;
  final String description;
  final String price;
  final double rawPrice;
  final String currencyCode;
  final String? planLabel;
  final Object? storeObject;

  const SubscriptionProduct({
    required this.id,
    required this.title,
    required this.description,
    required this.price,
    required this.rawPrice,
    required this.currencyCode,
    this.planLabel,
    this.storeObject,
  });
}

class SubscriptionProductQuery {
  final List<SubscriptionProduct> products;
  final Set<String> notFoundIds;
  final String? errorMessage;

  const SubscriptionProductQuery({
    required this.products,
    this.notFoundIds = const <String>{},
    this.errorMessage,
  });
}

abstract class SubscriptionStoreGateway {
  Stream<List<SubscriptionPurchaseDetails>> get purchaseStream;

  Future<bool> isAvailable();

  Future<SubscriptionProductQuery> queryProducts(Set<String> productIds);

  Future<bool> buyProduct(SubscriptionProduct product);

  Future<void> restorePurchases();

  Future<void> completePurchase(SubscriptionPurchaseDetails purchase);

  Future<List<SubscriptionPurchaseDetails>> pendingPurchases();
}

class InAppPurchaseStoreGateway implements SubscriptionStoreGateway {
  InAppPurchaseStoreGateway({
    InAppPurchase? inAppPurchase,
    required SubscriptionStoreKind store,
  }) : _inAppPurchase = inAppPurchase ?? InAppPurchase.instance,
       _store = store;

  final InAppPurchase _inAppPurchase;
  final SubscriptionStoreKind _store;

  @override
  Stream<List<SubscriptionPurchaseDetails>> get purchaseStream {
    return _inAppPurchase.purchaseStream.map((List<PurchaseDetails> purchases) {
      return purchases.map(_mapPurchase).toList(growable: false);
    });
  }

  @override
  Future<bool> isAvailable() {
    return _inAppPurchase.isAvailable();
  }

  @override
  Future<SubscriptionProductQuery> queryProducts(Set<String> productIds) async {
    final ProductDetailsResponse response = await _inAppPurchase
        .queryProductDetails(productIds);

    return SubscriptionProductQuery(
      products: response.productDetails
          .map((ProductDetails product) => _mapProduct(product))
          .toList(),
      notFoundIds: response.notFoundIDs.toSet(),
      errorMessage: response.error?.message,
    );
  }

  @override
  Future<bool> buyProduct(SubscriptionProduct product) {
    final Object? rawProduct = product.storeObject;
    if (rawProduct is! ProductDetails) {
      throw StateError('Subscription product is missing store details');
    }

    if (_store == SubscriptionStoreKind.playStore &&
        rawProduct is GooglePlayProductDetails) {
      return _inAppPurchase.buyNonConsumable(
        purchaseParam: GooglePlayPurchaseParam(
          productDetails: rawProduct,
          offerToken: rawProduct.offerToken,
        ),
      );
    }

    return _inAppPurchase.buyNonConsumable(
      purchaseParam: PurchaseParam(productDetails: rawProduct),
    );
  }

  @override
  Future<void> restorePurchases() {
    return _inAppPurchase.restorePurchases();
  }

  @override
  Future<List<SubscriptionPurchaseDetails>> pendingPurchases() async {
    if (_store != SubscriptionStoreKind.appStore) {
      return const <SubscriptionPurchaseDetails>[];
    }

    final List<SKPaymentTransactionWrapper> transactions =
        await SKPaymentQueueWrapper().transactions();
    if (transactions.isEmpty) {
      return const <SubscriptionPurchaseDetails>[];
    }

    String receipt = '';
    try {
      receipt = await SKReceiptManager.retrieveReceiptData();
    } catch (_) {
      // Failed/canceled StoreKit transactions can still be finished without a
      // receipt. Purchased/restored transactions will fail backend validation
      // and remain retryable if the receipt cannot be loaded yet.
    }

    return transactions
        .map(
          (SKPaymentTransactionWrapper transaction) => _mapPurchase(
            AppStorePurchaseDetails.fromSKTransaction(transaction, receipt),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> completePurchase(SubscriptionPurchaseDetails purchase) async {
    final Object? rawPurchase =
        purchase.storeObject ?? _rawPurchaseById[purchase.purchaseId];
    if (rawPurchase is PurchaseDetails && rawPurchase.pendingCompletePurchase) {
      await _inAppPurchase.completePurchase(rawPurchase);
    }
  }

  final Map<String, PurchaseDetails> _rawPurchaseById =
      <String, PurchaseDetails>{};

  SubscriptionProduct _mapProduct(ProductDetails product) {
    return SubscriptionProduct(
      id: product.id,
      title: product.title,
      description: product.description,
      price: product.price,
      rawPrice: product.rawPrice,
      currencyCode: product.currencyCode,
      planLabel: _planLabelForProduct(product),
      storeObject: product,
    );
  }

  String? _planLabelForProduct(ProductDetails product) {
    if (product is! GooglePlayProductDetails) return null;

    final int? subscriptionIndex = product.subscriptionIndex;
    final subscriptionOffers = product.productDetails.subscriptionOfferDetails;
    if (subscriptionIndex != null && subscriptionOffers != null) {
      final offer = subscriptionOffers[subscriptionIndex];
      return _playPlanLabel(
        basePlanId: offer.basePlanId,
        offerId: offer.offerId,
      );
    }

    if (product.id == SubscriptionProductIds.playOneTime) {
      return 'Lifetime';
    }

    return null;
  }

  static String _playPlanLabel({required String basePlanId, String? offerId}) {
    final String normalizedBasePlan = basePlanId.trim().toLowerCase();
    return switch (normalizedBasePlan) {
      SubscriptionProductIds.playOfferYear => 'Yearly',
      SubscriptionProductIds.playOfferMonthly => 'Monthly',
      SubscriptionProductIds.playOfferWeekly => 'Weekly',
      SubscriptionProductIds.playOfferLifeLong => 'Lifetime',
      _ => switch (offerId?.trim().toLowerCase()) {
        SubscriptionProductIds.playOfferLifeLong => 'Lifetime',
        _ => basePlanId,
      },
    };
  }

  SubscriptionPurchaseDetails _mapPurchase(PurchaseDetails purchase) {
    final String? purchaseId = purchase.purchaseID;
    if (purchaseId != null) {
      _rawPurchaseById[purchaseId] = purchase;
    }

    return SubscriptionPurchaseDetails(
      store: _store,
      productId: purchase.productID,
      purchaseId: purchaseId,
      transactionDate: purchase.transactionDate,
      status: _mapStatus(purchase.status),
      verificationData: SubscriptionVerificationData(
        source: purchase.verificationData.source,
        localVerificationData: purchase.verificationData.localVerificationData,
        serverVerificationData:
            purchase.verificationData.serverVerificationData,
      ),
      pendingCompletePurchase: purchase.pendingCompletePurchase,
      errorMessage: purchase.error?.message,
      storeObject: purchase,
    );
  }

  SubscriptionPurchaseStatus _mapStatus(PurchaseStatus status) {
    return switch (status) {
      PurchaseStatus.pending => SubscriptionPurchaseStatus.pending,
      PurchaseStatus.purchased => SubscriptionPurchaseStatus.purchased,
      PurchaseStatus.error => SubscriptionPurchaseStatus.error,
      PurchaseStatus.restored => SubscriptionPurchaseStatus.restored,
      PurchaseStatus.canceled => SubscriptionPurchaseStatus.canceled,
    };
  }
}
