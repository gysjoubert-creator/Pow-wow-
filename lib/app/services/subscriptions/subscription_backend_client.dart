import 'dart:convert';

import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../firebase/auth_service.dart';
import 'subscription_diagnostic_log.dart';
import 'subscription_entitlement.dart';
import 'subscription_product_catalog.dart';
import 'subscription_product_config.dart';
import 'subscription_product_ids.dart';
import 'subscription_purchase.dart';

class SubscriptionBackendException implements Exception {
  final String message;
  final int? statusCode;
  final Object? details;

  const SubscriptionBackendException(
    this.message, {
    this.statusCode,
    this.details,
  });

  bool get isAuthError => statusCode == 401 || statusCode == 403;

  /// The backend already validated this receipt/transaction in a previous
  /// call. The client can complete the StoreKit transaction, but subscription
  /// access still requires a valid expiry in the entitlement model.
  bool get isAlreadyProcessed => statusCode == 409;

  bool get isTransientNetworkFailure {
    return statusCode == 502 || statusCode == 503 || statusCode == 504;
  }

  @override
  String toString() {
    return 'SubscriptionBackendException(statusCode: $statusCode, message: $message)';
  }
}

/// Client for the "receipt-validator" purchases API.
///
/// The service only exposes purchase validation endpoints (no
/// `GET entitlement/me`), so [SubscriptionService] treats every successful
/// validation call as the source of truth and caches the result locally.
class SubscriptionBackendClient {
  static const String defaultBaseUrl = String.fromEnvironment(
    'POWWOW_IAP_API_BASE_URL',
    defaultValue: 'https://receipt-validator-237694335752.us-central1.run.app',
  );

  SubscriptionBackendClient({
    String? baseUrl,
    http.Client? httpClient,
    Future<String?> Function()? getFirebaseIdToken,
  }) : _baseUrl = (baseUrl ?? defaultBaseUrl).trim(),
       _httpClient = httpClient ?? http.Client(),
       _getFirebaseIdToken = getFirebaseIdToken ?? _defaultFirebaseIdToken;

  final String _baseUrl;
  final http.Client _httpClient;
  final Future<String?> Function() _getFirebaseIdToken;

  bool get isConfigured => _baseUrl.isNotEmpty;

  /// Fetches the typed product catalog from the backend API.
  Future<SubscriptionProductCatalogResponse> fetchProductCatalog() async {
    final _ProductsApiPayload payload = await _fetchProductsPayload();
    final SubscriptionProductCatalogResponse? catalog =
        SubscriptionProductCatalogResponse.tryParse(payload.decoded);
    if (catalog == null) {
      throw const SubscriptionBackendException(
        'Subscription product catalog has an unsupported response format',
      );
    }
    if (!catalog.isSuccess) {
      throw SubscriptionBackendException(
        'Subscription product catalog returned status: ${catalog.status}',
      );
    }

    _logProductCatalog(catalog);
    return catalog;
  }

  /// Fetches store product IDs from the backend catalog API.
  ///
  /// Uses the typed catalog when available; falls back to a legacy best-effort
  /// parser for older/dev response shapes so local testing keeps working.
  Future<Set<String>> fetchProductIds(SubscriptionStoreKind store) async {
    final _ProductsApiPayload payload = await _fetchProductsPayload();

    final SubscriptionProductCatalogResponse? catalog =
        SubscriptionProductCatalogResponse.tryParse(payload.decoded);
    if (catalog != null && catalog.isSuccess) {
      _logProductCatalog(catalog, store: store);
      final Set<String> ids = catalog.productIdsFor(store);
      if (ids.isNotEmpty) return ids;
    }

    return _parseLegacyProductIds(payload.decoded, store);
  }

  Future<_ProductsApiPayload> _fetchProductsPayload() async {
    final http.Response response = await _send(
      method: 'GET',
      path: '/api/v1/purchases/products',
    );

    subscriptionDiagnosticFlow(
      'fetch_product_ids_response',
      data: <String, Object?>{
        'statusCode': response.statusCode,
        'body': response.body,
      },
    );

    return _ProductsApiPayload(
      body: response.body,
      decoded: _decodeJsonValue(response.body),
    );
  }

