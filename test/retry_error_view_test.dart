import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pow_wow/widgets/retry_error_view.dart';

void main() {
  testWidgets('Try again invokes callback when not retrying', (
    WidgetTester tester,
  ) async {
    var retryCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RetryErrorView(
            message: 'Internet connection error',
            isNetworkError: true,
            onRetry: () => retryCount++,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Try again'));
    await tester.pump();

    expect(retryCount, 1);
    expect(find.byIcon(Icons.wifi_off), findsOneWidget);
  });

  testWidgets('Try again is disabled while retrying', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RetryErrorView(
            message: 'Something went wrong',
            isRetrying: true,
            onRetry: _noop,
          ),
        ),
      ),
    );

    final FilledButton button = tester.widget(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('compact layout shows message and retry button', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RetryErrorView(
            message: 'Internet connection error',
            layout: RetryErrorLayout.compact,
            onRetry: () {},
          ),
        ),
      ),
    );

    expect(find.text('Internet connection error'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}

void _noop() {}
