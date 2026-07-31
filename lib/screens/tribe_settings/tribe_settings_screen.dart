import 'dart:math';

import 'package:flutter/material.dart';
import 'package:pow_wow/widgets/avatar_placeholder.dart';
import 'package:pow_wow/widgets/cached_avatar_image.dart';
import 'package:flutter_svg/svg.dart';
import 'package:get/get.dart';

import '../../app/routes/app_routes.dart';
import '../../app/services/subscriptions/subscription_service.dart';
import '../../app/services/subscriptions/subscription_state.dart';
import '../../app/theme.dart';
import '../../main.dart';
import '../../test_screen/test_log_helper.dart';
import 'tribe_settings_controller.dart';
import 'widgets/volume_slider.dart';

class TribeSettingsScreen extends StatelessWidget {
  const TribeSettingsScreen({super.key});

  BoxShadow get _sectionShadow => BoxShadow(
    color: Colors.black.withValues(alpha: 0.05),
    spreadRadius: 0,
    blurRadius: 2,
    offset: const Offset(0, 1),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.greyBg,
      body: GetBuilder<TribeSettingsController>(
        builder: (controller) {
          return _buildContentView(context, controller);
        },
      ),
    );
  }

  Widget _buildContentView(
    BuildContext context,
    TribeSettingsController controller,
  ) {
    final EdgeInsets safeAreaInsets = MediaQuery.paddingOf(context);
    return Column(
      children: [
        SizedBox(height: max(safeAreaInsets.top, 20)),
        _buildHeader(),
        const SizedBox(height: 10),
        Expanded(
          child: SingleChildScrollView(child: _buildScrollContent(controller)),
        ),
      ],
    );
  }

  Widget _buildScrollContent(TribeSettingsController controller) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          const SizedBox(height: 38),
          _buildProfileSection(controller),
          const SizedBox(height: 24),
          _buildSubscriptionSection(),
          const SizedBox(height: 24),
          _buildAudioSection(controller),
          const SizedBox(height: 24),
          // _buildCrewSection(controller),
          // const SizedBox(height: 24),
          // _buildAlertsSection(controller),
          // const SizedBox(height: 24),//td
          // _buildLogoutSection(),
          const SizedBox(height: 32),

          Text(
            controller.appVersionTitle,
            style: AppTextStyle.mainRegular.copyWith(
              fontSize: 10,
              color: AppColors.greyText2,
            ),
          ),
          const SizedBox(height: 100),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        const SizedBox(width: 24),
        InkWell(
          onTap: () {
            testPrintLS(DiagnosticLog.ui('TribeSettingsScreen', 'back_tapped'));
            Get.back();
          },
          child: SvgPicture.asset(
            'assets/svg/back_button.svg',
            fit: BoxFit.contain,
            width: 40,
            height: 40,
          ),
        ),
        const SizedBox(width: 44),
        Text(
          'Tribe Settings'.toUpperCase(),
          style: AppTextStyle.mainRegular.copyWith(fontSize: 24),
        ),
      ],
    );
  }

  Widget _buildSectionCard({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(40),
        color: AppColors.whiteBg,
        boxShadow: [_sectionShadow],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
      child: child,
    );
  }

  static const double _avatarSize = 60;
  static const double _editButtonOverlap = 10;

  Widget _buildProfileSection(TribeSettingsController controller) {
    final String? avatarUrl = controller.myProfile.avatarUrl;
    final double avatarHitExtent = _avatarSize + _editButtonOverlap;
    return _buildSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: _avatarSize,
                height: _avatarSize,
                child: OverflowBox(
                  maxWidth: avatarHitExtent,
                  maxHeight: avatarHitExtent,
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: avatarHitExtent,
                    height: avatarHitExtent,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        SizedBox(
                          width: _avatarSize,
                          height: _avatarSize,
                          child: ClipOval(
                            child: avatarUrl != null
                                ? CachedAvatarImage(
                                    url: avatarUrl,
                                    size: _avatarSize,
                                  )
                                : AvatarPlaceholder(),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: _buildEditProfileButton(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Text(
                  controller.myProfile.name,
                  style: AppTextStyle.mainBold,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (controller.canLeaveTribe) ...[
            const SizedBox(height: 24),
            _buildLeaveTribeButton(controller),
          ],
        ],
      ),
    );
  }

  Widget _buildLeaveTribeButton(TribeSettingsController controller) {
    return Opacity(
      opacity: controller.isLeavingTribe ? 0.5 : 1,
      child: Align(
        alignment: Alignment.center,
        child: InkWell(
          onTap: controller.isLeavingTribe
              ? null
              : () => _showLeaveTribeDialog(controller),
          child: Text(
            'Leave Tribe'.toUpperCase(),
            style: AppTextStyle.mainRegular.copyWith(
              fontSize: 12,
              color: AppColors.redBg,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showLeaveTribeDialog(TribeSettingsController controller) async {
    testPrintLS(DiagnosticLog.ui('TribeSettingsScreen', 'leave_tribe_tapped'));

    final bool? confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('Leave Tribe?'),
        content: const Text(
          'You will leave this tribe and return to your own.',
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: Text(
              'Leave Tribe',
              style: AppTextStyle.mainSemibold.copyWith(color: AppColors.redBg),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await controller.leaveTribe();
    }
  }

  static const double _editButtonVisualSize = 28;
  static const double _editButtonTapSize = 48;

  Widget _buildEditProfileButton() {
    return SizedBox(
      width: _editButtonTapSize,
      height: _editButtonTapSize,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            testPrintLS(
              DiagnosticLog.ui('TribeSettingsScreen', 'edit_profile_tapped'),
            );
            Get.toNamed(AppRoutes.editProfile);
          },
          customBorder: const CircleBorder(),
          child: Align(
            alignment: Alignment.bottomRight,
            child: Container(
              width: _editButtonVisualSize,
              height: _editButtonVisualSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.whiteBg,
                border: Border.all(color: AppColors.greyBg3, width: 1.5),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.edit_outlined,
                size: 14,
                color: AppColors.blackText2,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAudioSection(TribeSettingsController controller) {
    return _buildSectionCard(
      child: Column(
        children: [
          _buildSectionHeader(
            image: 'assets/svg/audio.svg',
            title: 'Audio Controls'.toUpperCase(),
          ),
          const SizedBox(height: 32),
          Row(
            children: [
              Text(
                'Intercom Volume'.toUpperCase(),
                style: AppTextStyle.mainBold.copyWith(
                  fontSize: 12,
                  color: AppColors.greyText,
                ),
              ),
              const Spacer(),
              Text(
                '${(controller.intercomVolume * 100).round()}%',
                style: AppTextStyle.mainRegular,
              ),
            ],
          ),
          const SizedBox(height: 16),
          VolumeSlider(
            initialValue: controller.intercomVolume,
            onChanged: (value) {
              controller.setVolume(value);
            },
            onChangeEnd: (value) {
              testPrintLS(
                DiagnosticLog.ui(
                  'TribeSettingsScreen',
                  'volume_change_committed',
                  data: {'value': value.toStringAsFixed(2)},
                ),
              );
            },
          ),
          const SizedBox(height: 32),
          _buildToggleRow(
            icon: 'assets/svg/head_phones.svg',
            iconBg: AppColors.blueBg,
            title: 'Headphone Priority',
            iconHeight: 20,
            value: controller.isHeadphonePriority,
            onChanged: (value) {
              controller.setHeadphonePriority(value);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSubscriptionSection() {
    if (!Get.isRegistered<SubscriptionService>()) {
      return const SizedBox.shrink();
    }

    final SubscriptionService subscriptionService =
        Get.find<SubscriptionService>();

    return Obx(() {
      final SubscriptionState state = subscriptionService.state;
      return _buildSectionCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSectionHeader(
              image: 'assets/svg/crew.svg',
              title: 'Subscription'.toUpperCase(),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _subscriptionStatusTitle(state),
                    style: AppTextStyle.mainBold.copyWith(fontSize: 16),
                  ),
                ),
                const SizedBox(width: 12),
                _buildSubscriptionActionButton(
                  title: state.hasActiveEntitlement ? 'Manage' : 'Subscribe',
                  onTap: () {
                    testPrintLS(
                      DiagnosticLog.ui(
                        'TribeSettingsScreen',
                        'subscription_manage_tapped',
                      ),
                    );
                    Get.toNamed(AppRoutes.subscription);
                  },
                ),
              ],
            ),
          ],
        ),
      );
    });
  }

  Widget _buildSubscriptionActionButton({
    required String title,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: AppColors.greenText,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Text(
          title.toUpperCase(),
          style: AppTextStyle.mainBold.copyWith(
            fontSize: 11,
            color: AppColors.whiteText,
          ),
        ),
      ),
    );
  }

  String _subscriptionStatusTitle(SubscriptionState state) {
    if (state.hasActiveEntitlement) return 'Active subscription';
    if (state.needsVerificationRetry) return 'Validation pending';
    if (!state.productsConfigured) return 'Not configured yet';
    if (!state.backendConfigured) return 'Server validation missing';
    if (!state.storeAvailable) return 'Store unavailable';
    if (state.phase == SubscriptionServicePhase.error) return 'Needs attention';
    return 'No active subscription';
  }

  // Widget _buildCrewSection(TribeSettingsController controller) {
  //   return _buildSectionCard(
  //     child: Column(
  //       children: [
  //         _buildSectionHeader(
  //           image: 'assets/svg/crew.svg',
  //           title: 'The Crew'.toUpperCase(),
  //         ),
  //         const SizedBox(height: 24),

  //         GestureDetector(
  //           onTap: () {
  //             testPrintLS(
  //               DiagnosticLog.ui('TribeSettingsScreen', 'invite_member_tapped'),
  //             );
  //             InviteLinkService.invite();
  //           },
  //           child: _buildInviteMemberView(),
  //         ),
  //       ],
  //     ),
  //   );
  // }

  // Widget _buildInviteMemberView() {
  //   return Container(
  //     alignment: Alignment.center,
  //     decoration: BoxDecoration(
  //       borderRadius: BorderRadius.circular(16),
  //       color: AppColors.orangeBg2,
  //     ),
  //     height: 80,
  //     padding: const EdgeInsets.symmetric(horizontal: 20),
  //     child: Row(
  //       children: [
  //         _buildCircleWithImage(
  //           bgColor: Colors.white.withValues(alpha: 0.2),
  //           image: 'assets/svg/user_plus.svg',
  //           imageHeight: 19,
  //         ),
  //         const SizedBox(width: 16),
  //         Expanded(
  //           child: Text(
  //             'Invite New Member'.toUpperCase(),
  //             style: AppTextStyle.mainRegular.copyWith(
  //               color: AppColors.whiteText,
  //             ),
  //             maxLines: 2,
  //             overflow: TextOverflow.ellipsis,
  //           ),
  //         ),

  //         SvgPicture.asset(
  //           'assets/svg/chevron_right.svg',
  //           fit: BoxFit.contain,
  //           height: 12,
  //         ),
  //       ],
  //     ),
  //   );
  // }

  // Widget _buildAlertsSection(TribeSettingsController controller) {
  //   return _buildSectionCard(
  //     child: Column(
  //       children: [
  //         _buildSectionHeader(
  //           image: 'assets/svg/alerts.svg',
  //           title: 'Alerts'.toUpperCase(),
  //         ),
  //         const SizedBox(height: 24),
  //         _buildToggleRow(
  //           icon: 'assets/svg/bedtime.svg',
  //           iconBg: AppColors.orangeBg3,
  //           title: 'Bedtime DND',
  //           iconHeight: 21,
  //           value: controller.isBedtimeDND,
  //           onChanged: (value) {
  //             controller.setBedtimeDND(value);
  //           },
  //         ),
  //         const SizedBox(height: 8),
  //         Container(height: 1, color: AppColors.greyBg2),
  //         const SizedBox(height: 16),
  //         Row(
  //           children: [
  //             Container(
  //               alignment: Alignment.center,
  //               decoration: BoxDecoration(
  //                 borderRadius: BorderRadius.circular(16),
  //                 color: AppColors.greyBg2,
  //               ),
  //               width: 40,
  //               height: 40,
  //               margin: const EdgeInsets.symmetric(vertical: 12),
  //               child: SvgPicture.asset(
  //                 'assets/svg/tone.svg',
  //                 fit: BoxFit.contain,
  //                 height: 20,
  //               ),
  //             ),
  //             const SizedBox(width: 16),
  //             Expanded(
  //               child: Column(
  //                 crossAxisAlignment: CrossAxisAlignment.start,
  //                 children: [
  //                   Text(
  //                     'Alert Tone',
  //                     style: AppTextStyle.mainRegular.copyWith(
  //                       color: AppColors.blackText2,
  //                     ),
  //                   ),
  //                   Text(
  //                     'Bird Chirp'.toUpperCase(), //td
  //                     style: AppTextStyle.mainRegular.copyWith(
  //                       fontSize: 10,
  //                       color: AppColors.tealBg,
  //                     ),
  //                   ),
  //                 ],
  //               ),
  //             ),
  //             SvgPicture.asset(
  //               'assets/svg/chevron_bottom.svg',
  //               fit: BoxFit.contain,
  //               width: 12,
  //             ),
  //           ],
  //         ),
  //       ],
  //     ),
  //   );
  // }

  // Widget _buildLogoutSection() {
  //   return _buildSectionCard(
  //     child: Column(
  //       children: [
  //         Container(
  //           alignment: Alignment.center,
  //           child: InkWell(
  //             onTap: () {},
  //             child: Text(
  //               'LOG OUT',
  //               style: AppTextStyle.mainRegular.copyWith(
  //                 fontSize: 12,
  //                 color: AppColors.blackText3,
  //               ),
  //             ),
  //           ),
  //         ),
  //       ],
  //     ),
  //   );
  // }

  Widget _buildSectionHeader({required String image, required String title}) {
    return Row(
      children: [
        _buildCircleWithImage(
          bgColor: AppColors.greyBg2,
          image: image,
          imageHeight: 18,
        ),
        const SizedBox(width: 12),
        Text(
          title,
          style: AppTextStyle.mainRegular.copyWith(
            fontSize: 14,
            color: AppColors.greyText,
          ),
        ),
      ],
    );
  }

  Widget _buildCircleWithImage({
    required Color bgColor,
    required String image,
    double? imageWidth,
    double? imageHeight,
  }) {
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
      width: 40,
      height: 40,
      child: SvgPicture.asset(
        image,
        fit: BoxFit.contain,
        width: imageWidth,
        height: imageHeight,
      ),
    );
  }

  Widget _buildToggleRow({
    required String icon,
    required Color iconBg,
    required String title,
    required double iconHeight,
    required bool value,
    ValueChanged<bool>? onChanged,
  }) {
    return Row(
      children: [
        Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: iconBg,
            boxShadow: [
              BoxShadow(
                color: iconBg.withValues(alpha: 0.15),
                spreadRadius: 1,
                blurRadius: 5,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          width: 40,
          height: 40,
          margin: const EdgeInsets.symmetric(vertical: 12),
          child: SvgPicture.asset(
            icon,
            fit: BoxFit.contain,
            height: iconHeight,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            title,
            style: AppTextStyle.mainRegular.copyWith(
              color: AppColors.blackText2,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 5),
        Switch(
          value: value,
          onChanged: onChanged,
          activeTrackColor: AppColors.tealBg,
          activeThumbColor: Colors.white,
        ),
      ],
    );
  }
}
