import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../services/api_service.dart';
import 'bootstrap_error_helper.dart';

class ScreenHelper {
  static void showGenericErrorSnackbar(Object error) {
    showErrorSnackbar(bootstrapErrorMessage(error));
  }

  static void showErrorSnackbar(String error) {
    showSnackbar('Error', error);
  }

  static void showSendCallSnackbar(String name) {
    showSnackbar('', 'Call sent to $name');
  }

  static String sendCallErrorMessage({
    required String recipientName,
    required Object error,
  }) {
    if (error is ApiServiceException && error.isTargetUserNotFound) {
      return "$recipientName isn't ready for calls yet. Ask them to open the app and try again.";
    }

    if (error is ApiServiceException && error.isPushDeliveryError) {
      return "We couldn't reach $recipientName for a call. Ask them to update the app and try again.";
    }

    if (_isSendCallAuthError(error)) {
      return "Couldn't send the call. Please sign in again.";
    }

    return bootstrapErrorMessage(error);
  }

  static bool _isSendCallAuthError(Object error) {
    if (error is ApiServiceException && error.isAuthError) {
      return true;
    }

    return error is StateError &&
        error.message.contains('FirebaseIdToken is null');
  }

  static void showSendCallErrorSnackbar({
    required String recipientName,
    required Object error,
  }) {
    showErrorSnackbar(
      sendCallErrorMessage(recipientName: recipientName, error: error),
    );
  }

  static void showSnackbar(String title, String message) {
    Get.snackbar(
      title,
      message,
      backgroundColor: Colors.black54,
      colorText: Colors.white,
      borderRadius: 8,
      duration: const Duration(seconds: 2),
    );
  }
}
