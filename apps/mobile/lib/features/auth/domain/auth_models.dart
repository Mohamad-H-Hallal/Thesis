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
    this.isProtectedSuperAdmin = false,
  });

  final String id;
  final String fullName;
  final String email;
  final UserRole role;
  final bool isProtectedSuperAdmin;

  bool get isSuperAdmin => role == UserRole.admin && isProtectedSuperAdmin;

  String get roleLabel => role.label;
}

class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
  });

  final String accessToken;
  final String refreshToken;
  final AppUser user;
}

class PasswordResetRequestResult {
  const PasswordResetRequestResult({
    required this.message,
    this.devResetToken,
    this.expiresAt,
  });

  final String message;
  final String? devResetToken;
  final DateTime? expiresAt;
}
