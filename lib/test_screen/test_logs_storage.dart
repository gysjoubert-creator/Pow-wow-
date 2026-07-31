import 'package:get_storage/get_storage.dart';

class TestLogsStorage {
  static const _kKey = 'test_logs_v1';

  static GetStorage get _box => GetStorage();

  /// raw list of maps: [{ts:"...", text:"..."}]
  static List<Map<String, dynamic>> readRaw() {
    final raw = _box.read(_kKey);
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    }
    return <Map<String, dynamic>>[];
  }

  static Future<void> add({
    required DateTime ts,
    required String text,
    int maxItems = 1000,
  }) async {
    final list = appendRaw(
      current: readRaw(),
      ts: ts,
      text: text,
      maxItems: maxItems,
    );

    await _box.write(_kKey, list);
  }

  static Future<void> clear() async {
    await _box.remove(_kKey);
  }

  static List<Map<String, dynamic>> appendRaw({
    required List<Map<String, dynamic>> current,
    required DateTime ts,
    required String text,
    int maxItems = 1000,
  }) {
    final list = List<Map<String, dynamic>>.from(current)
      ..add({'ts': ts.toUtc().toIso8601String(), 'text': text});

    return trimToMaxItems(list, maxItems: maxItems);
  }

  static List<Map<String, dynamic>> trimToMaxItems(
    List<Map<String, dynamic>> items, {
    int maxItems = 1000,
  }) {
    if (items.length <= maxItems) {
      return List<Map<String, dynamic>>.from(items);
    }

    return List<Map<String, dynamic>>.from(
      items.sublist(items.length - maxItems),
    );
  }
}
