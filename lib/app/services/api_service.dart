import 'dart:convert';
import 'package:pow_wow/main.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../data/models/tribe_message.dart';
import 'firebase/auth_service.dart';

class ApiServiceException implements Exception {
  final String message;
  final int? statusCode;
  final Object? details;

  const ApiServiceException(this.message, {this.statusCode, this.details});

  bool get isTargetUserNotFound =>
      statusCode == 404 && message.toLowerCase().contains('target user id');

  bool get isApnsDeviceTokenNotForTopic => isPushDeliveryError;

  bool get isPushDeliveryError {
    final String errorText = '$message $details'.toLowerCase();
    if (errorText.contains('apns error') || errorText.contains('fcm error')) {
      return true;
    }

    const Set<String> pushFailureMarkers = <String>{
      'devicetokennotfortopic',
      'baddevicetoken',
      'unregistered',
      'invalid registration',
      'messaging/third-party-auth-error',
    };

    return pushFailureMarkers.any(errorText.contains);
  }

  bool get isAuthError => statusCode == 401 || statusCode == 403;

  bool get isTransientNetworkFailure {
    return statusCode == 502 || statusCode == 503 || statusCode == 504;
  }

  @override
  String toString() {
    return 'ApiServiceException(statusCode: $statusCode, message: $message, details: $details)';
  }
}

class LiveKitConnectionDetails {
  final String token;
  final String url;

  const LiveKitConnectionDetails({required this.token, required this.url});
}

class ApiService {
  final String? membersUrl;
  final String? lastMessageUrl;
  const ApiService({this.membersUrl, this.lastMessageUrl});

  String? _extractErrorMessage(String responseBody) {
    if (responseBody.trim().isEmpty) return null;

    try {
      final Object? decoded = jsonDecode(responseBody) as Object?;
      if (decoded is Map<String, dynamic>) {
        final Object? detail = decoded['detail'] ?? decoded['message'];
        if (detail is String && detail.trim().isNotEmpty) {
          return detail.trim();
        }
      }
    } catch (_) {
      // Keep the raw body fallback below when the response is not JSON.
    }

    return responseBody.trim();
  }

  Future<String?> _getFirebaseIdToken() async {
    if (Get.isRegistered<AuthService>()) {
      return await Get.find<AuthService>().getFirebaseIdToken();
    }
    return null;
  }

  Future<TribeMessage?> fetchLastMessage() async {
    if (lastMessageUrl == null || lastMessageUrl!.isEmpty) {
      return TribeMessage(
        id: 'msg_1',
        senderName: 'Liam',
        text: 'Hey guys, heading home now.',
        createdAt: DateTime(2000),
      );
    }

    final res = await http.get(Uri.parse(lastMessageUrl!));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('fetchLastMessage failed: ${res.statusCode}');
    }

    final decoded = jsonDecode(res.body) as Object?;
    if (decoded == null) return null;
    if (decoded is! Map<String, dynamic>) return null;

    final createdAtRaw = decoded['createdAt'];
    final createdAt = createdAtRaw is String
        ? DateTime.tryParse(createdAtRaw) ?? DateTime.now()
        : DateTime.now();

    return TribeMessage(
      id: decoded['id'] as String,
      senderName: decoded['senderName'] as String,
      text: decoded['text'] as String,
      createdAt: createdAt,
    );
  }

  /// LiveKit tokens must grant `can_publish_data: true` for PowWow presence
  /// heartbeats (`publishData` on topic `powwow.presence`).
  Future<LiveKitConnectionDetails> fetchLiveKitToken({
    required String userId,
    required String tribeId,
    required String name,
  }) async {
    final authToken = await _getFirebaseIdToken();
    if (authToken == null) {
      throw StateError('fetchLiveKitToken failed: FirebaseIdToken is null');
    }

    final String url =
        'https://api-livekit-tokens-237694335752.us-central1.run.app/api/livekit/tokens';

    final http.Response res = await http.post(
      Uri.parse(url),
      headers: <String, String>{
        'Authorization': authToken,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{
        'userId': userId,
        'tribeID': tribeId,
        'name': name,
      }),
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        'fetchLiveKitToken failed: ${res.statusCode}, body: ${res.body}',
      );
    }

    final Object? decoded = jsonDecode(res.body) as Object?;
    if (decoded is! Map<String, dynamic>) {
      throw StateError('fetchLiveKitToken failed: invalid response format');
    }

    final Object? token = decoded['token'];
    if (token is! String || token.isEmpty) {
      throw StateError('fetchLiveKitToken failed: token not found');
    }

    final Object? liveKitUrl = decoded['url'];
    if (liveKitUrl is! String || liveKitUrl.isEmpty) {
      throw StateError('fetchLiveKitToken failed: url not found');
    }

    return LiveKitConnectionDetails(token: token, url: liveKitUrl);
  }

  Future<void> sendIncomingCall({
    required String userId,
    required String tribeId,
  }) async {
    final authToken = await _getFirebaseIdToken();
    if (authToken == null) {
      throw StateError('sendIncomingCall failed: FirebaseIdToken is null');
    }

    final String url =
        'https://push-api-service-237694335752.us-central1.run.app/api/call';
    testPrintLS(
      'AS:: sendIncomingCall: request targetUserId=$userId, tribeId=$tribeId',
    );

    final http.Response res = await http.post(
      Uri.parse(url),
      headers: <String, String>{
        'Authorization': authToken,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{
        'targetUserId': userId,
        'tribeId': tribeId,
      }),
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      final String errorMessage =
          _extractErrorMessage(res.body) ?? 'Unable to send call';
      testPrintLS(
        'AS:: sendIncomingCall: ❌ ERROR: statusCode = ${res.statusCode}, body = ${res.body}',
      );
      throw ApiServiceException(
        errorMessage,
        statusCode: res.statusCode,
        details: res.body,
      );
    }

    testPrintLS(
      'AS:: sendIncomingCall: ✅ OK statusCode = ${res.statusCode}, body = ${res.body}',
    );
  }
}
