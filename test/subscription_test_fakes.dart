import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_backend_client.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_entitlement.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_product_catalog.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_product_config.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_purchase.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_store_gateway.dart';

/// Points `GetStorage`'s on-disk persistence at a temp directory so tests
/// touching `SubscriptionEntitlementStorage` don't hit the real
/// `path_provider` platform channel (unavailable in the test environment).
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._path);

  final String _path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _path;
}

Future<void> configureFakePathProviderForTests() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final Directory tempDir = await Directory.systemTemp.createTemp(
    'powwow_subscription_test_',
  );
  PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
}

class FakeSubscriptionStoreGateway implements SubscriptionStoreGateway {
  final StreamController<List<SubscriptionPurchaseDetails>> _controller =
      StreamController<List<SubscriptionPurchaseDetails>>.broadcast();

  bool available = true;
  List<SubscriptionProduct> products = const <SubscriptionProduct>[];
  Set<String> notFoundIds = const <String>{};
  String? queryErrorMessage;
  bool buyResult = true;
  Object? buyError;
  int buyCallCount = 0;
  int queryCallCount = 0;
  int restoreCallCount = 0;
  int completeCallCount = 0;
  int pendingPurchasesCallCount = 0;
  Completer<bool>? isAvailableCompleter;
  Completer<void>? restoreCompleter;
  Set<String>? lastQueriedProductIds;
  List<SubscriptionPurchaseDetails> completedPurchases =
      <SubscriptionPurchaseDetails>[];
  List<SubscriptionPurchaseDetails> pendingPurchasesResult =
      <SubscriptionPurchaseDetails>[];
  List<List<SubscriptionPurchaseDetails>> pendingPurchasesResults =
      <List<SubscriptionPurchaseDetails>>[];

  @override
  Stream<List<SubscriptionPurchaseDetails>> get purchaseStream {
    return _controller.stream;
  }

  @override
  Future<bool> isAvailable() {
    return isAvailableCompleter?.future ?? Future<bool>.value(available);
  }

  @override
  Future<SubscriptionProductQuery> queryProducts(Set<String> productIds) async {
    queryCallCount += 1;
    lastQueriedProductIds = productIds;
    return SubscriptionProductQuery(
      products: products,
      notFoundIds: notFoundIds,
      errorMessage: queryErrorMessage,
    );
  }

  @override
  Future<bool> buyProduct(SubscriptionProduct product) async {
    buyCallCount += 1;
    final Object? error = buyError;
    if (error != null) throw error;
    return buyResult;
  }

  @override
  Future<void> restorePurchases() async {
    restoreCallCount += 1;
    final Completer<void>? completer = restoreCompleter;
    if (completer != null) {
      return completer.future;
    }
  }

  @override
  Future<void> completePurchase(SubscriptionPurchaseDetails purchase) async {
    completeCallCount += 1;
    completedPurchases.add(purchase);
  }

  @override
  Future<List<SubscriptionPurchaseDetails>> pendingPurchases() async {
    pendingPurchasesCallCount += 1;
    if (pendingPurchasesResults.isNotEmpty) {
      return pendingPurchasesResults.removeAt(0);
    }
    return pendingPurchasesResult;
  }

  void emit(List<SubscriptionPurchaseDetails> purchases) {
    _controller.add(purchases);
  }

  Future<void> dispose() {
    return _controller.close();
  }
}

class FakeSubscriptionBackendClient extends SubscriptionBackendClient {
  FakeSubscriptionBackendClient({
    this.configured = true,
    SubscriptionEntitlement? verifyResult,
    List<SubscriptionEntitlement>? verifyResults,
    Set<String>? fetchProductIdsResult,
    this.fetchProductCatalogResult,
  }) : verifyResult = verifyResult ?? SubscriptionEntitlement.inactive(),
       verifyResults = verifyResults == null
           ? <SubscriptionEntitlement>[]
           : List<SubscriptionEntitlement>.of(verifyResults),
       fetchProductIdsResult =
           fetchProductIdsResult ?? const <String>{'powwow_monthly'},
       super(
         baseUrl: configured ? 'https://subscriptions.test' : '',
         getFirebaseIdToken: () async => 'firebase-token',
       );

