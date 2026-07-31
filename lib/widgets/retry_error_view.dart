import 'package:flutter/material.dart';

enum RetryErrorLayout { fullscreen, compact }

class RetryErrorView extends StatelessWidget {
  const RetryErrorView({
    super.key,
    required this.message,
    required this.onRetry,
    this.isNetworkError = false,
    this.isRetrying = false,
    this.layout = RetryErrorLayout.fullscreen,
    this.buttonLabel = 'Try again',
  });

  final String message;
  final VoidCallback onRetry;
  final bool isNetworkError;
  final bool isRetrying;
  final RetryErrorLayout layout;
  final String buttonLabel;

  @override
  Widget build(BuildContext context) {
    return layout == RetryErrorLayout.fullscreen
        ? _buildFullscreen(context)
        : _buildCompact(context);
  }

  Widget _buildFullscreen(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          isNetworkError ? Icons.wifi_off : Icons.error_outline,
          size: 48,
        ),
        const SizedBox(height: 16),
        Text(
          message,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        _buildRetryButton(fullWidth: true),
      ],
    );
  }

  Widget _buildCompact(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Material(
      color: colors.errorContainer.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              isNetworkError ? Icons.wifi_off : Icons.error_outline,
              size: 24,
              color: colors.onErrorContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: colors.onErrorContainer),
              ),
            ),
            const SizedBox(width: 8),
            _buildRetryButton(fullWidth: false),
          ],
        ),
      ),
    );
  }

  Widget _buildRetryButton({required bool fullWidth}) {
    final Widget button = FilledButton(
      onPressed: isRetrying ? null : onRetry,
      child: isRetrying
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(buttonLabel),
    );

    if (!fullWidth) {
      return button;
    }

    return SizedBox(
      width: double.infinity,
      child: button,
    );
  }
}
