import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:pow_wow/app/services/firebase/auth_service.dart';
import 'package:pow_wow/main.dart';
import 'package:get/get.dart';
import 'package:share_plus/share_plus.dart';

import '../data/models/user_profile.dart';

class InviteLinkService {
  InviteLinkService();

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;

  Future<String?> getInitalTribeId() async {
    final uri = await _appLinks.getInitialLink();
    if (uri != null) {
      return _parseRoomId(uri);
    }
    return null;
  }

  void startListening({required void Function(String roomId) onRoomReceived}) {
    _sub = _appLinks.uriLinkStream.listen((Uri uri) {
      final String? roomId = _parseRoomId(uri);
      if (roomId != null && roomId.isNotEmpty) {
        testPrintLS('InviteLinkService:: onRoomReceived: $roomId');
        onRoomReceived(roomId);
      }
    });
  }

  String? _parseRoomId(Uri uri) {
    return uri.queryParameters['roomId'];
  }

  Future<void> dispose() async {
    await _sub?.cancel();
  }

  static const String _inviteBaseUrl =
      'https://trtpost.github.io/powwow-invite/';

  static Future<void> shareInvite({required String roomId}) async {
    final String link = '$_inviteBaseUrl?roomId=$roomId';

    await SharePlus.instance.share(
      ShareParams(
        text: 'Join my PowWow tribe:\n$link',
        subject: 'PowWow Invite',
      ),
    );
  }

  static Future<bool> invite() async {
    UserProfile? profile;
    if (Get.isRegistered<AuthService>()) {
      profile = Get.find<AuthService>().myProfile;
    }

    if (profile == null) return false;

    try {
      await InviteLinkService.shareInvite(roomId: profile.tribeId);
      return true;
    } catch (e) {
      testPrintLS('ILS:: [Invite] ❌ Error sharing invite: $e');
      return false;
    }
  }
}
