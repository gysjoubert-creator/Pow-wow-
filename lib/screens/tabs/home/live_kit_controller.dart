import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../app/data/enums/tribe_member_status.dart';
import '../../../app/services/background_white_noise_service.dart';
import '../../../app/utils/bootstrap_error_helper.dart';
import '../../../app/utils/callkit_state_helper.dart';
import '../../../main.dart';
import '../../../test_screen/test_log_helper.dart';
import 'powwow_presence.dart';

bool isRetryableLiveKitDisconnectReason(DisconnectReason? reason) {
  switch (reason) {
    case DisconnectReason.clientInitiated:
    case DisconnectReason.participantRemoved:
    case DisconnectReason.roomDeleted:
    case DisconnectReason.duplicateIdentity:
    case DisconnectReason.joinFailure:
      return false;
    case DisconnectReason.reconnectAttemptsExceeded:
    case DisconnectReason.disconnected:
    case DisconnectReason.signalingConnectionFailure:
    case DisconnectReason.stateMismatch:
    case DisconnectReason.serverShutdown:
    case DisconnectReason.unknown:
    case null:
      return true;
  }
}

bool shouldForceDisconnectAfterBackgroundResume({
  required bool hadResumeInBackground,
  required bool isConnected,
  required bool skipForCallSession,
  required bool reconnectedInBackground,
  required bool mediaPathFailed,
}) {
  return hadResumeInBackground &&
      isConnected &&
      !skipForCallSession &&
      (!reconnectedInBackground || mediaPathFailed);
}

bool shouldRecoverBackgroundWhiteNoiseOnInterruptionBegan({
  required bool isAppInForeground,
  required bool localMicEnabled,
  required bool isSuppressed,
}) {
  return !isAppInForeground && !localMicEnabled && !isSuppressed;
}

bool shouldRunBackgroundWhiteNoiseWatchdog({
  required bool isIOS,
  required bool isAppInForeground,
  required bool localMicEnabled,
  required bool isSuppressed,
}) {
  return isIOS && !isAppInForeground && !localMicEnabled && !isSuppressed;
}

bool isLiveKitRtcMediaPathError(Object error) {
  final String message = error.toString();
  return message.contains('RTCPeerConnection::addTransceiver') ||
      message.contains("can't addTransceiver");
}

bool shouldApplyLifecycleSync({
  required int generation,
  required int currentGeneration,
}) {
  return generation == currentGeneration;
}

class LiveKitController {
  final VoidCallback? _onUpdate;
  final bool Function(DisconnectReason? reason)? _onUnexpectedDisconnect;

  final Room _room = Room(
    roomOptions: const RoomOptions(
      // Default is true: mute() stops the mic track; next unmute() restarts capture (slow).
      // For push-to-talk, keep capture alive while muted so unmute is instant.
      defaultAudioCaptureOptions: AudioCaptureOptions(
        stopAudioCaptureOnMute: false,
      ),
    ),
  );

  late final EventsListener<RoomEvent> _listener;
  late final BackgroundWhiteNoiseCoordinator _backgroundWhiteNoise;
  StreamSubscription<AVAudioSessionInterruptionNotification>?
  _iosAudioInterruptionSubscription;
  StreamSubscription<AVAudioSessionRouteChange>? _iosAudioRouteSubscription;
  StreamSubscription<void>? _iosMediaServicesLostSubscription;
  StreamSubscription<void>? _iosMediaServicesResetSubscription;

  bool _micEnabled = false;
  bool _desiredMicEnabled = false;
  bool _enableMicAfterConnect = false;
  bool _isConnecting = false;

  /// Pre-started iOS audio session config future for the next PTT enable.
  /// Kicked off immediately in [setMicEnabled](true) so the native
  /// setAppleAudioConfiguration call is already in-flight by the time
  /// [_applyDesiredMicState] runs, reducing PTT latency on quick taps.
  Future<void>? _pendingIosPlayAndRecordConfig;
  bool _backgroundRecoveryActive = false;
  bool _rtcMediaPathFailed = false;
  bool _duckOtherAppsAudio = false;
  bool _hasRemoteActiveSpeaker = false;
  bool _hadResumeInBackground = false;
  bool _reconnectedInBackgroundAfterResume = false;
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  int _appLifecycleGeneration = 0;
  Future<void> _appLifecycleOperation = Future<void>.value();
  ConnectionState _lastLoggedConnectionState = ConnectionState.disconnected;
  int _lastLoggedReconnectAttempt = -1;
  ConnectionState _lastLoggedReconnectConnectionState =
      ConnectionState.disconnected;
  double _intercomVolume = 1.0;
  Future<void> _micStateOperation = Future<void>.value();
  int _micStateGeneration = 0;
  Timer? _duckOtherAppsAudioReleaseTimer;
  Timer? _backgroundWhiteNoiseLifecycleSyncTimer;
  Timer? _backgroundWhiteNoiseWatchdogTimer;
  static const Duration _backgroundWhiteNoiseLifecycleResyncDelay = Duration(
    milliseconds: 400,
  );
  static const Duration _backgroundWhiteNoiseWatchdogInterval = Duration(
    seconds: 15,
  );
  final Map<String, DateTime> _presenceLastSeen = <String, DateTime>{};
  final Map<String, DateTime> _presenceConnectedAt = <String, DateTime>{};
  Map<String, CallMemberStatus> _presenceStatusSnapshot =
      <String, CallMemberStatus>{};
  Timer? _presenceHeartbeatTimer;
  Timer? _presenceStaleCheckTimer;
  bool _loggedPresencePublishPermission = false;

  /// One-shot guard: initial earpiece for an accepted CallKit call only.
  /// After this, the user can toggle Speaker on the native call UI.
  bool _iosCallkitInitialReceiverApplied = false;
  bool get isConnecting => _isConnecting;
  bool get isConnected => _room.connectionState == ConnectionState.connected;

  String get roomConnectionStateName => _room.connectionState.name;

  /// True while our connect() is running or the SDK room is connecting/reconnecting.
  bool get isRoomConnectionInFlight {
    switch (_room.connectionState) {
      case ConnectionState.connecting:
      case ConnectionState.reconnecting:
        return true;
      case ConnectionState.connected:
      case ConnectionState.disconnected:
        return _isConnecting;
    }
  }

  /// Returns true if a `RoomResumingEvent` occurred while the app was in the
  /// background, and resets the flag. Used by [HomeController] to detect a
  /// potential zombie connection that needs a forced disconnect on resume.
  bool consumeAndClearResumeFlag() {
    final bool value = _hadResumeInBackground;
    _hadResumeInBackground = false;
    return value;
  }

  bool consumeAndClearBackgroundReconnectFlag() {
    final bool value = _reconnectedInBackgroundAfterResume;
    _reconnectedInBackgroundAfterResume = false;
    return value;
  }

  bool consumeAndClearRtcMediaPathFailedFlag() {
    final bool value = _rtcMediaPathFailed;
    _rtcMediaPathFailed = false;
    return value;
  }

  bool markRtcMediaPathFailed({required String source, required Object error}) {
    if (!isLiveKitRtcMediaPathError(error)) return false;

    _rtcMediaPathFailed = true;
    if (_appLifecycleState != AppLifecycleState.resumed) {
      _hadResumeInBackground = true;
    }
    testPrintLS(
      DiagnosticLog.warn(
        'LiveKitController',
        'rtc_media_path_failed',
        data: {'source': source, 'error': error, ..._roomDiagnosticState()},
      ),
    );
    _setState();
    return true;
  }

