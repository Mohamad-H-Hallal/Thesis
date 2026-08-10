import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/app_env.dart';

/// Immutable proof that a request was created for one authenticated session.
///
/// The generation changes on every login/logout. The refresh token remains
/// private to this library and is never copied into request headers.
class ApiSessionBinding {
  const ApiSessionBinding._({
    required this.ownerUserId,
    required this.generation,
    required this.accessToken,
    required String refreshToken,
  }) : _refreshToken = refreshToken;

  final String ownerUserId;
  final int generation;
  final String accessToken;
  final String _refreshToken;
  String get refreshToken => _refreshToken;
}

class ApiClient {
  ApiClient({Dio? dio, FlutterSecureStorage? storage})
    : _storage = storage,
      dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: AppEnv.apiBaseUrl,
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 15),
              headers: const {'Content-Type': 'application/json'},
            ),
          ) {
    _installTokenRefreshInterceptor();
  }

  final Dio dio;
  final FlutterSecureStorage? _storage;
  final Map<({int generation, String ownerUserId}), Future<_TokenRefreshResult>>
  _refreshFutures =
      <({int generation, String ownerUserId}), Future<_TokenRefreshResult>>{};
  Future<void> _tokenStorageTail = Future<void>.value();
  ApiSessionBinding? _session;
  int _sessionGeneration = 0;

  static const _accessKey = 'access_token';
  static const _refreshKey = 'refresh_token';
  static const _skipAuthRefreshKey = 'skip_auth_refresh';
  static const _sessionBindingKey = 'api_session_binding';
  static const _deviceFingerprintKey = 'verification_device_fingerprint';
  Future<String?>? _deviceFingerprintFuture;

  ApiSessionBinding? get currentSessionBinding => _session;

  /// Starts a new authentication generation after all refreshes from the old
  /// generation have settled. Token persistence is serialized with refreshes
  /// so a late Account A response cannot overwrite Account B's credentials.
  Future<void> establishAuthenticatedSession({
    required String accessToken,
    required String refreshToken,
    required String ownerUserId,
    bool? persistTokens,
  }) async {
    final normalizedAccess = accessToken.trim();
    final normalizedRefresh = refreshToken.trim();
    final normalizedOwner = ownerUserId.trim();
    if (normalizedAccess.isEmpty ||
        normalizedRefresh.isEmpty ||
        normalizedOwner.isEmpty) {
      throw ArgumentError(
        'Authenticated session identity and tokens required.',
      );
    }

    final activationGeneration = _invalidateSessionNow();
    await _waitForRefreshes();
    await _runTokenStorageMutation(() async {
      if (_sessionGeneration != activationGeneration || _session != null) {
        return;
      }
      final storage = _storage;
      if (storage == null || persistTokens == null) {
        return;
      }
      if (persistTokens) {
        await storage.write(key: _accessKey, value: normalizedAccess);
        if (_sessionGeneration != activationGeneration || _session != null) {
          return;
        }
        await storage.write(key: _refreshKey, value: normalizedRefresh);
      } else {
        await storage.delete(key: _accessKey);
        if (_sessionGeneration != activationGeneration || _session != null) {
          return;
        }
        await storage.delete(key: _refreshKey);
      }
    });
    if (_sessionGeneration != activationGeneration || _session != null) {
      throw StateError('Authentication session changed while being activated.');
    }

    final binding = ApiSessionBinding._(
      ownerUserId: normalizedOwner,
      generation: activationGeneration,
      accessToken: normalizedAccess,
      refreshToken: normalizedRefresh,
    );
    _session = binding;
    dio.options.headers['Authorization'] = 'Bearer $normalizedAccess';
  }

  /// Invalidates the current generation synchronously, then waits for stale
  /// refresh work before clearing persisted tokens.
  Future<ApiSessionBinding?> invalidateAuthenticatedSession({
    bool clearPersistedTokens = true,
  }) async {
    final retired = _session;
    final invalidationGeneration = _invalidateSessionNow();
    await _waitForRefreshes();
    if (clearPersistedTokens) {
      await _runTokenStorageMutation(() async {
        if (_sessionGeneration != invalidationGeneration || _session != null) {
          return;
        }
        final storage = _storage;
        if (storage == null) {
          return;
        }
        await storage.delete(key: _accessKey);
        if (_sessionGeneration != invalidationGeneration || _session != null) {
          return;
        }
        await storage.delete(key: _refreshKey);
      });
    }
    return retired;
  }

  /// Compatibility hook for unauthenticated tests and legacy callers. Real
  /// authenticated flows must use [establishAuthenticatedSession] so refresh
  /// is bound to an owner and generation.
  void setAccessToken(String? token) {
    final normalized = token?.trim() ?? '';
    final generation = _invalidateSessionNow();
    if (normalized.isEmpty) {
      return;
    }
    _session = ApiSessionBinding._(
      ownerUserId: '',
      generation: generation,
      accessToken: normalized,
      refreshToken: '',
    );
    dio.options.headers['Authorization'] = 'Bearer $normalized';
  }

  ApiSessionBinding? captureSessionForOwner(String ownerUserId) {
    final current = _session;
    final normalizedOwner = ownerUserId.trim();
    if (current == null ||
        normalizedOwner.isEmpty ||
        current.ownerUserId != normalizedOwner) {
      return null;
    }
    return current;
  }

  Options bindAuthenticatedRequest({
    required ApiSessionBinding session,
    Map<String, dynamic> headers = const <String, dynamic>{},
  }) {
    return Options(
      headers: <String, dynamic>{
        ...headers,
        'Authorization': 'Bearer ${session.accessToken}',
      },
      extra: <String, dynamic>{_sessionBindingKey: session},
    );
  }

  int _invalidateSessionNow() {
    _sessionGeneration += 1;
    _session = null;
    dio.options.headers.remove('Authorization');
    return _sessionGeneration;
  }

  bool _isCurrentGeneration(ApiSessionBinding binding) {
    final current = _session;
    return current != null &&
        current.generation == binding.generation &&
        current.ownerUserId == binding.ownerUserId;
  }

  Future<void> _waitForRefreshes() async {
    final pending = _refreshFutures.values.toList(growable: false);
    if (pending.isEmpty) {
      return;
    }
    await Future.wait(
      pending.map((future) => future.then<void>((_) {}).catchError((_) {})),
    );
  }

  Future<void> _runTokenStorageMutation(Future<void> Function() mutation) {
    final completer = Completer<void>();
    final previous = _tokenStorageTail;
    _tokenStorageTail = completer.future;
    return () async {
      try {
        try {
          await previous;
        } catch (_) {
          // A prior storage failure must not permanently block later cleanup.
        }
        await mutation();
      } finally {
        completer.complete();
      }
    }();
  }

  void _installTokenRefreshInterceptor() {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          final fingerprint = await _getOrCreateDeviceFingerprint();
          if (fingerprint != null) {
            request.headers['X-Device-Fingerprint'] = fingerprint;
          }
          final binding = request.extra[_sessionBindingKey];
          if (binding is ApiSessionBinding) {
            if (!_isCurrentGeneration(binding)) {
              handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.cancel,
                  message:
                      'Authenticated session changed before the request was sent.',
                ),
              );
              return;
            }
            final current = _session!;
            request.headers['Authorization'] = 'Bearer ${current.accessToken}';
          }
          handler.next(request);
        },
        onError: (error, handler) async {
          final binding = _refreshBindingFor(error);
          if (binding == null) {
            handler.next(error);
            return;
          }

          _TokenRefreshResult refreshResult;
          try {
            refreshResult = await _refreshAccessToken(binding);
          } catch (_) {
            handler.next(error);
            return;
          }

          final propagatedRefreshError =
              refreshResult.terminalError ?? refreshResult.retryableError;
          if (propagatedRefreshError != null &&
              _isOfflineSyncRequest(error.requestOptions)) {
            handler.next(
              _copyRefreshErrorToOriginalRequest(
                originalRequest: error.requestOptions,
                refreshError: propagatedRefreshError,
              ),
            );
            return;
          }

          final freshAccessToken = refreshResult.accessToken;
          final current = _session;
          if (freshAccessToken == null ||
              freshAccessToken.isEmpty ||
              current == null ||
              !_isCurrentGeneration(binding) ||
              current.accessToken != freshAccessToken) {
            handler.next(error);
            return;
          }

          final request = error.requestOptions;
          final retryHeaders = Map<String, dynamic>.from(request.headers)
            ..['Authorization'] = 'Bearer $freshAccessToken';
          final retryOptions = request.copyWith(
            data: _cloneRetryBody(request.data),
            headers: retryHeaders,
            extra: Map<String, dynamic>.from(request.extra)
              ..[_skipAuthRefreshKey] = true
              ..[_sessionBindingKey] = current,
          );

          try {
            final response = await dio.fetch<dynamic>(retryOptions);
            handler.resolve(response);
          } on DioException catch (retryError) {
            handler.next(retryError);
          }
        },
      ),
    );
  }

  Future<String?> _getOrCreateDeviceFingerprint() {
    final existing = _deviceFingerprintFuture;
    if (existing != null) return existing;
    final future = () async {
      final storage = _storage;
      if (storage == null) return null;
      try {
        final stored = await storage.read(key: _deviceFingerprintKey);
        if (stored?.trim().isNotEmpty == true) return stored!.trim();
        final random = Random.secure();
        final bytes = List<int>.generate(32, (_) => random.nextInt(256));
        final generated = base64UrlEncode(bytes).replaceAll('=', '');
        await storage.write(key: _deviceFingerprintKey, value: generated);
        return generated;
      } catch (_) {
        return null;
      }
    }();
    _deviceFingerprintFuture = future;
    return future;
  }

  ApiSessionBinding? _refreshBindingFor(DioException error) {
    if (!_shouldAttemptRefresh(error)) {
      return null;
    }
    final request = error.requestOptions;
    final explicitBinding = request.extra[_sessionBindingKey];
    if (explicitBinding is ApiSessionBinding) {
      return _isCurrentGeneration(explicitBinding) ? explicitBinding : null;
    }

    final current = _session;
    final authHeader = request.headers['Authorization'];
    if (current == null ||
        current.ownerUserId.isEmpty ||
        authHeader != 'Bearer ${current.accessToken}') {
      return null;
    }
    return current;
  }

  bool _shouldAttemptRefresh(DioException error) {
    if (error.response?.statusCode != 401) {
      return false;
    }

    final request = error.requestOptions;
    if (request.extra[_skipAuthRefreshKey] == true) {
      return false;
    }

    final path = request.path;
    return !path.endsWith('/auth/login') &&
        !path.endsWith('/auth/reactivate-login') &&
        !path.endsWith('/auth/register') &&
        !path.endsWith('/auth/refresh-token');
  }

  bool _isOfflineSyncRequest(RequestOptions request) {
    return request.path.endsWith(
      '${AppEnv.apiVersionPrefix}/features/offline-sync',
    );
  }

  DioException _copyRefreshErrorToOriginalRequest({
    required RequestOptions originalRequest,
    required DioException refreshError,
  }) {
    final refreshResponse = refreshError.response;
    return DioException(
      requestOptions: originalRequest,
      response: refreshResponse == null
          ? null
          : Response<dynamic>(
              requestOptions: originalRequest,
              data: refreshResponse.data,
              headers: refreshResponse.headers,
              statusCode: refreshResponse.statusCode,
              statusMessage: refreshResponse.statusMessage,
            ),
      type: refreshResponse == null
          ? refreshError.type
          : DioExceptionType.badResponse,
      error: refreshError.error,
      message: refreshError.message,
    );
  }

  Future<_TokenRefreshResult> _refreshAccessToken(ApiSessionBinding binding) {
    final key = (
      generation: binding.generation,
      ownerUserId: binding.ownerUserId,
    );
    final inFlight = _refreshFutures[key];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _performTokenRefresh(binding);
    _refreshFutures[key] = future;
    return () async {
      try {
        return await future;
      } finally {
        if (identical(_refreshFutures[key], future)) {
          _refreshFutures.remove(key);
        }
      }
    }();
  }

  Future<_TokenRefreshResult> _performTokenRefresh(
    ApiSessionBinding binding,
  ) async {
    final refreshToken = binding._refreshToken;
    if (refreshToken.isEmpty || !_isCurrentGeneration(binding)) {
      return const _TokenRefreshResult();
    }

    try {
      final response = await dio.post<Map<String, dynamic>>(
        '${AppEnv.apiVersionPrefix}/auth/refresh-token',
        data: <String, dynamic>{'refresh_token': refreshToken},
        options: Options(
          extra: const <String, dynamic>{_skipAuthRefreshKey: true},
          headers: const <String, dynamic>{'Authorization': null},
        ),
      );

      final payload = response.data ?? const <String, dynamic>{};
      final data = Map<String, dynamic>.from(
        payload['data'] as Map? ?? const <String, dynamic>{},
      );
      final accessToken = (data['token'] as String?)?.trim() ?? '';
      final nextRefreshToken =
          (data['refreshToken'] as String?)?.trim() ?? refreshToken;
      if (accessToken.isEmpty || !_isCurrentGeneration(binding)) {
        return const _TokenRefreshResult();
      }

      await _runTokenStorageMutation(() async {
        if (!_isCurrentGeneration(binding)) {
          return;
        }
        final storage = _storage;
        if (storage == null) {
          return;
        }
        await storage.write(key: _accessKey, value: accessToken);
        if (!_isCurrentGeneration(binding)) {
          return;
        }
        await storage.write(key: _refreshKey, value: nextRefreshToken);
      });
      if (!_isCurrentGeneration(binding)) {
        return const _TokenRefreshResult();
      }

      final updated = ApiSessionBinding._(
        ownerUserId: binding.ownerUserId,
        generation: binding.generation,
        accessToken: accessToken,
        refreshToken: nextRefreshToken,
      );
      _session = updated;
      dio.options.headers['Authorization'] = 'Bearer $accessToken';
      return _TokenRefreshResult(accessToken: accessToken);
    } on DioException catch (error) {
      final terminalError = _isDefinitiveInactiveAccount(error) ? error : null;
      if (terminalError != null || _invalidatesCredentials(error)) {
        final invalidationGeneration = _invalidateIfCurrent(binding);
        if (invalidationGeneration != null) {
          await _clearInvalidatedTokens(invalidationGeneration);
        }
      }
      return _TokenRefreshResult(
        terminalError: terminalError,
        retryableError: _isTemporaryRefreshFailure(error) ? error : null,
      );
    }
  }

  int? _invalidateIfCurrent(ApiSessionBinding binding) {
    if (!_isCurrentGeneration(binding)) {
      return null;
    }
    return _invalidateSessionNow();
  }

  Future<void> _clearInvalidatedTokens(int invalidationGeneration) {
    return _runTokenStorageMutation(() async {
      if (_sessionGeneration != invalidationGeneration || _session != null) {
        return;
      }
      final storage = _storage;
      if (storage == null) {
        return;
      }
      await storage.delete(key: _accessKey);
      if (_sessionGeneration != invalidationGeneration || _session != null) {
        return;
      }
      await storage.delete(key: _refreshKey);
    });
  }

  bool _invalidatesCredentials(DioException error) {
    final statusCode = error.response?.statusCode;
    return statusCode == 400 || statusCode == 401 || statusCode == 403;
  }

  bool _isTemporaryRefreshFailure(DioException error) {
    final statusCode = error.response?.statusCode;
    return error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        statusCode == 429 ||
        (statusCode != null && statusCode >= 500);
  }

  bool _isDefinitiveInactiveAccount(DioException error) {
    final statusCode = error.response?.statusCode;
    if (statusCode == null || statusCode < 400 || statusCode >= 500) {
      return false;
    }
    final responseData = error.response?.data;
    if (responseData is! Map) {
      return false;
    }
    final errorData = responseData['error'];
    return errorData is Map &&
        errorData['code'] == 'OFFLINE_SYNC_ACCOUNT_INACTIVE' &&
        errorData['disposition'] == 'permanent_rejection' &&
        errorData['retryable'] == false;
  }

  dynamic _cloneRetryBody(dynamic data) {
    if (data is FormData) {
      return data.clone();
    }
    return data;
  }
}

class _TokenRefreshResult {
  const _TokenRefreshResult({
    this.accessToken,
    this.terminalError,
    this.retryableError,
  });

  final String? accessToken;
  final DioException? terminalError;
  final DioException? retryableError;
}
