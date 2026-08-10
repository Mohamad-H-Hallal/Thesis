import 'package:dio/dio.dart';

String userFacingErrorMessage(Object error, {required String fallback}) {
  if (error is DioException) {
    return userFacingDioMessage(error, fallback: fallback);
  }
  if (error is String) {
    return _sanitizeMessage(error, fallback: fallback);
  }
  return _sanitizeMessage(error.toString(), fallback: fallback);
}

String userFacingDioMessage(DioException error, {required String fallback}) {
  if (error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.receiveTimeout ||
      error.type == DioExceptionType.sendTimeout ||
      error.type == DioExceptionType.connectionError) {
    return 'Unable to reach the server right now. Please try again.';
  }

  final statusCode = error.response?.statusCode;
  final extracted = _extractMessage(error);

  if (statusCode == 401) {
    return 'Your session may have expired. Please sign in again.';
  }

  if (statusCode == 403) {
    final normalized = extracted?.toLowerCase() ?? '';
    if (normalized.contains('token') ||
        normalized.contains('unauthorized') ||
        normalized.contains('forbidden') ||
        normalized.contains('expired') ||
        normalized.contains('session')) {
      return 'Your session may have expired. Please sign in again.';
    }
  }

  if (statusCode == 429) {
    return 'Requests are temporarily limited. Please wait a moment and try again.';
  }

  if (extracted != null && extracted.trim().isNotEmpty) {
    return _sanitizeMessage(extracted, fallback: fallback);
  }

  return fallback;
}

String? _extractMessage(DioException error) {
  final data = error.response?.data;
  if (data is Map<String, dynamic>) {
    final fieldMessage = _extractFirstFieldError(data['errors']);
    final value = data['message'] ?? data['error'];
    if (value is String && value.trim().isNotEmpty) {
      final trimmed = value.trim();
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

String _sanitizeMessage(String message, {required String fallback}) {
  var normalized = message.trim();
  if (normalized.isEmpty) {
    return fallback;
  }

  const removablePrefixes = <String>['Exception:', 'Error:', 'Bad state:'];
  for (final prefix in removablePrefixes) {
    if (normalized.startsWith(prefix)) {
      normalized = normalized.substring(prefix.length).trim();
    }
  }
  if (normalized.isEmpty) {
    return fallback;
  }

  final lower = normalized.toLowerCase();
  if (normalized == 'Email already registered') {
    return 'This email is already registered.';
  }

  const technicalFragments = <String>[
    'dioexception',
    'bad response',
    'xmlhttprequest',
    'socketexception',
    'formatexception',
    'limit must be between',
    'renderflex overflowed',
    'boxconstraints forces',
    'null check operator used on a null value',
    'child.hassize',
    'response did not match the active project',
    'response did not match the active import',
    'authenticated session changed while',
  ];

  if (lower.startsWith('instance of') ||
      lower.startsWith('type ') ||
      technicalFragments.any(lower.contains)) {
    return fallback;
  }

  if (lower.contains('too many requests')) {
    return 'Requests are temporarily limited. Please wait a moment and try again.';
  }

  return normalized;
}
