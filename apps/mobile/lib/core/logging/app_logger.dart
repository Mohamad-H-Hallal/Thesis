import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../config/app_env.dart';

enum AppLogLevel { debug, info, warning, error }

/// Central, privacy-aware application diagnostics.
///
/// Messages are sent to the platform diagnostic stream (Android logcat,
/// Apple unified logging, or the browser console). Persistent device files are
/// deliberately avoided because they are difficult to protect, retain, and
/// collect safely from user devices without a dedicated consent workflow.
abstract final class AppLogger {
  static const String _redacted = '[REDACTED]';
  static final RegExp _sensitiveKey = RegExp(
    r'authorization|cookie|password|passphrase|access[_-]?token|refresh[_-]?token|otp|verification[_-]?code|secret|private[_-]?key|credential|email|phone|body|payload|geometry|coordinates|latitude|longitude|bbox|attributes|file[_-]?(?:path|name|buffer)',
    caseSensitive: false,
  );

  static void debug(
    String message, {
    required String component,
    Map<String, Object?> context = const <String, Object?>{},
  }) {
    _write(AppLogLevel.debug, message, component: component, context: context);
  }

  static void info(
    String message, {
    required String component,
    Map<String, Object?> context = const <String, Object?>{},
  }) {
    _write(AppLogLevel.info, message, component: component, context: context);
  }

  static void warning(
    String message, {
    required String component,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> context = const <String, Object?>{},
  }) {
    _write(
      AppLogLevel.warning,
      message,
      component: component,
      error: error,
      stackTrace: stackTrace,
      context: context,
    );
  }

  static void error(
    String message, {
    required String component,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> context = const <String, Object?>{},
  }) {
    _write(
      AppLogLevel.error,
      message,
      component: component,
      error: error,
      stackTrace: stackTrace,
      context: context,
    );
  }

  @visibleForTesting
  static String sanitizeForLogging(String value) {
    return value
        .replaceAll(
          RegExp(
            r'-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----',
            caseSensitive: false,
          ),
          _redacted,
        )
        .replaceAll(
          RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
          'Bearer $_redacted',
        )
        .replaceAll(
          RegExp(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b'),
          _redacted,
        )
        .replaceAll(
          RegExp(
            r'\b(password|passphrase|access[_-]?token|refresh[_-]?token|otp|verification[_-]?code|secret|private[_-]?key)\s*[:=]\s*([^\s,;]+)',
            caseSensitive: false,
          ),
          r'$1=[REDACTED]',
        )
        .replaceAll(
          RegExp(
            r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}',
            caseSensitive: false,
          ),
          _redacted,
        )
        .replaceAll(
          RegExp(r'(?<!\d)(?:\+?961|0)?(?:3|70|71|76|78|79|81)\d{6}(?!\d)'),
          _redacted,
        );
  }

  static void _write(
    AppLogLevel level,
    String message, {
    required String component,
    Object? error,
    StackTrace? stackTrace,
    required Map<String, Object?> context,
  }) {
    if (!_isEnabled(level)) return;

    final safeContext = <String, Object?>{};
    for (final entry in context.entries) {
      safeContext[entry.key] = _sanitizeValue(entry.value, key: entry.key);
    }
    final safeError = error == null
        ? null
        : '${error.runtimeType}: ${sanitizeForLogging(error.toString())}';
    final safeStack = stackTrace == null
        ? null
        : StackTrace.fromString(sanitizeForLogging(stackTrace.toString()));
    final event = <String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'level': level.name.toUpperCase(),
      'component': component,
      'message': sanitizeForLogging(message),
      'exception': ?safeError,
      if (safeContext.isNotEmpty) 'context': safeContext,
    };

    developer.log(
      jsonEncode(event),
      name: 'terraleb.$component',
      level: _developerLevel(level),
      error: safeError,
      stackTrace: safeStack,
      time: DateTime.now(),
    );
  }

  static Object? _sanitizeValue(Object? value, {required String key}) {
    if (_sensitiveKey.hasMatch(key)) return _redacted;
    if (value == null || value is num || value is bool) return value;
    if (value is String) return sanitizeForLogging(value);
    if (value is Iterable<Object?>) {
      return value
          .map((item) => _sanitizeValue(item, key: ''))
          .toList(growable: false);
    }
    if (value is Map<Object?, Object?>) {
      return <String, Object?>{
        for (final entry in value.entries)
          entry.key.toString(): _sanitizeValue(
            entry.value,
            key: entry.key.toString(),
          ),
      };
    }
    return sanitizeForLogging(value.toString());
  }

  static bool _isEnabled(AppLogLevel level) {
    final configured = switch (AppEnv.appLogLevel) {
      'error' => AppLogLevel.error,
      'warning' || 'warn' => AppLogLevel.warning,
      'debug' => AppLogLevel.debug,
      _ => AppLogLevel.info,
    };
    if (kReleaseMode && level == AppLogLevel.debug) return false;
    return level.index >= configured.index;
  }

  static int _developerLevel(AppLogLevel level) => switch (level) {
    AppLogLevel.debug => 500,
    AppLogLevel.info => 800,
    AppLogLevel.warning => 900,
    AppLogLevel.error => 1000,
  };
}
