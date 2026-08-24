import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/config/app_env.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';

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
    } else {
      _values[key] = value;
    }
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
  }) async => _values[key];

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

enum _RefreshMode {
  success,
  deletedAccount,
  inactiveAccount,
  invalidRefreshToken,
  unstructuredForbidden,
  rateLimited,
  serverFailure,
  timeout,
}

class _RefreshAdapter implements HttpClientAdapter {
  _RefreshAdapter({this.refreshMode = _RefreshMode.success});

  final _RefreshMode refreshMode;
  int featureAttempts = 0;
  int refreshAttempts = 0;
  final List<Map<String, dynamic>> featureHeaders = <Map<String, dynamic>>[];
  final List<List<int>> featureBodies = <List<int>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final requestBytes = BytesBuilder(copy: false);
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        requestBytes.add(chunk);
      }
    }
    const responseHeaders = <String, List<String>>{
      Headers.contentTypeHeader: <String>['application/json'],
    };
    if (options.path == '${AppEnv.apiVersionPrefix}/auth/refresh-token') {
      refreshAttempts += 1;
      if (refreshMode == _RefreshMode.inactiveAccount) {
        return ResponseBody.fromString(
          jsonEncode(const <String, dynamic>{
            'message': 'Account is inactive.',
            'error': <String, dynamic>{
              'code': 'OFFLINE_SYNC_ACCOUNT_INACTIVE',
              'disposition': 'permanent_rejection',
              'retryable': false,
            },
          }),
          403,
          headers: responseHeaders,
        );
      }
      if (refreshMode == _RefreshMode.unstructuredForbidden) {
        return ResponseBody.fromString(
          jsonEncode(const <String, dynamic>{'message': 'Refresh forbidden'}),
          403,
          headers: responseHeaders,
        );
      }
      if (refreshMode == _RefreshMode.invalidRefreshToken) {
        return ResponseBody.fromString(
          jsonEncode(const <String, dynamic>{'message': 'Refresh expired'}),
          401,
          headers: responseHeaders,
        );
      }
      if (refreshMode == _RefreshMode.rateLimited) {
        return ResponseBody.fromString(
          jsonEncode(const <String, dynamic>{'message': 'Retry later'}),
          429,
          headers: const <String, List<String>>{
            Headers.contentTypeHeader: <String>['application/json'],
            'retry-after': <String>['75'],
          },
        );
      }
      if (refreshMode == _RefreshMode.serverFailure) {
        return ResponseBody.fromString(
          jsonEncode(const <String, dynamic>{'message': 'Unavailable'}),
          503,
          headers: responseHeaders,
        );
      }
      if (refreshMode == _RefreshMode.timeout) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionTimeout,
        );
      }
      return ResponseBody.fromString(
        jsonEncode(const <String, dynamic>{
          'data': <String, dynamic>{
            'token': 'fresh-access',
            'refreshToken': 'fresh-refresh',
          },
        }),
        200,
        headers: responseHeaders,
      );
    }
    if (options.path == '${AppEnv.apiVersionPrefix}/features/offline-sync' ||
        options.path == '${AppEnv.apiVersionPrefix}/features') {
      featureAttempts += 1;
      featureHeaders.add(Map<String, dynamic>.from(options.headers));
      featureBodies.add(requestBytes.takeBytes());
      if (refreshMode == _RefreshMode.deletedAccount) {
        return ResponseBody.fromString(
          jsonEncode(const <String, dynamic>{
            'message': 'Account was deleted.',
            'error': <String, dynamic>{
              'code': 'ACCOUNT_DELETED',
              'disposition': 'permanent_rejection',
              'retryable': false,
            },
          }),
          401,
          headers: responseHeaders,
        );
      }
      final expired =
          options.headers['Authorization'] == 'Bearer expired-access';
      return ResponseBody.fromString(
        jsonEncode(
          expired
              ? const <String, dynamic>{'message': 'Token expired'}
              : const <String, dynamic>{'success': true},
        ),
        expired ? 401 : 201,
        headers: responseHeaders,
      );
    }
    return ResponseBody.fromString(
      jsonEncode(const <String, dynamic>{'message': 'Not found'}),
      404,
      headers: responseHeaders,
    );
  }

  @override
  void close({bool force = false}) {}
}

