import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';
import '../domain/auth_error_mapper.dart';
import '../domain/auth_failure.dart';
import '../domain/auth_models.dart';
import '../domain/auth_repository.dart';

class RealAuthRepository implements AuthRepository {
  RealAuthRepository(this._storage, this._apiClient);

  final FlutterSecureStorage _storage;
  final ApiClient _apiClient;

  static const _accessKey = 'access_token';
  static const _refreshKey = 'refresh_token';
  static const _roleKey = 'user_role';
  static const _nameKey = 'user_name';
  static const _emailKey = 'user_email';
  static const _userIdKey = 'user_id';
  static const _superAdminKey = 'is_protected_super_admin';

  String get _authBasePath => '${AppEnv.apiVersionPrefix}/auth';

  @override
  Future<AuthSession?> restoreSession() async {
    final access = await _storage.read(key: _accessKey);
    final refresh = await _storage.read(key: _refreshKey);
    if (access == null || refresh == null) {
      return null;
    }

    _apiClient.setAccessToken(access);

    try {
      final meResponse = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_authBasePath/me',
      );
      final user = _parseUserFromMeResponse(
        meResponse.data ?? const <String, dynamic>{},
      );
      await _persistUserMetadata(user);
      return AuthSession(
        accessToken: access,
        refreshToken: refresh,
        user: user,
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) {
        await _clearStoredSession();
        _apiClient.setAccessToken(null);
        return null;
      }

      final fallbackUser = await _readStoredUser();
      if (fallbackUser == null) {
        await _clearStoredSession();
        _apiClient.setAccessToken(null);
        return null;
      }

      return AuthSession(
        accessToken: access,
        refreshToken: refresh,
        user: fallbackUser,
      );
    }
  }

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
    required bool rememberMe,
  }) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_authBasePath/login',
        data: <String, dynamic>{'email': email, 'password': password},
      );
      return _sessionFromAuthResponse(
        response.data ?? const <String, dynamic>{},
        rememberMe: rememberMe,
      );
    } on DioException catch (error) {
      _apiClient.setAccessToken(null);
      await _clearStoredSession();
      throw mapAuthDioException(error, fallbackMessage: 'Login failed.');
    }
  }

  @override
  Future<AuthSession> reactivateContributorAndLogin({
    required String email,
    required String password,
    required bool rememberMe,
  }) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_authBasePath/reactivate-login',
        data: <String, dynamic>{'email': email, 'password': password},
      );
      return _sessionFromAuthResponse(
        response.data ?? const <String, dynamic>{},
        rememberMe: rememberMe,
      );
    } on DioException catch (error) {
      _apiClient.setAccessToken(null);
      await _clearStoredSession();
      throw mapAuthDioException(
        error,
        fallbackMessage: 'Account reactivation failed.',
      );
    }
  }

  @override
  Future<String> signup({
    required String fullName,
    required String email,
    required String password,
    required UserRole role,
    String? phone,
  }) async {
    try {
      final payload = <String, dynamic>{
        'full_name': fullName,
        'email': email,
        'password': password,
        'role': role.name,
      };
      final normalizedPhone = phone?.trim() ?? '';
      if (normalizedPhone.isNotEmpty) {
        payload['phone'] = normalizedPhone;
      }

      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_authBasePath/register',
        data: payload,
      );
      final payloadMap = response.data ?? const <String, dynamic>{};
      final message = payloadMap['message'] as String?;
      return message?.trim().isNotEmpty == true
          ? message!.trim()
          : 'Account created successfully.';
    } on DioException catch (error) {
      throw mapAuthDioException(error, fallbackMessage: 'Signup failed.');
    }
  }

  @override
  Future<PasswordResetRequestResult> requestPasswordReset(String email) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_authBasePath/forgot-password',
        data: <String, dynamic>{'email': email},
      );
      final payload = response.data ?? const <String, dynamic>{};
      final data = Map<String, dynamic>.from(
        payload['data'] as Map? ?? const <String, dynamic>{},
      );
      return PasswordResetRequestResult(
        message:
            (payload['message'] as String?)?.trim().isNotEmpty == true
                ? (payload['message'] as String).trim()
                : 'Password reset instructions were generated successfully.',
        devResetToken: (data['dev_reset_token'] as String?)?.trim(),
        expiresAt: _toDateTime(data['expires_at']),
      );
    } on DioException catch (error) {
      throw mapAuthDioException(
        error,
        fallbackMessage: 'Password reset request failed.',
      );
    }
  }

  @override
  Future<void> resetPassword({
    required String token,
    required String newPassword,
  }) async {
    try {
      await _apiClient.dio.post<Map<String, dynamic>>(
        '$_authBasePath/reset-password',
        data: <String, dynamic>{'token': token, 'new_password': newPassword},
      );
    } on DioException catch (error) {
      throw mapAuthDioException(
        error,
        fallbackMessage: 'Password reset failed.',
      );
    }
  }

  @override
  Future<void> logout() async {
    try {
      await _apiClient.dio.post<Map<String, dynamic>>('$_authBasePath/logout');
    } catch (_) {
      // Best-effort call; local token clear is mandatory.
    } finally {
      _apiClient.setAccessToken(null);
      await _clearStoredSession();
    }
  }

  @override
  Future<void> selfDeactivate() async {
    try {
      await _apiClient.dio.post<Map<String, dynamic>>(
        '$_authBasePath/self-deactivate',
      );
    } on DioException catch (error) {
      throw mapAuthDioException(
        error,
        fallbackMessage: 'Account deactivation failed.',
      );
    } finally {
      _apiClient.setAccessToken(null);
      await _clearStoredSession();
    }
  }

  Future<void> _persistSession({
    required String accessToken,
    required String refreshToken,
    required AppUser user,
  }) async {
    await _storage.write(key: _accessKey, value: accessToken);
    await _storage.write(key: _refreshKey, value: refreshToken);
    await _persistUserMetadata(user);
  }

  Future<void> _persistUserMetadata(AppUser user) async {
    await _storage.write(key: _userIdKey, value: user.id);
    await _storage.write(key: _nameKey, value: user.fullName);
    await _storage.write(key: _emailKey, value: user.email);
    await _storage.write(key: _roleKey, value: user.role.name);
    await _storage.write(
      key: _superAdminKey,
      value: user.isProtectedSuperAdmin.toString(),
    );
  }

  Future<AppUser?> _readStoredUser() async {
    final userId = await _storage.read(key: _userIdKey);
    final name = await _storage.read(key: _nameKey);
    final email = await _storage.read(key: _emailKey);
    final role = await _storage.read(key: _roleKey);
    final isProtectedSuperAdmin = await _storage.read(key: _superAdminKey);

    if (userId == null || name == null || email == null) {
      return null;
    }

    return AppUser(
      id: userId,
      fullName: name,
      email: email,
      role: _toRole(role),
      isProtectedSuperAdmin: isProtectedSuperAdmin == 'true',
    );
  }

  Future<void> _clearStoredSession() async {
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
    await _storage.delete(key: _roleKey);
    await _storage.delete(key: _nameKey);
    await _storage.delete(key: _emailKey);
    await _storage.delete(key: _userIdKey);
    await _storage.delete(key: _superAdminKey);
  }

  AppUser _parseUserFromMeResponse(Map<String, dynamic> payload) {
    final rawData = Map<String, dynamic>.from(
      payload['data'] as Map? ?? const <String, dynamic>{},
    );
    return _parseUser(rawData);
  }

  AppUser _parseUser(Map<String, dynamic> map) {
    final id = (map['id'] as String?) ?? 'unknown-user';
    final fullName =
        (map['full_name'] as String?) ??
        (map['fullName'] as String?) ??
        'Unknown User';
    final email = (map['email'] as String?) ?? 'unknown@example.com';
    final roleRaw = map['role'] as String?;
    final isProtectedSuperAdmin =
        (map['is_protected_super_admin'] as bool?) ?? false;

    return AppUser(
      id: id,
      fullName: fullName,
      email: email,
      role: _toRole(roleRaw),
      isProtectedSuperAdmin: isProtectedSuperAdmin,
    );
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

  DateTime? _toDateTime(dynamic value) {
    if (value is DateTime) {
      return value;
    }
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value);
    }
    return null;
  }

  Future<AuthSession> _sessionFromAuthResponse(
    Map<String, dynamic> payload, {
    required bool rememberMe,
  }) async {
    final data = Map<String, dynamic>.from(
      payload['data'] as Map? ?? const <String, dynamic>{},
    );
    final accessToken = (data['token'] as String?) ?? '';
    final refreshToken = (data['refreshToken'] as String?) ?? '';
    final userMap = Map<String, dynamic>.from(
      data['user'] as Map? ?? const <String, dynamic>{},
    );
    final user = _parseUser(userMap);

    if (accessToken.isEmpty || refreshToken.isEmpty) {
      throw const AuthFailure('Authentication response is missing tokens.');
    }

    _apiClient.setAccessToken(accessToken);

    if (rememberMe) {
      await _persistSession(
        accessToken: accessToken,
        refreshToken: refreshToken,
        user: user,
      );
    } else {
      await _clearStoredSession();
    }

    return AuthSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      user: user,
    );
  }
}
