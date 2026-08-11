import 'auth_models.dart';

class RotatedAuthTokens {
  const RotatedAuthTokens({
    required this.accessToken,
    required this.refreshToken,
  });

  final String accessToken;
  final String refreshToken;
}

abstract interface class AuthTokenRotationSource {
  RotatedAuthTokens? takeRotatedAuthTokens();
}

abstract class AuthRepository {
  Future<AuthSession?> restoreSession();

  Future<AuthSession> login({
    required String email,
    required String password,
    required bool rememberMe,
  });

  Future<AuthSession> reactivateContributorAndLogin({
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

  Future<PasswordResetRequestResult> requestPasswordReset(String email);

  Future<PasswordResetOtpVerificationResult> verifyPasswordResetOtp({
    required String email,
    required String otp,
  });

  Future<void> resetPassword({
    required String resetToken,
    required String newPassword,
  });

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  });

  Future<AppUser> updateProfile({String? fullName, String? phone});

  Future<void> selfDeactivate();

  Future<void> logout();
}
