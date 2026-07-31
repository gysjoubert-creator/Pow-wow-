import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:pow_wow/screens/tabs/home/live_kit_controller.dart';
import 'package:pow_wow/screens/tabs/home/livekit_recovery_policy.dart';

void main() {
  group('LiveKit recovery policy', () {
    test('does not retry intentional or terminal app-level disconnects', () {
      expect(
        isRetryableLiveKitDisconnectReason(DisconnectReason.clientInitiated),
        isFalse,
      );
      expect(
        isRetryableLiveKitDisconnectReason(DisconnectReason.participantRemoved),
        isFalse,
      );
      expect(
        isRetryableLiveKitDisconnectReason(DisconnectReason.roomDeleted),
        isFalse,
      );
      expect(
        isRetryableLiveKitDisconnectReason(DisconnectReason.duplicateIdentity),
        isFalse,
      );
      expect(
        isRetryableLiveKitDisconnectReason(DisconnectReason.joinFailure),
        isFalse,
      );
    });

    test('skips zombie disconnect after successful background reconnect', () {
      expect(
        shouldForceDisconnectAfterBackgroundResume(
          hadResumeInBackground: true,
          isConnected: true,
          skipForCallSession: false,
          reconnectedInBackground: false,
          mediaPathFailed: false,
        ),
        isTrue,
      );

      expect(
        shouldForceDisconnectAfterBackgroundResume(
          hadResumeInBackground: true,
          isConnected: true,
          skipForCallSession: false,
          reconnectedInBackground: true,
          mediaPathFailed: false,
        ),
        isFalse,
      );
      expect(
        shouldForceDisconnectAfterBackgroundResume(
          hadResumeInBackground: true,
          isConnected: true,
          skipForCallSession: false,
          reconnectedInBackground: true,
          mediaPathFailed: true,
        ),
        isTrue,
      );
      expect(
        shouldForceDisconnectAfterBackgroundResume(
          hadResumeInBackground: true,
          isConnected: true,
          skipForCallSession: true,
          reconnectedInBackground: false,
          mediaPathFailed: false,
        ),
        isFalse,
      );
    });

    test('detects LiveKit RTC media path errors', () {
      expect(
        isLiveKitRtcMediaPathError(
          "Unable to RTCPeerConnection::addTransceiver: Error: can't addTransceiver!",
        ),
        isTrue,
      );
      expect(isLiveKitRtcMediaPathError('unrelated error'), isFalse);
    });

    test('applies only the latest lifecycle white-noise sync', () {
      expect(
        shouldApplyLifecycleSync(generation: 3, currentGeneration: 3),
        isTrue,
      );
      expect(
        shouldApplyLifecycleSync(generation: 2, currentGeneration: 3),
        isFalse,
      );
    });

    test(
      'recovers white noise on interruption only in listen-only background',
      () {
        expect(
          shouldRecoverBackgroundWhiteNoiseOnInterruptionBegan(
            isAppInForeground: true,
            localMicEnabled: false,
            isSuppressed: false,
          ),
          isFalse,
        );
        expect(
          shouldRecoverBackgroundWhiteNoiseOnInterruptionBegan(
            isAppInForeground: false,
            localMicEnabled: false,
            isSuppressed: false,
          ),
          isTrue,
        );
        expect(
          shouldRecoverBackgroundWhiteNoiseOnInterruptionBegan(
            isAppInForeground: false,
            localMicEnabled: true,
            isSuppressed: false,
          ),
          isFalse,
        );
        expect(
          shouldRecoverBackgroundWhiteNoiseOnInterruptionBegan(
            isAppInForeground: false,
            localMicEnabled: false,
            isSuppressed: true,
          ),
          isFalse,
        );
      },
    );

    test('runs white noise watchdog only in iOS listen-only background', () {
      expect(
        shouldRunBackgroundWhiteNoiseWatchdog(
          isIOS: true,
          isAppInForeground: false,
          localMicEnabled: false,
          isSuppressed: false,
        ),
        isTrue,
      );
      expect(
        shouldRunBackgroundWhiteNoiseWatchdog(
          isIOS: false,
          isAppInForeground: false,
          localMicEnabled: false,
          isSuppressed: false,
        ),
        isFalse,
      );
      expect(
        shouldRunBackgroundWhiteNoiseWatchdog(
          isIOS: true,
          isAppInForeground: true,
          localMicEnabled: false,
          isSuppressed: false,
        ),
        isFalse,
      );
      expect(
        shouldRunBackgroundWhiteNoiseWatchdog(
          isIOS: true,
          isAppInForeground: false,
          localMicEnabled: true,
          isSuppressed: false,
        ),
        isFalse,
      );
      expect(
        shouldRunBackgroundWhiteNoiseWatchdog(
          isIOS: true,
          isAppInForeground: false,
          localMicEnabled: false,
          isSuppressed: true,
        ),
        isFalse,
      );
    });

    test('retries connection loss reasons with bounded backoff', () {
      expect(
        isRetryableLiveKitDisconnectReason(
          DisconnectReason.reconnectAttemptsExceeded,
        ),
        isTrue,
      );
      expect(
        isRetryableLiveKitDisconnectReason(DisconnectReason.disconnected),
        isTrue,
      );
      expect(
        isRetryableLiveKitDisconnectReason(
          DisconnectReason.signalingConnectionFailure,
        ),
        isTrue,
      );
      expect(isRetryableLiveKitDisconnectReason(null), isTrue);

      expect(liveKitBackgroundRecoveryRetryDelays, const <Duration>[
        Duration.zero,
        Duration(seconds: 5),
        Duration(seconds: 15),
        Duration(seconds: 30),
        Duration(seconds: 60),
      ]);
    });

    test('uses shorter foreground backoff totaling 30 seconds', () {
      expect(liveKitForegroundRecoveryRetryDelays, const <Duration>[
        Duration.zero,
        Duration(seconds: 5),
        Duration(seconds: 10),
        Duration(seconds: 15),
      ]);

      final int pauseMs = liveKitForegroundRecoveryRetryDelays
          .map((Duration delay) => delay.inMilliseconds)
          .fold<int>(0, (int sum, int value) => sum + value);
      expect(pauseMs, 30000);
    });

    test('selects delays by lifecycle', () {
      expect(
        liveKitRecoveryRetryDelaysFor(AppLifecycleState.resumed),
        liveKitForegroundRecoveryRetryDelays,
      );
      expect(
        liveKitRecoveryRetryDelaysFor(AppLifecycleState.paused),
        liveKitBackgroundRecoveryRetryDelays,
      );
    });

    test('isLiveKitRecoveryExhausted respects attempt count', () {
      expect(
        isLiveKitRecoveryExhausted(
          lifecycleState: AppLifecycleState.resumed,
          attemptCount: 3,
          recoveryStartedAt: DateTime.utc(2026, 1, 1),
          now: DateTime.utc(2026, 1, 1, 0, 0, 10),
        ),
        isFalse,
      );
      expect(
        isLiveKitRecoveryExhausted(
          lifecycleState: AppLifecycleState.resumed,
          attemptCount: 4,
          recoveryStartedAt: DateTime.utc(2026, 1, 1),
          now: DateTime.utc(2026, 1, 1, 0, 0, 10),
        ),
        isTrue,
      );
      expect(
        isLiveKitRecoveryExhausted(
          lifecycleState: AppLifecycleState.paused,
          attemptCount: 4,
          recoveryStartedAt: DateTime.utc(2026, 1, 1),
          now: DateTime.utc(2026, 1, 1, 0, 0, 10),
        ),
        isFalse,
      );
    });

    test('isLiveKitRecoveryExhausted respects foreground wall clock', () {
      final DateTime startedAt = DateTime.utc(2026, 1, 1);
      final DateTime afterBudget = startedAt.add(
        liveKitForegroundRecoveryMaxDuration + const Duration(seconds: 1),
      );

      expect(
        isLiveKitRecoveryExhausted(
          lifecycleState: AppLifecycleState.resumed,
          attemptCount: 1,
          recoveryStartedAt: startedAt,
          now: afterBudget,
        ),
        isTrue,
      );
    });
  });
}
