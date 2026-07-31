import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_backend_client.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_entitlement.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_product_config.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_product_ids.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_purchase.dart';

/// Builds a minimal 3-part JWS string with a JSON payload.
///
/// The signature segment is intentionally fake — the backend client only reads
/// the payload, never verifies the signature in tests.
String _fakeJws(Map<String, dynamic> payload) {
  String b64url(Object json) {
    return base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  }

  final header = b64url(<String, dynamic>{'alg': 'ES256'});
  final body = b64url(payload);
  return '$header.$body.fakesignature';
}

String _sandboxJws({String transactionId = 'sk2_tx_sandbox'}) => _fakeJws(
  <String, dynamic>{'environment': 'Sandbox', 'transactionId': transactionId},
);

String _productionJws({String transactionId = 'sk2_tx_prod'}) =>
    _fakeJws(<String, dynamic>{
      'environment': 'Production',
      'transactionId': transactionId,
    });

SubscriptionPurchaseDetails _purchase({
  SubscriptionStoreKind store = SubscriptionStoreKind.appStore,
  String productId = 'powwow_monthly',
  String serverVerificationData = 'server-data',
  String? purchaseId = 'tx_123',
}) {
  return SubscriptionPurchaseDetails(
    store: store,
    productId: productId,
    purchaseId: purchaseId,
    transactionDate: '2026-06-19T12:00:00Z',
    status: SubscriptionPurchaseStatus.purchased,
    verificationData: SubscriptionVerificationData(
      source: store.apiValue,
      localVerificationData: 'local-data',
      serverVerificationData: serverVerificationData,
    ),
    pendingCompletePurchase: true,
  );
}

