import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_failure.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';

class _TestAuthRepository implements AuthRepository {
  AuthSession? restoredSession;
  AuthSession? loginSession;
  Object? loginError;
  Object? signupError;
  bool logoutCalled = false;

  @override
  Future<AuthSession?> restoreSession() async => restoredSession;

  @override
  Future<AuthSession> login({
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
        : 'Viewer account created successfully. You can log in now.';
  }

  @override
  Future<void> requestPasswordReset(String email) async {}

  @override
  Future<void> resetPassword({
    required String token,
    required String newPassword,
  }) async {}

  @override
  Future<void> logout() async {
    logoutCalled = true;
  }
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
  });
}
