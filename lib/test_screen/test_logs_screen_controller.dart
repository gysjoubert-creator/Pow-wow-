import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'test_logs_storage.dart';

class LogItem {
  final DateTime ts;
  final String text;

  LogItem({required this.ts, required this.text});
}

class TestLogsScreenController extends GetxController {
  static const int maxItems = 1000;

  final List<LogItem> _items = [];
  List<LogItem> get items => List.unmodifiable(_items);

  bool isLoading = false;

  @override
  void onInit() {
    super.onInit();

    _restoreLogsFromStorage();
  }

  void refreshLogs() {
    _restoreLogsFromStorage();
    update();
  }

  void _restoreLogsFromStorage() {
    final raw = TestLogsStorage.readRaw(); // List<Map<String,dynamic>>

    _items.clear();

    for (final m in raw) {
      final tsRaw = (m['ts'] ?? '').toString();
      final text = (m['text'] ?? '').toString();

      final ts = DateTime.tryParse(tsRaw);

      _items.add(
        LogItem(
          ts: (ts ?? DateTime.fromMillisecondsSinceEpoch(0)).toLocal(),
          text: text,
        ),
      );
    }
  }

  void addMessage(String text, {DateTime? ts}) {
    final t = ts ?? DateTime.now();

    if (_items.length >= maxItems) {
      _items.removeAt(0);
    }
    _items.add(LogItem(ts: t, text: text));

    TestLogsStorage.add(ts: t, text: text, maxItems: maxItems);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isClosed) {
        update();
      }
    });
  }

  Future<void> removeAllLogItems() async {
    _items.clear();
    await TestLogsStorage.clear();
    update();
  }

  void copyAll() {
    final sb = StringBuffer();
    for (final item in _items) {
      sb.writeln('${formatDateTime(item.ts)}# ${item.text}');
    }

    Clipboard.setData(ClipboardData(text: sb.toString()));
    Get.snackbar(
      "",
      "Copied",
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.black54,
      colorText: Colors.white,
      borderRadius: 8,
      duration: const Duration(seconds: 2),
    );
  }

  String formatDateTime(DateTime dateTime) {
    return DateFormat('HH:mm:ss').format(dateTime);
  }
}
