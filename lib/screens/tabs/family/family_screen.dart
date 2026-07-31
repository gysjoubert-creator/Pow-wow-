import 'dart:math';

import 'package:dotted_border/dotted_border.dart';
import 'package:flutter/material.dart';
import 'package:pow_wow/app/utils/screen_helper.dart';
import 'package:pow_wow/screens/tabs/home/home_controller.dart';
import 'package:flutter_svg/svg.dart';
import 'package:get/get.dart';

import '../../../app/services/invite_link_service.dart';
import '../../../app/theme.dart';
import '../../../app/data/enums/tribe_member_status.dart';
import '../../../app/data/models/tribe_member.dart';
import '../../../main.dart';
import '../../../test_screen/test_log_helper.dart';
import '../../../widgets/loading_view.dart';
import 'widgets/family_screen_avatar.dart';

class FamilyScreen extends StatefulWidget {
  const FamilyScreen({super.key});

  @override
  State<FamilyScreen> createState() => _FamilyScreenState();
}

class _FamilyScreenState extends State<FamilyScreen> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.greyBg,
      body: GetBuilder<HomeController>(
        builder: (controller) {
          return Stack(
            children: [
              _buildContent(context, controller),
              Positioned.fill(child: _buildOverlay(context)),
              if (_isLoading || controller.isLoading) LoadingView(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildOverlay(BuildContext context) {
    final EdgeInsets safeAreaInsets = MediaQuery.paddingOf(context);
    final size = 0.0;
    final double radius = 128 - 32;
    return Stack(
      children: [
        Positioned(
          top: max(safeAreaInsets.top, 48) + 128 + 32,
          left: 128 * 0.25,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppColors.greenBg.withValues(alpha: 0.1),
                  spreadRadius: radius,
                  blurRadius: 64,
                  offset: const Offset(0, 0),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          top: Get.height * 0.5,
          right: 128 * 0.25,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppColors.orangeBg3.withValues(alpha: 0.1),
                  spreadRadius: radius,
                  blurRadius: 64,
                  offset: const Offset(0, 0),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContent(BuildContext context, HomeController controller) {
    if (!controller.isProfileReady) {
      return const SizedBox.shrink();
    }
    return Column(
      children: [
        _buildHeader(context),
        Expanded(child: _buildListView(controller)),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final EdgeInsets safeAreaInsets = MediaQuery.paddingOf(context);
    return Container(
      color: AppColors.whiteBg2,
      padding: EdgeInsets.only(bottom: 24),
      child: Container(
        color: AppColors.greyBg.withValues(alpha: 0.9),
        padding: EdgeInsets.only(top: max(safeAreaInsets.top, 48), bottom: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'The PowWow Call',
                    style: AppTextStyle.mainBold.copyWith(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                    maxLines: 1,
                  ),
                  Text(
                    'Family Tribe',
                    style: AppTextStyle.mainSemibold.copyWith(
                      fontSize: 14,
                      color: AppColors.greenText,
                    ),
                  ),
                ],
              ),
            ),
            _buildPlusButton(),
            const SizedBox(width: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildListView(HomeController controller) {
    final members = controller.familyMembers;
    final membersCount = members.length;
    final addMemberRowIndex = membersCount + 1;
    return ListView.separated(
      padding: EdgeInsets.only(left: 20, right: 20, top: 20, bottom: 20),
      itemCount: membersCount + 2,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _buildListeningNowRow(controller.activeFamilyMembersCount);
        } else if (index == addMemberRowIndex) {
          return _buildAddMemberRow();
        } else {
          return _buildRowItem(members[index - 1], controller);
        }
      },
      separatorBuilder: (context, index) {
        return const Divider(color: Colors.transparent, thickness: 16);
      },
    );
  }

  Widget _buildListeningNowRow(int listeningCount) {
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white,
      ),
      height: 54,
      margin: EdgeInsets.only(bottom: 16),
      width: double.infinity,
      child: Row(
        children: [
          const SizedBox(width: 16),
          Container(
            decoration: BoxDecoration(
              color: AppColors.greenBg,
              shape: BoxShape.circle,
            ),
            width: 10,
            height: 10,
          ),
          const SizedBox(width: 12),
          Text(
            '$listeningCount Members Listening Now',
            style: AppTextStyle.mainBold.copyWith(
              fontSize: 14,
              color: AppColors.blackText3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRowItem(TribeMember member, HomeController controller) {
    return Dismissible(
      key: ValueKey(member.id),
      direction: controller.canUseMemberActions
          ? DismissDirection.endToStart
          : DismissDirection.none,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        decoration: BoxDecoration(
          color: AppColors.redBg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.close, color: Colors.white, size: 20),
      ),
      confirmDismiss: (_) async {
        testPrintLS(
          DiagnosticLog.ui(
            'FamilyScreen',
            'remove_member_swiped',
            data: {'memberId': member.id, 'memberName': member.name},
          ),
        );
        return _showRemoveMemberDialog(member, controller);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          testPrintLS(
            DiagnosticLog.ui(
              'FamilyScreen',
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
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: Colors.white,
          ),
          height: 98,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(width: 16),
              FamilyScreenAvatar(member: member),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      member.name,
                      style: AppTextStyle.mainBold.copyWith(fontSize: 18),
                    ),
                    Text(
                      member.status.title,
                      style: AppTextStyle.mainSemibold.copyWith(
                        fontSize: 14,
                        color: member.status.titleColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              SvgPicture.asset(
                'assets/svg/chevron_right.svg',
                fit: BoxFit.contain,
                height: 12,
                colorFilter: const ColorFilter.mode(
                  AppColors.greyBg4,
                  BlendMode.srcIn,
                ),
              ),
              const SizedBox(width: 16),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _showRemoveMemberDialog(
    TribeMember member,
    HomeController controller,
  ) async {
    final bool? confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('Remove Member?'),
        content: Text('${member.name} will be removed from the tribe.'),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: Text(
              'Remove',
              style: AppTextStyle.mainSemibold.copyWith(color: AppColors.redBg),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _removeMember(member, controller);
      return true;
    }
    return false;
  }

  Future<void> _removeMember(
    TribeMember member,
    HomeController controller,
  ) async {
    setState(() => _isLoading = true);
    try {
      await controller.removeMemberFromTribe(member);
    } catch (e) {
      testPrintLS(
        DiagnosticLog.err(
          'FamilyScreen',
          'remove_member_failed',
          data: {'memberId': member.id, 'memberName': member.name, 'error': e},
        ),
      );
      ScreenHelper.showErrorSnackbar(
        'Could not remove ${member.name}. Please try again.',
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Widget _buildAddMemberRow() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        testPrintLS(DiagnosticLog.ui('FamilyScreen', 'add_member_tapped'));
        InviteLinkService.invite();
      },
      child: DottedBorder(
        options: RoundedRectDottedBorderOptions(
          dashPattern: [6, 4],
          strokeWidth: 2,
          radius: Radius.circular(16),
          color: AppColors.greyBg3,
        ),
        child: SizedBox(
          height: 68,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SvgPicture.asset(
                'assets/svg/add_member.svg',
                fit: BoxFit.contain,
                width: 22,
              ),
              const SizedBox(width: 8),
              Text(
                'Add Tribe Member',
                style: AppTextStyle.mainBold.copyWith(
                  color: AppColors.greyText2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlusButton() {
    return InkWell(
      onTap: () {
        testPrintLS(DiagnosticLog.ui('FamilyScreen', 'invite_plus_tapped'));
        InviteLinkService.invite();
      },
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.redBg,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AppColors.redBg.withValues(alpha: 0.15),
              spreadRadius: 2,
              blurRadius: 5,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        width: 48,
        height: 48,
        child: SvgPicture.asset(
          'assets/svg/plus.svg',
          fit: BoxFit.contain,
          width: 16,
        ),
      ),
    );
  }
}
