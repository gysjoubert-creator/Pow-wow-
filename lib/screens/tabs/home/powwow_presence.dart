import '../../../app/data/enums/tribe_member_status.dart';

/// App-level soft presence over LiveKit data messages.
abstract final class PowWowPresence {
  static const String topic = 'powwow.presence';
  static const Duration heartbeatInterval = Duration(seconds: 2);
  static const Duration staleThreshold = Duration(seconds: 5);
  static const Duration connectGracePeriod = Duration(seconds: 5);
  static const Duration staleCheckInterval = Duration(seconds: 1);
  static const List<int> heartbeatPayload = <int>[0x01];
}

/// Presence status for a remote participant in the LiveKit room.
CallMemberStatus remotePresenceStatus({
  required DateTime now,
  required bool isInRemoteParticipants,
  required DateTime? lastHeartbeatAt,
  required DateTime? participantConnectedAt,
}) {
  if (!isInRemoteParticipants) {
    return CallMemberStatus.silent;
  }

  if (lastHeartbeatAt != null) {
    final Duration age = now.difference(lastHeartbeatAt);
    if (age <= PowWowPresence.staleThreshold) {
      return CallMemberStatus.listening;
    }
    return CallMemberStatus.silent;
  }

  if (participantConnectedAt != null) {
    final Duration sinceConnect = now.difference(participantConnectedAt);
    if (sinceConnect <= PowWowPresence.connectGracePeriod) {
      return CallMemberStatus.listening;
    }
  }

  return CallMemberStatus.silent;
}
