import 'package:flutter_test/flutter_test.dart';
import 'package:pow_wow/app/services/call_session_coordinator.dart';

void main() {
  group('CallSessionCoordinator', () {
    test('starts with an idle immutable snapshot', () {
      final coordinator = CallSessionCoordinator();

      expect(coordinator.snapshot, CallSessionSnapshot.idle);
      expect(coordinator.phase, CallSessionPhase.idle);
      expect(coordinator.origin, CallSessionOrigin.none);
      expect(coordinator.hasPendingAcceptedCall, isFalse);
      expect(coordinator.shouldBlockTribeAutoConnect, isFalse);
      expect(coordinator.shouldSkipZombieDisconnectOnResume, isFalse);
      expect(coordinator.shouldEnableMicForAcceptedCall, isFalse);
      expect(coordinator.acceptedCallId, isNull);
    });

    test('ringing incoming call blocks auto-connect and zombie disconnect', () {
      final coordinator = CallSessionCoordinator();

      coordinator.incomingCallRinging(callkitCallId: 'ringing-call');

      expect(coordinator.phase, CallSessionPhase.ringing);
      expect(coordinator.origin, CallSessionOrigin.incomingCall);
      expect(coordinator.snapshot.callkitCallId, 'ringing-call');
      expect(coordinator.hasPendingAcceptedCall, isFalse);
      expect(coordinator.shouldBlockTribeAutoConnect, isTrue);
      expect(coordinator.shouldSkipZombieDisconnectOnResume, isTrue);
      expect(coordinator.shouldEnableMicForAcceptedCall, isFalse);
      expect(coordinator.acceptedCallId, isNull);
    });

    test('accepted incoming call exposes pending state and mic intent', () {
      final coordinator = CallSessionCoordinator();

      coordinator.incomingCallAccepted(
        callkitCallId: 'accepted-call',
        enableMic: true,
      );

      expect(coordinator.phase, CallSessionPhase.connecting);
      expect(coordinator.origin, CallSessionOrigin.incomingCall);
      expect(coordinator.snapshot.callkitCallId, 'accepted-call');
      expect(coordinator.snapshot.cleanupPending, isTrue);
      expect(coordinator.hasPendingAcceptedCall, isTrue);
      expect(coordinator.shouldBlockTribeAutoConnect, isTrue);
      expect(coordinator.shouldSkipZombieDisconnectOnResume, isTrue);
      expect(coordinator.shouldEnableMicForAcceptedCall, isTrue);
      expect(coordinator.acceptedCallId, 'accepted-call');
    });

    test(
      'connected consumes pending accepted mic flag but keeps cleanup id',
      () {
        final coordinator = CallSessionCoordinator()
          ..incomingCallAccepted(
            callkitCallId: 'accepted-call',
            enableMic: true,
          );

        coordinator.connected();

        expect(coordinator.phase, CallSessionPhase.connected);
        expect(coordinator.origin, CallSessionOrigin.incomingCall);
        expect(coordinator.hasPendingAcceptedCall, isFalse);
        expect(coordinator.shouldBlockTribeAutoConnect, isFalse);
        expect(coordinator.shouldEnableMicForAcceptedCall, isFalse);
        expect(coordinator.acceptedCallId, 'accepted-call');
        expect(coordinator.shouldSkipZombieDisconnectOnResume, isTrue);
      },
    );

    test('callkit cleanup completion clears accepted id and audio state', () {
      final coordinator = CallSessionCoordinator()
        ..incomingCallAccepted(callkitCallId: 'accepted-call', enableMic: true)
        ..callkitAudioSessionToggled(true)
        ..connected();

      coordinator.callkitCleanupCompleted();

      expect(coordinator.phase, CallSessionPhase.connected);
      expect(coordinator.origin, CallSessionOrigin.incomingCall);
      expect(coordinator.snapshot.callkitCallId, isNull);
      expect(coordinator.snapshot.cleanupPending, isFalse);
      expect(coordinator.snapshot.pendingAcceptedCallEnableMic, isFalse);
      expect(coordinator.snapshot.callkitAudioSessionActive, isFalse);
      expect(coordinator.acceptedCallId, isNull);
      expect(coordinator.shouldSkipZombieDisconnectOnResume, isFalse);
    });

    test('decline before foreground blocks auto-connect until cleared', () {
      final coordinator = CallSessionCoordinator();

      coordinator.incomingCallDeclined(beforeForeground: true);

      expect(coordinator.phase, CallSessionPhase.ended);
      expect(coordinator.origin, CallSessionOrigin.incomingCall);
      expect(coordinator.snapshot.declinedBeforeForeground, isTrue);
      expect(coordinator.shouldBlockTribeAutoConnect, isTrue);
      expect(coordinator.shouldSkipZombieDisconnectOnResume, isFalse);

      coordinator.clearDeclinedBeforeForeground();

      expect(coordinator.snapshot.declinedBeforeForeground, isFalse);
      expect(coordinator.shouldBlockTribeAutoConnect, isFalse);
    });

    test('decline after foreground does not block auto-connect', () {
      final coordinator = CallSessionCoordinator();

      coordinator.incomingCallDeclined(beforeForeground: false);

      expect(coordinator.phase, CallSessionPhase.ended);
      expect(coordinator.snapshot.declinedBeforeForeground, isFalse);
      expect(coordinator.shouldBlockTribeAutoConnect, isFalse);
      expect(coordinator.shouldSkipZombieDisconnectOnResume, isFalse);
    });

    test('failed keeps cleanup id and ended clears session context', () {
      final coordinator = CallSessionCoordinator()
        ..incomingCallAccepted(callkitCallId: 'accepted-call', enableMic: true);

      coordinator.failed();

      expect(coordinator.phase, CallSessionPhase.failed);
      expect(coordinator.hasPendingAcceptedCall, isFalse);
      expect(coordinator.shouldEnableMicForAcceptedCall, isFalse);
      expect(coordinator.acceptedCallId, 'accepted-call');
      expect(coordinator.shouldSkipZombieDisconnectOnResume, isTrue);

      coordinator.ended();

      expect(coordinator.phase, CallSessionPhase.ended);
      expect(coordinator.origin, CallSessionOrigin.none);
      expect(coordinator.snapshot.callkitCallId, isNull);
      expect(coordinator.acceptedCallId, isNull);
      expect(coordinator.shouldSkipZombieDisconnectOnResume, isFalse);
    });

    test('audio session active skips zombie disconnect on resume', () {
      final coordinator = CallSessionCoordinator();

      coordinator.callkitAudioSessionToggled(true);

      expect(coordinator.shouldSkipZombieDisconnectOnResume, isTrue);

      coordinator.callkitAudioSessionToggled(false);

      expect(coordinator.shouldSkipZombieDisconnectOnResume, isFalse);
    });

    test('non-callkit transitions clear incoming call context', () {
      final coordinator = CallSessionCoordinator()
        ..incomingCallAccepted(callkitCallId: 'accepted-call', enableMic: true);

      coordinator.manualRetryStarted();

      expect(coordinator.phase, CallSessionPhase.connecting);
      expect(coordinator.origin, CallSessionOrigin.manualRetry);
      expect(coordinator.snapshot.callkitCallId, isNull);
      expect(coordinator.hasPendingAcceptedCall, isFalse);
      expect(coordinator.shouldBlockTribeAutoConnect, isFalse);
      expect(coordinator.shouldSkipZombieDisconnectOnResume, isFalse);

      coordinator.recoveryStarted();

      expect(coordinator.phase, CallSessionPhase.recovering);
      expect(coordinator.origin, CallSessionOrigin.recovery);

      coordinator.autoJoinStarted();

      expect(coordinator.phase, CallSessionPhase.connecting);
      expect(coordinator.origin, CallSessionOrigin.autoJoin);
    });

    test('terminal updates preserve non-incoming connection origin', () {
      final coordinator = CallSessionCoordinator();

      coordinator.autoJoinStarted();
      coordinator.connected();

      expect(coordinator.phase, CallSessionPhase.connected);
      expect(coordinator.origin, CallSessionOrigin.autoJoin);

      coordinator.manualRetryStarted();
      coordinator.failed();

      expect(coordinator.phase, CallSessionPhase.failed);
      expect(coordinator.origin, CallSessionOrigin.manualRetry);

      coordinator.recoveryStarted();
      coordinator.failed();

      expect(coordinator.phase, CallSessionPhase.failed);
      expect(coordinator.origin, CallSessionOrigin.recovery);
    });

    test('reset returns to the idle baseline', () {
      final coordinator = CallSessionCoordinator()
        ..incomingCallAccepted(callkitCallId: 'accepted-call', enableMic: true)
        ..callkitAudioSessionToggled(true);

      coordinator.reset();

      expect(coordinator.snapshot, CallSessionSnapshot.idle);
    });
  });

  group('CallSessionDiagnosticFlags', () {
    test('mirrors incoming ringing snapshot to diagnostic flags', () {
      final coordinator = CallSessionCoordinator()
        ..incomingCallRinging(callkitCallId: 'ringing-call');

      final flags = CallSessionDiagnosticFlags.fromSnapshot(
        coordinator.snapshot,
      );

      expect(flags.incomingCallRinging, isTrue);
      expect(flags.pendingCallAccept, isFalse);
      expect(flags.pendingAcceptedCallId, isNull);
      expect(flags.pendingAcceptedCallEnableMic, isFalse);
      expect(flags.iosCallkitAudioSessionActive, isFalse);
      expect(flags.iosDeclinedIncomingCallBeforeForeground, isFalse);
    });

    test('mirrors accepted incoming snapshot to diagnostic flags', () {
      final coordinator = CallSessionCoordinator()
        ..incomingCallAccepted(callkitCallId: 'accepted-call', enableMic: true);

      final flags = CallSessionDiagnosticFlags.fromSnapshot(
        coordinator.snapshot,
      );

      expect(flags.incomingCallRinging, isFalse);
      expect(flags.pendingCallAccept, isTrue);
      expect(flags.pendingAcceptedCallId, 'accepted-call');
      expect(flags.pendingAcceptedCallEnableMic, isTrue);
      expect(flags.iosCallkitAudioSessionActive, isFalse);
      expect(flags.iosDeclinedIncomingCallBeforeForeground, isFalse);
    });

    test('mirrors declined incoming snapshot to diagnostic flags', () {
      final coordinator = CallSessionCoordinator()
        ..incomingCallDeclined(beforeForeground: true);

      final flags = CallSessionDiagnosticFlags.fromSnapshot(
        coordinator.snapshot,
      );

      expect(flags.incomingCallRinging, isFalse);
      expect(flags.pendingCallAccept, isFalse);
      expect(flags.pendingAcceptedCallId, isNull);
      expect(flags.pendingAcceptedCallEnableMic, isFalse);
      expect(flags.iosCallkitAudioSessionActive, isFalse);
      expect(flags.iosDeclinedIncomingCallBeforeForeground, isTrue);
    });

    test('mirrors audio session active and inactive snapshots', () {
      final coordinator = CallSessionCoordinator()
        ..incomingCallAccepted(callkitCallId: 'accepted-call', enableMic: false)
        ..callkitAudioSessionToggled(true);

      final activeFlags = CallSessionDiagnosticFlags.fromSnapshot(
        coordinator.snapshot,
      );
      expect(activeFlags.iosCallkitAudioSessionActive, isTrue);

      coordinator.callkitAudioSessionToggled(false);

      final inactiveFlags = CallSessionDiagnosticFlags.fromSnapshot(
        coordinator.snapshot,
      );
      expect(inactiveFlags.iosCallkitAudioSessionActive, isFalse);
      expect(inactiveFlags.pendingCallAccept, isTrue);
      expect(inactiveFlags.pendingAcceptedCallId, 'accepted-call');
    });

    test('mirrors cleanup completed snapshot to diagnostic flags', () {
      final coordinator = CallSessionCoordinator()
        ..incomingCallAccepted(callkitCallId: 'accepted-call', enableMic: true)
        ..callkitAudioSessionToggled(true)
        ..callkitCleanupCompleted();

      final flags = CallSessionDiagnosticFlags.fromSnapshot(
        coordinator.snapshot,
      );

      expect(flags.pendingCallAccept, isTrue);
      expect(flags.pendingAcceptedCallId, isNull);
      expect(flags.pendingAcceptedCallEnableMic, isFalse);
      expect(flags.incomingCallRinging, isFalse);
      expect(flags.iosCallkitAudioSessionActive, isFalse);
      expect(flags.iosDeclinedIncomingCallBeforeForeground, isFalse);
    });
  });
}
