import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';

import '../services/api_service.dart';

const String bootstrapConnectionErrorMessage = 'Internet connection error';
const String bootstrapGenericErrorMessage =
    'Something went wrong. Please try again.';

/// Shown when the LiveKit voice-room join fails (timeout, duplicate identity,
/// WebRTC ICE failure, etc.). Intentionally avoids "Internet" wording because
/// the user's network may be fine while the room-level connection fails.
const String liveKitConnectionErrorMessage = 'Voice room connection failed';

const Set<String> _firebaseAuthNetworkCodes = <String>{
  'network-request-failed',
  'network-error',
};

const Set<String> _firebaseNetworkCodes = <String>{
  'unavailable',
  'deadline-exceeded',
};

bool isNetworkBootstrapError(Object error) {
  if (error is ApiServiceException && error.isTransientNetworkFailure) {
    return true;
  }

  if (error is FirebaseAuthException) {
    return _firebaseAuthNetworkCodes.contains(error.code);
  }

  if (error is FirebaseException) {
    return _firebaseNetworkCodes.contains(error.code);
  }

  return error is SocketException ||
      error is HttpException ||
      error is HandshakeException ||
      error is TimeoutException ||
      _isHttpClientException(error);
}

bool _isHttpClientException(Object error) {
  return error.runtimeType.toString() == 'ClientException';
}

String bootstrapErrorMessage(Object error) {
  if (isNetworkBootstrapError(error)) {
    return bootstrapConnectionErrorMessage;
  }

  return bootstrapGenericErrorMessage;
}