  void _logProductCatalog(
    SubscriptionProductCatalogResponse catalog, {
    SubscriptionStoreKind? store,
  }) {
    final List<SubscriptionCatalogEntry> entries = store == null
        ? <SubscriptionCatalogEntry>[
            ...catalog.data.ios,
            ...catalog.data.android,
          ]
        : catalog.entriesFor(store);

    subscriptionDiagnosticFlow(
      'product_catalog_loaded',
      data: <String, Object?>{
        if (store != null) 'store': store.apiValue,
        'status': catalog.status,
        'entryCount': entries.length,
        'productIds': entries
            .map((SubscriptionCatalogEntry e) => e.productId)
            .join(', '),
      },
    );
  }

  Future<SubscriptionEntitlement> verifyPurchase(
    SubscriptionPurchaseDetails purchase,
  ) async {
    final String path = _validationPath(purchase);
    final Map<String, dynamic> body = _validationBody(purchase);

    subscriptionDiagnosticFlow(
      'purchase_validation_request',
      data: <String, Object?>{
        'store': purchase.store.apiValue,
        'path': path,
        'body': jsonEncode(body),
        if (purchase.store == SubscriptionStoreKind.appStore)
          'iosEnvironment': _iosEnvironmentLabel(
            purchase.verificationData.serverVerificationData,
          ),
        if (purchase.store == SubscriptionStoreKind.appStore)
          'iosOwnershipType':
              _iosOwnershipType(
                purchase.verificationData.serverVerificationData,
              ) ??
              '',
      },
    );

    try {
      final http.Response response = await _send(
        method: 'POST',
        path: path,
        body: body,
      );

      subscriptionDiagnosticFlow(
        'purchase_validation_response',
        data: <String, Object?>{
          'store': purchase.store.apiValue,
          'path': path,
          'statusCode': response.statusCode,
          'body': response.body,
        },
      );

      final Map<String, dynamic> decodedResponse = _decodeJsonObject(
        response.body,
      );
      _logValidationResponseFields(decodedResponse);

      return SubscriptionEntitlement.fromValidationResponse(
        decodedResponse,
        store: purchase.store,
        fallbackProductId: purchase.productId,
        fallbackEnvironment: purchase.store == SubscriptionStoreKind.appStore
            ? _iosEnvironmentLabel(
                purchase.verificationData.serverVerificationData,
              )
            : null,
      );
    } on SubscriptionBackendException catch (error) {
      // 409 means the backend already validated this transaction in a prior
      // request. Surface a fallback entitlement so StoreKit can complete the
      // transaction; subscription access still requires expiresAt downstream.
      if (error.isAlreadyProcessed) {
        subscriptionDiagnosticFlow(
          'purchase_already_processed',
          data: <String, Object?>{
            'store': purchase.store.apiValue,
            'path': path,
            'productId': purchase.productId,
          },
        );
        return SubscriptionEntitlement(
          active: true,
          store: purchase.store,
          productId: purchase.productId,
          source: SubscriptionEntitlementSource.purchased,
          expiresAt: null,
          validatedAt: DateTime.now().toUtc(),
          willRenew: null,
          environment: purchase.store == SubscriptionStoreKind.appStore
              ? _iosEnvironmentLabel(
                  purchase.verificationData.serverVerificationData,
                )
              : null,
        );
      }

      subscriptionDiagnosticFlow(
        'purchase_validation_failed',
        data: <String, Object?>{
          'store': purchase.store.apiValue,
          'path': path,
          'body': jsonEncode(body),
          'statusCode': error.statusCode,
          'error': error.message,
          'responseBody': error.details?.toString(),
        },
      );
      rethrow;
    }
  }

  void _logValidationResponseFields(Map<String, dynamic> response) {
    final Object? nestedData = response['data'];
    final Map<String, dynamic> validationPayload =
        nestedData is Map<String, dynamic>
        ? <String, dynamic>{...response, ...nestedData}
        : response;
    final Map<String, Object?> data = <String, Object?>{
      ..._jsonKeyDiagnostics('topLevel', response),
      ..._validationFieldPresence(validationPayload),
      ..._validationFieldValues(validationPayload),
    };

    if (nestedData is Map<String, dynamic>) {
      data.addAll(_jsonKeyDiagnostics('data', nestedData));
    }

    subscriptionDiagnosticFlow(
      'purchase_validation_response_fields',
      data: data,
    );
  }

  Map<String, Object?> _jsonKeyDiagnostics(
    String prefix,
    Map<String, dynamic> json,
  ) {
    final Map<String, Object?> data = <String, Object?>{
      '${prefix}KeyCount': json.length,
    };
    final List<String> keys = json.keys.toList(growable: false);
    for (int index = 0; index < keys.length; index += 1) {
      data['${prefix}Key${(index + 1).toString().padLeft(2, '0')}'] =
          keys[index];
    }
    return data;
  }

