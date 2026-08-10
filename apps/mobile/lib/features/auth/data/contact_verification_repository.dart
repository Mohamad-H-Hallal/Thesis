import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';
import '../domain/auth_error_mapper.dart';
import '../domain/auth_failure.dart';
import '../domain/auth_models.dart';
import '../domain/contact_verification_models.dart';

class ContactVerificationRepository {
  ContactVerificationRepository(this._storage, this._apiClient);

  static const pendingTokenKey = 'pending_contact_verification_token';
  static const _accessKey = 'access_token';
  static const _refreshKey = 'refresh_token';
  static const _roleKey = 'user_role';
  static const _nameKey = 'user_name';
  static const _emailKey = 'user_email';
  static const _userIdKey = 'user_id';
  static const _phoneKey = 'user_phone';
  static const _superAdminKey = 'is_protected_super_admin';

  final FlutterSecureStorage _storage;
  final ApiClient _apiClient;
  String get _base => '${AppEnv.apiVersionPrefix}/auth';

  Future<bool> hasPendingSession() async =>
      (await _storage.read(key: pendingTokenKey))?.trim().isNotEmpty == true;

  Future<void> savePendingToken(String token) async {
    if (token.trim().isEmpty) return;
    await _storage.write(key: pendingTokenKey, value: token.trim());
  }

  Future<void> clearPendingSession() => _storage.delete(key: pendingTokenKey);

  Future<ContactVerificationState> status() async {
    final response = await _call('GET', '/verification/status');
    return _stateFromPayload(response);
  }

  Future<ContactVerificationState> sendEmail({String? correctedEmail}) async {
    final response = await _call(
      'POST',
      '/verification/email/send',
      data: correctedEmail == null
          ? const {}
          : {'email': correctedEmail.trim()},
    );
    return _stateFromPayload(response);
  }

  Future<ContactVerificationResult> confirmEmail(String code) async {
    final response = await _call(
      'POST',
      '/verification/email/confirm',
      data: {'code': code.trim()},
    );
    await _saveReplacementVerificationToken(response);
    final data = Map<String, dynamic>.from(
      response['data'] as Map? ?? const {},
    );
    final state = ContactVerificationState.fromJson(
      Map<String, dynamic>.from(data['verification'] as Map? ?? const {}),
    );
    if (state.nextStep == ContactVerificationStep.complete) {
      await clearPendingSession();
    }
    return ContactVerificationResult(
      message: response['message'] as String? ?? 'Email verified.',
      state: state,
    );
  }

  Future<void> cancelPendingSignup() async {
    await _call('DELETE', '/verification/pending-signup');
    await clearPendingSession();
  }

  Future<ContactVerificationState> sendPhone({String? correctedPhone}) async {
    final response = await _call(
      'POST',
      '/verification/phone/send',
      data: correctedPhone == null ? const {} : {'phone': correctedPhone},
    );
    return _stateFromPayload(response);
  }

  Future<ContactVerificationResult> validatePhone({
    String? correctedPhone,
  }) async {
    final response = await _call(
      'POST',
      '/verification/phone/validate',
      data: correctedPhone == null ? const {} : {'phone': correctedPhone},
    );
    final data = Map<String, dynamic>.from(
      response['data'] as Map? ?? const {},
    );
    await clearPendingSession();
    return ContactVerificationResult(
      message:
          response['message'] as String? ??
          'Mobile-number format validated. Ownership was not verified.',
      state: ContactVerificationState.fromJson(
        Map<String, dynamic>.from(data['verification'] as Map? ?? const {}),
      ),
    );
  }

  Future<ContactVerificationResult> confirmPhone(String code) async {
    final response = await _call(
      'POST',
      '/verification/phone/confirm',
      data: {'code': code.trim()},
    );
    final data = Map<String, dynamic>.from(
      response['data'] as Map? ?? const {},
    );
    final state = ContactVerificationState.fromJson(
      Map<String, dynamic>.from(data['verification'] as Map? ?? const {}),
    );
    await clearPendingSession();
    return ContactVerificationResult(
      message: response['message'] as String? ?? 'Mobile number verified.',
      state: state,
    );
  }

