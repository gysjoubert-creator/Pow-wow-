enum CallSessionPhase {
  idle,
  ringing,
  connecting,
  connected,
  recovering,
  failed,
  ended,
}

enum CallSessionOrigin { none, autoJoin, incomingCall, manualRetry, recovery }

const Object _unchanged = Object();

final class CallSessionSnapshot {
  const CallSessionSnapshot({
    this.phase = CallSessionPhase.idle,
    this.origin = CallSessionOrigin.none,
    this.callkitCallId,
    this.pendingAcceptedCallEnableMic = false,
    this.callkitAudioSessionActive = false,
    this.declinedBeforeForeground = false,
    this.cleanupPending = false,
  });

  static const CallSessionSnapshot idle = CallSessionSnapshot();

  final CallSessionPhase phase;
  final CallSessionOrigin origin;
  final String? callkitCallId;
  final bool pendingAcceptedCallEnableMic;
  final bool callkitAudioSessionActive;
  final bool declinedBeforeForeground;
  final bool cleanupPending;

  CallSessionSnapshot copyWith({
    CallSessionPhase? phase,
    CallSessionOrigin? origin,
    Object? callkitCallId = _unchanged,
    bool? pendingAcceptedCallEnableMic,
    bool? callkitAudioSessionActive,
    bool? declinedBeforeForeground,
    bool? cleanupPending,
  }) {
    return CallSessionSnapshot(
      phase: phase ?? this.phase,
      origin: origin ?? this.origin,
      callkitCallId: identical(callkitCallId, _unchanged)
          ? this.callkitCallId
          : callkitCallId as String?,
      pendingAcceptedCallEnableMic:
          pendingAcceptedCallEnableMic ?? this.pendingAcceptedCallEnableMic,
      callkitAudioSessionActive:
          callkitAudioSessionActive ?? this.callkitAudioSessionActive,
      declinedBeforeForeground:
          declinedBeforeForeground ?? this.declinedBeforeForeground,
      cleanupPending: cleanupPending ?? this.cleanupPending,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is CallSessionSnapshot &&
            phase == other.phase &&
            origin == other.origin &&
            callkitCallId == other.callkitCallId &&
            pendingAcceptedCallEnableMic ==
                other.pendingAcceptedCallEnableMic &&
            callkitAudioSessionActive == other.callkitAudioSessionActive &&
            declinedBeforeForeground == other.declinedBeforeForeground &&
            cleanupPending == other.cleanupPending;
  }

  @override
  int get hashCode => Object.hash(
    phase,
    origin,
    callkitCallId,
    pendingAcceptedCallEnableMic,
    callkitAudioSessionActive,
    declinedBeforeForeground,
    cleanupPending,
  );

  @override
  String toString() {
    return 'CallSessionSnapshot('
        'phase: $phase, '
        'origin: $origin, '
        'callkitCallId: $callkitCallId, '
        'pendingAcceptedCallEnableMic: $pendingAcceptedCallEnableMic, '
        'callkitAudioSessionActive: $callkitAudioSessionActive, '
        'declinedBeforeForeground: $declinedBeforeForeground, '
        'cleanupPending: $cleanupPending'
        ')';
  }
}

final class CallSessionDiagnosticFlags {
  const CallSessionDiagnosticFlags({
    required this.pendingCallAccept,
    required this.pendingAcceptedCallId,
    required this.pendingAcceptedCallEnableMic,
    required this.incomingCallRinging,
    required this.iosCallkitAudioSessionActive,
    required this.iosDeclinedIncomingCallBeforeForeground,
  });

  factory CallSessionDiagnosticFlags.fromSnapshot(
    CallSessionSnapshot snapshot,
  ) {
    final bool hasPendingAcceptedCall =
        snapshot.origin == CallSessionOrigin.incomingCall &&
        snapshot.phase == CallSessionPhase.connecting;
    final bool incomingCallRinging =
        snapshot.origin == CallSessionOrigin.incomingCall &&
        snapshot.phase == CallSessionPhase.ringing;
    final String? pendingAcceptedCallId =
        snapshot.origin == CallSessionOrigin.incomingCall &&
            snapshot.phase != CallSessionPhase.idle &&
            snapshot.phase != CallSessionPhase.ringing &&
            snapshot.phase != CallSessionPhase.ended
        ? snapshot.callkitCallId
        : null;

    return CallSessionDiagnosticFlags(
      pendingCallAccept: hasPendingAcceptedCall,
      pendingAcceptedCallId: pendingAcceptedCallId,
      pendingAcceptedCallEnableMic:
          hasPendingAcceptedCall && snapshot.pendingAcceptedCallEnableMic,
      incomingCallRinging: incomingCallRinging,
      iosCallkitAudioSessionActive: snapshot.callkitAudioSessionActive,
      iosDeclinedIncomingCallBeforeForeground:
          snapshot.declinedBeforeForeground,
    );
  }

