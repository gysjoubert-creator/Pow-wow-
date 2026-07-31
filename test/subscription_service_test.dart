import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_backend_client.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_entitlement.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_entitlement_storage.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_product_config.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_purchase.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_service.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_state.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_store_gateway.dart';

import 'subscription_test_fakes.dart';

void main() {
  group('SubscriptionService', () {
    late FakeSubscriptionStoreGateway store;
    late FakeSubscriptionBackendClient backend;

    setUpAll(() async {
      await configureFakePathProviderForTests();
    });

    setUp(() async {
      await SubscriptionEntitlementStorage.clear();
    });

    tearDown(() async {
      await store.dispose();
      await SubscriptionEntitlementStorage.clear();
    });

    SubscriptionService buildService({
      SubscriptionProductConfig? config,
      Duration purchaseReplayDebounce = Duration.zero,
    }) {
      return SubscriptionService(
        config: config ?? testProductConfig(),
        storeGateway: store,
        backendClient: backend,
        autoInitialize: false,
        purchaseReplayDebounce: purchaseReplayDebounce,
      );
    }

    test(
      'marks subscriptions unavailable when product catalog source is missing',
      () async {
        store = FakeSubscriptionStoreGateway();
        backend = FakeSubscriptionBackendClient();
        final service = buildService(
          config: const SubscriptionProductConfig(
            store: SubscriptionStoreKind.unknown,
            productIds: <String>{},
          ),
        );

        await service.initialize();

        expect(service.state.productsConfigured, isFalse);
        expect(service.state.isUnavailable, isTrue);
        expect(store.products, isEmpty);
      },
    );

    test('loads products and starts with no cached entitlement', () async {
      store = FakeSubscriptionStoreGateway()
        ..products = <SubscriptionProduct>[testProduct()];
      backend = FakeSubscriptionBackendClient();
      final service = buildService();

      await service.initialize();

      expect(service.products.single.id, 'powwow_monthly');
      expect(service.state.storeAvailable, isTrue);
      expect(service.state.entitlement, isNull);
      expect(service.state.hasActiveEntitlement, isFalse);
      expect(store.restoreCallCount, 1);
    });

    test('joins concurrent initialize calls', () async {
      store = FakeSubscriptionStoreGateway()
        ..products = <SubscriptionProduct>[testProduct()]
        ..isAvailableCompleter = Completer<bool>();
      backend = FakeSubscriptionBackendClient();
      final service = buildService();

      final Future<void> firstInitialize = service.initialize();
      final Future<void> secondInitialize = service.initialize();

      expect(identical(firstInitialize, secondInitialize), isTrue);

      store.isAvailableCompleter!.complete(true);
      await Future.wait(<Future<void>>[firstInitialize, secondInitialize]);

      expect(backend.fetchProductIdsCallCount, 1);
      expect(store.restoreCallCount, 1);
      expect(service.state.phase, SubscriptionServicePhase.idle);
    });

    test('hydrates entitlement from the local cache on initialize', () async {
      await SubscriptionEntitlementStorage.write(activeEntitlement());
      store = FakeSubscriptionStoreGateway()
        ..products = <SubscriptionProduct>[testProduct()];
      backend = FakeSubscriptionBackendClient();
      final service = buildService();

      await service.initialize();

      expect(service.state.hasActiveEntitlement, isTrue);
      expect(service.state.entitlement?.productId, 'powwow_monthly');
    });

    test('rejects cached subscription entitlement without expiry', () async {
      await SubscriptionEntitlementStorage.write(
        activeEntitlement(includeExpiresAt: false),
      );
      store = FakeSubscriptionStoreGateway()
        ..products = <SubscriptionProduct>[testProduct()];
      backend = FakeSubscriptionBackendClient();
      final service = buildService();

      await service.initialize();

      expect(service.state.entitlement, isNull);
      expect(service.state.hasActiveEntitlement, isFalse);
      expect(SubscriptionEntitlementStorage.read(), isNull);
    });

    test(
      'rejects legacy cached entitlement without expiry or validation time',
      () async {
        await SubscriptionEntitlementStorage.write(
          const SubscriptionEntitlement(
            active: true,
            store: SubscriptionStoreKind.appStore,
            productId: 'powwow_monthly',
            source: SubscriptionEntitlementSource.purchased,
            expiresAt: null,
            validatedAt: null,
            willRenew: null,
            environment: 'sandbox',
          ),
        );
        store = FakeSubscriptionStoreGateway()
          ..products = <SubscriptionProduct>[testProduct()];
        backend = FakeSubscriptionBackendClient();
        final service = buildService();

        await service.initialize();

        expect(service.state.entitlement, isNull);
        expect(service.state.hasActiveEntitlement, isFalse);
        expect(SubscriptionEntitlementStorage.read(), isNull);
      },
    );

    test('keeps cached lifetime entitlement without expiry', () async {
      await SubscriptionEntitlementStorage.write(
        activeEntitlement(
          productId: 'com.gys.powwow.life',
          includeExpiresAt: false,
        ),
      );
      store = FakeSubscriptionStoreGateway()
        ..products = <SubscriptionProduct>[testProduct()];
      backend = FakeSubscriptionBackendClient();
      final service = buildService();

      await service.initialize();

      expect(store.restoreCallCount, 1);
      expect(service.state.hasActiveEntitlement, isTrue);
      expect(service.state.entitlement?.productId, 'com.gys.powwow.life');
      expect(
        SubscriptionEntitlementStorage.read()?.productId,
        'com.gys.powwow.life',
      );
    });

    test('silent refresh replays purchases via restorePurchases', () async {
      store = FakeSubscriptionStoreGateway()
        ..products = <SubscriptionProduct>[testProduct()];
      backend = FakeSubscriptionBackendClient();
      final service = buildService();

      await service.initialize();
      final int callsAfterInit = store.restoreCallCount;
      await service.refreshEntitlement(silent: true);

      expect(store.restoreCallCount, callsAfterInit + 1);
      expect(service.state.phase, SubscriptionServicePhase.idle);
      expect(service.state.errorMessage, isNull);
    });

    test('moves to purchase pending when store emits pending update', () async {
      store = FakeSubscriptionStoreGateway()
        ..products = <SubscriptionProduct>[testProduct()];
      backend = FakeSubscriptionBackendClient();
      final service = buildService();

      await service.initialize();
      store.emit(<SubscriptionPurchaseDetails>[
        testPurchase(status: SubscriptionPurchaseStatus.pending),
      ]);
      await flushMicrotasks();

      expect(service.state.phase, SubscriptionServicePhase.purchasePending);
      expect(service.state.hasActiveEntitlement, isFalse);
    });

    test(
      'validates purchased update before completing purchase and caches it',
      () async {
        store = FakeSubscriptionStoreGateway()
          ..products = <SubscriptionProduct>[testProduct()];
        backend = FakeSubscriptionBackendClient(
          verifyResult: activeEntitlement(),
        );
        final service = buildService();

        await service.initialize();
        store.emit(<SubscriptionPurchaseDetails>[testPurchase()]);
        await flushMicrotasks();

        expect(backend.verifyCallCount, 1);
        expect(store.completeCallCount, 1);
        expect(service.state.hasActiveEntitlement, isTrue);
        expect(service.state.pendingVerificationPurchase, isNull);
        expect(SubscriptionEntitlementStorage.read()?.active, isTrue);
      },
    );

    test('restore emits restored purchase and validates entitlement', () async {
      store = FakeSubscriptionStoreGateway()
        ..products = <SubscriptionProduct>[testProduct()];
      backend = FakeSubscriptionBackendClient(
        verifyResult: activeEntitlement(),
      );
      final service = buildService();

      await service.initialize();
      final restoreFuture = service.restorePurchases();
      store.emit(<SubscriptionPurchaseDetails>[
        testPurchase(status: SubscriptionPurchaseStatus.restored),
      ]);
      await restoreFuture;
      await flushMicrotasks();

      expect(store.restoreCallCount, 2);
      expect(backend.verifyCallCount, 1);
      expect(service.state.hasActiveEntitlement, isTrue);
    });

    test('collapses replayed renewals to the newest transaction', () async {
      store = FakeSubscriptionStoreGateway()
        ..products = <SubscriptionProduct>[testProduct()];
      backend = FakeSubscriptionBackendClient(
        verifyResult: activeEntitlement(),
      );
      final service = buildService();

      await service.initialize();
      store.emit(<SubscriptionPurchaseDetails>[
        testPurchase(
          purchaseId: '2000001199652697',
          transactionDate: '2026-07-04 12:58:51',
        ),
        testPurchase(
          purchaseId: '2000001199658128',
          transactionDate: '2026-07-04 13:22:51',
        ),
        testPurchase(
          purchaseId: '2000001199656355',
          transactionDate: '2026-07-04 13:13:51',
        ),
      ]);
      await flushMicrotasks();

      expect(backend.verifyCallCount, 1);
      expect(backend.verifiedPurchases.single.purchaseId, '2000001199658128');
      expect(store.completeCallCount, 3);
      expect(
        store.completedPurchases.map((purchase) => purchase.purchaseId),
        containsAll(<String>[
          '2000001199652697',
          '2000001199658128',
          '2000001199656355',
        ]),
      );
      expect(service.state.hasActiveEntitlement, isTrue);
    });

    test('debounces replayed purchases across stream events', () async {
      store = FakeSubscriptionStoreGateway()
        ..products = <SubscriptionProduct>[testProduct()];
      backend = FakeSubscriptionBackendClient(
        verifyResult: activeEntitlement(),
      );
      final service = buildService(
        purchaseReplayDebounce: const Duration(milliseconds: 20),
      );

      await service.initialize();
      store.emit(<SubscriptionPurchaseDetails>[
        testPurchase(
          purchaseId: '2000001199652697',
          transactionDate: '2026-07-04 12:58:51',
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      store.emit(<SubscriptionPurchaseDetails>[
        testPurchase(
          purchaseId: '2000001199658128',
          transactionDate: '2026-07-04 13:22:51',
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      store.emit(<SubscriptionPurchaseDetails>[
        testPurchase(
          purchaseId: '2000001199656355',
          transactionDate: '2026-07-04 13:13:51',
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await flushMicrotasks();

      expect(backend.verifyCallCount, 1);
      expect(backend.verifiedPurchases.single.purchaseId, '2000001199658128');
      expect(service.state.hasActiveEntitlement, isTrue);
    });

    test('entitlement gate waits for debounced replay validation', () async {
      store = FakeSubscriptionStoreGateway()
        ..products = <SubscriptionProduct>[testProduct()];
      backend = FakeSubscriptionBackendClient(
        verifyResult: activeEntitlement(),
      );
      final service = buildService(
        purchaseReplayDebounce: const Duration(milliseconds: 20),
      );

      final Future<void> gate = service.prepareEntitlementGate(source: 'test');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      store.emit(<SubscriptionPurchaseDetails>[
        testPurchase(
          purchaseId: '2000001199658128',
          transactionDate: '2026-07-04 13:22:51',
        ),
      ]);

      await gate;

      expect(backend.verifyCallCount, 1);
      expect(service.state.hasActiveEntitlement, isTrue);
    });

    test(
      'continues to the next product candidate until entitlement is active',
      () async {
        store = FakeSubscriptionStoreGateway()
          ..products = <SubscriptionProduct>[
            testProduct(id: 'powwow_weekly'),
            testProduct(id: 'powwow_lifetime'),
          ];
        backend = FakeSubscriptionBackendClient(
          verifyResults: <SubscriptionEntitlement>[
            SubscriptionEntitlement.inactive(),
            activeEntitlement(productId: 'powwow_lifetime'),
          ],
        );
        final service = buildService();

        await service.initialize();
        store.emit(<SubscriptionPurchaseDetails>[
          testPurchase(
            productId: 'powwow_lifetime',
            purchaseId: '100',
            transactionDate: '2026-07-03T12:00:00Z',
          ),
          testPurchase(
            productId: 'powwow_weekly',
            purchaseId: '200',
            transactionDate: '2026-07-04T12:00:00Z',
          ),
        ]);
        await flushMicrotasks();

        expect(backend.verifyCallCount, 2);
        expect(
          backend.verifiedPurchases.map((purchase) => purchase.productId),
          <String>['powwow_weekly', 'powwow_lifetime'],
        );
        expect(service.state.hasActiveEntitlement, isTrue);
        expect(service.state.entitlement?.productId, 'powwow_lifetime');
      },
    );

    test('dedupes concurrent verify calls for the same purchaseId', () async {
      store = FakeSubscriptionStoreGateway()
        ..products = <SubscriptionProduct>[testProduct()];
      final Completer<SubscriptionEntitlement> verifyCompleter =
          Completer<SubscriptionEntitlement>();
      backend = FakeSubscriptionBackendClient(verifyResult: activeEntitlement())
        ..verifyCompleter = verifyCompleter;
      final service = buildService();

      await service.initialize();
      store.emit(<SubscriptionPurchaseDetails>[testPurchase()]);
      store.emit(<SubscriptionPurchaseDetails>[
        testPurchase(status: SubscriptionPurchaseStatus.restored),
      ]);
      await flushMicrotasks();

      expect(backend.verifyCallCount, 1);

      verifyCompleter.complete(activeEntitlement());
      await flushMicrotasks();

      expect(backend.verifyCallCount, 1);
      expect(store.completeCallCount, 1);
      expect(service.state.hasActiveEntitlement, isTrue);

      store.emit(<SubscriptionPurchaseDetails>[
        testPurchase(status: SubscriptionPurchaseStatus.restored),
      ]);
      await flushMicrotasks();

      expect(backend.verifyCallCount, 2);
      expect(service.state.hasActiveEntitlement, isTrue);
    });

    test(
      'does not retain previous expiry when replay returns subscription without expiry',
      () async {
        final DateTime serverExpiry = DateTime.now().toUtc().add(
          const Duration(days: 30),
        );
        final DateTime firstValidatedAt = DateTime.utc(2026, 7, 6, 14, 40, 54);
        final DateTime replayValidatedAt = DateTime.utc(2026, 7, 6, 14, 40, 58);
        store = FakeSubscriptionStoreGateway()
          ..products = <SubscriptionProduct>[testProduct()];
        backend = FakeSubscriptionBackendClient(
          verifyResults: <SubscriptionEntitlement>[
            activeEntitlement(
              expiresAt: serverExpiry,
              validatedAt: firstValidatedAt,
            ),
            activeEntitlement(
              includeExpiresAt: false,
              validatedAt: replayValidatedAt,
            ),
          ],
        );
        final service = buildService();

        await service.initialize();
        store.emit(<SubscriptionPurchaseDetails>[testPurchase()]);
        await flushMicrotasks();

        expect(service.state.entitlement?.expiresAt, serverExpiry);

        store.emit(<SubscriptionPurchaseDetails>[
          testPurchase(status: SubscriptionPurchaseStatus.restored),
        ]);
        await flushMicrotasks();

        final SubscriptionEntitlement? cached =
            SubscriptionEntitlementStorage.read();
        expect(backend.verifyCallCount, 2);
        expect(service.state.hasActiveEntitlement, isFalse);
        expect(service.state.entitlement?.expiresAt, isNull);
        expect(service.state.entitlement?.validatedAt, replayValidatedAt);
        expect(cached?.expiresAt, isNull);
      },
    );

    test('keeps pending verification when backend validation fails', () async {
      store = FakeSubscriptionStoreGateway()
        ..products = <SubscriptionProduct>[testProduct()];
      backend = FakeSubscriptionBackendClient()
        ..verifyError = const SubscriptionBackendException(
          'Service unavailable',
          statusCode: 503,
        );
      final service = buildService();

      await service.initialize();
      store.emit(<SubscriptionPurchaseDetails>[testPurchase()]);
      await flushMicrotasks();

      expect(backend.verifyCallCount, 1);
      expect(store.completeCallCount, 0);
      expect(service.state.phase, SubscriptionServicePhase.error);
      expect(service.state.pendingVerificationPurchase, isNotNull);
      expect(service.state.hasActiveEntitlement, isFalse);
      expect(service.state.errorMessage, 'Service unavailable (HTTP 503)');
    });

    test(
      'keeps collapsed replay purchases unfinished when backend validation fails',
      () async {
        store = FakeSubscriptionStoreGateway()
          ..products = <SubscriptionProduct>[testProduct()];
        backend = FakeSubscriptionBackendClient()
          ..verifyError = const SubscriptionBackendException(
            'Service unavailable',
            statusCode: 503,
          );
        final service = buildService();

        await service.initialize();
        store.emit(<SubscriptionPurchaseDetails>[
          testPurchase(
            purchaseId: '2000001199652697',
            transactionDate: '2026-07-04 12:58:51',
          ),
          testPurchase(
            purchaseId: '2000001199658128',
            transactionDate: '2026-07-04 13:22:51',
          ),
        ]);
        await flushMicrotasks();

        expect(backend.verifyCallCount, 1);
        expect(store.completeCallCount, 0);
        expect(service.state.phase, SubscriptionServicePhase.error);
        expect(
          service.state.pendingVerificationPurchase?.purchaseId,
          '2000001199658128',
        );
      },
    );

    test(
      'completes failed purchase updates after handling the error',
      () async {
        store = FakeSubscriptionStoreGateway()
          ..products = <SubscriptionProduct>[testProduct()];
        backend = FakeSubscriptionBackendClient();
        final service = buildService();

        await service.initialize();
        store.emit(<SubscriptionPurchaseDetails>[
          testPurchase(
            status: SubscriptionPurchaseStatus.error,
            purchaseId: null,
            errorMessage: 'StoreKit failed',
          ),
        ]);
        await flushMicrotasks();

        expect(store.completeCallCount, 1);
        expect(
          store.completedPurchases.single.status,
          SubscriptionPurchaseStatus.error,
        );
        expect(backend.verifyCallCount, 0);
        expect(service.state.phase, SubscriptionServicePhase.error);
        expect(service.state.errorMessage, 'StoreKit failed');
      },
    );

    test(
      'drains stale canceled transactions before starting a new purchase',
      () async {
        store = FakeSubscriptionStoreGateway()
          ..products = <SubscriptionProduct>[testProduct()]
          ..pendingPurchasesResult = <SubscriptionPurchaseDetails>[
            testPurchase(
              status: SubscriptionPurchaseStatus.canceled,
              purchaseId: null,
            ),
          ];
        backend = FakeSubscriptionBackendClient();
        final service = buildService();

        await service.initialize();
        await service.buyProduct(service.products.single);

        expect(store.pendingPurchasesCallCount, 1);
        expect(store.completeCallCount, 1);
        expect(store.buyCallCount, 1);
        expect(backend.verifyCallCount, 0);
        expect(service.state.phase, SubscriptionServicePhase.purchasePending);
      },
    );

    test(
      'recovers duplicate product errors by validating stale purchased transactions',
      () async {
        store = FakeSubscriptionStoreGateway()
          ..products = <SubscriptionProduct>[testProduct()]
          ..buyError = PlatformException(
            code: 'storekit_duplicate_product_object',
            message:
                'There is a pending transaction for the same product identifier.',
          )
          ..pendingPurchasesResults = <List<SubscriptionPurchaseDetails>>[
            <SubscriptionPurchaseDetails>[],
            <SubscriptionPurchaseDetails>[
              testPurchase(productId: 'powwow_monthly', purchaseId: 'tx_stale'),
            ],
          ];
        backend = FakeSubscriptionBackendClient(
          verifyResult: activeEntitlement(),
        );
        final service = buildService();

        await service.initialize();
        await service.buyProduct(service.products.single);

        expect(store.buyCallCount, 1);
        expect(store.pendingPurchasesCallCount, 2);
        expect(backend.verifyCallCount, 1);
        expect(store.completeCallCount, 1);
        expect(service.state.hasActiveEntitlement, isTrue);
        expect(service.state.errorMessage, isNull);
      },
    );

    test(
      'shows friendly message when duplicate product cannot be drained',
      () async {
        store = FakeSubscriptionStoreGateway()
          ..products = <SubscriptionProduct>[testProduct()]
          ..buyError = PlatformException(
            code: 'storekit_duplicate_product_object',
            message:
                'There is a pending transaction for the same product identifier.',
          );
        backend = FakeSubscriptionBackendClient();
        final service = buildService();

        await service.initialize();
        await service.buyProduct(service.products.single);

        expect(store.pendingPurchasesCallCount, 2);
        expect(service.state.phase, SubscriptionServicePhase.error);
        expect(
          service.state.errorMessage,
          'A previous purchase for this product is still pending. '
          'Please wait a moment and try again.',
        );
      },
    );

    test(
      'disables purchases when backend validation is not configured',
      () async {
        store = FakeSubscriptionStoreGateway()
          ..products = <SubscriptionProduct>[testProduct()];
        backend = FakeSubscriptionBackendClient(configured: false);
        final service = buildService();

        await service.initialize();

        expect(service.state.backendConfigured, isFalse);
        expect(service.state.canPurchase, isFalse);
        expect(service.state.canRestore, isFalse);
        expect(service.state.isUnavailable, isTrue);
        expect(store.queryCallCount, 0);
      },
    );

    group('product ID resolution from API', () {
      test('uses product IDs returned by the backend catalog API', () async {
        store = FakeSubscriptionStoreGateway()
          ..products = <SubscriptionProduct>[
            testProduct(id: 'api_product_a'),
            testProduct(id: 'api_product_b'),
          ];
        backend = FakeSubscriptionBackendClient(
          fetchProductIdsResult: const <String>{
            'api_product_a',
            'api_product_b',
          },
        );
        final service = buildService();

        await service.initialize();

        expect(backend.fetchProductIdsCallCount, 1);
        expect(
          store.products.map((p) => p.id),
          containsAll(<String>['api_product_a', 'api_product_b']),
        );
        expect(service.state.storeAvailable, isTrue);
      });

      test(
        'does not fall back to config product IDs when API throws',
        () async {
          store = FakeSubscriptionStoreGateway()
            ..products = <SubscriptionProduct>[testProduct()];
          backend = FakeSubscriptionBackendClient()
            ..fetchProductIdsError = const SubscriptionBackendException(
              'Service unavailable',
              statusCode: 503,
            );
          final service = buildService();

          await service.initialize();

          expect(backend.fetchProductIdsCallCount, 1);
          expect(store.queryCallCount, 0);
          expect(service.state.storeAvailable, isFalse);
          expect(service.state.products, isEmpty);
          expect(service.state.phase, SubscriptionServicePhase.error);
          expect(service.state.errorMessage, 'Service unavailable (HTTP 503)');
        },
      );

      test(
        'does not fall back to config product IDs when API returns empty set',
        () async {
          store = FakeSubscriptionStoreGateway()
            ..products = <SubscriptionProduct>[testProduct()];
          backend = FakeSubscriptionBackendClient(
            fetchProductIdsResult: const <String>{},
          );
          final service = buildService();

          await service.initialize();

          expect(backend.fetchProductIdsCallCount, 1);
          expect(store.queryCallCount, 0);
          expect(service.state.storeAvailable, isFalse);
          expect(service.state.products, isEmpty);
          expect(service.state.phase, SubscriptionServicePhase.error);
          expect(
            service.state.errorMessage,
            'Subscription product catalog is empty for app_store',
          );
        },
      );

      test(
        'marks products unconfigured when backend client is not configured',
        () async {
          store = FakeSubscriptionStoreGateway()
            ..products = <SubscriptionProduct>[testProduct()];
          backend = FakeSubscriptionBackendClient(configured: false);
          final service = buildService();

          await service.initialize();

          expect(backend.fetchProductIdsCallCount, 0);
          expect(store.queryCallCount, 0);
          expect(service.state.productsConfigured, isFalse);
          expect(service.state.products, isEmpty);
          expect(service.state.isUnavailable, isTrue);
        },
      );
    });
  });
}
