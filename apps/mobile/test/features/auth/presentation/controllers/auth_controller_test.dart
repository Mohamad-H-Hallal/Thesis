import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_failure.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';

class _TestAuthRepository implements AuthRepository, AuthTokenRotationSource {
  AuthSession? restoredSession;
  AuthSession? loginSession;
  Object? loginError;
  Object? signupError;
  bool logoutCalled = false;
  int loginCallCount = 0;
  Completer<void>? logoutCompleter;
  RotatedAuthTokens? rotatedAuthTokens;

  @override
  Future<AuthSession?> restoreSession() async => restoredSession;

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
    required bool rememberMe,
  }) async {
    loginCallCount += 1;
    if (loginError != null) {
      throw loginError!;
    }
    return loginSession ??
        AuthSession(
          accessToken: 'token',
          refreshToken: 'refresh',
          user: const AppUser(
            id: 'u1',
            fullName: 'Collector User',
            email: 'collector@example.com',
            role: UserRole.contributor,
          ),
        );
  }

  @override
  Future<String> signup({
    required String fullName,
    required String email,
    required String password,
    required UserRole role,
    String? phone,
  }) async {
    if (signupError != null) {
      throw signupError!;
    }
    return role == UserRole.contributor
        ? 'Your contributor request is pending admin approval.'
        : 'Account created successfully. You can log in now.';
  }

  @override
  Future<PasswordResetRequestResult> requestPasswordReset(String email) async {
    return const PasswordResetRequestResult(
      message: 'A verification code has been sent to your email.',
      email: 'collector@example.com',
    );
  }

  @override
  Future<PasswordResetOtpVerificationResult> verifyPasswordResetOtp({
    required String email,
    required String otp,
  }) async => const PasswordResetOtpVerificationResult(
    message: 'Verification code confirmed.',
    resetToken: 'reset-session-token',
    email: 'collector@example.com',
  );

  @override
  Future<void> resetPassword({
    required String resetToken,
    required String newPassword,
  }) async {}

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {}

  @override
  RotatedAuthTokens? takeRotatedAuthTokens() {
    final tokens = rotatedAuthTokens;
    rotatedAuthTokens = null;
    return tokens;
  }

  @override
  Future<AppUser> updateProfile({String? fullName, String? phone}) async {
    return AppUser(
      id: 'u1',
      fullName: fullName ?? 'Collector User',
      email: 'collector@example.com',
      role: UserRole.contributor,
      phone: phone,
    );
  }

  @override
  Future<AuthSession> reactivateContributorAndLogin({
    required String email,
    required String password,
    required bool rememberMe,
  }) async {
    if (loginError != null) {
      throw loginError!;
    }
    return loginSession ??
        AuthSession(
          accessToken: 'token',
          refreshToken: 'refresh',
          user: const AppUser(
            id: 'u1',
            fullName: 'Collector User',
            email: 'collector@example.com',
            role: UserRole.contributor,
          ),
        );
  }

  @override
  Future<void> logout() async {
    logoutCalled = true;
    await logoutCompleter?.future;
  }

  @override
  Future<void> selfDeactivate() async {}
}

void main() {
  group('AuthController', () {
    test(
      'bootstrap restores authenticated state when session exists',
      () async {
        final repository = _TestAuthRepository()
          ..restoredSession = AuthSession(
            accessToken: 'token',
            refreshToken: 'refresh',
            user: const AppUser(
              id: 'u1',
              fullName: 'Officer',
              email: 'officer@example.com',
              role: UserRole.admin,
            ),
          );
        final controller = AuthController(repository);

        await controller.bootstrap();

        expect(controller.state.status, AuthStatus.authenticated);
        expect(controller.state.session?.user.email, 'officer@example.com');
      },
    );

    test('login surfaces mapped failure message', () async {
      final repository = _TestAuthRepository()
        ..loginError = const AuthFailure(
          'Invalid credentials',
          statusCode: 401,
        );
      final controller = AuthController(repository);

      await controller.login(
        email: 'bad@example.com',
        password: 'wrong-password',
        rememberMe: false,
      );

      expect(controller.state.status, AuthStatus.unauthenticated);
      expect(controller.state.error, 'Invalid credentials');
    });

    test('signup success resets to unauthenticated', () async {
      final repository = _TestAuthRepository();
      final controller = AuthController(repository);

      await controller.signup(
        fullName: 'New User',
        email: 'new@example.com',
        password: 'Passw0rd!123',
        role: UserRole.viewer,
      );

      expect(controller.state.status, AuthStatus.unauthenticated);
      expect(controller.state.error, isNull);
    });

    test('logout clears state', () async {
      final repository = _TestAuthRepository();
      final controller = AuthController(repository);

      await controller.login(
        email: 'collector@example.com',
        password: 'Passw0rd!123',
        rememberMe: true,
      );
      expect(controller.state.status, AuthStatus.authenticated);

      await controller.logout();

      expect(repository.logoutCalled, isTrue);
      expect(controller.state.status, AuthStatus.unauthenticated);
    });

    test(
      'password change installs the server-rotated current session',
      () async {
        final repository = _TestAuthRepository();
        final controller = AuthController(repository);
        await controller.login(
          email: 'collector@example.com',
          password: 'Passw0rd!123',
          rememberMe: true,
        );
        repository.rotatedAuthTokens = const RotatedAuthTokens(
          accessToken: 'rotated-access',
          refreshToken: 'rotated-refresh',
        );

        await controller.changePassword(
          currentPassword: 'Passw0rd!123',
          newPassword: 'N3w-Password!456',
        );

        expect(controller.state.status, AuthStatus.authenticated);
        expect(controller.state.session?.accessToken, 'rotated-access');
        expect(controller.state.session?.refreshToken, 'rotated-refresh');
        expect(controller.state.session?.user.id, 'u1');
      },
    );

    test('a new login waits for pending logout cleanup', () async {
      final repository = _TestAuthRepository();
      final controller = AuthController(repository);

      await controller.login(
        email: 'account-a@example.com',
        password: 'Passw0rd!123',
        rememberMe: true,
      );
      expect(repository.loginCallCount, 1);

      repository
        ..logoutCompleter = Completer<void>()
        ..loginSession = AuthSession(
          accessToken: 'token-b',
          refreshToken: 'refresh-b',
          user: const AppUser(
            id: 'user-b',
            fullName: 'Account B',
            email: 'account-b@example.com',
            role: UserRole.contributor,
          ),
        );

      final logoutFuture = controller.logout();
      final loginFuture = controller.login(
        email: 'account-b@example.com',
        password: 'Passw0rd!123',
        rememberMe: true,
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.status, AuthStatus.unauthenticated);
      expect(repository.loginCallCount, 1);

      repository.logoutCompleter!.complete();
      await Future.wait(<Future<void>>[logoutFuture, loginFuture]);

      expect(repository.loginCallCount, 2);
      expect(controller.state.status, AuthStatus.authenticated);
      expect(controller.state.session?.user.id, 'user-b');
    });
  });
}