  Map<String, Object?> _validationFieldPresence(Map<String, dynamic> json) {
    return <String, Object?>{
      'hasActive': json.containsKey('active'),
      'hasIsValid': json.containsKey('is_valid') || json.containsKey('valid'),
      'hasProductId':
          json.containsKey('productId') || json.containsKey('product_id'),
      'hasStore': json.containsKey('store'),
      'hasEnvironment': json.containsKey('environment'),
      'hasSource':
          json.containsKey('source') ||
          json.containsKey('entitlementSource') ||
          json.containsKey('entitlement_source'),
      'hasOwnershipType':
          json.containsKey('ownershipType') ||
          json.containsKey('ownership_type') ||
          json.containsKey('inAppOwnershipType') ||
          json.containsKey('in_app_ownership_type') ||
          json.containsKey('in_app_ownership'),
      'hasWillRenew':
          json.containsKey('willRenew') ||
          json.containsKey('will_renew') ||
          json.containsKey('auto_renew_status'),
      'hasValidatedAt':
          json.containsKey('validatedAt') ||
          json.containsKey('validated_at') ||
          json.containsKey('checkedAt') ||
          json.containsKey('checked_at'),
      'hasExpiresAt': json.containsKey('expiresAt'),
      'hasExpiresDateMs': json.containsKey('expires_date_ms'),
      'hasExpiryTimeMillis': json.containsKey('expiryTimeMillis'),
      'hasExpirationTimeMillis': json.containsKey('expiration_time_millis'),
    };
  }

  Map<String, Object?> _validationFieldValues(Map<String, dynamic> json) {
    return <String, Object?>{
      'active': _firstPresentValue(json, <String>['active']),
      'isValid': _firstPresentValue(json, <String>['is_valid', 'valid']),
      'productId': _firstPresentValue(json, <String>[
        'productId',
        'product_id',
      ]),
      'storeField': _firstPresentValue(json, <String>['store']),
      'environmentField': _firstPresentValue(json, <String>['environment']),
      'sourceField': _firstPresentValue(json, <String>[
        'source',
        'entitlementSource',
        'entitlement_source',
      ]),
      'ownershipType': _firstPresentValue(json, <String>[
        'ownershipType',
        'ownership_type',
        'inAppOwnershipType',
        'in_app_ownership_type',
        'in_app_ownership',
      ]),
      'willRenew': _firstPresentValue(json, <String>[
        'willRenew',
        'will_renew',
        'auto_renew_status',
      ]),
      'validatedAt': _firstPresentValue(json, <String>[
        'validatedAt',
        'validated_at',
        'checkedAt',
        'checked_at',
      ]),
      'expiresAt': _firstPresentValue(json, <String>[
        'expiresAt',
        'expires_date_ms',
        'expiryTimeMillis',
        'expiration_time_millis',
      ]),
    };
  }

  Object? _firstPresentValue(Map<String, dynamic> json, List<String> keys) {
    for (final String key in keys) {
      if (json.containsKey(key)) return json[key];
    }
    return null;
  }

  static String _iosEnvironmentLabel(String jws) {
    return _isIosProductionJws(jws) ? 'production' : 'sandbox';
  }

  String _validationPath(SubscriptionPurchaseDetails purchase) {
    return switch (purchase.store) {
      SubscriptionStoreKind.appStore =>
        _isIosProductionJws(purchase.verificationData.serverVerificationData)
            ? '/api/v1/purchases/validate/ios/production'
            : '/api/v1/purchases/validate/ios/sandbox',
      SubscriptionStoreKind.playStore => '/api/v1/purchases/validate/android',
      SubscriptionStoreKind.unknown => throw const SubscriptionBackendException(
        'Cannot validate a purchase from an unknown store',
      ),
    };
  }

  Map<String, dynamic> _validationBody(SubscriptionPurchaseDetails purchase) {
    return switch (purchase.store) {
      SubscriptionStoreKind.appStore => <String, dynamic>{
        'transaction_id': _resolveIosTransactionId(purchase),
      },
      SubscriptionStoreKind.playStore => <String, dynamic>{
        'package_name': SubscriptionProductIds.androidPackageName,
        'product_id': purchase.productId,
        'purchase_token': purchase.verificationData.serverVerificationData,
      },
      SubscriptionStoreKind.unknown => throw const SubscriptionBackendException(
        'Cannot validate a purchase from an unknown store',
      ),
    };
  }

