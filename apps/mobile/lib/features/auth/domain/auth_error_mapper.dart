import 'package:dio/dio.dart';
import 'auth_failure.dart';

AuthFailure mapAuthDioException(
  DioException error, {
  required String fallbackMessage,
}) {
  final statusCode = error.response?.statusCode;
  final responseMessage = _extractMessage(error.response?.data);
  final responseCode = _extractCode(error.response?.data);

  if (error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.receiveTimeout ||
      error.type == DioExceptionType.sendTimeout) {
    return AuthFailure(
      'Sign-in timed out. Check your connection and try again.${_localAndroidDevHint()}',
      code: 'timeout',
    );
  }

  if (error.type == DioExceptionType.connectionError) {
    return AuthFailure(
      'You are offline. New sign-in requires internet access. Reconnect and try again.${_localAndroidDevHint()}',
      code: 'network_error',
    );
  }

  switch (statusCode) {
    case 401:
      return AuthFailure(
        responseMessage ?? 'Wrong email or password.',
        statusCode: statusCode,
        code: 'invalid_credentials',
      );
    case 403:
      if (responseCode == 'CONTACT_VERIFICATION_REQUIRED') {
        return AuthFailure(
          responseMessage ?? 'Contact verification is required.',
          statusCode: 403,
          code: 'contact_verification_required',
        );
      }
      final normalized = (responseMessage ?? '').toLowerCase();
      if (normalized.contains('blocked')) {
        return const AuthFailure(
          'Your account has been blocked.',
          statusCode: 403,
          code: 'blocked_account',
        );
      }
      if (normalized.contains('activate it to continue')) {
        return const AuthFailure(
          'Your contributor account is deactivated. Activate it to continue logging in.',
          statusCode: 403,
          code: 'deactivated_contributor',
        );
      }
      if (normalized.contains('pending approval')) {
        return const AuthFailure(
          'Your contributor request is still pending approval. You cannot log in yet.',
          statusCode: 403,
          code: 'pending_contributor',
        );
      }
      if (normalized.contains('request was rejected')) {
        return const AuthFailure(
          'Your contributor request was rejected. You cannot log in with contributor access.',
          statusCode: 403,
          code: 'rejected_contributor',
        );
      }
      if (normalized.contains('inactive')) {
        return const AuthFailure(
          'This account is inactive.',
          statusCode: 403,
          code: 'inactive_account',
        );
      }
      return AuthFailure(
        responseMessage ?? 'Your account does not have access to continue.',
        statusCode: statusCode,
        code: 'forbidden',
      );
    case 404:
      return AuthFailure(
        responseMessage ?? 'This account does not exist.',
        statusCode: statusCode,
        code: 'account_not_found',
      );
    case 409:
      if (responseCode == 'EMAIL_ALREADY_IN_USE') {
        return AuthFailure(
          responseMessage ?? 'An account already uses this email address.',
          statusCode: statusCode,
          code: 'duplicate_email',
        );
      }
      if (responseCode == 'PHONE_ALREADY_IN_USE') {
        return AuthFailure(
          responseMessage ?? 'An account already uses this mobile number.',
          statusCode: statusCode,
          code: 'duplicate_phone',
        );
      }
      if (responseCode == 'PHONE_ACCOUNT_LIMIT_REACHED') {
        return AuthFailure(
          responseMessage ??
              'This mobile number is already used by the maximum of 3 accounts. Use another Lebanese mobile number.',
          statusCode: statusCode,
          code: 'phone_account_limit',
        );
      }
      if (responseCode == 'CONTACT_ALREADY_IN_USE') {
        return AuthFailure(
          responseMessage ??
              'An account already uses this email address and mobile number.',
          statusCode: statusCode,
          code: 'duplicate_contact',
        );
      }
      return AuthFailure(
        responseMessage ?? 'The request conflicts with existing account data.',
        statusCode: statusCode,
        code: 'conflict',
      );
    case 400:
    case 422:
      return AuthFailure(
        responseMessage ??
            'Submitted data is invalid. Please review all fields.',
        statusCode: statusCode,
        code: 'validation_error',
      );
    case 429:
      return AuthFailure(
        responseMessage ?? 'Too many attempts. Try again in a few minutes.',
        statusCode: statusCode,
        code: 'rate_limited',
      );
    case 503:
      return AuthFailure(
        responseMessage ??
            'We could not send the verification code right now. Please try again later.',
        statusCode: statusCode,
        code: 'email_delivery_failed',
      );
    default:
      return AuthFailure(
        responseMessage ?? fallbackMessage,
        statusCode: statusCode,
        code: 'unknown_auth_error',
      );
  }
}

String? _extractCode(Object? data) {
  if (data is! Map) return null;
  final error = data['error'];
  return error is Map && error['code'] is String
      ? error['code'] as String
      : null;
}

String _localAndroidDevHint() {
  return ' If you are using a real Android device against the local API, 10.0.2.2 only works on the emulator. Use your computer\'s LAN IP in API_BASE_URL.';
}

String? _extractMessage(Object? data) {
  if (data is Map<String, dynamic>) {
    final fieldMessage = _extractFirstFieldError(data['errors']);
    final message = data['message'] ?? data['error'];
    if (message is String && message.trim().isNotEmpty) {
      final trimmed = message.trim();
      if (trimmed.toLowerCase() == 'validation failed' &&
          fieldMessage != null) {
        return fieldMessage;
      }
      return trimmed;
    }

    return fieldMessage;
  }

  if (data is String && data.trim().isNotEmpty) {
    return data.trim();
  }

  return null;
}

String? _extractFirstFieldError(Object? errors) {
  if (errors is! List) {
    return null;
  }

  for (final item in errors) {
    if (item is String && item.trim().isNotEmpty) {
      return item.trim();
    }
    if (item is Map<String, dynamic>) {
      final nested = item['message'] ?? item['msg'];
      if (nested is String && nested.trim().isNotEmpty) {
        return nested.trim();
      }
    }
  }

  return null;
}
