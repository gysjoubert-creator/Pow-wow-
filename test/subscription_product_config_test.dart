import 'package:flutter_test/flutter_test.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_product_config.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_product_ids.dart';

void main() {
  group('SubscriptionProductIds', () {
    test('contains App Store product IDs', () {
      expect(SubscriptionProductIds.appStore, <String>{
        'com.gys.powwow.year',
        'com.gys.powwow.month',
        'com.gys.powwow.week',
        'com.gys.powwow.life',
      });
    });

    test('contains Google Play product IDs', () {
      expect(SubscriptionProductIds.playStore, <String>{
        'com.gys.powwow.subscription',
        'com.gys.powwow.one.time',
      });
    });
  });

  group('SubscriptionProductConfig', () {
    test('parseProductIds splits comma-separated values', () {
      expect(
        SubscriptionProductConfig.parseProductIds(
          ' com.gys.powwow.year , com.gys.powwow.month ',
        ),
        <String>{'com.gys.powwow.year', 'com.gys.powwow.month'},
      );
    });

    test('parseProductIds returns an empty set for blank values', () {
      expect(SubscriptionProductConfig.parseProductIds(' , , '), isEmpty);
    });
  });
}
