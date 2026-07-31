import 'package:flutter_test/flutter_test.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_entitlement.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_product_config.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_product_ids.dart';

void main() {
  group('SubscriptionEntitlement', () {
    test('parses active family-shared entitlement', () {
      final entitlement = SubscriptionEntitlement.fromJson(<String, dynamic>{
        'active': true,
        'store': 'app_store',
        'productId': 'powwow_yearly',
        'source': 'family_shared',
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(days: 7))
            .toIso8601String(),
        'validatedAt': DateTime.utc(2026, 7, 1).toIso8601String(),
        'willRenew': true,
        'environment': 'sandbox',
      });

      expect(entitlement.hasAccess, isTrue);
      expect(entitlement.isFamilyShared, isTrue);
      expect(entitlement.store, SubscriptionStoreKind.appStore);
      expect(entitlement.productId, 'powwow_yearly');
      expect(entitlement.validatedAt, DateTime.utc(2026, 7, 1));
      expect(entitlement.willRenew, isTrue);
      expect(entitlement.environment, 'sandbox');
    });

    test('parses family-shared validation source fields', () {
      final entitlement = SubscriptionEntitlement.fromValidationResponse(
        <String, dynamic>{
          'active': true,
          'productId': 'powwow_yearly',
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(days: 7))
              .toIso8601String(),
          'in_app_ownership_type': 'FAMILY_SHARED',
        },
        store: SubscriptionStoreKind.appStore,
        fallbackProductId: 'fallback_product',
        fallbackEnvironment: 'sandbox',
      );

      expect(entitlement.hasAccess, isTrue);
      expect(entitlement.isFamilyShared, isTrue);
      expect(entitlement.productId, 'powwow_yearly');
      expect(entitlement.environment, 'sandbox');
    });

    test('defaults validation source to purchased', () {
      final entitlement = SubscriptionEntitlement.fromValidationResponse(
        <String, dynamic>{
          'active': true,
          'productId': 'powwow_yearly',
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(days: 7))
              .toIso8601String(),
        },
        store: SubscriptionStoreKind.appStore,
        fallbackProductId: 'fallback_product',
      );

      expect(entitlement.source, SubscriptionEntitlementSource.purchased);
      expect(entitlement.isFamilyShared, isFalse);
    });

    test('parses validation entitlement from nested data payload', () {
      final DateTime expiresAt = DateTime.now().toUtc().add(
        const Duration(days: 7),
      );
      final entitlement = SubscriptionEntitlement.fromValidationResponse(
        <String, dynamic>{
          'status': 'success',
          'data': <String, dynamic>{
            'product_id': 'powwow_weekly',
            'expiresAt': expiresAt.toIso8601String(),
            'ownershipType': 'FAMILY_SHARED',
          },
        },
        store: SubscriptionStoreKind.appStore,
        fallbackProductId: 'fallback_product',
      );

      expect(entitlement.hasAccess, isTrue);
      expect(entitlement.isFamilyShared, isTrue);
      expect(entitlement.productId, 'powwow_weekly');
      expect(entitlement.expiresAt, expiresAt);
    });

    test('treats expired active response as no access locally', () {
      final entitlement = SubscriptionEntitlement.fromJson(<String, dynamic>{
        'active': true,
        'store': 'app_store',
        'source': 'purchased',
        'expiresAt': DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 1))
            .toIso8601String(),
      });

      expect(entitlement.active, isTrue);
      expect(entitlement.isExpired, isTrue);
      expect(entitlement.hasAccess, isFalse);
    });

    test('treats active subscription without expiry as no access', () {
      final entitlement = SubscriptionEntitlement.fromJson(<String, dynamic>{
        'active': true,
        'store': 'app_store',
        'productId': SubscriptionProductIds.appStoreMonth,
        'source': 'purchased',
        'expiresAt': null,
      });

      expect(entitlement.active, isTrue);
      expect(entitlement.isExpired, isFalse);
      expect(entitlement.hasAccess, isFalse);
    });

    test('allows lifetime entitlement without expiry', () {
      final entitlement = SubscriptionEntitlement.fromJson(<String, dynamic>{
        'active': true,
        'store': 'app_store',
        'productId': SubscriptionProductIds.appStoreLife,
        'source': 'purchased',
        'expiresAt': null,
      });

      expect(entitlement.isLifetimeProduct, isTrue);
      expect(entitlement.hasAccess, isTrue);
    });

    test('parses inactive entitlement defaults', () {
      final entitlement = SubscriptionEntitlement.fromJson(<String, dynamic>{
        'active': false,
      });

      expect(entitlement.hasAccess, isFalse);
      expect(entitlement.store, SubscriptionStoreKind.unknown);
      expect(entitlement.source, SubscriptionEntitlementSource.unknown);
      expect(entitlement.productId, isNull);
    });
  });
}
