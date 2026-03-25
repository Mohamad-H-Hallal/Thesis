import 'auth_models.dart';

abstract class AuthRepository {
  Future<AuthSession?> restoreSession();

  Future<AuthSession> login({
    required String email,
    required String password,
    required bool rememberMe,
  });

  Future<String> signup({
    required String fullName,
    required String email,
    required String password,
    required UserRole role,
    String? phone,
  });

  Future<void> requestPasswordReset(String email);

  Future<void> resetPassword({
    required String token,
    required String newPassword,
  });

  Future<void> selfDeactivate();

  Future<void> logout();
}