  bool configured;
  SubscriptionEntitlement verifyResult;
  List<SubscriptionEntitlement> verifyResults;
  Object? verifyError;
  Completer<SubscriptionEntitlement>? verifyCompleter;
  int verifyCallCount = 0;
  List<SubscriptionPurchaseDetails> verifiedPurchases =
      <SubscriptionPurchaseDetails>[];

  Set<String> fetchProductIdsResult;
  SubscriptionProductCatalogResponse? fetchProductCatalogResult;
  Object? fetchProductIdsError;
  Object? fetchProductCatalogError;
  int fetchProductIdsCallCount = 0;
  int fetchProductCatalogCallCount = 0;

  @override
  bool get isConfigured => configured;

  @override
  Future<SubscriptionEntitlement> verifyPurchase(
    SubscriptionPurchaseDetails purchase,
  ) async {
    verifyCallCount += 1;
    verifiedPurchases.add(purchase);
    final Completer<SubscriptionEntitlement>? completer = verifyCompleter;
    if (completer != null) {
      return completer.future;
    }
    final Object? error = verifyError;
    if (error != null) throw error;
    if (verifyResults.isNotEmpty) {
      return verifyResults.removeAt(0);
    }
    return verifyResult;
  }

  @override
  Future<Set<String>> fetchProductIds(SubscriptionStoreKind store) async {
    fetchProductIdsCallCount += 1;
    final Object? error = fetchProductIdsError;
    if (error != null) throw error;
    return fetchProductIdsResult;
  }

  @override
  Future<SubscriptionProductCatalogResponse> fetchProductCatalog() async {
    fetchProductCatalogCallCount += 1;
    final Object? error = fetchProductCatalogError;
    if (error != null) throw error;
    final SubscriptionProductCatalogResponse? catalog =
        fetchProductCatalogResult;
    if (catalog != null) return catalog;
    throw const SubscriptionBackendException(
      'Fake product catalog is not configured',
    );
  }
}

SubscriptionProductConfig testProductConfig({
  Set<String> productIds = const <String>{'powwow_monthly'},
}) {
  return SubscriptionProductConfig(
    store: SubscriptionStoreKind.appStore,
    productIds: productIds,
  );
}

SubscriptionProduct testProduct({
  String id = 'powwow_monthly',
  String title = 'PowWow Monthly',
  String price = r'$4.99',
  double rawPrice = 4.99,
}) {
  return SubscriptionProduct(
    id: id,
    title: title,
    description: 'Monthly family subscription',
    price: price,
    rawPrice: rawPrice,
    currencyCode: 'USD',
  );
}

SubscriptionPurchaseDetails testPurchase({
  String productId = 'powwow_monthly',
  String? purchaseId = 'tx_123',
  String? transactionDate = '2026-06-19T12:00:00Z',
  SubscriptionPurchaseStatus status = SubscriptionPurchaseStatus.purchased,
  bool pendingCompletePurchase = true,
  String? errorMessage,
}) {
  return SubscriptionPurchaseDetails(
    store: SubscriptionStoreKind.appStore,
    productId: productId,
    purchaseId: purchaseId,
    transactionDate: transactionDate,
    status: status,
    verificationData: const SubscriptionVerificationData(
      source: 'app_store',
      localVerificationData: 'local-data',
      serverVerificationData: 'server-data',
    ),
    pendingCompletePurchase: pendingCompletePurchase,
    errorMessage: errorMessage,
  );
}

SubscriptionEntitlement activeEntitlement({
  String productId = 'powwow_monthly',
  SubscriptionEntitlementSource source =
      SubscriptionEntitlementSource.purchased,
  DateTime? expiresAt,
  bool includeExpiresAt = true,
  DateTime? validatedAt,
  String environment = 'sandbox',
}) {
  return SubscriptionEntitlement(
    active: true,
    store: SubscriptionStoreKind.appStore,
    productId: productId,
    source: source,
    expiresAt:
        expiresAt ??
        (includeExpiresAt
            ? DateTime.now().toUtc().add(const Duration(days: 30))
            : null),
    validatedAt: validatedAt ?? DateTime.now().toUtc(),
    willRenew: true,
    environment: environment,
  );
}

Future<void> flushMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}
