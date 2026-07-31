import 'package:flutter_test/flutter_test.dart';
import 'package:pow_wow/test_screen/test_logs_storage.dart';

void main() {
  group('TestLogsStorage', () {
    test('appendRaw preserves order and applies maxItems limit', () {
      final baseTime = DateTime.utc(2026, 1, 1, 12, 0, 0);
      final current = <Map<String, dynamic>>[
        {'ts': baseTime.toIso8601String(), 'text': 'first'},
        {
          'ts': baseTime.add(const Duration(seconds: 1)).toIso8601String(),
          'text': 'second',
        },
      ];

      final result = TestLogsStorage.appendRaw(
        current: current,
        ts: baseTime.add(const Duration(seconds: 2)),
        text: 'third',
        maxItems: 2,
      );

      expect(result, hasLength(2));
      expect(result[0]['text'], 'second');
      expect(result[1]['text'], 'third');
    });

    test('trimToMaxItems returns a copy when size is already valid', () {
      final items = <Map<String, dynamic>>[
        {'ts': '2026-01-01T12:00:00.000Z', 'text': 'one'},
      ];

      final result = TestLogsStorage.trimToMaxItems(items, maxItems: 3);

      expect(result, items);
      expect(identical(result, items), isFalse);
    });
  });
}
