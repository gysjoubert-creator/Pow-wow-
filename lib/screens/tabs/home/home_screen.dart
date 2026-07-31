import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:get/get.dart';

import '../../../app/routes/app_routes.dart';
import '../../../app/utils/utils.dart';
import '../../../app/theme.dart';
import '../../../app/data/models/tribe_member.dart';
import '../../../app/data/models/tribe_message.dart';
import '../../../main.dart';
import '../../../test_screen/test_log_helper.dart';
import '../../../test_screen/test_logs_screen.dart';
import '../../../widgets/loading_view.dart';
import '../../../widgets/retry_error_view.dart';
import 'home_controller.dart';
import 'widgets/hold_to_speak_button.dart';
import 'widgets/home_screen_avatar.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.greyBg,
      body: GetBuilder<HomeController>(
        builder: (controller) {
          return Stack(
            children: [
              _buildContent(context, controller),
              if (controller.isLoading) LoadingView(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildContent(BuildContext context, HomeController controller) {
    if (!controller.isProfileReady) {
      return const SizedBox.shrink();
    }
    final isLiveKitConnecting =
        controller.liveKitController?.isConnecting == true;
    final showButtonLoading =
        controller.isFetchingLiveKitToken || isLiveKitConnecting;
    final isCallButtonDisabled =
        !controller.canCallTheTribe ||
        controller.isFetchingLiveKitToken ||
        isLiveKitConnecting;
    return Column(
      children: [
        _buildHeader(context, controller),
        if (controller.connectionErrorMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: RetryErrorView(
              layout: RetryErrorLayout.compact,
              message: controller.connectionErrorMessage!,
              isNetworkError: controller.connectionErrorIsNetwork,
              isRetrying: controller.isLiveKitJoinInProgress,
              onRetry: controller.retryConnection,
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                _buildMembersRow(
                  members: controller.familyMembers,
                  activeCount: controller.activeFamilyMembersCount,
                  controller: controller,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: SvgPicture.asset(
                    'assets/svg/home_bg.svg',
                    fit: BoxFit.contain,
                  ),
                ),
                Stack(
                  alignment: Alignment.center,
                  children: [
                    IgnorePointer(
                      ignoring: isCallButtonDisabled,
                      child: Opacity(
                        opacity: isCallButtonDisabled ? 0.3 : 1,
                        child: HoldToSpeakButton(
                          size: Get.width - 48,
                          onPressed: () => _handleHoldPressed(controller),
                          onReleased: () => _handleHoldReleased(controller),
                        ),
                      ),
                    ),

                    if (showButtonLoading) CircularProgressIndicator(),
                  ],
                ),

                if (controller.lastMessage != null) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: _buildLastMessageCard(controller.lastMessage!),
                  ),
                ],
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, HomeController controller) {
    final EdgeInsets safeAreaInsets = MediaQuery.paddingOf(context);
    return Container(
      padding: EdgeInsets.only(top: max(safeAreaInsets.top, 32), bottom: 16),
      color: AppColors.orangeBg,
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 24),
              InkWell(
                onTap: () {
                  //td//td
                  testPrintLS(
                    DiagnosticLog.ui('HomeScreen', 'logs_open_tapped'),
                  );
                  Get.to(() => TestLogsScreen());
                },
                child: SvgPicture.asset(
                  'assets/svg/family.svg',
                  fit: BoxFit.contain,
                  width: 40,
                  height: 40,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'The PowWow',
                style: AppTextStyle.mainSemibold.copyWith(fontSize: 20),
              ),
              const Spacer(),
              InkWell(
                onTap: () {
                  testPrintLS(
                    DiagnosticLog.ui('HomeScreen', 'settings_open_tapped'),
                  );
                  Get.toNamed(AppRoutes.tribeSettings);
                },
                child: SvgPicture.asset(
                  'assets/svg/settings.svg',
                  fit: BoxFit.contain,
                  width: 40,
                  height: 40,
                ),
              ),
              const SizedBox(width: 24),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMembersRow({
    required List<TribeMember> members,
    required int activeCount,
    required HomeController controller,
  }) {
    final rowHeight = 88.0;

    return Column(
      children: [
        const SizedBox(height: 4),
        Row(
          children: [
            const SizedBox(width: 24),
            Text(
              'Family Tribe',
              style: AppTextStyle.mainBold.copyWith(fontSize: 18),
            ),
            const Spacer(),
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(44),
                color: AppColors.greenText.withValues(alpha: 0.1),
              ),
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                '$activeCount Active',
                style: AppTextStyle.mainSemibold.copyWith(
                  fontSize: 12,
                  color: AppColors.greenText,
                ),
              ),
            ),
            const SizedBox(width: 24),
          ],
        ),
        const SizedBox(height: 16),
        !controller.membersLoaded
            ? SizedBox(height: rowHeight)
            : members.isEmpty
            ? SizedBox(
                height: rowHeight,
                child: Center(
                  child: Text(
                    'No tribe members yet',
                    style: AppTextStyle.mainSemibold.copyWith(
                      fontSize: 14,
                      color: AppColors.greyText2,
                    ),
                  ),
                ),
              )
            : SizedBox(
                height: rowHeight,
                child: ListView.separated(
                  shrinkWrap: true,
                  scrollDirection: Axis.horizontal,
                  itemCount: members.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(width: 12),
                  itemBuilder: (context, index) {
                    return _buildProfileView(members[index], controller);
                  },
                ),
              ),
      ],
    );
  }

  Widget _buildProfileView(TribeMember member, HomeController controller) {
    final Color textColor = member.status == .silent
        ? AppColors.greyText2
        : AppColors.blackText4;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        testPrintLS(
          DiagnosticLog.ui(
            'HomeScreen',
            'member_tapped',
            data: {
              'memberId': member.id,
              'memberName': member.name,
              'status': member.status.name,
            },
          ),
        );
        controller.sendCall(member);
      },

      child: SizedBox(
        width: 77,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            HomeScreenAvatar(member: member),
            const Spacer(),
            Text(
              member.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.mainBold.copyWith(
                fontSize: 12,
                color: textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLastMessageCard(TribeMessage message) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      height: 90,
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _buildMessagePlayButton(),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${message.senderName} (${Utils.timeAgo(message.createdAt)})',

                        style: AppTextStyle.mainBold.copyWith(fontSize: 14),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      'Last Audio'.toUpperCase(),
                      style: AppTextStyle.mainBold.copyWith(
                        fontSize: 10,
                        color: AppColors.greyText2,
                      ),
                    ),
                  ],
                ),

                Text(
                  '"${message.text}"',
                  style: AppTextStyle.mainRegular.copyWith(
                    fontSize: 14,
                    color: AppColors.greyText,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessagePlayButton() {
    return InkWell(
      onTap: () {
        testPrintLS(DiagnosticLog.ui('HomeScreen', 'last_audio_play_tapped'));
      },
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.redBg2,
        ),
        width: 48,
        height: 48,
        child: SvgPicture.asset(
          'assets/svg/play_small.svg',
          fit: BoxFit.contain,
          width: 20,
        ),
      ),
    );
  }

  void _handleHoldPressed(HomeController controller) {
    testPrintLS(
      DiagnosticLog.ui(
        'HomeScreen',
        'hold_to_speak_pressed',
        data: {
          'isConnected': controller.liveKitController?.isConnected,
          'isConnecting': controller.liveKitController?.isConnecting,
        },
      ),
    );
    controller.startTalking();
  }

  void _handleHoldReleased(HomeController controller) {
    testPrintLS(
      DiagnosticLog.ui(
        'HomeScreen',
        'hold_to_speak_released',
        data: {
          'isConnected': controller.liveKitController?.isConnected,
          'isConnecting': controller.liveKitController?.isConnecting,
        },
      ),
    );
    controller.stopTalking();
  }
}
