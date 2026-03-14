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
      'Request timed out. Please check your connection and try again.',
    );
  }

  if (error.type == DioExceptionType.connectionError) {
    return const AuthFailure(
      'Network connection failed. Verify internet access and API URL.',
    );
  }

  switch (statusCode) {
    case 401:
      return AuthFailure(
        responseMessage ?? 'Wrong email or password.',
        statusCode: statusCode,
      );
    case 403:
      return AuthFailure(
        responseMessage ?? 'Your account does not have access to continue.',
        statusCode: statusCode,
      );
    case 404:
      return AuthFailure(
        responseMessage ?? 'This account does not exist.',
        statusCode: statusCode,
      );
    case 409:
      return AuthFailure(
        responseMessage ?? 'An account with this email already exists.',
        statusCode: statusCode,
      );
    case 422:
      return AuthFailure(
        responseMessage ??
            'Submitted data is invalid. Please review all fields.',
        statusCode: statusCode,
      );
    case 429:
      return AuthFailure(
        responseMessage ?? 'Too many attempts. Try again in a few minutes.',
        statusCode: statusCode,
      );
    default:
      return AuthFailure(
        responseMessage ?? fallbackMessage,
        statusCode: statusCode,
      );
  }
}

String? _extractMessage(Object? data) {
  if (data is Map<String, dynamic>) {
    final message = data['message'] ?? data['error'];
    if (message is String && message.trim().isNotEmpty) {
      return message.trim();
    }

    final errors = data['errors'];
    if (errors is List) {
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
    }
  }

  if (data is String && data.trim().isNotEmpty) {
    return data.trim();
  }

  return null;
}
