import 'package:get_storage/get_storage.dart';

import 'subscription_entitlement.dart';

/// Local cache for the last subscription entitlement confirmed by the
/// backend.
///
/// The receipt-validator API has no `GET entitlement/me` endpoint, so
/// [SubscriptionService] hydrates the UI from this cache on startup and
/// keeps it fresh by re-validating purchases via `restorePurchases()` and
/// after every successful purchase validation.
abstract final class SubscriptionEntitlementStorage {
  static const String _keyPrefix = 'subscription_entitlement_v1';

  static GetStorage get _box => GetStorage();

  static SubscriptionEntitlement? read({String? uid}) {
    final Object? raw = _box.read(_key(uid));
    if (raw is Map) {
      try {
        return SubscriptionEntitlement.fromJson(
          Map<String, dynamic>.from(raw),
        );
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static Future<void> write(
    SubscriptionEntitlement entitlement, {
    String? uid,
  }) {
    return _box.write(_key(uid), entitlement.toJson());
  }

  static Future<void> clear({String? uid}) {
    return _box.remove(_key(uid));
  }

  static String _key(String? uid) {
    final String normalized = uid?.trim() ?? '';
    return normalized.isEmpty ? _keyPrefix : '${_keyPrefix}_$normalized';
  }
}
