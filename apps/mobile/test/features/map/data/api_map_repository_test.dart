import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/config/app_env.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/features/map/data/api_map_repository.dart';

void main() {
  group('ApiMapRepository', () {
    test('fetchProjectFeatures walks every project feature page', () async {
      final requestedPages = <int>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.endsWith('/projects/project-1/features')) {
              final page =
                  (options.queryParameters['page'] as num?)?.toInt() ?? 1;
              requestedPages.add(page);
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'success': true,
                    'data': page == 1
                        ? <Map<String, dynamic>>[
                            _featureRow('feature-1'),
                            _featureRow('feature-2'),
                          ]
                        : <Map<String, dynamic>>[_featureRow('feature-3')],
                    'pagination': <String, dynamic>{
                      'page': page,
                      'limit': 100,
                      'total': 101,
                      'has_more': page == 1,
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
                response: Response<dynamic>(
                  requestOptions: options,
                  statusCode: 404,
                  data: const <String, dynamic>{
                    'message': 'Unhandled test request',
                  },
                ),
              ),
            );
          },
        ),
      );

      final repository = ApiMapRepository(ApiClient(dio: dio));

      final features = await repository.fetchProjectFeatures('project-1');

      expect(features.map((feature) => feature.id), <String>[
        'feature-1',
        'feature-2',
        'feature-3',
      ]);
      expect(requestedPages, <int>[1, 2]);
    });

    test(
      'fetchProjectFeaturesViewport sends camera zoom to tile API',
      () async {
        final requestedZooms = <Object?>[];
        final requestedFeatureTypes = <Object?>[];
        final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.contains('/features/tiles/')) {
                requestedZooms.add(options.queryParameters['zoom']);
                requestedFeatureTypes.add(
                  options.queryParameters['feature_type'],
                );
                handler.resolve(
                  Response<Map<String, dynamic>>(
                    requestOptions: options,
                    statusCode: 200,
                    data: const <String, dynamic>{
                      'success': true,
                      'data': <String, dynamic>{
                        'type': 'FeatureCollection',
                        'features': <dynamic>[],
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
                  response: Response<dynamic>(
                    requestOptions: options,
                    statusCode: 404,
                    data: const <String, dynamic>{
                      'message': 'Unhandled test request',
                    },
                  ),
                ),
              );
            },
          ),
        );

        final repository = ApiMapRepository(ApiClient(dio: dio));

        await repository.fetchProjectFeaturesViewport(
          projectId: 'project-1',
          minLon: 35.094,
          minLat: 33.045,
          maxLon: 36.645,
          maxLat: 34.695,
          zoom: 10.25,
          featureType: 'Vineyards',
        );

        expect(requestedZooms, isNotEmpty);
        expect(requestedZooms.toSet(), <String>{'10.25'});
        expect(requestedFeatureTypes, isNotEmpty);
        expect(requestedFeatureTypes.toSet(), <String>{'Vineyards'});
      },
    );

    for (final testCase in <({String name, Map<String, dynamic> row})>[
      (
        name: 'missing project id',
        row: _featureRow('feature-missing-project', includeProjectId: false),
      ),
      (
        name: 'mismatched project id',
        row: _featureRow('feature-other-project', projectId: 'project-2'),
      ),
    ]) {
      test('fetchProjectFeaturesPage rejects ${testCase.name}', () async {
        final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'success': true,
                    'data': <Map<String, dynamic>>[testCase.row],
                    'pagination': const <String, dynamic>{
                      'page': 1,
                      'limit': 20,
                      'total': 1,
                      'has_more': false,
                    },
                  },
                ),
              );
            },
          ),
        );
        final repository = ApiMapRepository(ApiClient(dio: dio));

        await expectLater(
          repository.fetchProjectFeaturesPage(projectId: 'project-1'),
          throwsA(isA<StateError>()),
        );
      });
    }

    for (final testCase in <({String name, Map<String, dynamic> row})>[
      (
        name: 'missing project id',
        row: _featureRow('feature-missing-project', includeProjectId: false),
      ),
      (
        name: 'mismatched project id',
        row: _featureRow('feature-other-project', projectId: 'project-2'),
      ),
    ]) {
      test('fetchProjectFeatureById rejects ${testCase.name}', () async {
        final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'success': true,
                    'data': testCase.row,
                  },
                ),
              );
            },
          ),
        );
        final repository = ApiMapRepository(ApiClient(dio: dio));

        await expectLater(
          repository.fetchProjectFeatureById(
            projectId: 'project-1',
            featureId: 'feature-1',
          ),
          throwsA(isA<StateError>()),
        );
      });
    }

    for (final testCase in <({String name, Map<String, dynamic> properties})>[
      (
        name: 'missing project id',
        properties: const <String, dynamic>{'status': 'approved'},
      ),
      (
        name: 'non-string project id',
        properties: const <String, dynamic>{
          'project_id': 1,
          'status': 'approved',
        },
      ),
      (
        name: 'mismatched project id',
        properties: const <String, dynamic>{
          'project_id': 'project-2',
          'status': 'approved',
        },
      ),
    ]) {
      test('fetchProjectFeatureTile rejects ${testCase.name}', () async {
        final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'success': true,
                    'data': <String, dynamic>{
                      'type': 'FeatureCollection',
                      'features': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'id': 'feature-1',
                          'geometry': const <String, dynamic>{
                            'type': 'Point',
                            'coordinates': <double>[35.5, 33.9],
                          },
                          'properties': testCase.properties,
                        },
                      ],
                    },
                  },
                ),
              );
            },
          ),
        );
        final repository = ApiMapRepository(ApiClient(dio: dio));

        await expectLater(
          repository.fetchProjectFeatureTile(
            projectId: 'project-1',
            z: 10,
            x: 613,
            y: 410,
            renderZoom: 10,
          ),
          throwsA(isA<StateError>()),
        );
      });
    }

    test('legacy photo without a thumbnail falls back to full media', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'success': true,
                  'data': <Map<String, dynamic>>[
                    <String, dynamic>{
                      ..._featureRow('feature-with-legacy-photo'),
                      'photos': const <Map<String, dynamic>>[
                        <String, dynamic>{
                          'id': 'legacy-photo-id',
                          'thumbnail_path': null,
                        },
                      ],
                    },
                  ],
                  'pagination': const <String, dynamic>{
                    'page': 1,
                    'limit': 20,
                    'total': 1,
                    'has_more': false,
                  },
                },
              ),
            );
          },
        ),
      );
      final repository = ApiMapRepository(ApiClient(dio: dio));

      final page = await repository.fetchProjectFeaturesPage(
        projectId: 'project-1',
      );
      final photo = page.items.single.photos.single;

      expect(photo.thumbnailPath, isNull);
      expect(
        photo.filePath,
        '${AppEnv.apiVersionPrefix}/photos/legacy-photo-id',
      );
    });

    test(
      'tile cache is isolated by authenticated owner and session generation',
      () async {
        var requestCount = 0;
        final requestTokens = <String>[];
        final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requestCount += 1;
              final authorization =
                  options.headers['Authorization']?.toString() ?? '';
              requestTokens.add(authorization);
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
                      'type': 'FeatureCollection',
                      'features': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'id': 'feature-$featureSuffix',
                          'geometry': const <String, dynamic>{
                            'type': 'Point',
                            'coordinates': <double>[35.5, 33.9],
                          },
                          'properties': const <String, dynamic>{
                            'project_id': 'project-1',
                            'status': 'approved',
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
        final apiClient = ApiClient(dio: dio);
        final repository = ApiMapRepository(apiClient);

        await apiClient.establishAuthenticatedSession(
          accessToken: 'token-a1',
          refreshToken: 'refresh-a1',
          ownerUserId: 'owner-a',
        );
        final first = await repository.fetchProjectFeatureTile(
          projectId: 'project-1',
          z: 10,
          x: 613,
          y: 410,
          renderZoom: 10,
        );
        final cached = await repository.fetchProjectFeatureTile(
          projectId: 'project-1',
          z: 10,
          x: 613,
          y: 410,
          renderZoom: 10,
        );

        await apiClient.establishAuthenticatedSession(
          accessToken: 'token-a2',
          refreshToken: 'refresh-a2',
          ownerUserId: 'owner-a',
        );
        final newGeneration = await repository.fetchProjectFeatureTile(
          projectId: 'project-1',
          z: 10,
          x: 613,
          y: 410,
          renderZoom: 10,
        );

        await apiClient.establishAuthenticatedSession(
          accessToken: 'token-b',
          refreshToken: 'refresh-b',
          ownerUserId: 'owner-b',
        );
        final newOwner = await repository.fetchProjectFeatureTile(
          projectId: 'project-1',
          z: 10,
          x: 613,
          y: 410,
          renderZoom: 10,
        );

        expect(first.single.id, 'feature-a1');
        expect(cached.single.id, 'feature-a1');
        expect(newGeneration.single.id, 'feature-a2');
        expect(newOwner.single.id, 'feature-b');
        expect(requestCount, 3);
        expect(requestTokens, <String>[
          'Bearer token-a1',
          'Bearer token-a2',
          'Bearer token-b',
        ]);
      },
    );

    for (final operation in <String>['list', 'count', 'detail']) {
      test(
        'late $operation response is rejected after the authenticated session changes',
        () async {
          final requestStarted = Completer<void>();
          final releaseResponse = Completer<void>();
          final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
          dio.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) async {
                if (!requestStarted.isCompleted) {
                  requestStarted.complete();
                }
                await releaseResponse.future;
                handler.resolve(
                  Response<Map<String, dynamic>>(
                    requestOptions: options,
                    statusCode: 200,
                    data: operation == 'detail'
                        ? <String, dynamic>{
                            'success': true,
                            'data': _featureRow('late-feature'),
                          }
                        : <String, dynamic>{
                            'success': true,
                            'data': <Map<String, dynamic>>[
                              _featureRow('late-feature'),
                            ],
                            'pagination': const <String, dynamic>{
                              'page': 1,
                              'limit': 100,
                              'total': 1,
                              'has_more': false,
                            },
                          },
                  ),
                );
              },
            ),
          );
          final apiClient = ApiClient(dio: dio);
          final repository = ApiMapRepository(apiClient);
          await apiClient.establishAuthenticatedSession(
            accessToken: 'token-a',
            refreshToken: 'refresh-a',
            ownerUserId: 'owner-a',
          );

          late final Future<dynamic> pendingRequest;
          switch (operation) {
            case 'list':
              pendingRequest = repository.fetchProjectFeatures('project-1');
              break;
            case 'count':
              pendingRequest = repository.fetchProjectFeaturesCount(
                projectId: 'project-1',
              );
              break;
            case 'detail':
              pendingRequest = repository.fetchProjectFeatureById(
                projectId: 'project-1',
                featureId: 'late-feature',
              );
              break;
            default:
              throw StateError(
                'Unsupported map repository operation: $operation',
              );
          }

          await requestStarted.future;
          await apiClient.establishAuthenticatedSession(
            accessToken: 'token-b',
            refreshToken: 'refresh-b',
            ownerUserId: 'owner-b',
          );
          releaseResponse.complete();

          await expectLater(pendingRequest, throwsA(isA<StateError>()));
        },
      );
    }
  });
}

Map<String, dynamic> _featureRow(
  String id, {
  String projectId = 'project-1',
  bool includeProjectId = true,
}) {
  return <String, dynamic>{
    'id': id,
    if (includeProjectId) 'project_id': projectId,
    'status': 'approved',
    'geometry': const <String, dynamic>{
      'type': 'Point',
      'coordinates': <double>[35.5, 33.9],
    },
    'attributes': const <String, dynamic>{'tree_type': 'Olive'},
    'collected_by': 'Rana',
    'photo_count': 0,
    'photos': const <dynamic>[],
    'is_summary': false,
  };
}