void main() {
  group('SubscriptionBackendClient', () {
    test(
      'validates a sandbox App Store purchase against /validate/ios/sandbox',
      () async {
        final client = SubscriptionBackendClient(
          baseUrl: 'https://subscriptions.test/',
          getFirebaseIdToken: () async => 'firebase-token',
          httpClient: MockClient((http.Request request) async {
            expect(
              request.url.toString(),
              'https://subscriptions.test/api/v1/purchases/validate/ios/sandbox',
            );
            expect(request.headers['Authorization'], 'firebase-token');
            expect(request.body, '{"transaction_id":"tx_123"}');
            return http.Response(
              '{"active":true,"expiresAt":"2027-01-01T00:00:00Z"}',
              200,
            );
          }),
        );

        final SubscriptionEntitlement entitlement = await client.verifyPurchase(
          _purchase(serverVerificationData: _sandboxJws()),
        );

        expect(entitlement.hasAccess, isTrue);
        expect(entitlement.productId, 'powwow_monthly');
        expect(entitlement.validatedAt, isNotNull);
        expect(entitlement.environment, 'sandbox');
      },
    );

    test('routes production JWS to /validate/ios/production', () async {
      final client = SubscriptionBackendClient(
        baseUrl: 'https://subscriptions.test',
        getFirebaseIdToken: () async => 'firebase-token',
        httpClient: MockClient((http.Request request) async {
          expect(
            request.url.toString(),
            'https://subscriptions.test/api/v1/purchases/validate/ios/production',
          );
          expect(request.body, '{"transaction_id":"tx_123"}');
          return http.Response('{"active":true}', 200);
        }),
      );

      await client.verifyPurchase(
        _purchase(serverVerificationData: _productionJws()),
      );
    });

    test(
      'non-JWS serverVerificationData defaults to sandbox endpoint',
      () async {
        final client = SubscriptionBackendClient(
          baseUrl: 'https://subscriptions.test',
          getFirebaseIdToken: () async => 'firebase-token',
          httpClient: MockClient((http.Request request) async {
            expect(
              request.url.toString(),
              'https://subscriptions.test/api/v1/purchases/validate/ios/sandbox',
            );
            return http.Response('{"active":true}', 200);
          }),
        );

        await client.verifyPurchase(
          _purchase(serverVerificationData: 'not-a-jws'),
        );
      },
    );

    test('falls back to JWS transactionId when purchaseId is null', () async {
      const String jwsTransactionId = 'jws_extracted_tx';
      final client = SubscriptionBackendClient(
        baseUrl: 'https://subscriptions.test',
        getFirebaseIdToken: () async => 'firebase-token',
        httpClient: MockClient((http.Request request) async {
          expect(request.body, '{"transaction_id":"$jwsTransactionId"}');
          return http.Response('{"active":true}', 200);
        }),
      );

      await client.verifyPurchase(
        _purchase(
          purchaseId: null,
          serverVerificationData: _sandboxJws(transactionId: jwsTransactionId),
        ),
      );
    });

    test('validates a Play Store purchase against /validate/android', () async {
      final client = SubscriptionBackendClient(
        baseUrl: 'https://subscriptions.test',
        getFirebaseIdToken: () async => 'firebase-token',
        httpClient: MockClient((http.Request request) async {
          expect(
            request.url.toString(),
            'https://subscriptions.test/api/v1/purchases/validate/android',
          );
          expect(
            request.body,
            '{"package_name":"${SubscriptionProductIds.androidPackageName}",'
            '"product_id":"powwow_monthly","purchase_token":"token-abc"}',
          );
          return http.Response('{"active":true}', 200);
        }),
      );

      await client.verifyPurchase(
        _purchase(
          store: SubscriptionStoreKind.playStore,
          serverVerificationData: 'token-abc',
        ),
      );
    });

    test('throws for an unknown store kind without a network call', () async {
      final client = SubscriptionBackendClient(
        baseUrl: 'https://subscriptions.test',
        getFirebaseIdToken: () async => 'firebase-token',
        httpClient: MockClient((http.Request request) async {
          fail('HTTP request should not be sent');
        }),
      );

      expect(
        () => client.verifyPurchase(
          _purchase(store: SubscriptionStoreKind.unknown),
        ),
        throwsA(isA<SubscriptionBackendException>()),
      );
    });

    group('best-effort response parsing', () {
      test(
        'keeps HTTP 200 with no explicit fields active but without access',
        () async {
          final client = SubscriptionBackendClient(
            baseUrl: 'https://subscriptions.test',
            getFirebaseIdToken: () async => 'firebase-token',
            httpClient: MockClient((http.Request request) async {
              return http.Response('{}', 200);
            }),
          );

          final entitlement = await client.verifyPurchase(_purchase());

          expect(entitlement.active, isTrue);
          expect(entitlement.hasAccess, isFalse);
          expect(entitlement.productId, 'powwow_monthly');
          expect(entitlement.validatedAt, isNotNull);
        },
      );

      test('reads backend validation timestamp when present', () async {
        final client = SubscriptionBackendClient(
          baseUrl: 'https://subscriptions.test',
          getFirebaseIdToken: () async => 'firebase-token',
          httpClient: MockClient((http.Request request) async {
            return http.Response(
              '{"active":true,"validated_at":"2026-07-01T12:00:00Z"}',
              200,
            );
          }),
        );

        final entitlement = await client.verifyPurchase(_purchase());

        expect(entitlement.validatedAt, DateTime.utc(2026, 7, 1, 12));
      });

      test('honors an explicit active:false flag', () async {
        final client = SubscriptionBackendClient(
          baseUrl: 'https://subscriptions.test',
          getFirebaseIdToken: () async => 'firebase-token',
          httpClient: MockClient((http.Request request) async {
            return http.Response('{"active":false}', 200);
          }),
        );

        final entitlement = await client.verifyPurchase(_purchase());

        expect(entitlement.active, isFalse);
      });

      test('honors an explicit status:1 flag as invalid', () async {
        final client = SubscriptionBackendClient(
          baseUrl: 'https://subscriptions.test',
          getFirebaseIdToken: () async => 'firebase-token',
          httpClient: MockClient((http.Request request) async {
            return http.Response('{"status":1}', 200);
          }),
        );

        final entitlement = await client.verifyPurchase(_purchase());

        expect(entitlement.active, isFalse);
      });

      test('reads several alternative expiry date key names', () async {
        final Map<String, String> responsesByKey = <String, String>{
          'expiresAt': '{"expiresAt":"2027-01-01T00:00:00Z"}',
          'expires_date_ms': '{"expires_date_ms":"1798761600000"}',
          'expiryTimeMillis': '{"expiryTimeMillis":1798761600000}',
          'expiration_time_millis': '{"expiration_time_millis":1798761600000}',
        };

        for (final MapEntry<String, String> entry in responsesByKey.entries) {
          final client = SubscriptionBackendClient(
            baseUrl: 'https://subscriptions.test',
            getFirebaseIdToken: () async => 'firebase-token',
            httpClient: MockClient((http.Request request) async {
              return http.Response(entry.value, 200);
            }),
          );

          final entitlement = await client.verifyPurchase(_purchase());

          expect(
            entitlement.expiresAt,
            isNotNull,
            reason: 'expected ${entry.key} to be parsed',
          );
        }
      });
    });

    test('maps backend errors with status code helpers', () async {
      final client = SubscriptionBackendClient(
        baseUrl: 'https://subscriptions.test',
        getFirebaseIdToken: () async => 'firebase-token',
        httpClient: MockClient((http.Request request) async {
          return http.Response('{"detail":"Service unavailable"}', 503);
        }),
      );

      expect(
        () => client.verifyPurchase(_purchase()),
        throwsA(
          isA<SubscriptionBackendException>()
              .having((error) => error.statusCode, 'statusCode', 503)
              .having(
                (error) => error.message,
                'message',
                'Service unavailable',
              )
              .having(
                (error) => error.isTransientNetworkFailure,
                'isTransientNetworkFailure',
                isTrue,
              ),
        ),
      );
    });

    test(
      '409 already-processed without expiry does not grant subscription access',
      () async {
        final client = SubscriptionBackendClient(
          baseUrl: 'https://subscriptions.test',
          getFirebaseIdToken: () async => 'firebase-token',
          httpClient: MockClient((http.Request request) async {
            return http.Response('{"detail":"Receipt already processed"}', 409);
          }),
        );

        final entitlement = await client.verifyPurchase(
          _purchase(productId: 'com.gys.powwow.month'),
        );

        expect(entitlement.active, isTrue);
        expect(entitlement.productId, 'com.gys.powwow.month');
        expect(entitlement.hasAccess, isFalse);
        expect(entitlement.validatedAt, isNotNull);
      },
    );

    test('combines FastAPI 422 validation error messages', () async {
      final client = SubscriptionBackendClient(
        baseUrl: 'https://subscriptions.test',
        getFirebaseIdToken: () async => 'firebase-token',
        httpClient: MockClient((http.Request request) async {
          return http.Response(
            '{"detail":[{"loc":["body","receipt_data"],"msg":"Field required"}]}',
            422,
          );
        }),
      );

      expect(
        () => client.verifyPurchase(_purchase()),
        throwsA(
          isA<SubscriptionBackendException>().having(
            (error) => error.message,
            'message',
            'Field required',
          ),
        ),
      );
    });

    test('fails before request when backend URL is missing', () async {
      final client = SubscriptionBackendClient(
        baseUrl: '',
        getFirebaseIdToken: () async => 'firebase-token',
        httpClient: MockClient((http.Request request) async {
          fail('HTTP request should not be sent');
        }),
      );

      expect(
        () => client.verifyPurchase(_purchase()),
        throwsA(
          isA<SubscriptionBackendException>().having(
            (error) => error.message,
            'message',
            'Subscription backend URL is not configured',
          ),
        ),
      );
    });
  });

  group('fetchProductIds', () {
    SubscriptionBackendClient makeClient(
      String responseBody, {
      int status = 200,
    }) {
      return SubscriptionBackendClient(
        baseUrl: 'https://subscriptions.test',
        getFirebaseIdToken: () async => 'firebase-token',
        httpClient: MockClient((http.Request request) async {
          expect(
            request.url.toString(),
            'https://subscriptions.test/api/v1/purchases/products',
          );
          expect(request.method, 'GET');
          expect(request.headers['Authorization'], 'firebase-token');
          return http.Response(responseBody, status);
        }),
      );
    }

    test('parses a top-level array of strings', () async {
      final client = makeClient(
        '["com.gys.powwow.month","com.gys.powwow.year"]',
      );

      final ids = await client.fetchProductIds(SubscriptionStoreKind.appStore);

      expect(
        ids,
        containsAll(<String>['com.gys.powwow.month', 'com.gys.powwow.year']),
      );
      expect(ids.length, 2);
    });

    test('parses a top-level array of objects with product_id', () async {
      final client = makeClient(
        '[{"product_id":"com.gys.powwow.month"},{"product_id":"com.gys.powwow.year"}]',
      );

      final ids = await client.fetchProductIds(SubscriptionStoreKind.appStore);

      expect(
        ids,
        containsAll(<String>['com.gys.powwow.month', 'com.gys.powwow.year']),
      );
    });

    test('filters objects by store field', () async {
      final client = makeClient(
        '[{"product_id":"com.gys.powwow.month","store":"app_store"},'
        '{"product_id":"com.gys.powwow.subscription","store":"play_store"}]',
      );

      final iosIds = await client.fetchProductIds(
        SubscriptionStoreKind.appStore,
      );
      expect(iosIds, equals(<String>{'com.gys.powwow.month'}));
    });

    test(
      'includes objects without a store field regardless of requested store',
      () async {
        final client = makeClient(
          '[{"product_id":"com.gys.powwow.month"},'
          '{"product_id":"com.gys.powwow.subscription","store":"play_store"}]',
        );

        final iosIds = await client.fetchProductIds(
          SubscriptionStoreKind.appStore,
        );
        expect(iosIds, contains('com.gys.powwow.month'));
        expect(iosIds, isNot(contains('com.gys.powwow.subscription')));
      },
    );

    test('parses {"products": [...]} wrapper', () async {
      final client = makeClient(
        '{"products":["com.gys.powwow.month","com.gys.powwow.year"]}',
      );

      final ids = await client.fetchProductIds(SubscriptionStoreKind.appStore);

      expect(
        ids,
        containsAll(<String>['com.gys.powwow.month', 'com.gys.powwow.year']),
      );
    });

    test('parses {"ios": [...], "android": [...]} shape for iOS', () async {
      final client = makeClient(
        '{"ios":["com.gys.powwow.month","com.gys.powwow.year"],'
        '"android":["com.gys.powwow.subscription"]}',
      );

      final iosIds = await client.fetchProductIds(
        SubscriptionStoreKind.appStore,
      );
      expect(
        iosIds,
        containsAll(<String>['com.gys.powwow.month', 'com.gys.powwow.year']),
      );
      expect(iosIds, isNot(contains('com.gys.powwow.subscription')));
    });

    test('parses {"ios": [...], "android": [...]} shape for Android', () async {
      final client = makeClient(
        '{"ios":["com.gys.powwow.month"],'
        '"android":["com.gys.powwow.subscription","com.gys.powwow.one.time"]}',
      );

      final androidIds = await client.fetchProductIds(
        SubscriptionStoreKind.playStore,
      );
      expect(
        androidIds,
        containsAll(<String>[
          'com.gys.powwow.subscription',
          'com.gys.powwow.one.time',
        ]),
      );
      expect(androidIds, isNot(contains('com.gys.powwow.month')));
    });

    test(
      'parses live API shape {"status":"success","data":{"ios":[...]}}',
      () async {
        final client = makeClient(
          '{"status":"success","data":{"ios":['
          '{"product_id":"com.gys.powwow.year","type":"subscription"},'
          '{"product_id":"com.gys.powwow.month","type":"subscription"},'
          '{"product_id":"com.gys.powwow.week","type":"subscription"},'
          '{"product_id":"com.gys.powwow.life","type":"non-consumable"}'
          '],"android":[{"product_id":"com.gys.powwow.subscription"}]}}',
        );

        final iosIds = await client.fetchProductIds(
          SubscriptionStoreKind.appStore,
        );

        expect(
          iosIds,
          equals(<String>{
            'com.gys.powwow.year',
            'com.gys.powwow.month',
            'com.gys.powwow.week',
            'com.gys.powwow.life',
          }),
        );
      },
    );

    test('parses live API shape for Android inside data wrapper', () async {
      final client = makeClient(
        '{"status":"success","data":{"ios":[{"product_id":"com.gys.powwow.month"}],'
        '"android":[{"product_id":"com.gys.powwow.subscription"},'
        '{"product_id":"com.gys.powwow.one.time"}]}}',
      );

      final androidIds = await client.fetchProductIds(
        SubscriptionStoreKind.playStore,
      );

      expect(
        androidIds,
        equals(<String>{
          'com.gys.powwow.subscription',
          'com.gys.powwow.one.time',
        }),
      );
    });

    test('returns empty set for an empty object response', () async {
      final client = makeClient('{}');

      final ids = await client.fetchProductIds(SubscriptionStoreKind.appStore);

      expect(ids, isEmpty);
    });

    test('returns empty set for an empty array response', () async {
      final client = makeClient('[]');

      final ids = await client.fetchProductIds(SubscriptionStoreKind.appStore);

      expect(ids, isEmpty);
    });

    test('throws SubscriptionBackendException on 401', () async {
      final client = makeClient('{"detail":"Invalid token"}', status: 401);

      expect(
        () => client.fetchProductIds(SubscriptionStoreKind.appStore),
        throwsA(
          isA<SubscriptionBackendException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.isAuthError, 'isAuthError', isTrue),
        ),
      );
    });
  });

  group('fetchProductCatalog', () {
    const String liveBody =
        '{"status":"success","data":{"ios":['
        '{"product_id":"com.gys.powwow.year","type":"subscription","duration":"1 year"},'
        '{"product_id":"com.gys.powwow.life","type":"non-consumable","duration":"lifelong"}'
        '],"android":[{"product_id":"com.gys.powwow.subscription","base_plan":"year","type":"subscription","duration":"1 year"}]}}';

    SubscriptionBackendClient makeClient(
      String responseBody, {
      int status = 200,
    }) {
      return SubscriptionBackendClient(
        baseUrl: 'https://subscriptions.test',
        getFirebaseIdToken: () async => 'firebase-token',
        httpClient: MockClient((http.Request request) async {
          return http.Response(responseBody, status);
        }),
      );
    }

    test('returns typed catalog for the live API payload', () async {
      final client = makeClient(liveBody);

      final catalog = await client.fetchProductCatalog();

      expect(catalog.isSuccess, isTrue);
      expect(catalog.data.ios, hasLength(2));
      expect(catalog.data.ios.first.duration, '1 year');
      expect(catalog.data.android.single.basePlan, 'year');
    });

    test('throws for unsupported legacy payloads', () async {
      final client = makeClient('["com.gys.powwow.month"]');

      expect(
        () => client.fetchProductCatalog(),
        throwsA(isA<SubscriptionBackendException>()),
      );
    });
  });
}
