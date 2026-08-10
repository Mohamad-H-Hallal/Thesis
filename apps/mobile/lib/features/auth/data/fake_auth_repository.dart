import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/network/api_client.dart';
import '../domain/auth_models.dart';
import '../domain/auth_repository.dart';

class _FakePasswordResetChallenge {
  _FakePasswordResetChallenge({
    required this.codeHash,
    required this.expiresAt,
  });

  final String codeHash;
  final DateTime expiresAt;
  int attemptCount = 0;
}

class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository(this._storage, this._apiClient)
    : _passwordResetHmacKey = _secureRandomToken();

  final FlutterSecureStorage _storage;
  final ApiClient _apiClient;
  final String _passwordResetHmacKey;
  final Map<String, _FakePasswordResetChallenge> _passwordResetChallenges = {};
  final Map<String, DateTime> _passwordResetSessions = {};

  static final Random _secureRandom = Random.secure();

  static const _accessKey = 'access_token';
  static const _refreshKey = 'refresh_token';
  static const _roleKey = 'user_role';
  static const _nameKey = 'user_name';
  static const _emailKey = 'user_email';
  static const _phoneKey = 'user_phone';
  static const _superAdminKey = 'is_protected_super_admin';

  static String _secureRandomToken([int byteLength = 32]) {
    final bytes = List<int>.generate(
      byteLength,
      (_) => _secureRandom.nextInt(256),
      growable: false,
    );
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  String _passwordResetCodeHash(String email, String code) {
    return Hmac(
      sha256,
      utf8.encode(_passwordResetHmacKey),
    ).convert(utf8.encode('${email.toLowerCase()}:$code')).toString();
  }

  @override
  Future<AuthSession?> restoreSession() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final access = await _storage.read(key: _accessKey);
    final refresh = await _storage.read(key: _refreshKey);

    if (access == null || refresh == null) {
      return null;
    }

    final role = _toRole(await _storage.read(key: _roleKey));
    final isProtectedSuperAdmin =
        await _storage.read(key: _superAdminKey) == 'true';
    final user = AppUser(
      id: 'user-1',
      fullName: await _storage.read(key: _nameKey) ?? 'GIS Officer',
      email: await _storage.read(key: _emailKey) ?? 'officer@gov.lb',
      role: role,
      phone: await _storage.read(key: _phoneKey),
      isProtectedSuperAdmin: isProtectedSuperAdmin,
    );

    await _apiClient.establishAuthenticatedSession(
      accessToken: access,
      refreshToken: refresh,
      ownerUserId: user.id,
    );
    return AuthSession(accessToken: access, refreshToken: refresh, user: user);
  }

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
    required bool rememberMe,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 700));

    if (!email.contains('@') || password.length < 6) {
      throw DioException(
        requestOptions: RequestOptions(path: '/api/auth/login'),
        message: 'Invalid email or password.',
      );
    }

    final normalizedEmail = email.toLowerCase();

    if (normalizedEmail.contains('deactivated-contributor')) {
      throw DioException(
        requestOptions: RequestOptions(path: '/api/auth/login'),
        response: Response(
          requestOptions: RequestOptions(path: '/api/auth/login'),
          statusCode: 403,
          data: const <String, dynamic>{
            'message':
                'Your contributor account is deactivated. Activate it to continue logging in.',
          },
        ),
        message:
            'Your contributor account is deactivated. Activate it to continue logging in.',
      );
    }

    final isApprovedContributor = normalizedEmail.contains(
      'approved-contributor',
    );
    if ((normalizedEmail.contains('pending-contributor') ||
            normalizedEmail.contains('contributor')) &&
        !isApprovedContributor) {
      throw DioException(
        requestOptions: RequestOptions(path: '/api/auth/login'),
        response: Response(
          requestOptions: RequestOptions(path: '/api/auth/login'),
          statusCode: 403,
          data: const <String, dynamic>{
            'message': 'Your contributor request is still pending approval.',
          },
        ),
        message: 'Your contributor request is still pending approval.',
      );
    }

    final role = normalizedEmail.contains('admin')
        ? UserRole.admin
        : normalizedEmail.contains('viewer')
        ? UserRole.viewer
        : UserRole.contributor;
    final isProtectedSuperAdmin = normalizedEmail == 'superadmin@gov.lb';

    final session = AuthSession(
      accessToken: 'token_${DateTime.now().millisecondsSinceEpoch}',
      refreshToken: 'refresh_${DateTime.now().millisecondsSinceEpoch}',
      user: AppUser(
        id: 'user-1',
        fullName: role == UserRole.admin
            ? isProtectedSuperAdmin
                  ? 'GIS Administrator'
                  : 'Ministry Admin'
            : 'Field Contributor',
        email: email,
        role: role,
        phone: '70123456',
        isProtectedSuperAdmin: isProtectedSuperAdmin,
      ),
    );

    if (rememberMe) {
      await _storage.write(key: _accessKey, value: session.accessToken);
      await _storage.write(key: _refreshKey, value: session.refreshToken);
      await _storage.write(key: _roleKey, value: role.name);
      await _storage.write(key: _nameKey, value: session.user.fullName);
      await _storage.write(key: _emailKey, value: session.user.email);
      await _storage.write(key: _phoneKey, value: session.user.phone ?? '');
      await _storage.write(
        key: _superAdminKey,
        value: isProtectedSuperAdmin.toString(),
      );
    }

    await _apiClient.establishAuthenticatedSession(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      ownerUserId: session.user.id,
      persistTokens: rememberMe,
    );
    return session;
  }

  @override
  Future<AuthSession> reactivateContributorAndLogin({
    required String email,
    required String password,
    required bool rememberMe,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final session = AuthSession(
      accessToken: 'token_${DateTime.now().millisecondsSinceEpoch}',
      refreshToken: 'refresh_${DateTime.now().millisecondsSinceEpoch}',
      user: AppUser(
        id: 'user-1',
        fullName: 'Field Contributor',
        email: email,
        role: UserRole.contributor,
        phone: '70123456',
      ),
    );

    if (rememberMe) {
      await _storage.write(key: _accessKey, value: session.accessToken);
      await _storage.write(key: _refreshKey, value: session.refreshToken);
      await _storage.write(key: _roleKey, value: UserRole.contributor.name);
      await _storage.write(key: _nameKey, value: session.user.fullName);
      await _storage.write(key: _emailKey, value: session.user.email);
      await _storage.write(key: _phoneKey, value: session.user.phone ?? '');
      await _storage.write(key: _superAdminKey, value: 'false');
    }

    await _apiClient.establishAuthenticatedSession(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      ownerUserId: session.user.id,
      persistTokens: rememberMe,
    );
    return session;
  }

  @override
  Future<String> signup({
    required String fullName,
    required String email,
    required String password,
    required UserRole role,
    String? phone,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (fullName.trim().isEmpty ||
        !email.contains('@') ||
        password.length < 8) {
      throw DioException(
        requestOptions: RequestOptions(path: '/api/auth/register'),
        message: 'Signup validation failed.',
      );
    }

    return role == UserRole.contributor
        ? 'Account created successfully. Your contributor request is pending admin approval.'
        : 'Account created successfully. You can log in now.';
  }

  @override
  Future<PasswordResetRequestResult> requestPasswordReset(String email) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!email.contains('@')) {
      throw DioException(
        requestOptions: RequestOptions(path: '/api/auth/forgot-password'),
        message: 'Please enter a valid email.',
      );
    }
    final normalizedEmail = email.trim().toLowerCase();
    final code = _secureRandom.nextInt(1000000).toString().padLeft(6, '0');
    final expiresAt = DateTime.now().add(const Duration(minutes: 5));
    _passwordResetChallenges[normalizedEmail] = _FakePasswordResetChallenge(
      codeHash: _passwordResetCodeHash(normalizedEmail, code),
      expiresAt: expiresAt,
    );
    return PasswordResetRequestResult(
      message: 'A verification code has been sent to your email.',
      email: email,
      expiresAt: expiresAt,
    );
  }

  @override
  Future<PasswordResetOtpVerificationResult> verifyPasswordResetOtp({
    required String email,
    required String otp,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final normalizedEmail = email.trim().toLowerCase();
    final challenge = _passwordResetChallenges[normalizedEmail];
    final valid =
        challenge != null &&
        challenge.expiresAt.isAfter(DateTime.now()) &&
        challenge.attemptCount < 5 &&
        challenge.codeHash == _passwordResetCodeHash(normalizedEmail, otp);
    if (!valid) {
      if (challenge != null) {
        challenge.attemptCount += 1;
        if (challenge.attemptCount >= 5 ||
            !challenge.expiresAt.isAfter(DateTime.now())) {
          _passwordResetChallenges.remove(normalizedEmail);
        }
      }
      throw DioException(
        requestOptions: RequestOptions(path: '/api/auth/verify-reset-otp'),
        message: 'Verification code is invalid or expired.',
      );
    }
    _passwordResetChallenges.remove(normalizedEmail);
    final resetToken = _secureRandomToken();
    _passwordResetSessions[resetToken] = DateTime.now().add(
      const Duration(minutes: 5),
    );
    return PasswordResetOtpVerificationResult(
      message: 'Verification code confirmed.',
      resetToken: resetToken,
      email: email,
    );
  }

  @override
  Future<void> resetPassword({
    required String resetToken,
    required String newPassword,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final expiresAt = _passwordResetSessions.remove(resetToken);
    if (expiresAt == null ||
        !expiresAt.isAfter(DateTime.now()) ||
        newPassword.length < 8) {
      throw DioException(
        requestOptions: RequestOptions(path: '/api/auth/reset-password'),
        message: 'Reset password failed.',
      );
    }
  }

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (currentPassword.isEmpty || newPassword.length < 8) {
      throw DioException(
        requestOptions: RequestOptions(path: '/api/auth/change-password'),
        message: 'Password change failed.',
      );
    }
  }

  @override
  Future<AppUser> updateProfile({String? fullName, String? phone}) async {
    final currentName = await _storage.read(key: _nameKey) ?? 'GIS Officer';
    final currentEmail =
        await _storage.read(key: _emailKey) ?? 'officer@gov.lb';
    final currentPhone = await _storage.read(key: _phoneKey);
    final role = _toRole(await _storage.read(key: _roleKey));
    final isProtectedSuperAdmin =
        await _storage.read(key: _superAdminKey) == 'true';
    final user = AppUser(
      id: 'user-1',
      fullName: fullName ?? currentName,
      email: currentEmail,
      role: role,
      phone: phone ?? currentPhone,
      isProtectedSuperAdmin: isProtectedSuperAdmin,
    );
    await _storage.write(key: _nameKey, value: user.fullName);
    await _storage.write(key: _emailKey, value: user.email);
    await _storage.write(key: _phoneKey, value: user.phone ?? '');
    return user;
  }

  @override
  Future<void> logout() async {
    await _apiClient.invalidateAuthenticatedSession();
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
    await _storage.delete(key: _roleKey);
    await _storage.delete(key: _nameKey);
    await _storage.delete(key: _emailKey);
    await _storage.delete(key: _phoneKey);
    await _storage.delete(key: _superAdminKey);
  }

  @override
  Future<void> selfDeactivate() async {
    await _apiClient.invalidateAuthenticatedSession();
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
    await _storage.delete(key: _roleKey);
    await _storage.delete(key: _nameKey);
    await _storage.delete(key: _emailKey);
    await _storage.delete(key: _phoneKey);
    await _storage.delete(key: _superAdminKey);
  }

  UserRole _toRole(String? value) {
    switch (value) {
      case 'admin':
        return UserRole.admin;
      case 'viewer':
        return UserRole.viewer;
      default:
        return UserRole.contributor;
    }
  }
}
