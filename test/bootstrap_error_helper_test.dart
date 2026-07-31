import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pow_wow/app/services/api_service.dart';
import 'package:pow_wow/app/utils/bootstrap_error_helper.dart';

void main() {
  group('bootstrapErrorMessage', () {
    test('maps FirebaseAuth network errors to connection message', () {
      final error = FirebaseAuthException(code: 'network-request-failed');

      expect(
        bootstrapErrorMessage(error),
        bootstrapConnectionErrorMessage,
      );
      expect(isNetworkBootstrapError(error), isTrue);
    });

    test('maps SocketException to connection message', () {
      final error = const SocketException('Failed host lookup');

      expect(
        bootstrapErrorMessage(error),
        bootstrapConnectionErrorMessage,
      );
      expect(isNetworkBootstrapError(error), isTrue);
    });

    test('maps http ClientException to connection message', () {
      final error = http.ClientException('Connection failed');

      expect(
        bootstrapErrorMessage(error),
        bootstrapConnectionErrorMessage,
      );
      expect(isNetworkBootstrapError(error), isTrue);
    });

    test('maps unknown errors to generic message', () {
      final error = Exception('unexpected');

      expect(bootstrapErrorMessage(error), bootstrapGenericErrorMessage);
      expect(isNetworkBootstrapError(error), isFalse);
    });

    test('maps HandshakeException to connection message', () {
      final error = HandshakeException('Connection terminated during handshake');

      expect(
        bootstrapErrorMessage(error),
        bootstrapConnectionErrorMessage,
      );
      expect(isNetworkBootstrapError(error), isTrue);
    });

    test('maps transient API failures to connection message', () {
      const error = ApiServiceException('Service unavailable', statusCode: 503);

      expect(
        bootstrapErrorMessage(error),
        bootstrapConnectionErrorMessage,
      );
      expect(isNetworkBootstrapError(error), isTrue);
    });
  });
}