  Future<AuthSession?> requestPhoneChange({
    required String phone,
    required String currentPassword,
  }) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_base/me/phone-change/request',
        data: {'phone': phone, 'current_password': currentPassword},
      );
      final data = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const {},
      );
      if (data['completed'] != true) return null;
      final session = await _sessionFromData(data);
      if (session == null) {
        throw const AuthFailure(
          'The mobile number changed, but the renewed session is missing.',
        );
      }
      return session;
    } on DioException catch (error) {
      throw mapAuthDioException(
        error,
        fallbackMessage: 'Mobile-number change failed.',
      );
    }
  }

  Future<AuthSession> confirmPhoneChange(String code) =>
      _confirmAuthenticatedChange('/me/phone-change/confirm', code);

  Future<AuthSession> _confirmAuthenticatedChange(
    String path,
    String code,
  ) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_base$path',
        data: {'code': code.trim()},
      );
      final payload = response.data ?? const <String, dynamic>{};
      final data = Map<String, dynamic>.from(
        payload['data'] as Map? ?? const {},
      );
      final session = await _sessionFromData(data);
      if (session == null) {
        throw const AuthFailure(
          'The contact was verified, but the renewed session is missing.',
        );
      }
      return session;
    } on DioException catch (error) {
      throw mapAuthDioException(
        error,
        fallbackMessage: 'Contact verification failed.',
      );
    }
  }

  Future<AuthSession?> _sessionFromData(Map<String, dynamic> data) async {
    final access = data['token'] as String? ?? '';
    final refresh = data['refreshToken'] as String? ?? '';
    if (access.isEmpty || refresh.isEmpty) return null;
    final user = _parseUser(
      Map<String, dynamic>.from(data['user'] as Map? ?? const {}),
    );
    if (user.id.isEmpty) return null;
    await _apiClient.establishAuthenticatedSession(
      accessToken: access,
      refreshToken: refresh,
      ownerUserId: user.id,
      persistTokens: true,
    );
    await _persistUser(user);
    return AuthSession(accessToken: access, refreshToken: refresh, user: user);
  }

  Future<Map<String, dynamic>> _call(
    String method,
    String path, {
    Map<String, dynamic>? data,
  }) async {
    final token = await _storage.read(key: pendingTokenKey);
    if (token == null || token.trim().isEmpty) {
      throw const AuthFailure(
        'Your verification session has expired. Sign in again.',
        code: 'verification_session_expired',
      );
    }
    try {
      final response = await _apiClient.dio.request<Map<String, dynamic>>(
        '$_base$path',
        data: data,
        options: Options(
          method: method,
          headers: {'Authorization': 'Bearer ${token.trim()}'},
        ),
      );
      return response.data ?? const <String, dynamic>{};
    } on DioException catch (error) {
      throw mapAuthDioException(error, fallbackMessage: 'Verification failed.');
    }
  }

  ContactVerificationState _stateFromPayload(Map<String, dynamic> payload) {
    final data = Map<String, dynamic>.from(payload['data'] as Map? ?? const {});
    return ContactVerificationState.fromJson(
      Map<String, dynamic>.from(data['verification'] as Map? ?? const {}),
    );
  }

  Future<void> _saveReplacementVerificationToken(
    Map<String, dynamic> payload,
  ) async {
    final data = Map<String, dynamic>.from(payload['data'] as Map? ?? const {});
    final token = data['verification_token'] as String?;
    if (token != null) await savePendingToken(token);
  }

  AppUser _parseUser(Map<String, dynamic> map) => AppUser(
    id: map['id'] as String? ?? '',
    fullName: map['full_name'] as String? ?? '',
    email: map['email'] as String? ?? '',
    phone: (map['phone'] as String?)?.trim(),
    role: switch (map['role']) {
      'admin' => UserRole.admin,
      'viewer' => UserRole.viewer,
      _ => UserRole.contributor,
    },
    isProtectedSuperAdmin: map['is_protected_super_admin'] == true,
  );

  Future<void> _persistUser(AppUser user) async {
    await _storage.write(
      key: _accessKey,
      value: _apiClient.currentSessionBinding?.accessToken,
    );
    await _storage.write(
      key: _refreshKey,
      value: _apiClient.currentSessionBinding?.refreshToken,
    );
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
}
