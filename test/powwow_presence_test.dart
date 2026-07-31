import 'package:flutter_test/flutter_test.dart';
import 'package:pow_wow/app/data/enums/tribe_member_status.dart';
import 'package:pow_wow/screens/tabs/home/powwow_presence.dart';

void main() {
  group('remotePresenceStatus', () {
    final DateTime now = DateTime(2026, 5, 18, 12, 0, 0);

    test('returns silent when participant is not in remote participants', () {
      expect(
        remotePresenceStatus(
          now: now,
          isInRemoteParticipants: false,
          lastHeartbeatAt: now,
          participantConnectedAt: now,
        ),
        CallMemberStatus.silent,
      );
    });

    test('returns listening when heartbeat is fresh', () {
      expect(
        remotePresenceStatus(
          now: now,
          isInRemoteParticipants: true,
          lastHeartbeatAt: now.subtract(const Duration(seconds: 4)),
          participantConnectedAt: now.subtract(const Duration(minutes: 1)),
        ),
        CallMemberStatus.listening,
      );
    });

    test('returns silent when heartbeat is older than stale threshold', () {
      expect(
        remotePresenceStatus(
          now: now,
          isInRemoteParticipants: true,
          lastHeartbeatAt: now.subtract(const Duration(seconds: 6)),
          participantConnectedAt: now.subtract(const Duration(minutes: 1)),
        ),
        CallMemberStatus.silent,
      );
    });

    test('returns listening during connect grace before first heartbeat', () {
      expect(
        remotePresenceStatus(
          now: now,
          isInRemoteParticipants: true,
          lastHeartbeatAt: null,
          participantConnectedAt: now.subtract(const Duration(seconds: 4)),
        ),
        CallMemberStatus.listening,
      );
    });

    test('returns silent after connect grace expires without heartbeat', () {
      expect(
        remotePresenceStatus(
          now: now,
          isInRemoteParticipants: true,
          lastHeartbeatAt: null,
          participantConnectedAt: now.subtract(const Duration(seconds: 6)),
        ),
        CallMemberStatus.silent,
      );
    });

    test('prefers stale heartbeat over connect grace', () {
      expect(
        remotePresenceStatus(
          now: now,
          isInRemoteParticipants: true,
          lastHeartbeatAt: now.subtract(const Duration(seconds: 6)),
          participantConnectedAt: now,
        ),
        CallMemberStatus.silent,
      );
    });
  });
}
