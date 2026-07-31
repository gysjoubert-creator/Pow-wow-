import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../../../test_screen/test_log_helper.dart';
import '../../../test_screen/test_logs_screen_controller.dart';

void subscriptionDiagnosticLog(String text) {
  final DateTime dateTime = DateTime.now();
  final String formattedTime =
      '${DateFormat('HH:mm:ss').format(dateTime)}.${dateTime.millisecond.toString().padLeft(3, '0')}';

  debugPrint('[$formattedTime]#### $text');

  if (Get.isRegistered<TestLogsScreenController>()) {
    Get.find<TestLogsScreenController>().addMessage(text, ts: dateTime);
  }
}

void subscriptionDiagnosticFlow(
  String event, {
  Map<String, Object?> data = const {},
}) {
  subscriptionDiagnosticLog(
    DiagnosticLog.flow('SubscriptionService', event, data: data),
  );
}