  final bool pendingCallAccept;
  final String? pendingAcceptedCallId;
  final bool pendingAcceptedCallEnableMic;
  final bool incomingCallRinging;
  final bool iosCallkitAudioSessionActive;
  final bool iosDeclinedIncomingCallBeforeForeground;
}

final class CallSessionCoordinator {
  CallSessionCoordinator({
    CallSessionSnapshot initialSnapshot = CallSessionSnapshot.idle,
  }) : _snapshot = initialSnapshot;

  CallSessionSnapshot _snapshot;

  CallSessionSnapshot get snapshot => _snapshot;
  CallSessionPhase get phase => _snapshot.phase;
  CallSessionOrigin get origin => _snapshot.origin;
  CallSessionDiagnosticFlags get diagnosticFlags =>
      CallSessionDiagnosticFlags.fromSnapshot(_snapshot);

  bool get hasPendingAcceptedCall =>
      _snapshot.origin == CallSessionOrigin.incomingCall &&
      _snapshot.phase == CallSessionPhase.connecting;

  bool get isIncomingCallRinging =>
      _snapshot.origin == CallSessionOrigin.incomingCall &&
      _snapshot.phase == CallSessionPhase.ringing;

  bool get callkitAudioSessionActive => _snapshot.callkitAudioSessionActive;

  bool get declinedBeforeForeground => _snapshot.declinedBeforeForeground;

  bool get shouldBlockTribeAutoConnect =>
      hasPendingAcceptedCall ||
      isIncomingCallRinging ||
      _snapshot.declinedBeforeForeground;

  bool get shouldSkipZombieDisconnectOnResume =>
      hasPendingAcceptedCall ||
      isIncomingCallRinging ||
      _snapshot.callkitCallId != null ||
      _snapshot.callkitAudioSessionActive;

  bool get shouldEnableMicForAcceptedCall =>
      hasPendingAcceptedCall && _snapshot.pendingAcceptedCallEnableMic;

  bool get shouldApplyCallkitInitialReceiverOutput =>
      _snapshot.callkitAudioSessionActive || acceptedCallId != null;

  String? get acceptedCallId {
    if (_snapshot.origin != CallSessionOrigin.incomingCall) return null;
    if (_snapshot.phase == CallSessionPhase.idle ||
        _snapshot.phase == CallSessionPhase.ringing ||
        _snapshot.phase == CallSessionPhase.ended) {
      return null;
    }
    return _snapshot.callkitCallId;
  }

  void reset() {
    _snapshot = CallSessionSnapshot.idle;
  }

  void incomingCallRinging({String? callkitCallId}) {
    _snapshot = CallSessionSnapshot(
      phase: CallSessionPhase.ringing,
      origin: CallSessionOrigin.incomingCall,
      callkitCallId: callkitCallId,
    );
  }

  void incomingCallAccepted({
    String? callkitCallId,
    required bool enableMic,
    bool cleanupPending = true,
  }) {
    _snapshot = CallSessionSnapshot(
      phase: CallSessionPhase.connecting,
      origin: CallSessionOrigin.incomingCall,
      callkitCallId: callkitCallId,
      pendingAcceptedCallEnableMic: enableMic,
      cleanupPending: cleanupPending,
    );
  }

  void autoJoinStarted() {
    _snapshot = const CallSessionSnapshot(
      phase: CallSessionPhase.connecting,
      origin: CallSessionOrigin.autoJoin,
    );
  }

  void manualRetryStarted() {
    _snapshot = const CallSessionSnapshot(
      phase: CallSessionPhase.connecting,
      origin: CallSessionOrigin.manualRetry,
    );
  }

  void recoveryStarted() {
    _snapshot = const CallSessionSnapshot(
      phase: CallSessionPhase.recovering,
      origin: CallSessionOrigin.recovery,
    );
  }

  void connected() {
    _snapshot = _snapshot.copyWith(
      phase: CallSessionPhase.connected,
      pendingAcceptedCallEnableMic: false,
      declinedBeforeForeground: false,
    );
  }

  void failed() {
    _snapshot = _snapshot.copyWith(
      phase: CallSessionPhase.failed,
      pendingAcceptedCallEnableMic: false,
    );
  }

  void ended() {
    _snapshot = const CallSessionSnapshot(
      phase: CallSessionPhase.ended,
      origin: CallSessionOrigin.none,
    );
  }

  void incomingCallDeclined({required bool beforeForeground}) {
    _snapshot = CallSessionSnapshot(
      phase: CallSessionPhase.ended,
      origin: CallSessionOrigin.incomingCall,
      declinedBeforeForeground: beforeForeground,
    );
  }

  void clearDeclinedBeforeForeground() {
    _snapshot = _snapshot.copyWith(declinedBeforeForeground: false);
  }

  void callkitAudioSessionToggled(bool active) {
    _snapshot = _snapshot.copyWith(callkitAudioSessionActive: active);
  }

  void callkitCleanupStarted() {
    _snapshot = _snapshot.copyWith(callkitCallId: null, cleanupPending: true);
  }

  void callkitCleanupCompleted() {
    _snapshot = _snapshot.copyWith(
      callkitCallId: null,
      pendingAcceptedCallEnableMic: false,
      callkitAudioSessionActive: false,
      cleanupPending: false,
    );
  }
}
