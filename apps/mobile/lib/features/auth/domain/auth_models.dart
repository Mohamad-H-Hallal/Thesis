enum UserRole { admin, contributor, viewer }

extension UserRoleX on UserRole {
  String get label {
    switch (this) {
      case UserRole.admin:
        return 'Admin';
      case UserRole.contributor:
        return 'Contributor';
      case UserRole.viewer:
        return 'Viewer';
    }
  }
}

class AppUser {
  const AppUser({
    required this.id,
    required this.fullName,
    required this.email,
    required this.role,
    this.phone,
    this.isProtectedSuperAdmin = false,
  });

  final String id;
  final String fullName;
  final String email;
  final UserRole role;
  final String? phone;
  final bool isProtectedSuperAdmin;

  bool get isSuperAdmin => role == UserRole.admin && isProtectedSuperAdmin;

  String get roleLabel => role.label;

  AppUser copyWith({
    String? id,
    String? fullName,
    String? email,
    UserRole? role,
    String? phone,
    bool? isProtectedSuperAdmin,
  }) {
    return AppUser(
      id: id ?? this.id,
      fullName: fullName ?? this.fullName,
      email: email ?? this.email,
      role: role ?? this.role,
      phone: phone ?? this.phone,
      isProtectedSuperAdmin:
          isProtectedSuperAdmin ?? this.isProtectedSuperAdmin,
    );
  }
}

class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
    this.legalAcceptanceRequired = false,
  });

  final String accessToken;
  final String refreshToken;
  final AppUser user;
  final bool legalAcceptanceRequired;
}

class PasswordResetRequestResult {
  const PasswordResetRequestResult({
    required this.message,
    this.email,
    this.expiresAt,
  });

  final String message;
  final String? email;
  final DateTime? expiresAt;
}

class PasswordResetOtpVerificationResult {
  const PasswordResetOtpVerificationResult({
    required this.message,
    required this.resetToken,
    required this.email,
  });

  final String message;
  final String resetToken;
  final String email;
}
