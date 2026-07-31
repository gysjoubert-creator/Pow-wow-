import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pow_wow/app/services/background_white_noise_service.dart';

class FakeWhiteNoisePlayer implements LocalWhiteNoisePlayer {
  int startCount = 0;
  int stopCount = 0;
  int disposeCount = 0;
  bool playbackActive = false;

  @override
  bool get isPlaybackActive => playbackActive;

  @override
  Future<void> start() async {
    startCount++;
    playbackActive = true;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    playbackActive = false;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}

void main() {
  group('BackgroundWhiteNoiseCoordinator', () {
    test('does not start in foreground', () {
      fakeAsync((async) {
        final player = FakeWhiteNoisePlayer();
        final coordinator = BackgroundWhiteNoiseCoordinator(player: player);

        coordinator.update(
          isAppInForeground: true,
          hasRemoteSpeaker: false,
          localMicEnabled: false,
        );
        async.flushMicrotasks();

        expect(player.startCount, 0);
        expect(coordinator.isPlaying, isFalse);
      });
    });

    test('starts when backgrounded and silent', () {
      fakeAsync((async) {
        final player = FakeWhiteNoisePlayer();
        final coordinator = BackgroundWhiteNoiseCoordinator(player: player);

        coordinator.update(
          isAppInForeground: false,
          hasRemoteSpeaker: false,
          localMicEnabled: false,
        );
        async.flushMicrotasks();

        expect(player.startCount, 1);
        expect(coordinator.isPlaying, isTrue);
      });
    });

    test('starts in background even when not connected to a room', () {
      // White noise is connection-agnostic: it keeps the iOS AVAudioSession
      // alive so that RTCPeerConnection addTransceiver calls succeed during
      // reconnects in background.
      fakeAsync((async) {
        final player = FakeWhiteNoisePlayer();
        final coordinator = BackgroundWhiteNoiseCoordinator(player: player);

        coordinator.update(
          isAppInForeground: false,
          hasRemoteSpeaker: false,
          localMicEnabled: false,
        );
        async.flushMicrotasks();

        // Stays playing even after additional updates with no connection
        coordinator.update(hasRemoteSpeaker: false);
        async.flushMicrotasks();

        expect(player.startCount, 1);
        expect(player.stopCount, 0);
        expect(coordinator.isPlaying, isTrue);
      });
    });

    // BG-03: white noise keeps playing silently (volume=0.0005) even when a
    // remote speaker is active.  Stopping it would freeze the Dart VM in iOS
    // background mode, blocking the coordinator's own restart call.
    test('stays playing when remote speaker becomes active', () {
      fakeAsync((async) {
        final player = FakeWhiteNoisePlayer();
        final coordinator = BackgroundWhiteNoiseCoordinator(player: player);

        coordinator.update(
          isAppInForeground: false,
          hasRemoteSpeaker: false,
          localMicEnabled: false,
        );
        async.flushMicrotasks();

        coordinator.update(hasRemoteSpeaker: true);
        async.flushMicrotasks();

        expect(player.startCount, 1);
        expect(player.stopCount, 0);
        expect(coordinator.isPlaying, isTrue);
      });
    });

    // BG-04: white noise is never stopped on speaker active/inactive cycles in
    // background, so there is nothing to restart — it stays playing throughout.
    test(
      'keeps playing throughout speaker active/inactive cycle in background',
      () {
        fakeAsync((async) {
          final player = FakeWhiteNoisePlayer();
          final coordinator = BackgroundWhiteNoiseCoordinator(player: player);

          coordinator.update(
            isAppInForeground: false,
            hasRemoteSpeaker: false,
            localMicEnabled: false,
          );
          async.flushMicrotasks();
          coordinator.update(hasRemoteSpeaker: true);
          async.flushMicrotasks();

          coordinator.update(hasRemoteSpeaker: false);
          async.flushMicrotasks();

          expect(player.startCount, 1);
          expect(player.stopCount, 0);
          expect(coordinator.isPlaying, isTrue);
        });
      },
    );

    // BG-02 is no longer a distinct scenario: white noise starts immediately
    // in background regardless of the initial hasRemoteSpeaker value.
    test('starts immediately in background even with stale remote speaker', () {
      fakeAsync((async) {
        final player = FakeWhiteNoisePlayer();
        final coordinator = BackgroundWhiteNoiseCoordinator(player: player);

        coordinator.update(
          isAppInForeground: false,
          hasRemoteSpeaker: true,
          localMicEnabled: false,
        );
        async.flushMicrotasks();
        expect(player.startCount, 1);
        expect(coordinator.isPlaying, isTrue);

        coordinator.update(hasRemoteSpeaker: false);
        async.flushMicrotasks();
        expect(player.startCount, 1);
        expect(player.stopCount, 0);
        expect(coordinator.isPlaying, isTrue);
      });
    });

    test('stops when the local microphone is enabled', () {
      fakeAsync((async) {
        final player = FakeWhiteNoisePlayer();
        final coordinator = BackgroundWhiteNoiseCoordinator(player: player);

        coordinator.update(
          isAppInForeground: false,
          hasRemoteSpeaker: false,
          localMicEnabled: false,
        );
        async.flushMicrotasks();

        coordinator.update(localMicEnabled: true);
        async.flushMicrotasks();

        expect(player.startCount, 1);
        expect(player.stopCount, 1);
        expect(coordinator.isPlaying, isFalse);
      });
    });

    test('stops when the app comes to foreground', () {
      fakeAsync((async) {
        final player = FakeWhiteNoisePlayer();
        final coordinator = BackgroundWhiteNoiseCoordinator(player: player);

        coordinator.update(
          isAppInForeground: false,
          hasRemoteSpeaker: false,
          localMicEnabled: false,
        );
        async.flushMicrotasks();

        coordinator.update(isAppInForeground: true);
        async.flushMicrotasks();

        expect(player.startCount, 1);
        expect(player.stopCount, 1);
        expect(coordinator.isPlaying, isFalse);
      });
    });

    test('does not start while incoming call flow is suppressed', () {
      fakeAsync((async) {
        final player = FakeWhiteNoisePlayer();
        final coordinator = BackgroundWhiteNoiseCoordinator(player: player);

        coordinator.update(
          isAppInForeground: false,
          hasRemoteSpeaker: false,
          localMicEnabled: false,
          isSuppressed: true,
        );
        async.flushMicrotasks();

        expect(player.startCount, 0);
        expect(coordinator.isPlaying, isFalse);
      });
    });

    test('forceStop cancels pending resume and stops playback', () {
      fakeAsync((async) {
        final player = FakeWhiteNoisePlayer();
        final coordinator = BackgroundWhiteNoiseCoordinator(player: player);

        coordinator.update(
          isAppInForeground: false,
          hasRemoteSpeaker: false,
          localMicEnabled: false,
        );
        async.flushMicrotasks();
        // Speaker events no longer stop white noise, so noise plays throughout.
        coordinator.update(hasRemoteSpeaker: true);
        async.flushMicrotasks();
        coordinator.update(hasRemoteSpeaker: false);
        async.flushMicrotasks();

        coordinator.forceStop();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        expect(player.stopCount, 1);
        expect(player.startCount, 1);
        expect(coordinator.isPlaying, isFalse);
      });
    });

    test('recoverFromInterruption restarts after ghost playing state', () {
      fakeAsync((async) {
        final player = FakeWhiteNoisePlayer();
        final coordinator = BackgroundWhiteNoiseCoordinator(player: player);

        coordinator.update(
          isAppInForeground: false,
          hasRemoteSpeaker: false,
          localMicEnabled: false,
        );
        async.flushMicrotasks();

        expect(player.startCount, 1);
        expect(coordinator.isPlaying, isTrue);

        coordinator.recoverFromInterruption();
        async.flushMicrotasks();

        expect(player.startCount, 2);
        expect(coordinator.isPlaying, isTrue);
      });
    });

    test('ensurePlaybackIfEligible restarts when flag is stale', () {
      fakeAsync((async) {
        final player = FakeWhiteNoisePlayer();
        final coordinator = BackgroundWhiteNoiseCoordinator(player: player);

        coordinator.update(
          isAppInForeground: false,
          hasRemoteSpeaker: false,
          localMicEnabled: false,
        );
        async.flushMicrotasks();
        expect(coordinator.isPlaying, isTrue);
        expect(coordinator.isPlaybackActive, isTrue);

        player.playbackActive = false;
        coordinator.ensurePlaybackIfEligible();
        async.flushMicrotasks();

        expect(player.startCount, 2);
        expect(coordinator.isPlaying, isTrue);
        expect(coordinator.isPlaybackActive, isTrue);
      });
    });

    test('ensurePlaybackIfEligible does not restart active playback', () {
      fakeAsync((async) {
        final player = FakeWhiteNoisePlayer();
        final coordinator = BackgroundWhiteNoiseCoordinator(player: player);

        coordinator.update(
          isAppInForeground: false,
          hasRemoteSpeaker: false,
          localMicEnabled: false,
        );
        async.flushMicrotasks();

        coordinator.ensurePlaybackIfEligible();
        async.flushMicrotasks();

        expect(player.startCount, 1);
        expect(coordinator.isPlaying, isTrue);
        expect(coordinator.isPlaybackActive, isTrue);
      });
    });

    test('clearStalePlayingFlag allows a later sync to restart', () {
      fakeAsync((async) {
        final player = FakeWhiteNoisePlayer();
        final coordinator = BackgroundWhiteNoiseCoordinator(player: player);

        coordinator.update(
          isAppInForeground: false,
          hasRemoteSpeaker: false,
          localMicEnabled: false,
        );
        async.flushMicrotasks();

        coordinator.clearStalePlayingFlag();
        async.flushMicrotasks();
        expect(coordinator.isPlaying, isFalse);

        coordinator.update(isAppInForeground: false, hasRemoteSpeaker: false);
        async.flushMicrotasks();

        expect(player.startCount, 2);
        expect(coordinator.isPlaying, isTrue);
      });
    });
  });
}
