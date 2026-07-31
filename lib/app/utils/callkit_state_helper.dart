import 'package:flutter/widgets.dart';

/// Returns true when Dart must not reconfigure AVAudioSession because CallKit
/// (or the native CallKit accept UI before foreground) owns the session.
bool shouldSuppressBackgroundWhiteNoise({
  required bool isIOS,
  required bool incomingCallRinging,
  required bool declinedIncomingCallBeforeForeground,
}) {
  if (!isIOS) return false;
  return incomingCallRinging || declinedIncomingCallBeforeForeground;
}

bool shouldDeferIosAudioSessionConfiguration({
  required bool isIOS,
  required bool iosCallkitAudioSessionActive,
  required String? pendingAcceptedCallId,
  required AppLifecycleState appLifecycle,
}) {
  if (!isIOS) return false;
  if (iosCallkitAudioSessionActive) return true;
  if (pendingAcceptedCallId != null &&
      appLifecycle != AppLifecycleState.resumed) {
    return true;
  }
  return false;
}

Map<String, dynamic>? normalizeCallkitCall(dynamic rawCall) {
  if (rawCall is! Map) return null;

  return rawCall.map<String, dynamic>(
    (dynamic key, dynamic value) =>
        MapEntry<String, dynamic>(key.toString(), value),
  );
}

List<Map<String, dynamic>> normalizeActiveCallkitCalls(
  Iterable<dynamic> rawCalls,
) {
  return rawCalls
      .map(normalizeCallkitCall)
      .whereType<Map<String, dynamic>>()
      .toList();
}

bool isAcceptedCallkitCall(Map<String, dynamic> call) {
  final dynamic acceptedValue = call['isAccepted'] ?? call['accepted'];
  return acceptedValue == true;
}

Map<String, dynamic>? findAcceptedCallkitCall(Iterable<dynamic> rawCalls) {
  for (final Map<String, dynamic> call in normalizeActiveCallkitCalls(
    rawCalls,
  )) {
    if (isAcceptedCallkitCall(call)) {
      return call;
    }
  }

  return null;
}

bool hasRingingCallkitCall(Iterable<dynamic> rawCalls) {
  return normalizeActiveCallkitCalls(
    rawCalls,
  ).any((Map<String, dynamic> call) => !isAcceptedCallkitCall(call));
}
