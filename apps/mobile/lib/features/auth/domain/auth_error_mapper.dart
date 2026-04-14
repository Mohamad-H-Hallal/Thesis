import 'package:dio/dio.dart';

import 'auth_failure.dart';

AuthFailure mapAuthDioException(
  DioException error, {
  required String fallbackMessage,
}) {
  final statusCode = error.response?.statusCode;
  final responseMessage = _extractMessage(error.response?.data);

  if (error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.receiveTimeout ||
      error.type == DioExceptionType.sendTimeout) {
    return const AuthFailure(
      'Sign-in timed out. Check your connection and try again.',
      code: 'timeout',
    );
  }

  if (error.type == DioExceptionType.connectionError) {
    return const AuthFailure(
      'You are offline. New sign-in requires internet access. Reconnect and try again.',
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
      return AuthFailure(
        responseMessage == 'Email already registered'
            ? 'This email is already registered.'
            : (responseMessage ?? 'This email is already registered.'),
        statusCode: statusCode,
        code: 'duplicate_email',
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
