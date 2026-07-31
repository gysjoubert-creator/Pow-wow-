import 'package:flutter_test/flutter_test.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_entitlement.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_entitlement_storage.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_product_config.dart';

import 'subscription_test_fakes.dart';

void main() {
  group('SubscriptionEntitlementStorage', () {
    setUpAll(() async {
      await configureFakePathProviderForTests();
    });

    setUp(() async {
      await SubscriptionEntitlementStorage.clear();
      await SubscriptionEntitlementStorage.clear(uid: 'user-1');
      await SubscriptionEntitlementStorage.clear(uid: 'user-2');
    });

    test('returns null when nothing is cached', () {
      expect(SubscriptionEntitlementStorage.read(), isNull);
    });

    test('round-trips an entitlement for the anonymous key', () async {
      final SubscriptionEntitlement entitlement = SubscriptionEntitlement(
        active: true,
        store: SubscriptionStoreKind.appStore,
        productId: 'powwow_monthly',
        source: SubscriptionEntitlementSource.purchased,
        expiresAt: DateTime.utc(2027, 1, 1),
        validatedAt: DateTime.utc(2026, 7, 1),
        willRenew: true,
        environment: 'production',
      );

      await SubscriptionEntitlementStorage.write(entitlement);
      final SubscriptionEntitlement? cached =
          SubscriptionEntitlementStorage.read();

      expect(cached, isNotNull);
      expect(cached!.active, isTrue);
      expect(cached.productId, 'powwow_monthly');
      expect(cached.expiresAt, entitlement.expiresAt);
      expect(cached.validatedAt, entitlement.validatedAt);
      expect(cached.willRenew, isTrue);
      expect(cached.environment, 'production');
    });

    test(
      'keeps per-uid entries separate from each other and anonymous',
      () async {
        await SubscriptionEntitlementStorage.write(
          activeEntitlement(),
          uid: 'user-1',
        );

        expect(
          SubscriptionEntitlementStorage.read(uid: 'user-1')?.active,
          isTrue,
        );
        expect(SubscriptionEntitlementStorage.read(uid: 'user-2'), isNull);
        expect(SubscriptionEntitlementStorage.read(), isNull);
      },
    );

    test('clear removes only the targeted key', () async {
      await SubscriptionEntitlementStorage.write(activeEntitlement());
      await SubscriptionEntitlementStorage.write(
        activeEntitlement(),
        uid: 'user-1',
      );

      await SubscriptionEntitlementStorage.clear();

      expect(SubscriptionEntitlementStorage.read(), isNull);
      expect(SubscriptionEntitlementStorage.read(uid: 'user-1'), isNotNull);
    });
  });
}
