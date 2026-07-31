import 'subscription_product_config.dart';
import 'subscription_product_ids.dart';

enum SubscriptionEntitlementSource {
  purchased('purchased'),
  familyShared('family_shared'),
  unknown('unknown');

  const SubscriptionEntitlementSource(this.apiValue);

  final String apiValue;

  static SubscriptionEntitlementSource fromValue(Object? value) {
    final String normalized = value?.toString().trim().toLowerCase() ?? '';
    return switch (normalized) {
      'purchased' || 'purchase' => purchased,
      'family_shared' ||
      'familyshared' ||
      'family_shared_purchase' ||
      'familysharedpurchase' ||
      'familysharedtransaction' ||
      'family_shared_transaction' ||
      'family' => familyShared,
      _ => unknown,
    };
  }
}

class SubscriptionEntitlement {
  final bool active;
  final SubscriptionStoreKind store;
  final String? productId;
  final SubscriptionEntitlementSource source;
  final DateTime? expiresAt;
  final DateTime? validatedAt;
  final bool? willRenew;
  final String? environment;

  const SubscriptionEntitlement({
    required this.active,
    required this.store,
    required this.productId,
    required this.source,
    required this.expiresAt,
    required this.validatedAt,
    required this.willRenew,
    required this.environment,
  });

  factory SubscriptionEntitlement.inactive() {
    return const SubscriptionEntitlement(
      active: false,
      store: SubscriptionStoreKind.unknown,
      productId: null,
      source: SubscriptionEntitlementSource.unknown,
      expiresAt: null,
      validatedAt: null,
      willRenew: null,
      environment: null,
    );
  }

  factory SubscriptionEntitlement.fromJson(Map<String, dynamic> json) {
    return SubscriptionEntitlement(
      active: json['active'] == true,
      store: SubscriptionStoreKind.fromValue(json['store']),
      productId: _parseString(json['productId']),
      source: SubscriptionEntitlementSource.fromValue(json['source']),
      expiresAt: _parseDate(json['expiresAt']),
      validatedAt: _parseDate(json['validatedAt']),
      willRenew: _parseBool(json['willRenew']),
      environment: _parseString(json['environment']),
    );
  }

  /// Parses a receipt-validator response body.
  ///
  /// Backend responses now include `expiresAt` for subscriptions. A missing
  /// expiry grants access only for lifetime / one-time products.
  factory SubscriptionEntitlement.fromValidationResponse(
    Map<String, dynamic> json, {
    required SubscriptionStoreKind store,
    required String fallbackProductId,
    String? fallbackEnvironment,
    DateTime? validatedAt,
  }) {
    final Map<String, dynamic> payload = _validationPayload(json);
    final bool? explicitActive = _parseValidationActive(payload);
    final String productId =
        _parseString(payload['productId']) ??
        _parseString(payload['product_id']) ??
        fallbackProductId;
    final bool? willRenew =
        _parseBool(payload['willRenew']) ??
        _parseBool(payload['will_renew']) ??
        _parseAutoRenewStatus(payload['auto_renew_status']);
    final SubscriptionEntitlementSource source =
        _parseValidationSource(payload) ??
        SubscriptionEntitlementSource.purchased;

    return SubscriptionEntitlement(
      active: explicitActive ?? true,
      store: store,
      productId: productId,
      source: source,
      expiresAt: _parseValidationExpiresAt(payload),
      validatedAt:
          _parseValidationValidatedAt(payload) ??
          validatedAt?.toUtc() ??
          DateTime.now().toUtc(),
      willRenew: willRenew,
      environment: _parseString(payload['environment']) ?? fallbackEnvironment,
    );
  }

  bool get isExpired {
    final DateTime? expiry = expiresAt;
    if (expiry == null) return false;

    return !expiry.isAfter(DateTime.now().toUtc());
  }

  bool get hasAccess {
    if (!active || isExpired) return false;
    return expiresAt != null || isLifetimeProduct;
  }