class _DelayedRefreshAdapter implements HttpClientAdapter {
  final Completer<void> refreshStarted = Completer<void>();
  final Completer<void> releaseRefresh = Completer<void>();
  int refreshAttempts = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) {
      await requestStream.drain<void>();
    }
    const headers = <String, List<String>>{
      Headers.contentTypeHeader: <String>['application/json'],
    };
    if (options.path == '${AppEnv.apiVersionPrefix}/auth/refresh-token') {
      refreshAttempts += 1;
      if (!refreshStarted.isCompleted) {
        refreshStarted.complete();
      }
      await releaseRefresh.future;
      return ResponseBody.fromString(
        jsonEncode(const <String, dynamic>{
          'data': <String, dynamic>{
            'token': 'late-a-access',
            'refreshToken': 'late-a-refresh',
          },
        }),
        200,
        headers: headers,
      );
    }
    return ResponseBody.fromString(
      jsonEncode(const <String, dynamic>{'message': 'Token expired'}),
      401,
      headers: headers,
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'expired token retries the actual multipart offline bundle intact',
    () async {
      final storage = _MemorySecureStorage();
      await storage.write(key: 'refresh_token', value: 'valid-refresh');
      final adapter = _RefreshAdapter();
      final dio = Dio(
        BaseOptions(
          headers: const <String, dynamic>{'Content-Type': 'application/json'},
        ),
      )..httpClientAdapter = adapter;
      final client = ApiClient(dio: dio, storage: storage);
      await client.establishAuthenticatedSession(
        accessToken: 'expired-access',
        refreshToken: 'valid-refresh',
        ownerUserId: 'user-1',
      );

      await client.dio.post<Map<String, dynamic>>(
        '${AppEnv.apiVersionPrefix}/features/offline-sync',
        data: FormData.fromMap(<String, dynamic>{
          'payload': jsonEncode(const <String, dynamic>{
            'draft_id': 'draft-1',
            'offline_owner_user_id': 'user-1',
            'project_id': 'project-1',
            'operation': 'create',
            'geom': <String, dynamic>{
              'type': 'Point',
              'coordinates': <double>[35.5, 33.9],
            },
            'attributes': <String, dynamic>{'tree_type': 'olive'},
            'accuracy_meters': null,
            'submit_for_review': true,
          }),
          'photos': <MultipartFile>[
            MultipartFile.fromBytes(
              utf8.encode('offline-photo-bytes'),
              filename: 'photo.jpg',
            ),
          ],
        }),
        options: Options(
          headers: const <String, dynamic>{
            'Idempotency-Key': 'idem-1',
            'X-Offline-Owner-Id': 'user-1',
            'X-Offline-Project-Id': 'project-1',
            'Authorization': 'Bearer expired-access',
          },
        ),
      );

      expect(adapter.refreshAttempts, 1);
      expect(adapter.featureAttempts, 2);
      expect(
        adapter.featureHeaders.last['Authorization'],
        'Bearer fresh-access',
      );
      expect(adapter.featureHeaders.last['Idempotency-Key'], 'idem-1');
      expect(adapter.featureHeaders.last['X-Offline-Owner-Id'], 'user-1');
      expect(adapter.featureHeaders.last['X-Offline-Project-Id'], 'project-1');
      for (var index = 0; index < adapter.featureBodies.length; index += 1) {
        final body = latin1.decode(adapter.featureBodies[index]);
        expect(body, contains('name="payload"'));
        expect(body, contains('"draft_id":"draft-1"'));
        expect(body, contains('filename="photo.jpg"'));
        expect(body, contains('offline-photo-bytes'));
        final contentType = adapter.featureHeaders[index].entries
            .firstWhere(
              (entry) => entry.key.toLowerCase() == Headers.contentTypeHeader,
            )
            .value
            .toString();
        expect(contentType, contains('multipart/form-data'));
      }
      expect(dio.options.headers['Authorization'], 'Bearer fresh-access');
      expect(await storage.read(key: 'refresh_token'), 'fresh-refresh');
    },
  );

  test(
    'exact inactive-account refresh rejection is propagated to offline sync',
    () async {
      final storage = _MemorySecureStorage();
      await storage.write(key: 'refresh_token', value: 'valid-refresh');
      final adapter = _RefreshAdapter(
        refreshMode: _RefreshMode.inactiveAccount,
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final client = ApiClient(dio: dio, storage: storage);
      await client.establishAuthenticatedSession(
        accessToken: 'expired-access',
        refreshToken: 'valid-refresh',
        ownerUserId: 'user-1',
      );

      DioException? rejection;
      try {
        await client.dio.post<Map<String, dynamic>>(
          '${AppEnv.apiVersionPrefix}/features/offline-sync',
          data: FormData.fromMap(<String, dynamic>{
            'payload': jsonEncode(const <String, dynamic>{
              'draft_id': 'draft-1',
            }),
          }),
        );
      } on DioException catch (error) {
        rejection = error;
      }

      expect(rejection, isNotNull);
      expect(
        rejection!.requestOptions.path,
        '${AppEnv.apiVersionPrefix}/features/offline-sync',
      );
      expect(rejection.response?.statusCode, 403);
      final responseData = rejection.response?.data as Map<String, dynamic>;
      expect(
        (responseData['error'] as Map<String, dynamic>)['code'],
        'OFFLINE_SYNC_ACCOUNT_INACTIVE',
      );
      expect(adapter.featureAttempts, 1);
      expect(adapter.refreshAttempts, 1);
      expect(await storage.read(key: 'refresh_token'), isNull);
    },
  );

  test(
    'deleted-account response clears only the bound session and runs cleanup once',
    () async {
      final storage = _MemorySecureStorage();
      final adapter = _RefreshAdapter(refreshMode: _RefreshMode.deletedAccount);
      final dio = Dio()..httpClientAdapter = adapter;
      final client = ApiClient(dio: dio, storage: storage);
      final cleanedOwners = <String>[];
      client.onAccountDeleted = (owner) async => cleanedOwners.add(owner);
      await client.establishAuthenticatedSession(
        accessToken: 'deleted-access',
        refreshToken: 'deleted-refresh',
        ownerUserId: 'deleted-owner',
        persistTokens: true,
      );

      for (var attempt = 0; attempt < 2; attempt += 1) {
        await expectLater(
          client.dio.get<Map<String, dynamic>>(
            '${AppEnv.apiVersionPrefix}/features',
          ),
          throwsA(isA<DioException>()),
        );
      }

      expect(cleanedOwners, <String>['deleted-owner']);
      expect(client.currentSessionBinding, isNull);
      expect(await storage.read(key: 'access_token'), isNull);
      expect(await storage.read(key: 'refresh_token'), isNull);
      expect(adapter.refreshAttempts, 0);
    },
  );

  for (final testCase in <(_RefreshMode, String)>[
    (_RefreshMode.invalidRefreshToken, 'expired refresh token'),
    (_RefreshMode.unstructuredForbidden, 'unstructured refresh rejection'),
  ]) {
    test('${testCase.$2} preserves the original offline 401', () async {
      final storage = _MemorySecureStorage();
      await storage.write(key: 'refresh_token', value: 'valid-refresh');
      final adapter = _RefreshAdapter(refreshMode: testCase.$1);
      final dio = Dio()..httpClientAdapter = adapter;
      final client = ApiClient(dio: dio, storage: storage);
      await client.establishAuthenticatedSession(
        accessToken: 'expired-access',
        refreshToken: 'valid-refresh',
        ownerUserId: 'user-1',
      );

      DioException? rejection;
      try {
        await client.dio.post<Map<String, dynamic>>(
          '${AppEnv.apiVersionPrefix}/features/offline-sync',
          data: FormData.fromMap(<String, dynamic>{
            'payload': jsonEncode(const <String, dynamic>{
              'draft_id': 'draft-1',
            }),
          }),
        );
      } on DioException catch (error) {
        rejection = error;
      }

      expect(rejection, isNotNull);
      expect(rejection!.response?.statusCode, 401);
      expect(rejection.response?.data, <String, dynamic>{
        'message': 'Token expired',
      });
      expect(adapter.featureAttempts, 1);
      expect(adapter.refreshAttempts, 1);
    });
  }

  for (final testCase in <(_RefreshMode, int?, DioExceptionType, String)>[
    (
      _RefreshMode.rateLimited,
      429,
      DioExceptionType.badResponse,
      'refresh rate limit',
    ),
    (
      _RefreshMode.serverFailure,
      503,
      DioExceptionType.badResponse,
      'refresh server failure',
    ),
    (
      _RefreshMode.timeout,
      null,
      DioExceptionType.connectionTimeout,
      'refresh timeout',
    ),
  ]) {
    test('${testCase.$4} remains a retryable offline error', () async {
      final storage = _MemorySecureStorage();
      final adapter = _RefreshAdapter(refreshMode: testCase.$1);
      final dio = Dio()..httpClientAdapter = adapter;
      final client = ApiClient(dio: dio, storage: storage);
      await client.establishAuthenticatedSession(
        accessToken: 'expired-access',
        refreshToken: 'valid-refresh',
        ownerUserId: 'user-1',
      );

      DioException? rejection;
      try {
        await client.dio.post<Map<String, dynamic>>(
          '${AppEnv.apiVersionPrefix}/features/offline-sync',
          data: FormData.fromMap(<String, dynamic>{
            'payload': jsonEncode(const <String, dynamic>{
              'draft_id': 'draft-1',
            }),
          }),
        );
      } on DioException catch (error) {
        rejection = error;
      }

      expect(rejection, isNotNull);
      expect(rejection!.response?.statusCode, testCase.$2);
      expect(rejection.type, testCase.$3);
      if (testCase.$1 == _RefreshMode.rateLimited) {
        expect(rejection.response?.headers.value('retry-after'), '75');
      }
      expect(adapter.featureAttempts, 1);
      expect(adapter.refreshAttempts, 1);
    });
  }

  test(
    'inactive-account refresh rejection is not substituted for normal APIs',
    () async {
      final storage = _MemorySecureStorage();
      await storage.write(key: 'refresh_token', value: 'valid-refresh');
      final adapter = _RefreshAdapter(
        refreshMode: _RefreshMode.inactiveAccount,
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final client = ApiClient(dio: dio, storage: storage);
      await client.establishAuthenticatedSession(
        accessToken: 'expired-access',
        refreshToken: 'valid-refresh',
        ownerUserId: 'user-1',
      );

      DioException? rejection;
      try {
        await client.dio.get<Map<String, dynamic>>(
          '${AppEnv.apiVersionPrefix}/features',
        );
      } on DioException catch (error) {
        rejection = error;
      }

      expect(rejection, isNotNull);
      expect(rejection!.response?.statusCode, 401);
      expect(adapter.featureAttempts, 1);
      expect(adapter.refreshAttempts, 1);
    },
  );

  test(
    'late Account A refresh cannot overwrite or retry under Account B',
    () async {
      final storage = _MemorySecureStorage();
      final adapter = _DelayedRefreshAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final client = ApiClient(dio: dio, storage: storage);
      await client.establishAuthenticatedSession(
        accessToken: 'expired-a-access',
        refreshToken: 'a-refresh',
        ownerUserId: 'account-a',
        persistTokens: true,
      );
      final accountABinding = client.captureSessionForOwner('account-a')!;
      final staleRequest = client.dio.post<Map<String, dynamic>>(
        '${AppEnv.apiVersionPrefix}/features/offline-sync',
        data: FormData.fromMap(<String, dynamic>{
          'payload': jsonEncode(const <String, dynamic>{'draft_id': 'draft-a'}),
        }),
        options: client.bindAuthenticatedRequest(session: accountABinding),
      );
      final staleExpectation = expectLater(
        staleRequest,
        throwsA(isA<DioException>()),
      );

      await adapter.refreshStarted.future;
      final logout = client.invalidateAuthenticatedSession();
      expect(client.currentSessionBinding, isNull);
      final loginB = client.establishAuthenticatedSession(
        accessToken: 'b-access',
        refreshToken: 'b-refresh',
        ownerUserId: 'account-b',
        persistTokens: true,
      );

      adapter.releaseRefresh.complete();
      await logout;
      await loginB;
      await staleExpectation;

      expect(adapter.refreshAttempts, 1);
      expect(client.captureSessionForOwner('account-a'), isNull);
      expect(
        client.captureSessionForOwner('account-b')?.accessToken,
        'b-access',
      );
      expect(dio.options.headers['Authorization'], 'Bearer b-access');
      expect(await storage.read(key: 'access_token'), 'b-access');
      expect(await storage.read(key: 'refresh_token'), 'b-refresh');
    },
  );

  test(
    'security-event rotation updates memory and remembered credentials',
    () async {
      final storage = _MemorySecureStorage();
      final client = ApiClient(dio: Dio(), storage: storage);
      await client.establishAuthenticatedSession(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
        ownerUserId: 'user-1',
        persistTokens: true,
      );

      await client.replaceCurrentSessionTokens(
        accessToken: 'rotated-access',
        refreshToken: 'rotated-refresh',
      );

      expect(client.currentSessionBinding?.accessToken, 'rotated-access');
      expect(client.currentSessionBinding?.refreshToken, 'rotated-refresh');
      expect(
        client.dio.options.headers['Authorization'],
        'Bearer rotated-access',
      );
      expect(await storage.read(key: 'access_token'), 'rotated-access');
      expect(await storage.read(key: 'refresh_token'), 'rotated-refresh');
    },
  );

  test(
    'security-event rotation does not persist a memory-only session',
    () async {
      final storage = _MemorySecureStorage();
      final client = ApiClient(dio: Dio(), storage: storage);
      await client.establishAuthenticatedSession(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
        ownerUserId: 'user-1',
        persistTokens: false,
      );

      await client.replaceCurrentSessionTokens(
        accessToken: 'rotated-access',
        refreshToken: 'rotated-refresh',
      );

      expect(client.currentSessionBinding?.accessToken, 'rotated-access');
      expect(await storage.read(key: 'access_token'), isNull);
      expect(await storage.read(key: 'refresh_token'), isNull);
    },
  );
}
