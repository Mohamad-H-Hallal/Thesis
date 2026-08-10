import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/features/imports/data/api_imports_repository.dart';

void main() {
  group('ApiImportsRepository', () {
    test('rejects staged features from another import', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: const <String, dynamic>{
                  'success': true,
                  'data': <String, dynamic>{
                    'staged_features': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'staged-1',
                        'import_job_id': 'import-2',
                      },
                    ],
                    'approved_project_features': <dynamic>[],
                  },
                },
              ),
            );
          },
        ),
      );
      final repository = ApiImportsRepository(ApiClient(dio: dio));

      await expectLater(
        repository.fetchImportMapData(
          importId: 'import-1',
          projectId: 'project-1',
          minLon: 35.49,
          minLat: 33.89,
          maxLon: 35.51,
          maxLat: 33.91,
          zoom: 15,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects project context features from another project', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: const <String, dynamic>{
                  'success': true,
                  'data': <String, dynamic>{
                    'staged_features': <dynamic>[],
                    'approved_project_features': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'feature-1',
                        'project_id': 'project-2',
                        'status': 'approved',
                        'geometry': <String, dynamic>{
                          'type': 'Point',
                          'coordinates': <double>[35.5, 33.9],
                        },
                      },
                    ],
                  },
                },
              ),
            );
          },
        ),
      );
      final repository = ApiImportsRepository(ApiClient(dio: dio));

      await expectLater(
        repository.fetchImportMapData(
          importId: 'import-1',
          projectId: 'project-1',
          minLon: 35.49,
          minLat: 33.89,
          maxLon: 35.51,
          maxLat: 33.91,
          zoom: 15,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('tile cache is isolated by authenticated session', () async {
      var requestCount = 0;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requestCount += 1;
            final authorization =
                options.headers['Authorization']?.toString() ?? '';
            final featureSuffix = authorization.contains('token-b')
                ? 'b'
                : authorization.contains('token-a2')
                ? 'a2'
                : 'a1';
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'success': true,
                  'data': <String, dynamic>{
                    'staged_features': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'staged-$featureSuffix',
                        'import_job_id': 'import-1',
                      },
                    ],
                    'approved_project_features': const <dynamic>[],
                  },
                },
              ),
            );
          },
        ),
      );
      final apiClient = ApiClient(dio: dio);
      final repository = ApiImportsRepository(apiClient);

      Future<String> fetchFeatureId() async {
        final result = await repository.fetchImportMapData(
          importId: 'import-1',
          projectId: 'project-1',
          minLon: 35.49,
          minLat: 33.89,
          maxLon: 35.51,
          maxLat: 33.91,
          zoom: 15,
        );
        return result.stagedFeatures.single.id;
      }

      await apiClient.establishAuthenticatedSession(
        accessToken: 'token-a1',
        refreshToken: 'refresh-a1',
        ownerUserId: 'owner-a',
      );
      expect(await fetchFeatureId(), 'staged-a1');
      final requestsPerViewport = requestCount;
      expect(requestsPerViewport, greaterThan(0));

      expect(await fetchFeatureId(), 'staged-a1');
      expect(requestCount, requestsPerViewport);

      await apiClient.establishAuthenticatedSession(
        accessToken: 'token-a2',
        refreshToken: 'refresh-a2',
        ownerUserId: 'owner-a',
      );
      expect(await fetchFeatureId(), 'staged-a2');
      expect(requestCount, requestsPerViewport * 2);

      await apiClient.establishAuthenticatedSession(
        accessToken: 'token-b',
        refreshToken: 'refresh-b',
        ownerUserId: 'owner-b',
      );
      expect(await fetchFeatureId(), 'staged-b');
      expect(requestCount, requestsPerViewport * 3);
    });
  });
}
