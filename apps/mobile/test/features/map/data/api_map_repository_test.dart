import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
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
        final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.contains('/features/tiles/')) {
                requestedZooms.add(options.queryParameters['zoom']);
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
        );

        expect(requestedZooms, isNotEmpty);
        expect(requestedZooms.toSet(), <String>{'10.25'});
      },
    );
  });
}

Map<String, dynamic> _featureRow(String id) {
  return <String, dynamic>{
    'id': id,
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