  /// Resolves the Apple transaction ID to send to the backend.
  ///
  /// Prefers [SubscriptionPurchaseDetails.purchaseId] (StoreKit
  /// `transaction.id`). When that is null, falls back to extracting
  /// `transactionId` from the JWS payload so that edge-cases where
  /// `in_app_purchase` has not yet populated `purchaseId` are covered.
  String _resolveIosTransactionId(SubscriptionPurchaseDetails purchase) {
    final String? purchaseId = purchase.purchaseId;
    if (purchaseId != null && purchaseId.isNotEmpty) return purchaseId;

    final String? fromJws = _extractTransactionIdFromJws(
      purchase.verificationData.serverVerificationData,
    );
    if (fromJws != null && fromJws.isNotEmpty) return fromJws;

    throw const SubscriptionBackendException(
      'iOS purchase has no transaction ID and the JWS payload could not be decoded',
    );
  }

  /// Returns `true` when the JWS [serverVerificationData] carries
  /// `"environment": "Production"`, meaning the purchase came from the
  /// App Store (not sandbox / TestFlight).
  ///
  /// Defaults to `false` (sandbox) on any parse failure so we never
  /// accidentally route a non-production transaction to the production
  /// endpoint.
  static bool _isIosProductionJws(String jws) {
    try {
      final Map<String, dynamic>? payload = _decodeJwsPayload(jws);
      if (payload == null) return false;
      return payload['environment'] == 'Production';
    } catch (_) {
      return false;
    }
  }

  static String? _extractTransactionIdFromJws(String jws) {
    try {
      final Map<String, dynamic>? payload = _decodeJwsPayload(jws);
      return payload?['transactionId']?.toString();
    } catch (_) {
      return null;
    }
  }

  static String? _iosOwnershipType(String jws) {
    try {
      final Map<String, dynamic>? payload = _decodeJwsPayload(jws);
      return payload?['inAppOwnershipType']?.toString();
    } catch (_) {
      return null;
    }
  }

  /// Base64url-decodes the middle segment of a JWS/JWT string and JSON-parses
  /// it. Returns `null` when the string does not look like a JWS.
  static Map<String, dynamic>? _decodeJwsPayload(String jws) {
    final List<String> parts = jws.split('.');
    if (parts.length < 2) return null;

    // base64url → standard base64 with padding
    String b64 = parts[1].replaceAll('-', '+').replaceAll('_', '/');
    switch (b64.length % 4) {
      case 2:
        b64 += '==';
      case 3:
        b64 += '=';
    }

    final Object? decoded = jsonDecode(String.fromCharCodes(base64Decode(b64)));
    if (decoded is Map<String, dynamic>) return decoded;
    return null;
  }

  Future<http.Response> _send({
    required String method,
    required String path,
    Map<String, dynamic>? body,
  }) async {
    if (!isConfigured) {
      throw const SubscriptionBackendException(
        'Subscription backend URL is not configured',
      );
    }

    final String? authToken = await _getFirebaseIdToken();
    if (authToken == null || authToken.isEmpty) {
      throw const SubscriptionBackendException(
        'Subscription backend auth token is missing',
        statusCode: 401,
      );
    }

    final Uri uri = _buildUri(path);
    final Map<String, String> headers = <String, String>{
      'Authorization': authToken,
      'Content-Type': 'application/json',
    };

    final http.Response response = switch (method) {
      'GET' => await _httpClient.get(uri, headers: headers),
      'POST' => await _httpClient.post(
        uri,
        headers: headers,
        body: jsonEncode(body ?? <String, dynamic>{}),
      ),
      _ => throw StateError('Unsupported subscription backend method: $method'),
    };

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SubscriptionBackendException(
        _extractErrorMessage(response.body) ?? 'Subscription backend failed',
        statusCode: response.statusCode,
        details: response.body,
      );
    }

