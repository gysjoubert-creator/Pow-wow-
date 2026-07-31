import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pow_wow/app/services/onboarding_storage.dart';
import 'package:pow_wow/screens/onboarding/onboarding_screen.dart';

void main() {
  testWidgets('moves through all onboarding pages and completes', (
    WidgetTester tester,
  ) async {
    final _FakeOnboardingStore store = _FakeOnboardingStore();
    var finished = false;

    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingScreen(
          completionStore: store,
          onFinished: () async {
            finished = true;
          },
        ),
      ),
    );

    expect(find.text('Stay close\nto your tribe'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('onboarding_primary_button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Invite your\npeople'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('onboarding_primary_button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Press. Talk. Release.'), findsOneWidget);
    expect(find.text('Start PowWow'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('Press. Talk. Release.')).textAlign,
      TextAlign.center,
    );
    expect(
      tester
          .widget<Text>(find.text('Hold the coral button while\nyou speak.'))
          .textAlign,
      TextAlign.center,
    );
    expect(
      find.byKey(const ValueKey<String>('onboarding_skip_button')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('onboarding_primary_button')),
    );
    await tester.pumpAndSettle();

    expect(store.isCompleted, isTrue);
    expect(finished, isTrue);
  });

  testWidgets('Skip completes onboarding from the first page', (
    WidgetTester tester,
  ) async {
    final _FakeOnboardingStore store = _FakeOnboardingStore();
    var finished = false;

    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingScreen(
          completionStore: store,
          onFinished: () async {
            finished = true;
          },
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('onboarding_skip_button')),
    );
    await tester.pumpAndSettle();

    expect(store.isCompleted, isTrue);
    expect(finished, isTrue);
  });

  testWidgets('PageView spans the viewport while content keeps its inset', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingScreen(
          completionStore: _FakeOnboardingStore(),
          onFinished: () async {},
        ),
      ),
    );

    final Rect pageViewRect = tester.getRect(
      find.byKey(const ValueKey<String>('onboarding_page_view')),
    );
    final Rect buttonRect = tester.getRect(
      find.byKey(const ValueKey<String>('onboarding_primary_button')),
    );
    final Rect titleRect = tester.getRect(
      find.text('Stay close\nto your tribe'),
    );

    expect(pageViewRect.left, 0);
    expect(pageViewRect.right, 390);
    expect(buttonRect.left, 24);
    expect(buttonRect.right, 366);
    expect(titleRect.left, greaterThanOrEqualTo(24));
    expect(titleRect.right, lessThanOrEqualTo(366));
  });

  testWidgets('all pages fit a compact phone viewport', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingScreen(
          completionStore: _FakeOnboardingStore(),
          onFinished: () async {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);

    await tester.tap(
      find.byKey(const ValueKey<String>('onboarding_primary_button')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.byKey(const ValueKey<String>('onboarding_primary_button')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

class _FakeOnboardingStore implements OnboardingCompletionStore {
  @override
  bool isCompleted = false;

  @override
  Future<void> markCompleted() async {
    isCompleted = true;
  }
}
