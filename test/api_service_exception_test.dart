import 'package:flutter_test/flutter_test.dart';
import 'package:pow_wow/app/services/api_service.dart';

void main() {
  group('ApiServiceException', () {
    test('detects APNs topic mismatch from backend detail', () {
      const error = ApiServiceException(
        'APNs Error: {"reason":"DeviceTokenNotForTopic"}',
        statusCode: 500,
        details:
            '{"detail":"APNs Error: {\\"reason\\":\\"DeviceTokenNotForTopic\\"}"}',
      );

      expect(error.isApnsDeviceTokenNotForTopic, isTrue);
    });

    test(
      'does not classify unrelated backend errors as APNs topic mismatch',
      () {
        const error = ApiServiceException(
          'Unable to send call',
          statusCode: 500,
        );

        expect(error.isApnsDeviceTokenNotForTopic, isFalse);
        expect(error.isPushDeliveryError, isFalse);
      },
    );

    test('detects auth errors by status code', () {
      const unauthorized = ApiServiceException('Unauthorized', statusCode: 401);
      const forbidden = ApiServiceException('Forbidden', statusCode: 403);
      const serverError = ApiServiceException('Server error', statusCode: 500);

      expect(unauthorized.isAuthError, isTrue);
      expect(forbidden.isAuthError, isTrue);
      expect(serverError.isAuthError, isFalse);
    });

    test('detects generic push delivery failures', () {
      const error = ApiServiceException(
        'FCM Error: registration token not registered',
        statusCode: 500,
      );

      expect(error.isPushDeliveryError, isTrue);
    });

    test('detects transient network failures by status code', () {
      const gateway = ApiServiceException('Bad gateway', statusCode: 502);
      const unavailable = ApiServiceException('Unavailable', statusCode: 503);
      const timeout = ApiServiceException('Gateway timeout', statusCode: 504);
      const serverError = ApiServiceException('Server error', statusCode: 500);

      expect(gateway.isTransientNetworkFailure, isTrue);
      expect(unavailable.isTransientNetworkFailure, isTrue);
      expect(timeout.isTransientNetworkFailure, isTrue);
      expect(serverError.isTransientNetworkFailure, isFalse);
    });
  });
}
