import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';
import '../../notifications/domain/push_notification_constants.dart';
import '../domain/auth_error_mapper.dart';
import '../domain/auth_failure.dart';
import '../domain/auth_models.dart';
import '../domain/auth_repository.dart';
import 'contact_verification_repository.dart';

class RealAuthRepository implements AuthRepository, AuthTokenRotationSource {
  RealAuthRepository(this._storage, this._apiClient);

  final FlutterSecureStorage _storage;
  final ApiClient _apiClient;

  static const _accessKey = 'access_token';
  static const _refreshKey = 'refresh_token';
  static const _roleKey = 'user_role';
  static const _nameKey = 'user_name';
  static const _emailKey = 'user_email';
  static const _userIdKey = 'user_id';
  static const _phoneKey = 'user_phone';
  static const _superAdminKey = 'is_protected_super_admin';
  RotatedAuthTokens? _rotatedAuthTokens;
  String get _authBasePath => '${AppEnv.apiVersionPrefix}/auth';
  Options get _publicAuthRequestOptions =>
      Options(headers: const <String, dynamic>{'Authorization': null});

  @override
  Future<AuthSession?> restoreSession() async {
    final access = await _storage.read(key: _accessKey);
    final refresh = await _storage.read(key: _refreshKey);
    if (access == null || refresh == null) {
      return null;
    }

    final storedUser = await _readStoredUser();
    await _apiClient.establishAuthenticatedSession(
      accessToken: access,
      refreshToken: refresh,
      ownerUserId: storedUser?.id ?? '__restoring_session__',
    );

    try {
      final meResponse = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_authBasePath/me',
      );
      final user = _parseUserFromMeResponse(
        meResponse.data ?? const <String, dynamic>{},
      );
      var binding = _apiClient.currentSessionBinding;
      if (binding == null) {
        throw const AuthFailure('Authentication session expired.');
      }
      if (binding.ownerUserId != user.id) {
        await _apiClient.establishAuthenticatedSession(
          accessToken: binding.accessToken,
          refreshToken: binding.refreshToken,
          ownerUserId: user.id,
        );
        binding = _apiClient.currentSessionBinding;
      }
      await _persistUserMetadata(user);
      return AuthSession(
        accessToken: binding?.accessToken ?? access,
        refreshToken: binding?.refreshToken ?? refresh,
        user: user,
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) {
        try {
          return await _refreshRememberedSession(refresh);
        } on DioException catch (refreshError) {
          if (_isTemporaryAuthenticationFailure(refreshError)) {
            final fallbackUser = await _readStoredUser();
            if (fallbackUser == null) {
              await _apiClient.invalidateAuthenticatedSession();
              await _clearStoredSession();
              return null;
            }

            final binding = _apiClient.currentSessionBinding;
            return AuthSession(
              accessToken: binding?.accessToken ?? access,
              refreshToken: binding?.refreshToken ?? refresh,
              user: fallbackUser,
            );
          }

          await _apiClient.invalidateAuthenticatedSession();
          await _clearStoredSession();
          return null;
        }
      }

      final fallbackUser = storedUser ?? await _readStoredUser();
      if (fallbackUser == null) {
        await _apiClient.invalidateAuthenticatedSession();
        await _clearStoredSession();
        return null;
      }

      final binding = _apiClient.currentSessionBinding;
      return AuthSession(
        accessToken: binding?.accessToken ?? access,
        refreshToken: binding?.refreshToken ?? refresh,
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
        options: _publicAuthRequestOptions,
      );
      return _sessionFromAuthResponse(
        response.data ?? const <String, dynamic>{},
        rememberMe: rememberMe,
      );
    } on DioException catch (error) {
      if (_isContactVerificationRequired(error)) {
        await _savePendingVerificationToken(error.response?.data);
      }
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
        options: _publicAuthRequestOptions,
      );
      return _sessionFromAuthResponse(
        response.data ?? const <String, dynamic>{},
        rememberMe: rememberMe,
      );
    } on DioException catch (error) {
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
        options: _publicAuthRequestOptions,
      );
      final payloadMap = response.data ?? const <String, dynamic>{};
      await _savePendingVerificationToken(payloadMap);
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
        options: _publicAuthRequestOptions,
      );
      final payload = response.data ?? const <String, dynamic>{};
      final data = Map<String, dynamic>.from(
        payload['data'] as Map? ?? const <String, dynamic>{},
      );
      return PasswordResetRequestResult(
        message: (payload['message'] as String?)?.trim().isNotEmpty == true
            ? (payload['message'] as String).trim()
            : 'A verification code has been sent to your email.',
        email: (data['email'] as String?)?.trim(),
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
  Future<PasswordResetOtpVerificationResult> verifyPasswordResetOtp({
    required String email,
    required String otp,
  }) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_authBasePath/verify-reset-otp',
        data: <String, dynamic>{'email': email, 'otp': otp},
        options: _publicAuthRequestOptions,
      );
      final payload = response.data ?? const <String, dynamic>{};
      final data = Map<String, dynamic>.from(
        payload['data'] as Map? ?? const <String, dynamic>{},
      );
      final resetToken = (data['reset_token'] as String?)?.trim() ?? '';
      final verifiedEmail = (data['email'] as String?)?.trim() ?? email;

      if (resetToken.isEmpty) {
        throw const AuthFailure(
          'Password reset verification failed.',
          code: 'password_reset_verification_failed',
        );
      }

      return PasswordResetOtpVerificationResult(
        message: (payload['message'] as String?)?.trim().isNotEmpty == true
            ? (payload['message'] as String).trim()
            : 'Verification code confirmed.',
        resetToken: resetToken,
        email: verifiedEmail,
      );
    } on DioException catch (error) {
      throw mapAuthDioException(
        error,
        fallbackMessage: 'Verification code confirmation failed.',
      );
    }
  }

  @override
  Future<void> resetPassword({
    required String resetToken,
    required String newPassword,
  }) async {
    try {
      await _apiClient.dio.post<Map<String, dynamic>>(
        '$_authBasePath/reset-password',
        data: <String, dynamic>{
          'reset_token': resetToken,
          'new_password': newPassword,
        },
        options: _publicAuthRequestOptions,
      );
    } on DioException catch (error) {
      throw mapAuthDioException(
        error,
        fallbackMessage: 'Password reset failed.',
      );
    }
  }

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    _rotatedAuthTokens = null;
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_authBasePath/change-password',
        data: <String, dynamic>{
          'current_password': currentPassword,
          'new_password': newPassword,
        },
      );
      final payload = response.data ?? const <String, dynamic>{};
      final data = Map<String, dynamic>.from(
        payload['data'] as Map? ?? const <String, dynamic>{},
      );
      final accessToken = (data['token'] as String?)?.trim() ?? '';
      final refreshToken = (data['refreshToken'] as String?)?.trim() ?? '';
      if (accessToken.isEmpty || refreshToken.isEmpty) {
        throw DioException(
          requestOptions: response.requestOptions,
          response: response,
          message: 'Password change response is missing rotated credentials.',
        );
      }
      await _apiClient.replaceCurrentSessionTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
      );
      _rotatedAuthTokens = RotatedAuthTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
      );
    } on DioException catch (error) {
      throw mapAuthDioException(
        error,
        fallbackMessage: 'Password change failed.',
      );
    }
  }

  @override
  RotatedAuthTokens? takeRotatedAuthTokens() {
    final tokens = _rotatedAuthTokens;
    _rotatedAuthTokens = null;
    return tokens;
  }

  @override
  Future<AppUser> updateProfile({String? fullName, String? phone}) async {
    try {
      final data = <String, dynamic>{};
      if (fullName != null) {
        data['full_name'] = fullName;
      }
      if (phone != null) {
        data['phone'] = phone;
      }
      final response = await _apiClient.dio.put<Map<String, dynamic>>(
        '$_authBasePath/me',
        data: data,
      );
      final payload = response.data ?? const <String, dynamic>{};
      final userMap = Map<String, dynamic>.from(
        payload['data'] as Map? ?? const <String, dynamic>{},
      );
      final user = _parseUser(userMap);
      await _persistUserMetadata(user);
      return user;
    } on DioException catch (error) {
      throw mapAuthDioException(
        error,
        fallbackMessage: 'Profile update failed.',
      );
    }
  }

  @override
  Future<void> logout() async {
    final retired = await _apiClient.invalidateAuthenticatedSession();
    await _clearStoredSession();
    try {
      await _bestEffortUnregisterPushDevice(retired);
      await _apiClient.dio.post<Map<String, dynamic>>(
        '$_authBasePath/logout',
        options: _retiredSessionOptions(retired),
      );
    } catch (_) {
      // Best-effort call; local token clear is mandatory.
    }
  }

  @override
  Future<void> selfDeactivate() async {
    try {
      await _bestEffortUnregisterPushDevice(_apiClient.currentSessionBinding);
      await _apiClient.dio.post<Map<String, dynamic>>(
        '$_authBasePath/self-deactivate',
      );
      await _apiClient.invalidateAuthenticatedSession();
      await _clearStoredSession();
    } on DioException catch (error) {
      throw mapAuthDioException(
        error,
        fallbackMessage: 'Account deactivation failed.',
      );
    }
  }

  Future<void> _persistUserMetadata(AppUser user) async {
    await _storage.write(key: _userIdKey, value: user.id);
    await _storage.write(key: _nameKey, value: user.fullName);
    await _storage.write(key: _emailKey, value: user.email);
    await _storage.write(key: _phoneKey, value: user.phone ?? '');
    await _storage.write(key: _roleKey, value: user.role.name);
    await _storage.write(
      key: _superAdminKey,
      value: user.isProtectedSuperAdmin.toString(),
    );
  }

  bool _isContactVerificationRequired(DioException error) {
    final payload = error.response?.data;
    if (payload is! Map) return false;
    final responseError = payload['error'];
    return responseError is Map &&
        responseError['code'] == 'CONTACT_VERIFICATION_REQUIRED';
  }

  Future<void> _savePendingVerificationToken(Object? payload) async {
    if (payload is! Map) return;
    final data = payload['data'];
    if (data is! Map) return;
    final token = data['verification_token'];
    if (token is String && token.trim().isNotEmpty) {
      await _storage.write(
        key: ContactVerificationRepository.pendingTokenKey,
        value: token.trim(),
      );
    }
  }

  Future<AppUser?> _readStoredUser() async {
    final userId = await _storage.read(key: _userIdKey);
    final name = await _storage.read(key: _nameKey);
    final email = await _storage.read(key: _emailKey);
    final phone = await _storage.read(key: _phoneKey);
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
      phone: phone?.trim().isNotEmpty == true ? phone!.trim() : null,
      isProtectedSuperAdmin: isProtectedSuperAdmin == 'true',
    );
  }

  Future<void> _clearStoredSession() async {
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
    await _storage.delete(key: _roleKey);
    await _storage.delete(key: _nameKey);
    await _storage.delete(key: _emailKey);
    await _storage.delete(key: _phoneKey);
    await _storage.delete(key: _userIdKey);
    await _storage.delete(key: _superAdminKey);
  }

  Future<void> _bestEffortUnregisterPushDevice(
    ApiSessionBinding? retired,
  ) async {
    final token = await _storage.read(key: storedPushDeviceTokenKey);
    if (token == null || token.trim().isEmpty) {
      return;
    }

    try {
      await _apiClient.dio.post<Map<String, dynamic>>(
        '${AppEnv.apiVersionPrefix}/notifications/devices/unregister',
        data: <String, dynamic>{'token': token.trim()},
        options: _retiredSessionOptions(retired),
      );
      await _storage.delete(key: storedPushDeviceTokenKey);
    } catch (_) {
      // Best effort. A future authenticated session can overwrite this mapping.
    }
  }

  Options _retiredSessionOptions(ApiSessionBinding? retired) => Options(
    headers: <String, dynamic>{
      'Authorization': retired == null ? null : 'Bearer ${retired.accessToken}',
    },
  );

  Future<AuthSession> _refreshRememberedSession(String refreshToken) async {
    final response = await _apiClient.dio.post<Map<String, dynamic>>(
      '$_authBasePath/refresh-token',
      data: <String, dynamic>{'refresh_token': refreshToken},
      options: _publicAuthRequestOptions,
    );
    return _sessionFromAuthResponse(
      response.data ?? const <String, dynamic>{},
      rememberMe: true,
    );
  }

  bool _isTemporaryAuthenticationFailure(DioException error) {
    final statusCode = error.response?.statusCode;
    return error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        statusCode == 429 ||
        (statusCode != null && statusCode >= 500);
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
    final phone = (map['phone'] as String?)?.trim();
    final roleRaw = map['role'] as String?;
    final isProtectedSuperAdmin =
        (map['is_protected_super_admin'] as bool?) ?? false;

    return AppUser(
      id: id,
      fullName: fullName,
      email: email,
      role: _toRole(roleRaw),
      phone: phone?.isNotEmpty == true ? phone : null,
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

    await _apiClient.establishAuthenticatedSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      ownerUserId: user.id,
      persistTokens: rememberMe,
    );

    if (rememberMe) {
      await _persistUserMetadata(user);
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
