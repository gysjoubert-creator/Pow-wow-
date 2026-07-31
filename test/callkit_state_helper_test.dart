import 'package:pow_wow/app/utils/callkit_state_helper.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('callkit state helper', () {
    test('finds accepted call from mixed payload keys', () {
      final Map<String, dynamic>? acceptedCall = findAcceptedCallkitCall(
        <dynamic>[
          <String, dynamic>{'id': 'ringing-call', 'accepted': false},
          <String, dynamic>{'id': 'accepted-call', 'isAccepted': true},
        ],
      );

      expect(acceptedCall, isNotNull);
      expect(acceptedCall?['id'], 'accepted-call');
    });

    test('treats non-accepted active call as ringing', () {
      final bool hasRingingCall = hasRingingCallkitCall(<dynamic>[
        <String, dynamic>{'id': 'ringing-call', 'accepted': false},
      ]);

      expect(hasRingingCall, isTrue);
    });

    test('ignores malformed active call items', () {
      final List<Map<String, dynamic>> calls = normalizeActiveCallkitCalls(
        <dynamic>[
          'unexpected',
          42,
          <String, dynamic>{'id': 'valid-call', 'accepted': false},
        ],
      );

      expect(calls, hasLength(1));
      expect(calls.single['id'], 'valid-call');
    });

    test('defers ios audio session config while CallKit owns the session', () {
      expect(
        shouldDeferIosAudioSessionConfiguration(
          isIOS: true,
          iosCallkitAudioSessionActive: true,
          pendingAcceptedCallId: null,
          appLifecycle: AppLifecycleState.resumed,
        ),
        isTrue,
      );
    });

    test(
      'defers ios audio session config on CallKit UI before app foreground',
      () {
        expect(
          shouldDeferIosAudioSessionConfiguration(
            isIOS: true,
            iosCallkitAudioSessionActive: false,
            pendingAcceptedCallId: 'call-id',
            appLifecycle: AppLifecycleState.inactive,
          ),
          isTrue,
        );
      },
    );

    test('allows ios audio session config after foreground resume', () {
      expect(
        shouldDeferIosAudioSessionConfiguration(
          isIOS: true,
          iosCallkitAudioSessionActive: false,
          pendingAcceptedCallId: 'call-id',
          appLifecycle: AppLifecycleState.resumed,
        ),
        isFalse,
      );
    });

    test('suppresses background white noise during incoming call flow', () {
      expect(
        shouldSuppressBackgroundWhiteNoise(
          isIOS: true,
          incomingCallRinging: true,
          declinedIncomingCallBeforeForeground: false,
        ),
        isTrue,
      );
      expect(
        shouldSuppressBackgroundWhiteNoise(
          isIOS: true,
          incomingCallRinging: false,
          declinedIncomingCallBeforeForeground: true,
        ),
        isTrue,
      );
      expect(
        shouldSuppressBackgroundWhiteNoise(
          isIOS: true,
          incomingCallRinging: false,
          declinedIncomingCallBeforeForeground: false,
        ),
        isFalse,
      );
    });
  });
}
