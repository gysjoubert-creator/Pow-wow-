import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pow_wow/app/services/api_service.dart';
import 'package:pow_wow/app/utils/bootstrap_error_helper.dart';
import 'package:pow_wow/app/utils/screen_helper.dart';

void main() {
  group('sendCallErrorMessage', () {
    test('maps missing callee token to open-app message', () {
      const error = ApiServiceException(
        'Target user id not found',
        statusCode: 404,
      );

      expect(
        ScreenHelper.sendCallErrorMessage(
          recipientName: 'Jane',
          error: error,
        ),
        "Jane isn't ready for calls yet. Ask them to open the app and try again.",
      );
    });

    test('maps APNs topic mismatch to update-app message', () {
      const error = ApiServiceException(
        'APNs Error: {"reason":"DeviceTokenNotForTopic"}',
        statusCode: 500,
        details:
            '{"detail":"APNs Error: {\\"reason\\":\\"DeviceTokenNotForTopic\\"}"}',
      );

      expect(
        ScreenHelper.sendCallErrorMessage(
          recipientName: 'Jane',
          error: error,
        ),
        "We couldn't reach Jane for a call. Ask them to update the app and try again.",
      );
    });

    test('maps network failures to connection message', () {
      final error = const SocketException('Failed host lookup');

      expect(
        ScreenHelper.sendCallErrorMessage(
          recipientName: 'Jane',
          error: error,
        ),
        bootstrapConnectionErrorMessage,
      );
    });

    test('maps auth failures to sign-in message', () {
      const error = ApiServiceException('Unauthorized', statusCode: 401);

      expect(
        ScreenHelper.sendCallErrorMessage(
          recipientName: 'Jane',
          error: error,
        ),
        "Couldn't send the call. Please sign in again.",
      );
    });

    test('maps missing Firebase token to sign-in message', () {
      final error = StateError('sendIncomingCall failed: FirebaseIdToken is null');

      expect(
        ScreenHelper.sendCallErrorMessage(
          recipientName: 'Jane',
          error: error,
        ),
        "Couldn't send the call. Please sign in again.",
      );
    });

    test('maps unknown backend failures to generic message', () {
      const error = ApiServiceException('Unable to send call', statusCode: 500);

      expect(
        ScreenHelper.sendCallErrorMessage(
          recipientName: 'Jane',
          error: error,
        ),
        bootstrapGenericErrorMessage,
      );
    });

    test('maps http client failures to connection message', () {
      final error = http.ClientException('Connection failed');

      expect(
        ScreenHelper.sendCallErrorMessage(
          recipientName: 'Jane',
          error: error,
        ),
        bootstrapConnectionErrorMessage,
      );
    });

    test('maps transient HTTP failures to connection message', () {
      const error = ApiServiceException('Bad gateway', statusCode: 502);

      expect(
        ScreenHelper.sendCallErrorMessage(
          recipientName: 'Jane',
          error: error,
        ),
        bootstrapConnectionErrorMessage,
      );
    });
  });
}
