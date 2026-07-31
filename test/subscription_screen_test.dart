import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_entitlement_storage.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_product_config.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_product_ids.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_purchase.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_service.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_store_gateway.dart';
import 'package:pow_wow/screens/subscription/subscription_screen.dart';
import 'package:pow_wow/test_screen/test_logs_screen_controller.dart';

import 'subscription_test_fakes.dart';

void main() {
  group('SubscriptionScreen', () {
    late FakeSubscriptionStoreGateway store;
    late FakeSubscriptionBackendClient backend;

    setUpAll(() async {
      await configureFakePathProviderForTests();
    });

    setUp(() async {
      Get.testMode = true;
      store = FakeSubscriptionStoreGateway();
      backend = FakeSubscriptionBackendClient();
      await SubscriptionEntitlementStorage.clear();
    });

    tearDown(() async {
      await store.dispose();
      await SubscriptionEntitlementStorage.clear();
      Get.reset();
    });

    Future<SubscriptionService> pumpScreen(
      WidgetTester tester, {
      SubscriptionProductConfig? config,
    }) async {
      final service = SubscriptionService(
        config: config ?? testProductConfig(),
        storeGateway: store,
        backendClient: backend,
        autoInitialize: false,
        purchaseReplayDebounce: Duration.zero,
      );
      Get.put<SubscriptionService>(service);
      Get.put<TestLogsScreenController>(TestLogsScreenController());

      await tester.pumpWidget(const GetMaterialApp(home: SubscriptionScreen()));
      return service;
    }

    testWidgets(
      'shows unavailable state when product catalog is not configured',
      (WidgetTester tester) async {
        final service = await pumpScreen(
          tester,
          config: const SubscriptionProductConfig(
            store: SubscriptionStoreKind.unknown,
            productIds: <String>{},
          ),
        );

        await service.initialize();
        await tester.pump();

        expect(find.text('Product catalog is not configured'), findsOneWidget);
        expect(find.text('Catalog unavailable'), findsOneWidget);
      },
    );

    testWidgets('shows loading state while products load', (
      WidgetTester tester,
    ) async {
      store.isAvailableCompleter = Completer<bool>();
      final service = await pumpScreen(tester);

      unawaited(service.initialize());
      await tester.pump();

      expect(find.text('Loading plans'), findsWidgets);
      expect(find.text('Loading plans from the store...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);

      store.isAvailableCompleter!.complete(true);
      await tester.pumpAndSettle();
    });

    testWidgets('shows active entitlement state', (WidgetTester tester) async {
      store.products = <SubscriptionProduct>[
        testProduct(
          id: SubscriptionProductIds.appStoreWeek,
          title: 'Full access weekly',
        ),
      ];
      await SubscriptionEntitlementStorage.write(
        activeEntitlement(productId: SubscriptionProductIds.appStoreWeek),
      );
      final service = await pumpScreen(tester);

      await service.initialize();
      await tester.pump();

      expect(
        find.text('Active subscription: Full access weekly'),
        findsOneWidget,
      );
      expect(
        find.textContaining(SubscriptionProductIds.appStoreWeek),
        findsNothing,
      );
      expect(find.text('CURRENT'), findsNothing);
      expect(find.text('Current plan'), findsOneWidget);
      expect(find.textContaining('Store purchase confirmed'), findsNothing);
    });

    testWidgets('shows unavailable state when backend is not configured', (
      WidgetTester tester,
    ) async {
      store.products = <SubscriptionProduct>[testProduct()];
      backend = FakeSubscriptionBackendClient(configured: false);
      final service = await pumpScreen(tester);

      await service.initialize();
      await tester.pump();

      expect(find.text('Product catalog is not configured'), findsOneWidget);
      expect(find.text('Catalog unavailable'), findsOneWidget);
      expect(find.text('PowWow Monthly'), findsNothing);
    });

    testWidgets('shows purchase error state', (WidgetTester tester) async {
      store.products = <SubscriptionProduct>[testProduct()];
      store.buyResult = false;
      final service = await pumpScreen(tester);

      await service.initialize();
      await service.buyProduct(service.products.single);
      await tester.pump();

      expect(find.text('Purchase could not be started'), findsOneWidget);
    });

    testWidgets('does not duplicate plan title as subtitle', (
      WidgetTester tester,
    ) async {
      store.products = <SubscriptionProduct>[
        testProduct(
          id: SubscriptionProductIds.appStoreYear,
          title: 'Full access yearly',
          price: r'$29.99',
          rawPrice: 29.99,
        ),
      ];
      final service = await pumpScreen(tester);

      await service.initialize();
      await tester.pump();

      expect(find.text('Full access yearly'), findsOneWidget);
      expect(find.text('Monthly family subscription'), findsNothing);
    });

    testWidgets('shows restore in progress state', (WidgetTester tester) async {
      store.products = <SubscriptionProduct>[testProduct()];
      final service = await pumpScreen(tester);

      await service.initialize();

      // Only gate the explicit "Restore purchases" tap below; the silent
      // restore triggered by initialize() above must resolve immediately.
      store.restoreCompleter = Completer<void>();
      final restoreFuture = service.restorePurchases();
      await tester.pump();

      expect(find.text('Restoring...'), findsOneWidget);
      expect(find.text('Restore purchases'), findsOneWidget);

      store.restoreCompleter!.complete();
      await restoreFuture;
      await tester.pumpAndSettle();
    });

    testWidgets('shows validation overlay instead of inline pending card', (
      WidgetTester tester,
    ) async {
      store.products = <SubscriptionProduct>[testProduct()];
      final service = await pumpScreen(tester);

      await service.initialize();
      store.emit(<SubscriptionPurchaseDetails>[
        testPurchase(status: SubscriptionPurchaseStatus.pending),
      ]);
      await tester.pump();

      expect(find.text('Validating...'), findsOneWidget);
      expect(find.text('Continue with PowWow Monthly'), findsOneWidget);
      expect(find.text('Please wait'), findsNothing);
      expect(find.text('Validation pending'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('subscription_validation_overlay')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('subscription_validation_back')),
        findsOneWidget,
      );
    });

    testWidgets('sorts plans by highest price first', (
      WidgetTester tester,
    ) async {
      store.products = <SubscriptionProduct>[
        testProduct(
          id: SubscriptionProductIds.appStoreWeek,
          title: 'Full access weekly',
          price: r'$0.99',
          rawPrice: 0.99,
        ),
        testProduct(
          id: SubscriptionProductIds.appStoreMonth,
          title: 'Full access monthly',
          price: r'$3.99',
          rawPrice: 3.99,
        ),
        testProduct(
          id: SubscriptionProductIds.appStoreYear,
          title: 'Full access yearly',
          price: r'$29.99',
          rawPrice: 29.99,
        ),
      ];
      final service = await pumpScreen(tester);

      await service.initialize();
      await tester.pump();

      final double yearlyTop = tester
          .getTopLeft(find.text('Full access yearly'))
          .dy;
      final double monthlyTop = tester
          .getTopLeft(find.text('Full access monthly'))
          .dy;
      final double weeklyTop = tester
          .getTopLeft(find.text('Full access weekly'))
          .dy;

      expect(yearlyTop, lessThan(monthlyTop));
      expect(monthlyTop, lessThan(weeklyTop));
    });

    testWidgets(
      'keeps current plan disabled and allows another plan purchase',
      (WidgetTester tester) async {
        store.products = <SubscriptionProduct>[
          testProduct(title: 'PowWow Monthly'),
          testProduct(
            id: 'powwow_yearly',
            title: 'PowWow Yearly',
            price: r'$49.99',
          ),
        ];
        await SubscriptionEntitlementStorage.write(
          activeEntitlement(productId: 'powwow_monthly'),
        );
        final service = await pumpScreen(tester);

        await service.initialize();
        await tester.pump();

        expect(find.text('CURRENT'), findsNothing);
        expect(find.text('Continue with PowWow Yearly'), findsOneWidget);

        await tester.tap(find.text('PowWow Monthly'));
        await tester.pump();

        expect(find.text('Continue with PowWow Yearly'), findsOneWidget);

        await tester.ensureVisible(find.text('Continue with PowWow Yearly'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Continue with PowWow Yearly'));
        await tester.pump();

        expect(store.buyCallCount, 1);
      },
    );

    testWidgets('opens test logs before HomeController is registered', (
      WidgetTester tester,
    ) async {
      final service = await pumpScreen(tester);

      await service.initialize();
      await tester.tap(find.byTooltip('Test logs'));
      await tester.pumpAndSettle();

      expect(find.text('Home controller not active'), findsOneWidget);
      expect(find.text('No logs'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
