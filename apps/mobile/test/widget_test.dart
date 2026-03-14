import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_failure.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/screens/login_screen.dart';

class _FailingAuthRepository implements AuthRepository {
  const _FailingAuthRepository(this.failure);

  final AuthFailure failure;

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
    required bool rememberMe,
  }) async {
    throw failure;
  }

  @override
  Future<void> logout() async {}

  @override
  Future<void> requestPasswordReset(String email) async {}

  @override
  Future<void> resetPassword({
    required String token,
    required String newPassword,
  }) async {}

  @override
  Future<AuthSession?> restoreSession() async => null;

  @override
  Future<String> signup({
    required String fullName,
    required String email,
    required String password,
    required UserRole role,
    String? phone,
  }) async {
    throw UnimplementedError();
  }
}

void main() {
  testWidgets('login screen renders required fields', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: LoginScreen())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Email address'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Login'), findsOneWidget);
  });

  testWidgets('login screen does not enforce signup password strength rules', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: LoginScreen())),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextFormField).at(0),
      'viewer@example.com',
    );
    await tester.enterText(find.byType(TextFormField).at(1), 'x');
    final loginButton = find.widgetWithText(FilledButton, 'Login');
    await tester.ensureVisible(loginButton);
    await tester.tap(loginButton, warnIfMissed: false);
    await tester.pump();

    expect(find.text('Password must be at least 8 characters'), findsNothing);
    expect(
      find.text('Password must include at least one uppercase letter'),
      findsNothing,
    );
  });

  testWidgets(
    'login failure keeps user on page, preserves values, and shows auth error',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            authRepositoryProvider.overrideWithValue(
              const _FailingAuthRepository(
                AuthFailure('Wrong email or password.', statusCode: 401),
              ),
            ),
          ],
          child: const MaterialApp(home: LoginScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final emailField = find.byType(TextFormField).at(0);
      final passwordField = find.byType(TextFormField).at(1);

      await tester.enterText(emailField, 'viewer@example.com');
      await tester.enterText(passwordField, 'WrongPass1!');

      final loginButton = find.widgetWithText(FilledButton, 'Login');
      await tester.ensureVisible(loginButton);
      tester.widget<FilledButton>(loginButton).onPressed!.call();
      await tester.pumpAndSettle();

      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Wrong email or password.'), findsWidgets);
      expect(
        tester.widget<TextFormField>(emailField).controller?.text,
        'viewer@example.com',
      );
      expect(
        tester.widget<TextFormField>(passwordField).controller?.text,
        'WrongPass1!',
      );
    },
  );
}