  bool get isLifetimeProduct {
    return productId == SubscriptionProductIds.appStoreLife ||
        productId == SubscriptionProductIds.playOneTime ||
        productId == 'powwow_lifetime' ||
        productId == 'powwow_life';
  }

  bool get isFamilyShared {
    return source == SubscriptionEntitlementSource.familyShared;
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'active': active,
      'store': store.apiValue,
      'productId': productId,
      'source': source.apiValue,
      'expiresAt': expiresAt?.toIso8601String(),
      'validatedAt': validatedAt?.toIso8601String(),
      'willRenew': willRenew,
      'environment': environment,
    };
  }

  static String? _parseString(Object? value) {
    final String normalized = value?.toString().trim() ?? '';
    return normalized.isEmpty ? null : normalized;
  }

  static Map<String, dynamic> _validationPayload(Map<String, dynamic> json) {
    final Object? data = json['data'];
    if (data is Map<String, dynamic>) {
      return <String, dynamic>{...json, ...data};
    }
    return json;
  }

  static bool? _parseBool(Object? value) {
    if (value is bool) return value;
    if (value is String) {
      final String normalized = value.trim().toLowerCase();
      if (normalized == 'true') return true;
      if (normalized == 'false') return false;
    }
    return null;
  }

  static SubscriptionEntitlementSource? _parseValidationSource(
    Map<String, dynamic> json,
  ) {
    const List<String> sourceKeys = <String>[
      'source',
      'entitlementSource',
      'entitlement_source',
      'ownershipType',
      'ownership_type',
      'inAppOwnershipType',
      'in_app_ownership_type',
      'in_app_ownership',
    ];

    for (final String key in sourceKeys) {
      final SubscriptionEntitlementSource source =
          SubscriptionEntitlementSource.fromValue(json[key]);
      if (source != SubscriptionEntitlementSource.unknown) return source;
    }
    return null;
  }

  static DateTime? _parseDate(Object? value) {
    if (value is DateTime) return value.toUtc();
    if (value is int) {
      final bool looksLikeMilliseconds = value > 1000000000000;
      final int milliseconds = looksLikeMilliseconds ? value : value * 1000;
      return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
    }
    if (value is String) {
      final String normalized = value.trim();
      if (normalized.isEmpty) return null;

      final int? asMilliseconds = int.tryParse(normalized);
      if (asMilliseconds != null) {
        return _parseDate(asMilliseconds);
      }

      final DateTime? parsed = DateTime.tryParse(normalized);
      return parsed?.toUtc();
    }
    return null;
  }

  static bool? _parseValidationActive(Map<String, dynamic> json) {
    final Object? active = json['active'];
    if (active is bool) return active;

    final Object? isValid = json['is_valid'] ?? json['valid'];
    if (isValid is bool) return isValid;

    final Object? status = json['status'];
    if (status is int) return status == 0;
    if (status is String) {
      final int? parsedStatus = int.tryParse(status.trim());
      if (parsedStatus != null) return parsedStatus == 0;
    }

    return null;
  }

  static DateTime? _parseValidationExpiresAt(Map<String, dynamic> json) {
    const List<String> expiryKeys = <String>[
      'expiresAt',
      'expires_date_ms',
      'expiryTimeMillis',
      'expiration_time_millis',
    ];

    for (final String key in expiryKeys) {
      final DateTime? parsed = _parseDate(json[key]);
      if (parsed != null) return parsed;
    }
    return null;
  }

  static DateTime? _parseValidationValidatedAt(Map<String, dynamic> json) {
    const List<String> validatedAtKeys = <String>[
      'validatedAt',
      'validated_at',
      'checkedAt',
      'checked_at',
    ];

    for (final String key in validatedAtKeys) {
      final DateTime? parsed = _parseDate(json[key]);
      if (parsed != null) return parsed;
    }
    return null;
  }

  static bool? _parseAutoRenewStatus(Object? value) {
    if (value is bool) return value;
    if (value is int) return value == 1;
    if (value is String) {
      final String normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') return true;
      if (normalized == 'false' || normalized == '0') return false;
    }
    return null;
  }
}