    return response;
  }

  Uri _buildUri(String path) {
    return Uri.parse('${_baseUrl.replaceAll(RegExp(r'/+$'), '')}$path');
  }

  Map<String, dynamic> _decodeJsonObject(String responseBody) {
    final Object? decoded = _decodeJsonValue(responseBody);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }

    throw const SubscriptionBackendException(
      'Subscription backend returned invalid response format',
    );
  }

  Object? _decodeJsonValue(String responseBody) {
    return jsonDecode(responseBody) as Object?;
  }

  /// Legacy best-effort extraction of product IDs from non-catalog payloads.
  Set<String> _parseLegacyProductIds(
    Object? decoded,
    SubscriptionStoreKind store,
  ) {
    if (decoded == null) return const <String>{};

    if (decoded is Map<String, dynamic>) {
      // Shape: {"status":"success","data":{"ios":[...],"android":[...]}}
      final Object? data = decoded['data'];
      if (data is Map<String, dynamic>) {
        final Set<String> fromData = _parseLegacyProductIds(data, store);
        if (fromData.isNotEmpty) return fromData;
      }

      // Shape: {"products": [...], ...}
      final Object? products = decoded['products'];
      if (products is List) {
        return _extractIdsFromList(products, store);
      }

      // Shape: {"ios": [...], "android": [...]}  or  {"app_store": [...], ...}
      final List<String> storeKeys = _storeKeys(store);
      for (final String key in storeKeys) {
        final Object? storeList = decoded[key];
        if (storeList is List) {
          return _extractIdsFromList(storeList, store, ignoreStoreField: true);
        }
      }

      return const <String>{};
    }

    // Shape: top-level array
    if (decoded is List) {
      return _extractIdsFromList(decoded, store);
    }

    return const <String>{};
  }

  /// Extracts product ID strings from a JSON array.
  ///
  /// Each element may be:
  /// - a plain [String] — included as-is (filtered by [store] only when an
  ///   explicit `store` field is present in the surrounding object context);
  /// - a [Map] with a `product_id`/`id` field and an optional `store` field.
  ///
  /// Set [ignoreStoreField] to `true` when the outer key already identifies the
  /// store (e.g. the array came from a `{"ios": [...]}` object).
  Set<String> _extractIdsFromList(
    List<Object?> items,
    SubscriptionStoreKind store, {
    bool ignoreStoreField = false,
  }) {
    final Set<String> result = <String>{};

    for (final Object? item in items) {
      if (item is String) {
        final String trimmed = item.trim();
        if (trimmed.isNotEmpty) result.add(trimmed);
        continue;
      }

      if (item is Map) {
        final String? id =
            _parseString(item['product_id']) ?? _parseString(item['id']);
        if (id == null) continue;

        if (!ignoreStoreField) {
          final Object? storeField = item['store'] ?? item['platform'];
          if (storeField != null) {
            final SubscriptionStoreKind itemStore =
                SubscriptionStoreKind.fromValue(storeField);
            if (itemStore != store &&
                itemStore != SubscriptionStoreKind.unknown) {
              continue;
            }
          }
        }

        result.add(id);
      }
    }

    return result;
  }

  static List<String> _storeKeys(SubscriptionStoreKind store) {
    return switch (store) {
      SubscriptionStoreKind.appStore => const <String>[
        'ios',
        'app_store',
        'appStore',
        'apple',
      ],
      SubscriptionStoreKind.playStore => const <String>[
        'android',
        'play_store',
        'playStore',
        'google_play',
      ],
      SubscriptionStoreKind.unknown => const <String>[],
    };
  }

  static String? _parseString(Object? value) {
    final String normalized = value?.toString().trim() ?? '';
    return normalized.isEmpty ? null : normalized;
  }

  /// Handles both FastAPI error shapes seen from the live service:
  /// `{"detail":"Invalid token"}` and
  /// `{"detail":[{"loc":[...],"msg":"..."}]}` (422 validation errors).
  String? _extractErrorMessage(String responseBody) {
    if (responseBody.trim().isEmpty) return null;

    try {
      final Object? decoded = jsonDecode(responseBody) as Object?;
      if (decoded is Map<String, dynamic>) {
        final Object? detail = decoded['detail'] ?? decoded['message'];
        if (detail is String && detail.trim().isNotEmpty) {
          return detail.trim();
        }
        if (detail is List) {
          final String combined = detail
              .whereType<Map>()
              .map((Map item) => item['msg'])
              .whereType<String>()
              .map((String msg) => msg.trim())
              .where((String msg) => msg.isNotEmpty)
              .join('; ');
          if (combined.isNotEmpty) {
            return combined;
          }
        }
      }
    } catch (_) {
      // Keep the raw body fallback below when the response is not JSON.
    }

    return responseBody.trim();
  }

  static Future<String?> _defaultFirebaseIdToken() async {
    if (Get.isRegistered<AuthService>()) {
      return Get.find<AuthService>().getFirebaseIdToken();
    }
    return null;
  }
}

class _ProductsApiPayload {
  const _ProductsApiPayload({required this.body, required this.decoded});

  final String body;
  final Object? decoded;
}
