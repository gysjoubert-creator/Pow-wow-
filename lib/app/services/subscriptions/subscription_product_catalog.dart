import 'subscription_product_config.dart';

enum SubscriptionCatalogProductType {
  subscription,
  nonConsumable,
  unknown;

  static SubscriptionCatalogProductType fromValue(Object? value) {
    final String normalized = value?.toString().trim().toLowerCase() ?? '';
    return switch (normalized) {
      'subscription' => subscription,
      'non-consumable' || 'non_consumable' || 'nonconsumable' => nonConsumable,
      _ => unknown,
    };
  }
}

/// One purchasable plan entry from `GET /api/v1/purchases/products`.
class SubscriptionCatalogEntry {
  final String productId;
  final SubscriptionCatalogProductType type;
  final String? duration;
  final String? basePlan;

  const SubscriptionCatalogEntry({
    required this.productId,
    required this.type,
    this.duration,
    this.basePlan,
  });

  factory SubscriptionCatalogEntry.fromJson(Map<String, dynamic> json) {
    return SubscriptionCatalogEntry(
      productId: _requireString(json['product_id'] ?? json['id']),
      type: SubscriptionCatalogProductType.fromValue(json['type']),
      duration: _optionalString(json['duration']),
      basePlan: _optionalString(json['base_plan']),
    );
  }

  /// Unique key for catalog rows (Android may repeat [productId] per base plan).
  String get catalogKey {
    final String? plan = basePlan;
    if (plan == null || plan.isEmpty) return productId;
    return '$productId:$plan';
  }

  /// Human-readable plan label derived from [duration] or [basePlan].
  String? get planLabel {
    final String? fromDuration = _labelFromDuration(duration);
    if (fromDuration != null) return fromDuration;

    final String? plan = basePlan?.trim().toLowerCase();
    if (plan == null || plan.isEmpty) return null;

    return switch (plan) {
      'year' => 'Yearly',
      'monthly' => 'Monthly',
      'weekly' => 'Weekly',
      'life-long' || 'lifelong' => 'Lifetime',
      _ => basePlan,
    };
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'product_id': productId,
      'type': _typeToJson(type),
      if (duration != null) 'duration': duration,
      if (basePlan != null) 'base_plan': basePlan,
    };
  }

  static String? _labelFromDuration(String? value) {
    final String normalized = value?.trim().toLowerCase() ?? '';
    if (normalized.isEmpty) return null;

    return switch (normalized) {
      '1 year' || 'year' || 'yearly' => 'Yearly',
      '1 month' || 'month' || 'monthly' => 'Monthly',
      '1 week' || 'week' || 'weekly' => 'Weekly',
      'lifelong' || 'lifetime' || 'life-long' => 'Lifetime',
      _ => value,
    };
  }

  static String _requireString(Object? value) {
    final String? parsed = _optionalString(value);
    if (parsed == null) {
      throw FormatException('Subscription catalog entry is missing product_id');
    }
    return parsed;
  }

  static String? _optionalString(Object? value) {
    final String normalized = value?.toString().trim() ?? '';
    return normalized.isEmpty ? null : normalized;
  }

  static String _typeToJson(SubscriptionCatalogProductType type) {
    return switch (type) {
      SubscriptionCatalogProductType.subscription => 'subscription',
      SubscriptionCatalogProductType.nonConsumable => 'non-consumable',
      SubscriptionCatalogProductType.unknown => 'unknown',
    };
  }
}

class SubscriptionProductCatalogData {
  final List<SubscriptionCatalogEntry> ios;
  final List<SubscriptionCatalogEntry> android;

  const SubscriptionProductCatalogData({
    required this.ios,
    required this.android,
  });

  factory SubscriptionProductCatalogData.fromJson(Map<String, dynamic> json) {
    return SubscriptionProductCatalogData(
      ios: _parseEntries(json['ios']),
      android: _parseEntries(json['android']),
    );
  }

  List<SubscriptionCatalogEntry> entriesFor(SubscriptionStoreKind store) {
    return switch (store) {
      SubscriptionStoreKind.appStore => ios,
      SubscriptionStoreKind.playStore => android,
      SubscriptionStoreKind.unknown => const <SubscriptionCatalogEntry>[],
    };
  }

  Set<String> productIdsFor(SubscriptionStoreKind store) {
    return entriesFor(store).map((SubscriptionCatalogEntry e) => e.productId).toSet();
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'ios': ios.map((SubscriptionCatalogEntry e) => e.toJson()).toList(),
      'android': android.map((SubscriptionCatalogEntry e) => e.toJson()).toList(),
    };
  }

  static List<SubscriptionCatalogEntry> _parseEntries(Object? value) {
    if (value is! List) return const <SubscriptionCatalogEntry>[];

    return value
        .whereType<Map>()
        .map((Map item) => SubscriptionCatalogEntry.fromJson(
              Map<String, dynamic>.from(item),
            ))
        .toList(growable: false);
  }
}

/// Typed response from `GET /api/v1/purchases/products`.
class SubscriptionProductCatalogResponse {
  final String status;
  final SubscriptionProductCatalogData data;

  const SubscriptionProductCatalogResponse({
    required this.status,
    required this.data,
  });

  bool get isSuccess => status.trim().toLowerCase() == 'success';

  factory SubscriptionProductCatalogResponse.fromJson(Map<String, dynamic> json) {
    final String status = json['status']?.toString().trim() ?? '';
    final Object? data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw const FormatException(
        'Subscription product catalog is missing a data object',
      );
    }

    return SubscriptionProductCatalogResponse(
      status: status,
      data: SubscriptionProductCatalogData.fromJson(data),
    );
  }

  /// Parses the live API shape; returns `null` for legacy/unknown payloads.
  static SubscriptionProductCatalogResponse? tryParse(Object? decoded) {
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['data'] is! Map<String, dynamic>) return null;

    try {
      return SubscriptionProductCatalogResponse.fromJson(decoded);
    } on FormatException {
      return null;
    }
  }

  List<SubscriptionCatalogEntry> entriesFor(SubscriptionStoreKind store) {
    return data.entriesFor(store);
  }

  Set<String> productIdsFor(SubscriptionStoreKind store) {
    return data.productIdsFor(store);
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'status': status,
      'data': data.toJson(),
    };
  }
}
