import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app/routes/app_routes.dart';
import '../../app/services/firebase/auth_service.dart';
import '../../app/services/first_run_access.dart';
import '../../app/services/first_run_router.dart';
import '../../app/services/invite_link_service.dart';
import '../../app/theme.dart';
import '../../main.dart';

/// Shown once, straight after a new profile is created: Pow Wow is only
/// useful once a second family member joins, so inviting comes first.
class InviteFamilyScreen extends StatefulWidget {
  const InviteFamilyScreen({super.key});

  @override
  State<InviteFamilyScreen> createState() => _InviteFamilyScreenState();
}

class _InviteFamilyScreenState extends State<InviteFamilyScreen> {
  final InviteLinkService _inviteLinkService = InviteLinkService();
  bool _isBusy = false;

  @override
  void initState() {
    super.initState();
    // Someone who installed from an invite and taps the link again lands here.
    _inviteLinkService.startListening(
      onRoomReceived: (String roomId) {
        unawaited(
          handleInviteBeforeHome(roomId, ownUid: Get.find<AuthService>().uid),
        );
      },
    );
  }

  @override
  void dispose() {
    unawaited(_inviteLinkService.dispose());
    super.dispose();
  }

  Future<void> _sendInvite() async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    testPrintLS('InviteFamilyScreen:: send_invite_tapped');
    await InviteLinkService.invite();
    await _continue(source: 'invite_sent');
  }

  Future<void> _continue({required String source}) async {
    testPrintLS('InviteFamilyScreen:: continue source=$source');
    await FirstRunAccess().markInviteStepSeen();
    if (!mounted) return;
    Get.offAllNamed(
      AppRoutes.subscription,
      arguments: const <String, bool>{'blockingPaywall': true},
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.greyBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Who do you want\nto reach?',
                key: const ValueKey<String>('invite_family_title'),
                style: AppTextStyle.mainBold.copyWith(
                  fontSize: 32,
                  height: 1.08,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Pow Wow works once your family is in. Send them a link: '
                'it\'s free for the people you invite.',
                style: AppTextStyle.mainRegular.copyWith(
                  color: AppColors.blackText3,
                  fontSize: 17,
                  height: 1.35,
                ),
              ),
              Expanded(
                child: Center(
                  child: Image.asset(
                    'assets/png/onboarding_invite.png',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              SizedBox(
                width: double.infinity,
                height: 62,
                child: ElevatedButton(
                  key: const ValueKey<String>('invite_family_send'),
                  onPressed: _isBusy ? null : _sendInvite,
                  style: ElevatedButton.styleFrom(
                    elevation: 0,
                    backgroundColor: AppColors.orangeBg,
                    foregroundColor: AppColors.whiteText,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    'Invite my family',
                    style: AppTextStyle.mainBold.copyWith(
                      color: AppColors.whiteText,
                      fontSize: 19,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  key: const ValueKey<String>('invite_family_later'),
                  onPressed: _isBusy
                      ? null
                      : () => _continue(source: 'later_tapped'),
                  child: Text(
                    'I\'ll do it later',
                    style: AppTextStyle.mainSemibold.copyWith(
                      color: AppColors.blackText3,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
