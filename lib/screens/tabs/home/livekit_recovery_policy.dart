import 'package:flutter/widgets.dart';

/// Backoff while the app is not in the foreground (background / inactive).
const List<Duration> liveKitBackgroundRecoveryRetryDelays = <Duration>[
  Duration.zero,
  Duration(seconds: 5),
  Duration(seconds: 15),
  Duration(seconds: 30),
  Duration(seconds: 60),
];

/// Shorter backoff when the app is active; pauses sum to 30 seconds.
const List<Duration> liveKitForegroundRecoveryRetryDelays = <Duration>[
  Duration.zero,
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 15),
];

/// Wall-clock cap for foreground auto-retry (connect time is extra).
const Duration liveKitForegroundRecoveryMaxDuration = Duration(seconds: 30);

/// @deprecated Use [liveKitBackgroundRecoveryRetryDelays]. Kept for tests.
const List<Duration> liveKitRecoveryRetryDelays =
    liveKitBackgroundRecoveryRetryDelays;

List<Duration> liveKitRecoveryRetryDelaysFor(AppLifecycleState state) {
  return state == AppLifecycleState.resumed
      ? liveKitForegroundRecoveryRetryDelays
      : liveKitBackgroundRecoveryRetryDelays;
}

bool isLiveKitRecoveryExhausted({
  required AppLifecycleState lifecycleState,
  required int attemptCount,
  DateTime? recoveryStartedAt,
  DateTime? now,
}) {
  final List<Duration> delays = liveKitRecoveryRetryDelaysFor(lifecycleState);
  if (attemptCount >= delays.length) {
    return true;
  }

  if (lifecycleState != AppLifecycleState.resumed) {
    return false;
  }

  final DateTime? startedAt = recoveryStartedAt;
  if (startedAt == null) {
    return false;
  }

  final DateTime clock = now ?? DateTime.now();
  return clock.difference(startedAt) > liveKitForegroundRecoveryMaxDuration;
}
