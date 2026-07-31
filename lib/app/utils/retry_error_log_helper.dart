import '../../main.dart';
import '../../test_screen/test_log_helper.dart';

void logRetryErrorBannerShown({
  required String scope,
  required String message,
  required bool isNetworkError,
  String? source,
  String layout = 'fullscreen',
}) {
  testPrintLS(
    DiagnosticLog.warn(
      scope,
      'retry_error_banner_shown',
      data: <String, Object?>{
        'layout': layout,
        'isNetworkError': isNetworkError,
        'message': message,
        'source': ?source,
      },
    ),
  );
}

void logRetryErrorBannerCleared({
  required String scope,
  String? reason,
}) {
  testPrintLS(
    DiagnosticLog.flow(
      scope,
      'retry_error_banner_cleared',
      data: <String, Object?>{
        'reason': ?reason,
      },
    ),
  );
}

void logRetryErrorTryAgainTapped({
  required String scope,
  String? source,
}) {
  testPrintLS(
    DiagnosticLog.ui(
      scope,
      'retry_error_try_again_tapped',
      data: <String, Object?>{
        'source': ?source,
      },
    ),
  );
}
