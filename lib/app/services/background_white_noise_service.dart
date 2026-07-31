import 'dart:async';

import 'package:just_audio/just_audio.dart';

const String kBackgroundWhiteNoiseAssetPath = 'assets/audio/white_noise.wav';
const double kBackgroundWhiteNoiseVolume = 0.0005;
const Duration kBackgroundWhiteNoiseResumeDelay = Duration(milliseconds: 1500);

abstract interface class LocalWhiteNoisePlayer {
  bool get isPlaybackActive;

  Future<void> start();

  Future<void> stop();

  Future<void> dispose();
}

class JustAudioWhiteNoisePlayer implements LocalWhiteNoisePlayer {
  JustAudioWhiteNoisePlayer({AudioPlayer? player})
    : _player = player ?? AudioPlayer();

  final AudioPlayer _player;
  bool _isPrepared = false;

  @override
  bool get isPlaybackActive => _player.playing;

  @override
  Future<void> start() async {
    if (_player.playing) return;

    if (!_isPrepared) {
      await _player.setLoopMode(LoopMode.one);
      await _player.setVolume(kBackgroundWhiteNoiseVolume);
      await _player.setAsset(kBackgroundWhiteNoiseAssetPath);
      _isPrepared = true;
    }

    // iOS audio session may be slow after interruptions — guard against a hang.
    await _player.play().timeout(const Duration(seconds: 5), onTimeout: () {});
  }

  @override
  Future<void> stop() async {
    if (!_player.playing) return;

    // pause() and seek() can hang indefinitely when the iOS AVAudioSession is
    // in a bad state (e.g. after an interruption). Use timeouts so the
    // coordinator's internal queue never gets permanently blocked.
    try {
      await _player.pause().timeout(const Duration(seconds: 3));
    } catch (_) {}
    try {
      await _player.seek(Duration.zero).timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  @override
  Future<void> dispose() => _player.dispose();
}

typedef WhiteNoiseTimerFactory =
    Timer Function(Duration duration, void Function() callback);

typedef WhiteNoiseErrorHandler =
    void Function(Object error, StackTrace stackTrace);

typedef WhiteNoisePlaybackChanged = Future<void> Function(bool isPlaying);

class BackgroundWhiteNoiseCoordinator {
  BackgroundWhiteNoiseCoordinator({
    required LocalWhiteNoisePlayer player,
    Duration resumeDelay = kBackgroundWhiteNoiseResumeDelay,
    WhiteNoiseTimerFactory? timerFactory,
    WhiteNoiseErrorHandler? onError,
    WhiteNoisePlaybackChanged? onPlaybackChanged,
  }) : _player = player,
       _resumeDelay = resumeDelay,
       _timerFactory = timerFactory ?? Timer.new,
       _onError = onError,
       _onPlaybackChanged = onPlaybackChanged;

  final LocalWhiteNoisePlayer _player;
  final Duration _resumeDelay;
  final WhiteNoiseTimerFactory _timerFactory;
  final WhiteNoiseErrorHandler? _onError;
  final WhiteNoisePlaybackChanged? _onPlaybackChanged;

  bool _isAppInForeground = true;
  bool _hasRemoteSpeaker = false;
  bool _localMicEnabled = false;
  bool _isSuppressed = false;
  bool _isPlaying = false;
  Timer? _resumeTimer;
  Future<void> _operation = Future<void>.value();

  bool get isPlaying => _isPlaying;

  bool get isPlaybackActive => _player.isPlaybackActive;

  Future<void> update({
    bool? isAppInForeground,
    bool? hasRemoteSpeaker,
    bool? localMicEnabled,
    bool? isSuppressed,
  }) {
    _isAppInForeground = isAppInForeground ?? _isAppInForeground;
    _hasRemoteSpeaker = hasRemoteSpeaker ?? _hasRemoteSpeaker;
    _localMicEnabled = localMicEnabled ?? _localMicEnabled;
    _isSuppressed = isSuppressed ?? _isSuppressed;

    return _enqueue(() => _sync(delayStart: false));
  }

  /// Stops playback immediately and cancels any pending resume timer.
  Future<void> forceStop() {
    return _enqueue(() async {
      _cancelResumeTimer();
      await _safeStop();
    });
  }

  Future<void> dispose() async {
    _cancelResumeTimer();
    await _operation;
    await _safeStop();
    await _player.dispose();
  }

  /// Clears a stale playing flag after iOS silently stops playback (e.g. audio
  /// interruption) and restarts white noise when still eligible.
  Future<void> recoverFromInterruption() {
    return _enqueue(() async {
      _cancelResumeTimer();
      _isPlaying = false;
      await _sync(delayStart: false);
    });
  }

  /// Drops the in-memory playing flag when iOS pauses audio without a clean stop.
  Future<void> clearStalePlayingFlag() {
    return _enqueue(() async {
      _cancelResumeTimer();
      _isPlaying = false;
    });
  }

  /// Restarts playback when eligible but the player is not actually playing.
  Future<void> ensurePlaybackIfEligible() {
    return _enqueue(() async {
      if (!_isEligible) return;

      if (_isPlaying && _player.isPlaybackActive) return;

      _isPlaying = false;
      await _sync(delayStart: false);
    });
  }

  // White noise plays whenever the app is in background, including when a
  // remote participant is speaking.  At volume 0.0005 it is inaudible, but it
  // keeps the iOS AVAudioSession alive so the Dart VM is not suspended by the
  // OS.  Stopping white noise during remote speech caused the VM to freeze,
  // preventing the coordinator's own _player.play() call from completing and
  // blocking all subsequent coordinator operations until the OS woke the app
  // for an unrelated reason.  Connection state is intentionally ignored.
  bool get _isEligible =>
      !_isSuppressed && !_isAppInForeground && !_localMicEnabled;

  Future<void> _enqueue(Future<void> Function() action) {
    _operation = _operation.then((_) => action()).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      _onError?.call(error, stackTrace);
    });

    return _operation;
  }

  Future<void> _sync({required bool delayStart}) async {
    if (!_isEligible) {
      _cancelResumeTimer();
      await _safeStop();
      return;
    }

    if (_isPlaying && !_player.isPlaybackActive) {
      _isPlaying = false;
    }

    if (_isPlaying) return;

    // iOS may not fire Dart timers while the app is suspended in background.
    // Start immediately once we are already backgrounded and eligible.
    final bool shouldDelayStart = delayStart && _isAppInForeground;
    if (shouldDelayStart) {
      if (_resumeTimer != null) return;
      _scheduleResume();
      return;
    }

    _cancelResumeTimer();
    await _safeStart();
  }

  void _scheduleResume() {
    _cancelResumeTimer();
    _resumeTimer = _timerFactory(_resumeDelay, () {
      _resumeTimer = null;
      if (!_isEligible || _isPlaying) return;

      unawaited(_enqueue(_safeStart));
    });
  }

  void _cancelResumeTimer() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
  }

  Future<void> _safeStart() async {
    if (_isPlaying && _player.isPlaybackActive) return;

    try {
      await _player.start();
      if (!_player.isPlaybackActive) {
        _isPlaying = false;
        return;
      }
      _isPlaying = true;
      await _onPlaybackChanged?.call(true);
    } catch (error, stackTrace) {
      _isPlaying = false;
      _onError?.call(error, stackTrace);
    }
  }

  Future<void> _safeStop() async {
    if (!_isPlaying) return;

    try {
      await _player.stop();
    } catch (error, stackTrace) {
      _onError?.call(error, stackTrace);
    } finally {
      _isPlaying = false;
      await _onPlaybackChanged?.call(false);
    }
  }
}
