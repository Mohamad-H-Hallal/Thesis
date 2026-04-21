import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/screens/forgot_password_screen.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/screens/login_screen.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/screens/reset_password_screen.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/screens/signup_screen.dart';

void main() {
  Future<void> pumpAtSize(
    WidgetTester tester, {
    required Widget child,
    required Size size,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(child: MaterialApp(home: child)));
    await tester.pumpAndSettle();
  }

  testWidgets('login screen stays scrollable on compact heights', (
    tester,
  ) async {
    await pumpAtSize(
      tester,
      child: const LoginScreen(),
      size: const Size(320, 560),
    );

    final loginButton = find.widgetWithText(FilledButton, 'Login');
    await tester.ensureVisible(loginButton);

    expect(loginButton, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('signup screen stays usable on compact widths', (tester) async {
    await pumpAtSize(
      tester,
      child: const SignupScreen(),
      size: const Size(320, 620),
    );

    final submitButton = find.widgetWithText(
      FilledButton,
      'Request contributor access',
    );
    await tester.ensureVisible(submitButton);

    expect(find.text('Create your account'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('forgot password screen stays scrollable on compact heights', (
    tester,
  ) async {
    await pumpAtSize(
      tester,
      child: const ForgotPasswordScreen(),
      size: const Size(320, 560),
    );

    final sendButton = find.widgetWithText(FilledButton, 'Send reset code');
    await tester.ensureVisible(sendButton);

    expect(sendButton, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reset password screen stays usable on compact heights', (
    tester,
  ) async {
    await pumpAtSize(
      tester,
      child: const ResetPasswordScreen(email: 'user@example.com'),
      size: const Size(320, 560),
    );

    final verifyButton = find.widgetWithText(FilledButton, 'Verify code');
    await tester.ensureVisible(verifyButton);

    expect(verifyButton, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
