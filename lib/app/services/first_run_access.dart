import 'package:get_storage/get_storage.dart';

/// Decides what a user without their own subscription may do.
///
/// Rules (first-minute experience, Nov 2026):
/// - Everyone can enter the app, set up a profile and invite family once they
///   tap "Not now" on the paywall ([paywallDeferred]).
/// - People who joined a family through an invite link can talk for free: the
///   person who invited them is expected to hold the plan
///   ([joinedViaInvite]).
/// - Talking or ringing someone without either of the above opens the paywall.
///
/// This is a client-side policy only. A server-side "one plan covers the
/// family" check is a planned follow-up.
class FirstRunAccess {
  FirstRunAccess({GetStorage? box}) : _box = box ?? GetStorage();

  static const String paywallDeferredKey = 'powwow_paywall_deferred_v1';
  static const String joinedViaInviteKey = 'powwow_joined_via_invite_v1';
  static const String pendingInviteRoomKey = 'powwow_pending_invite_room_v1';
  static const String inviteStepSeenKey = 'powwow_invite_step_seen_v1';
  static const String talkSessionsKey = 'powwow_talk_sessions_with_family_v1';
  static const String reviewRequestedKey = 'powwow_review_requested_v1';

  /// Talk sessions (with at least one other family member connected) after
  /// which the system review prompt is requested once.
  static const int reviewPromptAfterSessions = 3;

  final GetStorage _box;

  bool get paywallDeferred => _box.read<bool>(paywallDeferredKey) ?? false;

  Future<void> deferPaywall() => _box.write(paywallDeferredKey, true);

  bool get joinedViaInvite => _box.read<bool>(joinedViaInviteKey) ?? false;

  String? get pendingInviteRoomId {
    final String? value = _box.read<String>(pendingInviteRoomKey);
    if (value == null || value.trim().isEmpty) return null;
    return value;
  }

  /// Records an invite link that was opened before the user reached Home.
  /// An invite to the user's own family ([ownUid]) does not count.
  Future<bool> recordInvite(String roomId, {String? ownUid}) async {
    final String trimmed = roomId.trim();
    if (trimmed.isEmpty || trimmed == ownUid) return false;
    await _box.write(pendingInviteRoomKey, trimmed);
    await _box.write(joinedViaInviteKey, true);
    return true;
  }

  Future<void> clearPendingInvite() => _box.remove(pendingInviteRoomKey);

  bool get inviteStepSeen => _box.read<bool>(inviteStepSeenKey) ?? false;

  Future<void> markInviteStepSeen() => _box.write(inviteStepSeenKey, true);

  /// Whether a user may enter Home.
  bool canEnterApp({required bool hasEntitlement}) {
    return hasEntitlement || paywallDeferred || joinedViaInvite;
  }

  /// Whether a user may talk or ring family members.
  bool canTalk({required bool hasEntitlement}) {
    return hasEntitlement || joinedViaInvite;
  }

  /// Counts a finished talk session and returns true exactly once, when the
  /// review prompt should be requested.
  Future<bool> recordTalkSessionWithFamily() async {
    final int sessions = (_box.read<int>(talkSessionsKey) ?? 0) + 1;
    await _box.write(talkSessionsKey, sessions);
    final bool alreadyRequested = _box.read<bool>(reviewRequestedKey) ?? false;
    if (alreadyRequested || sessions < reviewPromptAfterSessions) {
      return false;
    }
    await _box.write(reviewRequestedKey, true);
    return true;
  }
}
