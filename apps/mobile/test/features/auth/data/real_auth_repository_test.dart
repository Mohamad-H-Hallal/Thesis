import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/config/app_env.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/features/auth/data/real_auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';

class _MemorySecureStorage extends FlutterSecureStorage {
  _MemorySecureStorage();

  final Map<String, String> _values = <String, String>{};

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _values.remove(key);
      return;
    }
    _values[key] = value;
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _values[key];
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _values.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> seedStoredSession(
    _MemorySecureStorage storage, {
    required String accessToken,
    required String refreshToken,
  }) async {
    await storage.write(key: 'access_token', value: accessToken);
    await storage.write(key: 'refresh_token', value: refreshToken);
    await storage.write(key: 'user_id', value: 'contributor-1');
    await storage.write(key: 'user_name', value: 'Field Collector');
    await storage.write(key: 'user_email', value: 'collector@example.com');
    await storage.write(key: 'user_phone', value: '70123456');
    await storage.write(key: 'user_role', value: 'contributor');
    await storage.write(key: 'is_protected_super_admin', value: 'false');
  }

  test('restoreSession refreshes expired remembered access tokens', () async {
    final storage = _MemorySecureStorage();
    await seedStoredSession(
      storage,
      accessToken: 'expired-access',
      refreshToken: 'valid-refresh',
    );

    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '${AppEnv.apiVersionPrefix}/auth/me') {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 401,
                  data: const <String, dynamic>{'message': 'Token expired'},
                ),
                type: DioExceptionType.badResponse,
              ),
            );
            return;
          }

          if (options.path == '${AppEnv.apiVersionPrefix}/auth/refresh-token') {
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: const <String, dynamic>{
                  'data': <String, dynamic>{
                    'token': 'fresh-access',
                    'refreshToken': 'fresh-refresh',
                    'user': <String, dynamic>{
                      'id': 'contributor-1',
                      'full_name': 'Field Collector',
                      'email': 'collector@example.com',
                      'phone': '70123456',
                      'role': 'contributor',
                    },
                  },
                },
              ),
            );
            return;
          }

          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 404,
              ),
            ),
          );
        },
      ),
    );

    final repository = RealAuthRepository(storage, ApiClient(dio: dio));

    final session = await repository.restoreSession();

    expect(session, isNotNull);
    expect(session!.accessToken, 'fresh-access');
    expect(session.refreshToken, 'fresh-refresh');
    expect(session.user.role, UserRole.contributor);
    expect(await storage.read(key: 'access_token'), 'fresh-access');
    expect(await storage.read(key: 'refresh_token'), 'fresh-refresh');
  });

  test(
    'restoreSession falls back to stored user during offline bootstrap',
    () async {
      final storage = _MemorySecureStorage();
      await seedStoredSession(
        storage,
        accessToken: 'remembered-access',
        refreshToken: 'remembered-refresh',
      );

      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                error: Exception('offline'),
              ),
            );
          },
        ),
      );

      final repository = RealAuthRepository(storage, ApiClient(dio: dio));

      final session = await repository.restoreSession();

      expect(session, isNotNull);
      expect(session!.accessToken, 'remembered-access');
      expect(session.refreshToken, 'remembered-refresh');
      expect(session.user.id, 'contributor-1');
    },
  );
}