  LiveKitController({
    VoidCallback? onUpdate,
    bool Function(DisconnectReason? reason)? onUnexpectedDisconnect,
  }) : _onUpdate = onUpdate,
       _onUnexpectedDisconnect = onUnexpectedDisconnect {
    _backgroundWhiteNoise = BackgroundWhiteNoiseCoordinator(
      player: JustAudioWhiteNoisePlayer(),
      onPlaybackChanged: (_) async {
        if (_shouldDeferIosAudioSessionConfiguration()) return;
        await _configureIosAudioSession(
          source: 'background_white_noise_playback_changed',
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        testPrintLS(
          DiagnosticLog.warn(
            'LiveKitController',
            'background_white_noise_failed',
            data: {'error': error},
          ),
        );
      },
    );
    _initialize();
  }

  Future<void> dispose() async {
    _stopPresence();
    _pendingIosPlayAndRecordConfig = null;
    _duckOtherAppsAudioReleaseTimer?.cancel();
    _backgroundWhiteNoiseLifecycleSyncTimer?.cancel();
    _stopBackgroundWhiteNoiseWatchdog();
    await _iosAudioInterruptionSubscription?.cancel();
    await _iosAudioRouteSubscription?.cancel();
    await _iosMediaServicesLostSubscription?.cancel();
    await _iosMediaServicesResetSubscription?.cancel();
    await _backgroundWhiteNoise.dispose();
    await _stopForegroundService();
    await _room.disconnect();
    _listener.dispose();
    _room.removeListener(_onRoomChanged);
    _room.dispose();
  }

  void _initialize() {
    _initForegroundService();
    _initIosLiveKitAudioRouting();
    _initIosAudioSessionDiagnostics();

    _listener = _room.createListener();
    _room.addListener(_onRoomChanged);

    _listener
      ..on<RoomConnectedEvent>((_) async {
        _resetReconnectAttemptLogDedup();
        _backgroundRecoveryActive = false;
        testPrintLS(
          DiagnosticLog.flow(
            'LiveKitController',
            'room_connected_event',
            data: _roomDiagnosticState(),
          ),
        );
        await _configureIosAudioSession(source: 'room_connected_event');
        await _applyIntercomVolumeToRemoteAudioTracks(
          source: 'room_connected_event',
        );
        await _syncBackgroundWhiteNoise(source: 'room_connected_event');
        _seedRemoteParticipantPresence();
        _logPresencePublishPermissionOnce();
        _startPresence();
        _setState();
      })
      ..on<RoomReconnectingEvent>((_) {
        // A full reconnect (new RTCPeerConnection) in background also needs the
        // zombie-disconnect treatment on resume, not just a lightweight resume.
        if (_appLifecycleState != AppLifecycleState.resumed) {
          _hadResumeInBackground = true;
          _reconnectedInBackgroundAfterResume = false;
        }
        testPrintLS(
          DiagnosticLog.warn(
            'LiveKitController',
            'room_reconnecting_event',
            data: _roomDiagnosticState(),
          ),
        );
        _setState();
      })
      ..on<RoomResumingEvent>((_) {
        final bool inBackground =
            _appLifecycleState != AppLifecycleState.resumed;
        if (inBackground) {
          _hadResumeInBackground = true;
          _reconnectedInBackgroundAfterResume = false;
        }
        testPrintLS(
          DiagnosticLog.warn(
            'LiveKitController',
            'room_resuming_event',
            data: {
              ..._roomDiagnosticState(),
              'hadResumeInBackground': _hadResumeInBackground,
            },
          ),
        );
        _setState();
      })
      ..on<RoomAttemptReconnectEvent>((event) {
        final ConnectionState connectionState = _room.connectionState;
        if (event.attempt == _lastLoggedReconnectAttempt &&
            connectionState == _lastLoggedReconnectConnectionState) {
          _setState();
          return;
        }
        _lastLoggedReconnectAttempt = event.attempt;
        _lastLoggedReconnectConnectionState = connectionState;
        testPrintLS(
          DiagnosticLog.warn(
            'LiveKitController',
            'room_reconnect_attempt',
            data: {
              ..._roomDiagnosticState(),
              'attempt': event.attempt,
              'maxAttempts': event.maxAttemptsRetry,
              'nextRetryDelayMs': event.nextRetryDelaysInMs,
            },
          ),
        );
        _setState();
      })
      ..on<RoomReconnectedEvent>((_) async {
        _resetReconnectAttemptLogDedup();
        _backgroundRecoveryActive = false;
        if (_appLifecycleState != AppLifecycleState.resumed &&
            _hadResumeInBackground) {
          _reconnectedInBackgroundAfterResume = true;
        }
        testPrintLS(
          DiagnosticLog.flow(
            'LiveKitController',
            'room_reconnected_event',
            data: _roomDiagnosticState(),
          ),
        );
        await _configureIosAudioSession(source: 'room_reconnected_event');
        await _applyIntercomVolumeToRemoteAudioTracks(
          source: 'room_reconnected_event',
        );
        await _recoverBackgroundWhiteNoiseAfterInterruption(
          source: 'room_reconnected_event',
        );
        _seedRemoteParticipantPresence();
        _startPresence();
        _setState();
      })
      ..on<RoomDisconnectedEvent>((event) {
        _stopPresence();
        final DisconnectReason? reason = event.reason;
        final bool retryable = isRetryableLiveKitDisconnectReason(reason);
        _micEnabled = false;
        _desiredMicEnabled = false;
        _enableMicAfterConnect = false;
        _hasRemoteActiveSpeaker = false;
        _reconnectedInBackgroundAfterResume = false;
        _rtcMediaPathFailed = false;
        _duckOtherAppsAudioReleaseTimer?.cancel();
        _duckOtherAppsAudio = false;
        final bool recoveryAccepted =
            retryable && (_onUnexpectedDisconnect?.call(reason) ?? false);
        _backgroundRecoveryActive = recoveryAccepted;
        unawaited(_syncBackgroundWhiteNoise(source: 'room_disconnected_event'));
        testPrintLS('LKC:: EVENT: RoomDisconnected');
        testPrintLS(
          DiagnosticLog.warn(
            'LiveKitController',
            'room_disconnected_event',
            data: {
              ..._roomDiagnosticState(),
              'reason': reason?.name ?? 'unknown',
              'retryable': retryable,
              'recoveryAccepted': recoveryAccepted,
            },
          ),
        );
        if (!recoveryAccepted) {
          testPrintLS(
            DiagnosticLog.flow(
              'LiveKitController',
              'room_disconnect_recovery_skipped',
              data: {'reason': reason?.name ?? 'unknown'},
            ),
          );
        }
        _setState();
      })
      ..on<ActiveSpeakersChangedEvent>((e) {
        _handleActiveSpeakersChanged(e);
        _setState();
      })
      ..on<TrackSubscribedEvent>((_) async {
        await _configureIosAudioSession(source: 'track_subscribed_event');
        await _applyIntercomVolumeToRemoteAudioTracks(
          source: 'track_subscribed_event',
        );
        _setState();
      })
      ..on<LocalTrackPublishedEvent>((_) async {
        await _configureIosAudioSession(
          source: 'local_track_published_event',
          localMicActive: _desiredMicEnabled || _micEnabled,
        );
        _setState();
      })
      ..on<ParticipantConnectedEvent>((e) {
        testPrintLS(
          'LKC::  EVENT: ParticipantConnected, id: ${e.participant.identity}',
        );
        _recordParticipantConnected(e.participant.identity);
        unawaited(
          _applyIntercomVolumeToRemoteAudioTracks(
            source: 'participant_connected_event',
          ),
        );
        _setState();
      })
      ..on<ParticipantDisconnectedEvent>((e) {
        testPrintLS(
          'LKC::  EVENT: ParticipantDisconnected, id: ${e.participant.identity}',
        );
        _removeParticipantPresence(e.participant.identity);
        _refreshRemoteActiveSpeakerFromParticipants();
        unawaited(
          _syncBackgroundWhiteNoise(source: 'participant_disconnected_event'),
        );
        _setState();
      })
      ..on<TrackMutedEvent>((e) {
        testPrintLS(
          'LKC::  EVENT: TrackMuted ☑️: ${e.participant.name} ${e.participant.identity}',
        );
        if (e.participant is RemoteParticipant &&
            e.publication.kind == TrackType.AUDIO) {
          _onRemoteParticipantAudioTrackMuteChanged();
        }
        _setState();
      })
      ..on<TrackUnmutedEvent>((e) {
        testPrintLS(
          'LKC::  EVENT: TrackUnmuted ✅: ${e.participant.name} ${e.participant.identity}',
        );
        if (e.participant is RemoteParticipant &&
            e.publication.kind == TrackType.AUDIO) {
          _onRemoteParticipantAudioTrackMuteChanged();
        }
        _setState();
      })
      ..on<DataReceivedEvent>((e) {
        if (e.topic != PowWowPresence.topic) return;

        final String? identity = e.participant?.identity;
        if (identity == null || identity.isEmpty) return;

        _presenceLastSeen[identity] = DateTime.now();
      });
  }

  void _setState() {
    _onUpdate?.call();
  }

  void _startPresence() {
    _stopPresenceTimersOnly();

    unawaited(_publishPresenceHeartbeat());
    _presenceHeartbeatTimer = Timer.periodic(
      PowWowPresence.heartbeatInterval,
      (_) => unawaited(_publishPresenceHeartbeat()),
    );
    _presenceStaleCheckTimer = Timer.periodic(
      PowWowPresence.staleCheckInterval,
      (_) => _checkPresenceStale(),
    );
    _presenceStatusSnapshot = _buildRemotePresenceSnapshot();
  }

  void _stopPresence() {
    _stopPresenceTimersOnly();
    _clearPresenceState();
  }

  void _stopPresenceTimersOnly() {
    _presenceHeartbeatTimer?.cancel();
    _presenceHeartbeatTimer = null;
    _presenceStaleCheckTimer?.cancel();
    _presenceStaleCheckTimer = null;
  }

  void _clearPresenceState() {
    _presenceLastSeen.clear();
    _presenceConnectedAt.clear();
    _presenceStatusSnapshot = <String, CallMemberStatus>{};
    _loggedPresencePublishPermission = false;
  }

  void _seedRemoteParticipantPresence() {
    final DateTime now = DateTime.now();
    for (final RemoteParticipant participant
        in _room.remoteParticipants.values) {
      _presenceConnectedAt.putIfAbsent(participant.identity, () => now);
    }
    _presenceStatusSnapshot = _buildRemotePresenceSnapshot();
  }

  void _recordParticipantConnected(String identity) {
    _presenceConnectedAt[identity] = DateTime.now();
  }

  void _removeParticipantPresence(String identity) {
    _presenceLastSeen.remove(identity);
    _presenceConnectedAt.remove(identity);
    _presenceStatusSnapshot.remove(identity);
  }

  void _logPresencePublishPermissionOnce() {
    if (_loggedPresencePublishPermission) return;
    _loggedPresencePublishPermission = true;

    final ParticipantPermissions? permissions =
        _room.localParticipant?.permissions;
    testPrintLS(
      DiagnosticLog.flow(
        'LiveKitController',
        'presence_publish_permissions',
        data: {
          'canPublish': permissions?.canPublish,
          'canPublishData': permissions?.canPublishData,
        },
      ),
    );
  }

  Future<void> _publishPresenceHeartbeat() async {
    if (!isConnected) return;

    final LocalParticipant? localParticipant = _room.localParticipant;
    if (localParticipant == null) return;

    try {
      await localParticipant.publishData(
        PowWowPresence.heartbeatPayload,
        reliable: false,
        topic: PowWowPresence.topic,
      );
    } catch (e) {
      testPrintLS(
        DiagnosticLog.warn(
          'LiveKitController',
          'presence_heartbeat_publish_failed',
          data: {'error': e},
        ),
      );
    }
  }

  Map<String, CallMemberStatus> _buildRemotePresenceSnapshot() {
    final DateTime now = DateTime.now();
    final Map<String, CallMemberStatus> snapshot = <String, CallMemberStatus>{};

    for (final RemoteParticipant participant
        in _room.remoteParticipants.values) {
      final String identity = participant.identity;
      snapshot[identity] = remotePresenceStatus(
        now: now,
        isInRemoteParticipants: true,
        lastHeartbeatAt: _presenceLastSeen[identity],
        participantConnectedAt: _presenceConnectedAt[identity],
      );
    }

    return snapshot;
  }

  void _checkPresenceStale() {
    if (!isConnected) return;

    final Map<String, CallMemberStatus> nextSnapshot =
        _buildRemotePresenceSnapshot();
    if (_presenceSnapshotsEqual(_presenceStatusSnapshot, nextSnapshot)) return;

    _presenceStatusSnapshot = nextSnapshot;
    _setState();
  }

  bool _presenceSnapshotsEqual(
    Map<String, CallMemberStatus> a,
    Map<String, CallMemberStatus> b,
  ) {
    if (a.length != b.length) return false;
    for (final MapEntry<String, CallMemberStatus> entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  void _resetReconnectAttemptLogDedup() {
    _lastLoggedReconnectAttempt = -1;
    _lastLoggedReconnectConnectionState = ConnectionState.disconnected;
  }

  void _onRoomChanged() {
    final ConnectionState connectionState = _room.connectionState;
    if (_lastLoggedConnectionState != connectionState) {
      if (connectionState == ConnectionState.disconnected) {
        _resetReconnectAttemptLogDedup();
      }
      _lastLoggedConnectionState = connectionState;
      testPrintLS(
        DiagnosticLog.flow(
          'LiveKitController',
          'room_connection_state_changed',
          data: _roomDiagnosticState(),
        ),
      );
    }
    _setState();
  }

  /// LiveKit defaults to speaker-friendly routing (`preferSpeakerOutput=true` and
  /// automatic native reconfiguration). PowWow manages iOS audio explicitly
  /// (earpiece/receiver during CallKit, mixed playback for listen-only,
  /// playAndRecord only while the local mic is active).
  void _initIosLiveKitAudioRouting() {
    if (!Platform.isIOS) return;

    Hardware.instance.setAutomaticConfigurationEnabled(enable: false);
    unawaited(_forceIosReceiverOutput(source: 'init'));
  }

  Future<void> _forceIosReceiverOutput({required String source}) async {
    if (!Platform.isIOS) return;

    try {
      await Hardware.instance.setSpeakerphoneOn(false);
      await rtc.Helper.setSpeakerphoneOn(false);
      testPrintLS(
        DiagnosticLog.flow(
          'LiveKitController',
          'ios_receiver_output_forced',
          data: {'source': source, 'route': await _describeIosAudioRoute()},
        ),
      );
    } catch (e) {
      testPrintLS(
        DiagnosticLog.warn(
          'LiveKitController',
          'ios_receiver_output_force_failed',
          data: {'source': source, 'error': e},
        ),
      );
    }
  }

  /// Applies earpiece once per CallKit call so accept does not start on speaker,
  /// without overriding later user Speaker toggles on the native call screen.
  Future<void> _ensureCallkitInitialReceiverOutput({
    required String source,
  }) async {
    if (!Platform.isIOS || _iosCallkitInitialReceiverApplied) return;
    if (!callSessionCoordinator.shouldApplyCallkitInitialReceiverOutput) {
      return;
    }

    await _forceIosReceiverOutput(source: source);
    _iosCallkitInitialReceiverApplied = true;
  }

  void _resetCallkitInitialReceiverGuard() {
    _iosCallkitInitialReceiverApplied = false;
  }

  Future<String> _describeIosAudioRoute() async {
    if (!Platform.isIOS) return '';

    try {
      final AVAudioSessionRouteDescription route =
          await AVAudioSession().currentRoute;
      final String outputs = route.outputs
          .map((AVAudioSessionPortDescription port) => port.portType.name)
          .join(',');
      return outputs.isEmpty ? 'none' : outputs;
    } catch (_) {
      return 'unknown';
    }
  }

  void _initIosAudioSessionDiagnostics() {
    if (!Platform.isIOS) return;

    try {
      final AVAudioSession audioSession = AVAudioSession();
      _iosAudioInterruptionSubscription = audioSession
          .interruptionNotificationStream
          .listen((AVAudioSessionInterruptionNotification event) {
            final bool shouldResume = event.options.contains(
              AVAudioSessionInterruptionOptions.shouldResume,
            );
            testPrintLS(
              DiagnosticLog.warn(
                'LiveKitController',
                'ios_audio_interruption',
                data: {
                  ..._roomDiagnosticState(),
                  'type': event.type.name,
                  'shouldResume': shouldResume,
                  'wasSuspended': event.wasSuspended,
                  'whiteNoisePlaying': _backgroundWhiteNoise.isPlaying,
                  'whiteNoisePlaybackActive':
                      _backgroundWhiteNoise.isPlaybackActive,
                },
              ),
            );
            if (event.type == AVAudioSessionInterruptionType.began) {
              if (_shouldRecoverBackgroundWhiteNoiseOnInterruptionBegan()) {
                unawaited(
                  _resyncBackgroundWhiteNoiseAfterInterruptionBegan(
                    source: 'interruption_began_background',
                  ),
                );
              }
            } else if (event.type == AVAudioSessionInterruptionType.ended &&
                shouldResume) {
              unawaited(
                _recoverBackgroundWhiteNoiseAfterInterruption(
                  source: 'interruption_ended',
                ),
              );
            }
          });
      _iosAudioRouteSubscription = audioSession.routeChangeStream.listen((
        AVAudioSessionRouteChange event,
      ) {
        unawaited(() async {
          testPrintLS(
            DiagnosticLog.flow(
              'LiveKitController',
              'ios_audio_route_changed',
              data: {
                ..._roomDiagnosticState(),
                'reason': event.reason.name,
                'route': await _describeIosAudioRoute(),
              },
            ),
          );
        }());
      });
      _iosMediaServicesLostSubscription = audioSession
          .mediaServicesWereLostStream
          .listen((_) {
            testPrintLS(
              DiagnosticLog.warn(
                'LiveKitController',
                'ios_media_services_lost',
                data: _roomDiagnosticState(),
              ),
            );
          });
      _iosMediaServicesResetSubscription = audioSession
          .mediaServicesWereResetStream
          .listen((_) {
            testPrintLS(
              DiagnosticLog.warn(
                'LiveKitController',
                'ios_media_services_reset',
                data: _roomDiagnosticState(),
              ),
            );
            unawaited(
              _recoverBackgroundWhiteNoiseAfterInterruption(
                source: 'media_services_reset',
              ),
            );
          });
      testPrintLS(
        DiagnosticLog.flow(
          'LiveKitController',
          'ios_audio_session_diagnostics_started',
        ),
      );
    } catch (e) {
      testPrintLS(
        DiagnosticLog.warn(
          'LiveKitController',
          'ios_audio_session_diagnostics_failed',
          data: {'error': e},
        ),
      );
    }
  }

  Future<void> _recoverBackgroundWhiteNoiseAfterInterruption({
    required String source,
  }) async {
    await _configureIosAudioSession(source: source);
    await _backgroundWhiteNoise.recoverFromInterruption();
    await _syncBackgroundWhiteNoise(source: source);
  }

  Future<void> _resyncBackgroundWhiteNoiseAfterInterruptionBegan({
    required String source,
  }) async {
    await _configureIosAudioSession(source: source);
    await _backgroundWhiteNoise.ensurePlaybackIfEligible();
    await _syncBackgroundWhiteNoise(source: source);
  }

  bool _shouldRecoverBackgroundWhiteNoiseOnInterruptionBegan() {
    return shouldRecoverBackgroundWhiteNoiseOnInterruptionBegan(
      isAppInForeground: _appLifecycleState == AppLifecycleState.resumed,
      localMicEnabled:
          _micEnabled || _desiredMicEnabled || _enableMicAfterConnect,
      isSuppressed: _isBackgroundWhiteNoiseSuppressed,
    );
  }

  bool _shouldRunBackgroundWhiteNoiseWatchdog() {
    return shouldRunBackgroundWhiteNoiseWatchdog(
      isIOS: Platform.isIOS,
      isAppInForeground: _appLifecycleState == AppLifecycleState.resumed,
      localMicEnabled:
          _micEnabled || _desiredMicEnabled || _enableMicAfterConnect,
      isSuppressed: _isBackgroundWhiteNoiseSuppressed,
    );
  }

  Future<void> _resyncBackgroundWhiteNoiseAfterLifecycleDefer() async {
    _refreshRemoteActiveSpeakerFromParticipants();
    await _syncBackgroundWhiteNoise(source: 'app_lifecycle_deferred_resync');
    await _backgroundWhiteNoise.ensurePlaybackIfEligible();
  }

  bool get _isBackgroundWhiteNoiseSuppressed {
    return shouldSuppressBackgroundWhiteNoise(
      isIOS: Platform.isIOS,
      incomingCallRinging: callSessionCoordinator.isIncomingCallRinging,
      declinedIncomingCallBeforeForeground:
          callSessionCoordinator.declinedBeforeForeground,
    );
  }

  Map<String, Object?> _roomDiagnosticState() {
    return {
      'connectionState': _room.connectionState.name,
      'isConnected': isConnected,
      'isConnecting': _isConnecting,
      'remoteParticipants': _room.remoteParticipants.length,
      'remoteAudioTracks': _remoteAudioTrackCount(),
      'appLifecycle': _appLifecycleState.name,
      'localMicEnabled': _micEnabled,
      'desiredMicEnabled': _desiredMicEnabled,
      'backgroundRecoveryActive': _backgroundRecoveryActive,
      'hasRemoteSpeaker': _hasRemoteActiveSpeaker,
    };
  }

  int _remoteAudioTrackCount() {
    int count = 0;
    for (final RemoteParticipant participant
        in _room.remoteParticipants.values) {
      count += participant.audioTrackPublications.length;
    }
    return count;
  }

  Future<void> setAppLifecycleState(AppLifecycleState state) async {
    final int generation = ++_appLifecycleGeneration;
    _appLifecycleState = state;
    _appLifecycleOperation = _appLifecycleOperation.then(
      (_) => _applyAppLifecycleState(state: state, generation: generation),
    );
    return _appLifecycleOperation;
  }

  Future<void> _applyAppLifecycleState({
    required AppLifecycleState state,
    required int generation,
  }) async {
    if (!shouldApplyLifecycleSync(
      generation: generation,
      currentGeneration: _appLifecycleGeneration,
    )) {
      return;
    }

    final bool leavingForeground = state != AppLifecycleState.resumed;
    if (leavingForeground) {
      _backgroundWhiteNoiseLifecycleSyncTimer?.cancel();
      _refreshRemoteActiveSpeakerFromParticipants();
    } else {
      _backgroundWhiteNoiseLifecycleSyncTimer?.cancel();
      _backgroundWhiteNoiseLifecycleSyncTimer = null;
    }

    await _syncBackgroundWhiteNoise(source: 'app_lifecycle_${state.name}');

    if (!shouldApplyLifecycleSync(
      generation: generation,
      currentGeneration: _appLifecycleGeneration,
    )) {
      return;
    }

    if (leavingForeground) {
      _scheduleBackgroundWhiteNoiseLifecycleResync();
    }
  }

  void _scheduleBackgroundWhiteNoiseLifecycleResync() {
    _backgroundWhiteNoiseLifecycleSyncTimer?.cancel();
    _backgroundWhiteNoiseLifecycleSyncTimer = Timer(
      _backgroundWhiteNoiseLifecycleResyncDelay,
      () {
        _backgroundWhiteNoiseLifecycleSyncTimer = null;
        if (_appLifecycleState == AppLifecycleState.resumed) return;

        unawaited(_resyncBackgroundWhiteNoiseAfterLifecycleDefer());
      },
    );
  }

  void _updateBackgroundWhiteNoiseWatchdog() {
    if (_shouldRunBackgroundWhiteNoiseWatchdog()) {
      _startBackgroundWhiteNoiseWatchdog();
    } else {
      _stopBackgroundWhiteNoiseWatchdog();
    }
  }

  void _startBackgroundWhiteNoiseWatchdog() {
    if (_backgroundWhiteNoiseWatchdogTimer != null) return;

    _backgroundWhiteNoiseWatchdogTimer = Timer.periodic(
      _backgroundWhiteNoiseWatchdogInterval,
      (_) {
        if (!_shouldRunBackgroundWhiteNoiseWatchdog()) {
          _stopBackgroundWhiteNoiseWatchdog();
          return;
        }

        unawaited(
          _syncBackgroundWhiteNoise(source: 'background_white_noise_watchdog'),
        );
      },
    );
  }

  void _stopBackgroundWhiteNoiseWatchdog() {
    _backgroundWhiteNoiseWatchdogTimer?.cancel();
    _backgroundWhiteNoiseWatchdogTimer = null;
  }

  void _onRemoteParticipantAudioTrackMuteChanged() {
    _refreshRemoteActiveSpeakerFromParticipants();
    unawaited(_syncBackgroundWhiteNoise(source: 'remote_track_mute_changed'));
  }

  /// CallKit activated AVAudioSession — native AppDelegate already bridged it
  /// to WebRTC. Re-apply playback volume and mic without touching the session.
  Future<void> onCallkitAudioSessionActivated() async {
    if (!Platform.isIOS) return;

    testPrintLS(
      DiagnosticLog.flow(
        'LiveKitController',
        'callkit_audio_session_activated',
        data: _roomDiagnosticState(),
      ),
    );

    await _applyIntercomVolumeToRemoteAudioTracks(
      source: 'callkit_audio_activated',
    );
    await _ensureCallkitInitialReceiverOutput(
      source: 'callkit_audio_activated',
    );
    await _resyncMicCaptureAfterCallkitHandoff(
      source: 'callkit_audio_activated',
    );
  }

  /// Re-establishes mic capture after CallKit hands AVAudioSession to WebRTC.
  Future<void> _resyncMicCaptureAfterCallkitHandoff({
    required String source,
  }) async {
    if (!Platform.isIOS || !isConnected || !_desiredMicEnabled) return;

    try {
      if (_micEnabled) {
        await _setLiveKitMicrophoneEnabled(false);
      }
      await _setLiveKitMicrophoneEnabled(true);
      _micEnabled = true;
      _setState();
      testPrintLS(
        DiagnosticLog.flow(
          'LiveKitController',
          'callkit_mic_restored',
          data: {'source': source, 'micEnabled': true},
        ),
      );
    } catch (e) {
      testPrintLS(
        DiagnosticLog.warn(
          'LiveKitController',
          'callkit_mic_restore_failed',
          data: {'source': source, 'error': e},
        ),
      );
    }
  }

  /// CallKit released AVAudioSession — restore PowWow's preferred configuration.
  Future<void> onCallkitAudioSessionDeactivated() async {
    if (!Platform.isIOS) return;

    testPrintLS(
      DiagnosticLog.flow(
        'LiveKitController',
        'callkit_audio_session_deactivated',
        data: _roomDiagnosticState(),
      ),
    );

    _resetCallkitInitialReceiverGuard();
    await _configureIosAudioSession(source: 'callkit_audio_deactivated');
    await _syncBackgroundWhiteNoise(source: 'callkit_audio_deactivated');
  }

  bool _shouldDeferIosAudioSessionConfiguration() {
    return shouldDeferIosAudioSessionConfiguration(
      isIOS: Platform.isIOS,
      iosCallkitAudioSessionActive:
          callSessionCoordinator.callkitAudioSessionActive,
      pendingAcceptedCallId: callSessionCoordinator.acceptedCallId,
      appLifecycle: _appLifecycleState,
    );
  }

  Future<void> setBackgroundRecoveryActive(
    bool active, {
    required String source,
  }) async {
    if (_backgroundRecoveryActive == active) return;

    _backgroundRecoveryActive = active;
    testPrintLS(
      DiagnosticLog.flow(
        'LiveKitController',
        'background_recovery_state_changed',
        data: {'active': active, 'source': source},
      ),
    );
    await _syncBackgroundWhiteNoise(source: 'background_recovery_$source');
  }

  // Configures the foreground service options (Android only).
  // Called once at widget init; does not start the service yet.
  void _initForegroundService() {
    if (!Platform.isAndroid) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'audio_chat_service',
        channelName: 'Audio Chat',
        channelDescription: 'Active audio chat session',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  // Starts the Android foreground service after a successful room connection.
  Future<void> _startForegroundService() async {
    if (!Platform.isAndroid) return;

    final NotificationPermission perm =
        await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    if (await FlutterForegroundTask.isRunningService) {
      testPrintLS('LKC:: [FGService] already running');
      testPrintLS(
        DiagnosticLog.flow(
          'LiveKitController',
          'foreground_service_already_running',
        ),
      );
      return;
    }

    await FlutterForegroundTask.startService(
      serviceId: 100,
      notificationTitle: 'Audio Chat Active',
      notificationText: 'Tap to return to the app',
      serviceTypes: const [ForegroundServiceTypes.mediaPlayback],
    );
    testPrintLS('LKC:: [FGService] start requested');
    testPrintLS(
      DiagnosticLog.flow(
        'LiveKitController',
        'foreground_service_start_requested',
      ),
    );
  }

  // Stops the Android foreground service on disconnect.
  Future<void> _stopForegroundService() async {
    if (!Platform.isAndroid) return;
    await FlutterForegroundTask.stopService();
    testPrintLS('LKC::  [FGService] stop requested');
    testPrintLS(
      DiagnosticLog.flow(
        'LiveKitController',
        'foreground_service_stop_requested',
      ),
    );
  }

  Future<String?> _requestCallPermissions() async {
    final PermissionStatus micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      testPrintLS(
        DiagnosticLog.warn(
          'LiveKitController',
          'microphone_permission_denied',
          data: {'status': micStatus.name},
        ),
      );
      return 'Microphone permission denied';
    }

    if (Platform.isAndroid) {
      final PermissionStatus btStatus = await Permission.bluetoothConnect
          .request();

      if (!btStatus.isGranted) {
        testPrintLS(
          DiagnosticLog.warn(
            'LiveKitController',
            'bluetooth_permission_denied',
            data: {'status': btStatus.name},
          ),
        );
        return 'Nearby devices permission denied';
      }
    }

    testPrintLS(
      DiagnosticLog.flow(
        'LiveKitController',
        'permissions_granted',
        data: {'platform': Platform.isAndroid ? 'android' : 'ios'},
      ),
    );

    return null;
  }

  Future<void> _configureIosAudioSession({
    required String source,
    bool? localMicActive,
  }) async {
    if (!Platform.isIOS) return;

    if (_shouldDeferIosAudioSessionConfiguration()) {
      testPrintLS(
        DiagnosticLog.flow(
          'LiveKitController',
          'ios_audio_session_configure_deferred',
          data: {
            'source': source,
            'iosCallkitAudioSessionActive':
                callSessionCoordinator.callkitAudioSessionActive,
            'pendingAcceptedCallId': callSessionCoordinator.acceptedCallId,
            'appLifecycle': _appLifecycleState.name,
          },
        ),
      );
      return;
    }

    try {
      final bool isLocalMicActive = localMicActive ?? _micEnabled;
      final appleAudioCategoryOptions = {
        rtc.AppleAudioCategoryOption.mixWithOthers,
        if (_duckOtherAppsAudio) rtc.AppleAudioCategoryOption.duckOthers,
        if (isLocalMicActive) ...{
          rtc.AppleAudioCategoryOption.allowBluetooth,
          rtc.AppleAudioCategoryOption.allowBluetoothA2DP,
          rtc.AppleAudioCategoryOption.allowAirPlay,
        },
      };
      final avAudioCategoryOptions =
          AVAudioSessionCategoryOptions.mixWithOthers |
          (_duckOtherAppsAudio
              ? AVAudioSessionCategoryOptions.duckOthers
              : AVAudioSessionCategoryOptions.none) |
          (isLocalMicActive
              ? AVAudioSessionCategoryOptions.allowBluetooth |
                    AVAudioSessionCategoryOptions.allowBluetoothA2dp |
                    AVAudioSessionCategoryOptions.allowAirPlay
              : AVAudioSessionCategoryOptions.none);

      await rtc.Helper.setAppleAudioConfiguration(
        rtc.AppleAudioConfiguration(
          appleAudioCategory: isLocalMicActive
              ? rtc.AppleAudioCategory.playAndRecord
              : rtc.AppleAudioCategory.playback,
          appleAudioCategoryOptions: appleAudioCategoryOptions,
          appleAudioMode: isLocalMicActive
              ? rtc.AppleAudioMode.voiceChat
              : rtc.AppleAudioMode.default_,
        ),
      );
      final audioSession = await AudioSession.instance;
      await audioSession.configure(
        AudioSessionConfiguration(
          avAudioSessionCategory: isLocalMicActive
              ? AVAudioSessionCategory.playAndRecord
              : AVAudioSessionCategory.playback,
          avAudioSessionCategoryOptions: avAudioCategoryOptions,
          avAudioSessionMode: isLocalMicActive
              ? AVAudioSessionMode.voiceChat
              : AVAudioSessionMode.defaultMode,
        ),
      );
      testPrintLS(
        DiagnosticLog.flow(
          'LiveKitController',
          'ios_audio_session_configured',
          data: {
            'source': source,
            'localMicActive': isLocalMicActive,
            'mixedWithOthers': true,
            'duckOtherAppsAudio': _duckOtherAppsAudio,
          },
        ),
      );
    } catch (e) {
      testPrintLS(
        DiagnosticLog.warn(
          'LiveKitController',
          'ios_audio_session_configuration_failed',
          data: {'source': source, 'error': e},
        ),
      );
    }
  }

  void _handleActiveSpeakersChanged(ActiveSpeakersChangedEvent event) {
    final bool hasRemoteSpeaker = event.speakers.any(
      (participant) => participant is RemoteParticipant,
    );
    _hasRemoteActiveSpeaker = hasRemoteSpeaker;

    unawaited(
      _setDuckOtherAppsAudio(
        hasRemoteSpeaker,
        source: 'active_speakers_changed',
      ),
    );
    unawaited(_syncBackgroundWhiteNoise(source: 'active_speakers_changed'));
  }

  void _refreshRemoteActiveSpeakerFromParticipants() {
    final bool nextState = _room.remoteParticipants.values.any(
      (participant) => participant.isSpeaking,
    );

    if (_hasRemoteActiveSpeaker == nextState) return;

    _hasRemoteActiveSpeaker = nextState;
  }

  Future<void> _syncBackgroundWhiteNoise({required String source}) async {
    final bool isAppInForeground =
        _appLifecycleState == AppLifecycleState.resumed;
    final bool localMicEnabled =
        _micEnabled || _desiredMicEnabled || _enableMicAfterConnect;
    final bool isSuppressed = shouldSuppressBackgroundWhiteNoise(
      isIOS: Platform.isIOS,
      incomingCallRinging: callSessionCoordinator.isIncomingCallRinging,
      declinedIncomingCallBeforeForeground:
          callSessionCoordinator.declinedBeforeForeground,
    );

    await _backgroundWhiteNoise.update(
      isAppInForeground: isAppInForeground,
      hasRemoteSpeaker: _hasRemoteActiveSpeaker,
      localMicEnabled: localMicEnabled,
      isSuppressed: isSuppressed,
    );
    _updateBackgroundWhiteNoiseWatchdog();
    testPrintLS(
      DiagnosticLog.flow(
        'LiveKitController',
        'background_white_noise_synced',
        data: {
          'source': source,
          'isConnected': isConnected,
          'isAppInForeground': isAppInForeground,
          'hasRemoteSpeaker': _hasRemoteActiveSpeaker,
          'localMicEnabled': localMicEnabled,
          'isSuppressed': isSuppressed,
          'backgroundRecoveryActive': _backgroundRecoveryActive,
          'isPlaying': _backgroundWhiteNoise.isPlaying,
          'playbackActive': _backgroundWhiteNoise.isPlaybackActive,
          'watchdogActive': _backgroundWhiteNoiseWatchdogTimer != null,
        },
      ),
    );
  }

  Future<void> forceStopBackgroundWhiteNoise({required String source}) async {
    testPrintLS(
      DiagnosticLog.flow(
        'LiveKitController',
        'background_white_noise_force_stop',
        data: {'source': source},
      ),
    );
    await _backgroundWhiteNoise.forceStop();
  }

  Future<void> syncBackgroundWhiteNoiseAfterCallFlowChange({
    required String source,
  }) async {
    await _syncBackgroundWhiteNoise(source: source);
  }

  Future<void> _setDuckOtherAppsAudio(
    bool shouldDuck, {
    required String source,
  }) async {
    if (!Platform.isIOS) return;

    _duckOtherAppsAudioReleaseTimer?.cancel();
    _duckOtherAppsAudioReleaseTimer = null;

    if (shouldDuck) {
      if (_duckOtherAppsAudio) return;

      _duckOtherAppsAudio = true;
      if (_shouldDeferIosAudioSessionConfiguration()) return;
      await _configureIosAudioSession(source: '${source}_duck_on');
      return;
    }

    _duckOtherAppsAudioReleaseTimer = Timer(
      const Duration(milliseconds: 900),
      () {
        _duckOtherAppsAudio = false;
        if (_shouldDeferIosAudioSessionConfiguration()) return;
        unawaited(_configureIosAudioSession(source: '${source}_duck_off'));
      },
    );
  }

  Future<void> _setLiveKitMicrophoneEnabled(bool enabled) async {
    await _room.localParticipant?.setMicrophoneEnabled(
      enabled,
      audioCaptureOptions: Platform.isIOS
          ? const AudioCaptureOptions(stopAudioCaptureOnMute: true)
          : null,
    );
  }

  bool _isLocalMicTrackUnmuted() {
    final LocalParticipant? local = _room.localParticipant;
    if (local == null) return false;

    for (final TrackPublication<Track> publication
        in local.audioTrackPublications) {
      if (publication.kind == TrackType.AUDIO &&
          publication.track != null &&
          !publication.muted) {
        return true;
      }
    }
    return false;
  }

  Future<void> _handleStaleMicOperation({
    required int generation,
    required bool appliedEnable,
  }) async {
    if (generation == _micStateGeneration) return;

    if (appliedEnable) {
      testPrintLS(
        DiagnosticLog.flow(
          'LiveKitController',
          'mic_stale_enable_reverted',
          data: {
            'generation': generation,
            'currentGeneration': _micStateGeneration,
            'desiredMicEnabled': _desiredMicEnabled,
          },
        ),
      );
      // When the user is still pressing PTT (_desiredMicEnabled=true), a newer
      // enable operation is already in flight or queued. Reverting here would
      // race with it: we would physically mute the mic and downgrade the iOS
      // audio session from playAndRecord to playback while the user holds the
      // button. Skip — the live operation will set the correct final state.
      if (_desiredMicEnabled) return;

      try {
        await _setLiveKitMicrophoneEnabled(false);
      } catch (_) {}
      _micEnabled = false;
      if (!_shouldDeferIosAudioSessionConfiguration()) {
        await _configureIosAudioSession(
          source: 'stale_mic_enable_reverted',
          localMicActive: false,
        );
      }
      unawaited(_syncBackgroundWhiteNoise(source: 'stale_mic_enable_reverted'));
      _setState();
    }

    // Do not re-apply desired state here: the _micStateOperation chain already
    // has the correct next operation (either a fresh enable or nothing if the
    // user released). Running a resync outside the chain with the current
    // generation races against that queued operation and causes double
    // LiveKit API calls and audio-session category thrashing.
  }

  Future<void> setIntercomVolume(double value) async {
    _intercomVolume = value.clamp(0.0, 1.0);
    await _applyIntercomVolumeToRemoteAudioTracks(source: 'settings_changed');
  }

  Future<void> _applyIntercomVolumeToRemoteAudioTracks({
    required String source,
  }) async {
    int updatedTracks = 0;

    for (final RemoteParticipant participant
        in _room.remoteParticipants.values) {
      for (final publication in participant.audioTrackPublications) {
        final RemoteAudioTrack? track = publication.track;
        if (track == null) {
          continue;
        }

        try {
          await rtc.Helper.setVolume(_intercomVolume, track.mediaStreamTrack);
          updatedTracks++;
        } catch (e) {
          testPrintLS(
            DiagnosticLog.warn(
              'LiveKitController',
              'intercom_volume_apply_failed',
              data: {
                'source': source,
                'participantId': participant.identity,
                'volume': _intercomVolume.toStringAsFixed(2),
                'error': e,
              },
            ),
          );
        }
      }
    }

    testPrintLS(
      DiagnosticLog.flow(
        'LiveKitController',
        'intercom_volume_applied',
        data: {
          'source': source,
          'volume': _intercomVolume.toStringAsFixed(2),
          'tracks': updatedTracks,
        },
      ),
    );
  }

  Future<String?> connect({
    required String url,
    required String token,
    bool prewarmMic = true,
  }) async {
    testPrintLS('LKC:: connect... prewarmMic=$prewarmMic');
    testPrintLS(
      DiagnosticLog.flow(
        'LiveKitController',
        'connect_started',
        data: {
          'isConnected': isConnected,
          'isConnecting': _isConnecting,
          'prewarmMic': prewarmMic,
        },
      ),
    );

    if (_isConnecting) {
      testPrintLS('LKC:: connect: already connecting');
      testPrintLS(
        DiagnosticLog.warn(
          'LiveKitController',
          'connect_skipped_already_connecting',
        ),
      );
      return null;
    }

    if (isConnected) {
      testPrintLS('LKC:: connect: already connected');
      testPrintLS(
        DiagnosticLog.warn(
          'LiveKitController',
          'connect_skipped_already_connected',
        ),
      );
      return null;
    }

    _isConnecting = true;
    _setState();

    try {
      final String? permissionError = await _requestCallPermissions();
      if (permissionError != null) {
        testPrintLS('LKC:: connect: ❌ permission error: $permissionError');
        return permissionError;
      }

      await _configureIosAudioSession(source: 'before_connect');

      await _startForegroundService();

      await _room.prepareConnection(url, token);
      testPrintLS(
        DiagnosticLog.flow('LiveKitController', 'prepare_connection_succeeded'),
      );
      await _room.connect(url, token);
      await _applyIntercomVolumeToRemoteAudioTracks(source: 'connect');
      await _syncBackgroundWhiteNoise(source: 'connect');

      if (prewarmMic) {
        await _configureIosAudioSession(
          source: 'before_prewarm_mic',
          localMicActive: true,
        );
        await _setLiveKitMicrophoneEnabled(true);
        await _setLiveKitMicrophoneEnabled(false);
        await _configureIosAudioSession(
          source: 'after_prewarm_mic',
          localMicActive: false,
        );
      }

      testPrintLS('LKC:: LiveKit CONNECTED ✅');
      testPrintLS(
        DiagnosticLog.flow(
          'LiveKitController',
          'connect_succeeded',
          data: {'connectionState': _room.connectionState.name},
        ),
      );

      if (_enableMicAfterConnect) {
        _enableMicAfterConnect = false;
        _desiredMicEnabled = true;
        testPrintLS('LKC:: connect: enabling mic (pendingCallAccept)');
        testPrintLS(
          DiagnosticLog.flow('LiveKitController', 'pending_mic_enable_applied'),
        );
        await _applyDesiredMicState(
          source: 'pending_mic_enable',
          generation: ++_micStateGeneration,
        );
      }

      if (callSessionCoordinator.callkitAudioSessionActive) {
        await _applyIntercomVolumeToRemoteAudioTracks(
          source: 'connect_callkit_active',
        );
        await _ensureCallkitInitialReceiverOutput(
          source: 'connect_callkit_active',
        );
        await _resyncMicCaptureAfterCallkitHandoff(
          source: 'connect_callkit_active',
        );
      }

      await _configureIosAudioSession(source: 'after_connect');
      await _syncBackgroundWhiteNoise(source: 'after_connect');

      _setState();
      return null;
    } catch (e) {
      testPrintLS('LKC:: connect: ❌ catch error $e');
      testPrintLS(
        DiagnosticLog.err(
          'LiveKitController',
          'connect_failed',
          data: {'error': e},
        ),
      );

      try {
        await _room.disconnect();
      } catch (_) {}

      await _stopForegroundService();
      _setState();
      if (isNetworkBootstrapError(e)) {
        return bootstrapConnectionErrorMessage;
      }
      return liveKitConnectionErrorMessage;
    } finally {
      _isConnecting = false;
      _setState();
    }
  }

  Future<void> disconnect() async {
    testPrintLS(
      DiagnosticLog.flow(
        'LiveKitController',
        'disconnect_started',
        data: {'isConnected': isConnected},
      ),
    );
    _stopPresence();
    if (Platform.isIOS) {
      _resetCallkitInitialReceiverGuard();
    }
    await _room.disconnect();
    await _stopForegroundService();

    _backgroundRecoveryActive = false;
    _rtcMediaPathFailed = false;
    _micEnabled = false;
    _desiredMicEnabled = false;
    _enableMicAfterConnect = false;
    _pendingIosPlayAndRecordConfig = null;
    _hasRemoteActiveSpeaker = false;
    _duckOtherAppsAudioReleaseTimer?.cancel();
    _duckOtherAppsAudio = false;
    await _syncBackgroundWhiteNoise(source: 'disconnect');
    _setState();
    testPrintLS('LKC:: LiveKit DISCONNECTED ☑️');
    testPrintLS(
      DiagnosticLog.flow('LiveKitController', 'disconnect_completed'),
    );
  }

  Future<void> toggleMic() async {
    if (!isConnected) return;

    final bool newState = !_micEnabled;
    if (newState) {
      await _configureIosAudioSession(
        source: 'before_toggle_mic_enable',
        localMicActive: true,
      );
    }
    await _setLiveKitMicrophoneEnabled(newState);
    _micEnabled = newState;
    await _configureIosAudioSession(
      source: 'toggle_mic',
      localMicActive: newState,
    );
    await _syncBackgroundWhiteNoise(source: 'toggle_mic');
    _setState();
  }

  Future<void> setMicEnabled(bool newValue) {
    testPrintLS(
      'LKC:: setMicEnabled: $newValue, isConnected: $isConnected, prev_micEnabled: $_micEnabled, prev_desiredMicEnabled: $_desiredMicEnabled',
    );
    _desiredMicEnabled = newValue;
    final int generation = ++_micStateGeneration;

    if (!isConnected) {
      _enableMicAfterConnect = newValue;
      testPrintLS(
        'LKC:: setMicEnabled: not connected yet → _enableMicAfterConnect=$newValue',
      );
      testPrintLS(
        DiagnosticLog.flow(
          'LiveKitController',
          'mic_deferred_until_connect',
          data: {'value': newValue},
        ),
      );
      return Future<void>.value();
    }

    _enableMicAfterConnect = false;

    // Pre-start iOS audio session reconfiguration immediately (same Dart event
    // loop tick as the button press).  The native setAppleAudioConfiguration
    // call is queued in the platform channel right away, so it races ahead of
    // the _micStateOperation chain and reduces the latency window that causes
    // mic_stale_enable_reverted on quick PTT taps (< ~300 ms hold time).
    // On disable we clear the reference so _applyDesiredMicState starts fresh.
    if (newValue &&
        Platform.isIOS &&
        !_shouldDeferIosAudioSessionConfiguration()) {
      _pendingIosPlayAndRecordConfig = _configureIosAudioSession(
        source: 'pre_set_mic_enabled',
        localMicActive: true,
      );
    } else {
      _pendingIosPlayAndRecordConfig = null;
    }

    // Release must not wait behind a slow in-flight enable (PTT race after BG).
    if (!newValue) {
      _micStateOperation = Future<void>.value().then(
        (_) => _applyDesiredMicState(
          source: 'set_mic_enabled',
          generation: generation,
        ),
      );
    } else {
      _micStateOperation = _micStateOperation.then(
        (_) => _applyDesiredMicState(
          source: 'set_mic_enabled',
          generation: generation,
        ),
      );
    }

    return _micStateOperation;
  }

  Future<void> _applyDesiredMicState({
    required String source,
    required int generation,
  }) async {
    if (!isConnected) {
      _enableMicAfterConnect = _desiredMicEnabled;
      testPrintLS(
        DiagnosticLog.flow(
          'LiveKitController',
          'mic_deferred_until_connect',
          data: {'value': _desiredMicEnabled, 'source': source},
        ),
      );
      return;
    }

    if (generation != _micStateGeneration) {
      testPrintLS(
        DiagnosticLog.flow(
          'LiveKitController',
          'mic_apply_skipped_stale',
          data: {
            'generation': generation,
            'currentGeneration': _micStateGeneration,
            'source': source,
          },
        ),
      );
      return;
    }

    final bool targetMicEnabled = _desiredMicEnabled;

    if (targetMicEnabled == _micEnabled) {
      if (!targetMicEnabled && _isLocalMicTrackUnmuted()) {
        testPrintLS(
          DiagnosticLog.flow(
            'LiveKitController',
            'mic_reconcile_mute',
            data: {'source': source},
          ),
        );
      } else {
        testPrintLS(
          DiagnosticLog.flow(
            'LiveKitController',
            'mic_noop_same_state',
            data: {'value': targetMicEnabled, 'source': source},
          ),
        );
        return;
      }
    }

    try {
      if (targetMicEnabled) {
        // If setMicEnabled(true) pre-started the audio session config, await
        // that future instead of issuing a second native call.  This way the
        // native setAppleAudioConfiguration is already running (or done) by
        // the time we reach here, cutting the PTT enable latency on quick taps.
        final Future<void>? preConfig = _pendingIosPlayAndRecordConfig;
        _pendingIosPlayAndRecordConfig = null;
        if (preConfig != null) {
          await preConfig;
        } else {
          await _configureIosAudioSession(
            source: 'before_$source',
            localMicActive: true,
          );
        }
        // Re-check staleness after the async audio-session call: a disable
        // arriving during this await would have already advanced the generation,
        // so skip the LiveKit API call to avoid a physical unmute/remute cycle.
        if (generation != _micStateGeneration) return;
      }
      await _setLiveKitMicrophoneEnabled(targetMicEnabled);
      if (generation != _micStateGeneration) {
        await _handleStaleMicOperation(
          generation: generation,
          appliedEnable: targetMicEnabled,
        );
        return;
      }
      _micEnabled = targetMicEnabled;
      await _configureIosAudioSession(
        source: source,
        localMicActive: targetMicEnabled,
      );
      // White noise sync is a side-effect and must not block the mic-state
      // operation chain: a stuck coordinator would prevent subsequent PTT
      // presses from activating the mic. Fire-and-forget is safe here because
      // the coordinator serialises its own queue independently.
      unawaited(_syncBackgroundWhiteNoise(source: source));
      testPrintLS('LKC:: DID setMicrophoneEnabled: $targetMicEnabled');
      testPrintLS(
        DiagnosticLog.flow(
          'LiveKitController',
          'mic_state_changed',
          data: {'value': targetMicEnabled, 'source': source},
        ),
      );
      _setState();

      if (_desiredMicEnabled != targetMicEnabled) {
        testPrintLS(
          DiagnosticLog.flow(
            'LiveKitController',
            'mic_desired_state_changed_during_apply',
            data: {
              'applied': targetMicEnabled,
              'desired': _desiredMicEnabled,
              'source': source,
            },
          ),
        );
        await _applyDesiredMicState(
          source: '${source}_latest',
          generation: _micStateGeneration,
        );
      }
    } catch (e) {
      testPrintLS('LKC:: setMicEnabled error: $e');
      testPrintLS(
        DiagnosticLog.err(
          'LiveKitController',
          'mic_state_change_failed',
          data: {'value': targetMicEnabled, 'source': source, 'error': e},
        ),
      );
      if (!targetMicEnabled) {
        try {
          await _setLiveKitMicrophoneEnabled(false);
        } catch (_) {}
        _micEnabled = false;
        if (generation == _micStateGeneration) {
          if (!_shouldDeferIosAudioSessionConfiguration()) {
            await _configureIosAudioSession(
              source: '${source}_error_recovery',
              localMicActive: false,
            );
          }
          unawaited(
            _syncBackgroundWhiteNoise(source: '${source}_error_recovery'),
          );
          _setState();
        }
      }
      if (generation == _micStateGeneration &&
          _desiredMicEnabled != _micEnabled) {
        await _applyDesiredMicState(
          source: '${source}_retry',
          generation: _micStateGeneration,
        );
      }
    }
  }

  /*
  [speakerOn] включает или выключает громкую связь; 
  по умолчанию проводные/Bluetooth-гарнитуры будут по-прежнему иметь приоритет, 
  даже если установлено значение true. 

  [forceSpeakerOutput] если true, принудительно выводит звук через динамик, 
  даже если подключены наушники или Bluetooth-гарнитура; 
  пока поддерживается только на iOS.
  */
  // void _setSpeakerphoneOn() async {
  //   // _speakerphoneOn = !_speakerphoneOn;
  //   await _room.setSpeakerOn(true, forceSpeakerOutput: false);
  //   _setState();
  // }

  List<Participant> get allParticipants {
    final List<Participant> list = <Participant>[];
    final LocalParticipant? local = _room.localParticipant;
    if (local != null) {
      list.add(local);
    }
    list.addAll(_room.remoteParticipants.values);
    return list;
  }

  CallMemberStatus getStatus({required String userId}) {
    final DateTime now = DateTime.now();
    final LocalParticipant? local = _room.localParticipant;
    if (local?.identity == userId) {
      return isConnected ? CallMemberStatus.listening : CallMemberStatus.silent;
    }

    if (_room.remoteParticipants[userId] == null) {
      return CallMemberStatus.silent;
    }

    return remotePresenceStatus(
      now: now,
      isInRemoteParticipants: true,
      lastHeartbeatAt: _presenceLastSeen[userId],
      participantConnectedAt: _presenceConnectedAt[userId],
    );
  }

  String get statusLabel {
    switch (_room.connectionState) {
      case ConnectionState.connected:
        return 'Connected';
      case ConnectionState.connecting:
        return 'Connecting...';
      case ConnectionState.reconnecting:
        return 'Reconnecting...';
      case ConnectionState.disconnected:
        return 'Disconnected';
    }
  }

  Color get statusColor {
    switch (_room.connectionState) {
      case ConnectionState.connected:
        return Colors.green;
      case ConnectionState.connecting:
      case ConnectionState.reconnecting:
        return Colors.orange;
      case ConnectionState.disconnected:
        return Colors.grey;
    }
  }
}
