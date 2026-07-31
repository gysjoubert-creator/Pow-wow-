import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_product_catalog.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_product_config.dart';

void main() {
  group('SubscriptionProductCatalogResponse', () {
    const String liveJson = '''
{
  "status": "success",
  "data": {
    "ios": [
      {"product_id": "com.gys.powwow.year", "type": "subscription", "duration": "1 year"},
      {"product_id": "com.gys.powwow.month", "type": "subscription", "duration": "1 month"},
      {"product_id": "com.gys.powwow.week", "type": "subscription", "duration": "1 week"},
      {"product_id": "com.gys.powwow.life", "type": "non-consumable", "duration": "lifelong"}
  ],
    "android": [
      {"product_id": "com.gys.powwow.subscription", "base_plan": "year", "type": "subscription", "duration": "1 year"},
      {"product_id": "com.gys.powwow.subscription", "base_plan": "monthly", "type": "subscription", "duration": "1 month"},
      {"product_id": "com.gys.powwow.subscription", "base_plan": "weekly", "type": "subscription", "duration": "1 week"},
      {"product_id": "com.gys.powwow.one.time", "base_plan": null, "type": "non-consumable", "duration": "lifelong"}
    ]
  }
}
''';

    test('parses the live API payload', () {
      final catalog = SubscriptionProductCatalogResponse.tryParse(
        jsonDecode(liveJson) as Object?,
      )!;

      expect(catalog.isSuccess, isTrue);
      expect(catalog.data.ios, hasLength(4));
      expect(catalog.data.android, hasLength(4));
      expect(
        catalog.data.ios.first.productId,
        'com.gys.powwow.year',
      );
      expect(
        catalog.data.ios.last.type,
        SubscriptionCatalogProductType.nonConsumable,
      );
      expect(catalog.data.android.first.basePlan, 'year');
    });

    test('productIdsFor deduplicates Android subscription product IDs', () {
      final catalog = SubscriptionProductCatalogResponse.tryParse(
        jsonDecode(liveJson) as Object?,
      )!;

      expect(
        catalog.productIdsFor(SubscriptionStoreKind.playStore),
        equals(<String>{
          'com.gys.powwow.subscription',
          'com.gys.powwow.one.time',
        }),
      );
    });

    test('entriesFor preserves every Android base plan row', () {
      final catalog = SubscriptionProductCatalogResponse.tryParse(
        jsonDecode(liveJson) as Object?,
      )!;

      final entries = catalog.entriesFor(SubscriptionStoreKind.playStore);

      expect(entries, hasLength(4));
      expect(entries.map((e) => e.catalogKey), <String>[
        'com.gys.powwow.subscription:year',
        'com.gys.powwow.subscription:monthly',
        'com.gys.powwow.subscription:weekly',
        'com.gys.powwow.one.time',
      ]);
    });

    test('planLabel maps duration and base_plan', () {
      final catalog = SubscriptionProductCatalogResponse.tryParse(
        jsonDecode(liveJson) as Object?,
      )!;

      expect(catalog.data.ios[0].planLabel, 'Yearly');
      expect(catalog.data.ios[2].planLabel, 'Weekly');
      expect(catalog.data.ios[3].planLabel, 'Lifetime');
      expect(catalog.data.android[1].planLabel, 'Monthly');
    });

    test('tryParse returns null for legacy payloads', () {
      expect(
        SubscriptionProductCatalogResponse.tryParse(<String>['id']),
        isNull,
      );
      expect(
        SubscriptionProductCatalogResponse.tryParse(<String, dynamic>{}),
        isNull,
      );
    });
  });
}
