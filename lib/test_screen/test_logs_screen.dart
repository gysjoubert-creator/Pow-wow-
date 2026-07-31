import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/svg.dart';
import 'package:get/get.dart';
import '../../app/theme.dart';
import '../main.dart';
import '../screens/tabs/home/home_controller.dart';
import 'test_log_helper.dart';
import 'test_logs_screen_controller.dart';

class TestLogsScreen extends StatefulWidget {
  const TestLogsScreen({super.key});

  @override
  State<TestLogsScreen> createState() => _TestLogsScreenState();
}

class _TestLogsScreenState extends State<TestLogsScreen> {
  TestLogsScreenController get controller =>
      Get.find<TestLogsScreenController>();

  EdgeInsets get safeAreaInsets =>
      Get.context?.mediaQueryPadding ?? EdgeInsets.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.refreshLogs();
      testPrintLS(
        DiagnosticLog.ui(
          'TestLogsScreen',
          'opened',
          data: {'items': controller.items.length},
        ),
      );
      testPrintLS(
        DiagnosticLog.flow(
          'TestLogsScreen',
          'refresh_on_open',
          data: {'items': controller.items.length},
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: _contentView());
  }

  Widget _contentView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _topBar(),
        _roomView(),
        Expanded(
          child: Stack(
            children: [
              Container(
                decoration: BoxDecoration(color: Colors.green[50]),
                width: double.infinity,
                child: _infoView(),
              ),
              Positioned(left: 0, top: 0, right: 0, child: _topBarSeparator()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _infoView() {
    return GetBuilder<TestLogsScreenController>(
      builder: (c) {
        final items = c.items;

        if (items.isEmpty) {
          return const Center(
            child: Text(
              'No logs',
              style: TextStyle(fontFamily: 'Courier', fontSize: 12),
            ),
          );
        }

        return ListView.separated(
          itemCount: items.length,
          padding: const EdgeInsets.only(bottom: 40),
          itemBuilder: (context, index) => _listItem(c, index),
          separatorBuilder: (context, index) =>
              const Divider(color: Colors.transparent, thickness: 16),
        );
      },
    );
  }

  Widget _listItem(TestLogsScreenController c, int index) {
    final item = c.items[index];

    return InkWell(
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: item.text));
        testPrintLS(
          DiagnosticLog.ui(
            'TestLogsScreen',
            'log_item_copied',
            data: {'index': index, 'ts': c.formatDateTime(item.ts)},
          ),
        );
        Get.snackbar(
          "",
          "Copied",
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.black54,
          colorText: Colors.white,
          borderRadius: 8,
          duration: const Duration(seconds: 2),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Text(
          '${c.formatDateTime(item.ts)}# ${item.text}',
          style: const TextStyle(
            fontFamily: 'Courier',
            fontSize: 11,
            fontWeight: AppFontWeight.semibold,
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    return Container(
      decoration: const BoxDecoration(color: AppColors.blueBg),
      padding: EdgeInsets.only(top: max(safeAreaInsets.top, 20)),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            const SizedBox(width: 15),
            InkWell(
              onTap: () {
                testPrintLS(DiagnosticLog.ui('TestLogsScreen', 'back_tapped'));
                Get.back();
              },
              child: SvgPicture.asset(
                'assets/svg/back_button.svg',
                fit: BoxFit.contain,
                width: 40,
                height: 40,
              ),
            ),

            const Spacer(),
            DropdownButton<String>(
              underline: const SizedBox.shrink(),
              hint: Text(
                'MENU ...',
                style: AppTextStyle.mainBold.copyWith(color: Colors.white),
              ),
              items: [
                DropdownMenuItem(
                  value: 'refresh',
                  child: Text(
                    'Refresh Logs',
                    style: AppTextStyle.mainBold.copyWith(fontSize: 12),
                  ),
                ),
                DropdownMenuItem(
                  value: 'copyAll',
                  child: Text(
                    'Copy All Logs',
                    style: AppTextStyle.mainBold.copyWith(fontSize: 12),
                  ),
                ),
                DropdownMenuItem(
                  value: 'clear',
                  child: Text(
                    'Clear All Logs',
                    style: AppTextStyle.mainBold.copyWith(
                      color: Colors.red,
                      fontSize: 12,
                    ),
                  ),
                ),
                // const DropdownMenuItem(
                //   value: 'sep1',
                //   enabled: false,
                //   child: Text('----------------------'),
                // ),
                // DropdownMenuItem(
                //   value: 'room2222',
                //   child: Text(
                //     'room 2222',
                //     style: AppTextStyle.mainBold.copyWith(fontSize: 12),
                //   ),
                // ),
              ],
              onChanged: (value) async {
                if (value == null) return;

                if (value == 'refresh') {
                  controller.refreshLogs();
                  testPrintLS(
                    DiagnosticLog.ui(
                      'TestLogsScreen',
                      'refresh_tapped',
                      data: {'items': controller.items.length},
                    ),
                  );
                } else if (value == 'clear') {
                  await controller.removeAllLogItems();
                  testPrintLS(
                    DiagnosticLog.flow('TestLogsScreen', 'logs_cleared'),
                  );
                } else if (value == 'copyAll') {
                  controller.copyAll();
                  testPrintLS(
                    DiagnosticLog.ui(
                      'TestLogsScreen',
                      'copy_all_tapped',
                      data: {'items': controller.items.length},
                    ),
                  );
                } else if (value == 'room2222') {
                  testPrintLS(
                    DiagnosticLog.ui(
                      'TestLogsScreen',
                      'switch_room_tapped',
                      data: {'roomId': '2222'},
                    ),
                  );
                  await Get.find<HomeController>().switchToRoom('2222');
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _roomView() {
    if (!Get.isRegistered<HomeController>()) {
      return Container(
        decoration: BoxDecoration(border: Border.all(color: Colors.blue)),
        padding: const EdgeInsets.all(10),
        child: Text(
          'Home controller not active',
          style: AppTextStyle.mainSemibold.copyWith(fontSize: 12),
        ),
      );
    }

    return GetBuilder<HomeController>(
      builder: (homeController) {
        return Container(
          decoration: BoxDecoration(border: Border.all(color: Colors.blue)),
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'ROOM: ${homeController.liveKitController?.statusLabel}',
                    style: AppTextStyle.mainSemibold.copyWith(
                      color:
                          homeController.liveKitController?.statusColor ??
                          Colors.red,
                    ),
                  ),
                ],
              ),
              Text(
                'ID: ${homeController.myProfile.tribeId}',
                style: AppTextStyle.mainSemibold.copyWith(fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _topBarSeparator() {
    return Container(height: 3, color: AppColors.blueBg.withValues(alpha: 0.2));
  }
}
