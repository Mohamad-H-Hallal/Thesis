import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/network/api_client.dart';
import '../domain/auth_models.dart';
import '../domain/auth_repository.dart';

class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository(this._storage, this._apiClient);

  final FlutterSecureStorage _storage;
  final ApiClient _apiClient;

  static const _accessKey = 'access_token';
  static const _refreshKey = 'refresh_token';
  static const _roleKey = 'user_role';
  static const _nameKey = 'user_name';
  static const _emailKey = 'user_email';
  static const _superAdminKey = 'is_protected_super_admin';

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
      isProtectedSuperAdmin: isProtectedSuperAdmin,
    );

    _apiClient.setAccessToken(access);
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
                  ? 'GIS Super Administrator'
                  : 'Ministry Admin'
            : 'Field Contributor',
        email: email,
        role: role,
        isProtectedSuperAdmin: isProtectedSuperAdmin,
      ),
    );

    if (rememberMe) {
      await _storage.write(key: _accessKey, value: session.accessToken);
      await _storage.write(key: _refreshKey, value: session.refreshToken);
      await _storage.write(key: _roleKey, value: role.name);
      await _storage.write(key: _nameKey, value: session.user.fullName);
      await _storage.write(key: _emailKey, value: session.user.email);
      await _storage.write(
        key: _superAdminKey,
        value: isProtectedSuperAdmin.toString(),
      );
    }

    _apiClient.setAccessToken(session.accessToken);
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
        ? 'Your contributor request is pending admin approval.'
        : 'Viewer account created successfully. You can log in now.';
  }

  @override
  Future<void> requestPasswordReset(String email) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!email.contains('@')) {
      throw DioException(
        requestOptions: RequestOptions(path: '/api/auth/forgot-password'),
        message: 'Please enter a valid email.',
      );
    }
  }

  @override
  Future<void> resetPassword({
    required String token,
    required String newPassword,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (token.isEmpty || newPassword.length < 8) {
      throw DioException(
        requestOptions: RequestOptions(path: '/api/auth/reset-password'),
        message: 'Reset password failed.',
      );
    }
  }

  @override
  Future<void> logout() async {
    _apiClient.setAccessToken(null);
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
    await _storage.delete(key: _roleKey);
    await _storage.delete(key: _nameKey);
    await _storage.delete(key: _emailKey);
    await _storage.delete(key: _superAdminKey);
  }

  @override
  Future<void> selfDeactivate() async {
    _apiClient.setAccessToken(null);
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
    await _storage.delete(key: _roleKey);
    await _storage.delete(key: _nameKey);
    await _storage.delete(key: _emailKey);
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
