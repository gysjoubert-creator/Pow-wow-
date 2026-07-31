import 'package:flutter_test/flutter_test.dart';
import 'package:pow_wow/test_screen/test_log_helper.dart';

void main() {
  group('DiagnosticLog', () {
    test('formats structured records and skips nulls', () {
      final result = DiagnosticLog.flow(
        'HomeController',
        'send_call_started',
        data: {'memberId': 'abc', 'memberName': 'Jane', 'ignored': null},
      );

      expect(
        result,
        'FLOW::HomeController::send_call_started | memberId=abc, memberName=Jane',
      );
    });

    test('skips sensitive keys and normalizes whitespace', () {
      final result = DiagnosticLog.err(
        'LiveKitController',
        'connect_failed',
        data: {'token': 'secret-token', 'error': 'some\nvery   noisy\tmessage'},
      );

      expect(
        result,
        'ERR::LiveKitController::connect_failed | error=some very noisy message',
      );
      expect(result.contains('secret-token'), isFalse);
    });
  });
}
