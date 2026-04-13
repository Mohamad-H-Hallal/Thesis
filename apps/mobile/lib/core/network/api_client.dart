import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/app_env.dart';

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
    if (_storage != null) {
      _installTokenRefreshInterceptor();
    }
  }

  final Dio dio;
  final FlutterSecureStorage? _storage;
  Future<String?>? _refreshFuture;

  static const _accessKey = 'access_token';
  static const _refreshKey = 'refresh_token';
  static const _skipAuthRefreshKey = 'skip_auth_refresh';

  void setAccessToken(String? token) {
    if (token == null || token.isEmpty) {
      dio.options.headers.remove('Authorization');
      return;
    }
    dio.options.headers['Authorization'] = 'Bearer $token';
  }

  void _installTokenRefreshInterceptor() {
    dio.interceptors.add(
      InterceptorsWrapper(
        onError: (error, handler) async {
          if (!_shouldAttemptRefresh(error)) {
            handler.next(error);
            return;
          }

          final freshAccessToken = await _refreshAccessToken();
          if (freshAccessToken == null || freshAccessToken.isEmpty) {
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
              ..[_skipAuthRefreshKey] = true,
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

  bool _shouldAttemptRefresh(DioException error) {
    final statusCode = error.response?.statusCode;
    if (statusCode != 401) {
      return false;
    }

    final request = error.requestOptions;
    if (request.extra[_skipAuthRefreshKey] == true) {
      return false;
    }

    final path = request.path;
    if (path.endsWith('/auth/login') ||
        path.endsWith('/auth/reactivate-login') ||
        path.endsWith('/auth/register') ||
        path.endsWith('/auth/refresh-token')) {
      return false;
    }

    final authHeader =
        request.headers['Authorization'] ??
        dio.options.headers['Authorization'];
    return authHeader is String && authHeader.trim().isNotEmpty;
  }

  Future<String?> _refreshAccessToken() {
    final inFlight = _refreshFuture;
    if (inFlight != null) {
      return inFlight;
    }

    final future = _performTokenRefresh();
    _refreshFuture = future;
    return future.whenComplete(() {
      _refreshFuture = null;
    });
  }

  Future<String?> _performTokenRefresh() async {
    final storage = _storage;
    if (storage == null) {
      return null;
    }

    final refreshToken = await storage.read(key: _refreshKey);
    if (refreshToken == null || refreshToken.isEmpty) {
      return null;
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
      if (accessToken.isEmpty) {
        return null;
      }

      await storage.write(key: _accessKey, value: accessToken);
      await storage.write(key: _refreshKey, value: nextRefreshToken);
      setAccessToken(accessToken);
      return accessToken;
    } on DioException catch (error) {
      final statusCode = error.response?.statusCode;
      if (statusCode == 400 || statusCode == 401 || statusCode == 403) {
        setAccessToken(null);
        await storage.delete(key: _accessKey);
        await storage.delete(key: _refreshKey);
      }
      return null;
    }
  }

  dynamic _cloneRetryBody(dynamic data) {
    if (data is FormData) {
      return data.clone();
    }
    return data;
  }
}
