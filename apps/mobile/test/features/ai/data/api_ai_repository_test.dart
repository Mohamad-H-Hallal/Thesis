import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/features/ai/data/api_ai_repository.dart';

void main() {
  group('ApiAiRepository', () {
    test('fetchLayerFeatures loads database-backed AI predictions', () async {
      final requestedPaths = <String>[];
      final requestedClassFilters = <Object?>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requestedPaths.add(options.path);
            requestedClassFilters.add(options.queryParameters['class_label']);
            if (options.path.endsWith(
              '/api/v1/ai/layers/layer-1/predictions',
            )) {
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'success': true,
                    'data': <String, dynamic>{
                      'layer': <String, dynamic>{
                        'id': 'layer-1',
                        'ai_run_id': 'run-1',
                        'project_id': 'project-1',
                        'layer_type': 'classification',
                        'status': 'published',
                        'name': 'Published AI predictions',
                        'source': 'ai_prediction_feature',
                      },
                      'feature_collection': <String, dynamic>{
                        'type': 'FeatureCollection',
                        'features': <Map<String, dynamic>>[
                          <String, dynamic>{
                            'type': 'Feature',
                            'id': 'prediction-1',
                            'properties': <String, dynamic>{
                              'prediction_feature_id': 'prediction-row-1',
                              'predicted_class': 'olives',
                              'confidence': 0.91,
                              'source': 'ai_prediction',
                              'not_official_field_data': true,
                            },
                            'geometry': <String, dynamic>{
                              'type': 'Point',
                              'coordinates': <double>[35.5, 33.9],
                            },
                          },
                        ],
                      },
                      'total_count': 1394,
                      'visible_count': 181,
                      'returned_count': 1,
                      'class_counts': <String, dynamic>{'olives': 1147},
                      'geometry_types': <String>['Point'],
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

      final repository = ApiAiRepository(ApiClient(dio: dio));

      final collection = await repository.fetchLayerFeatures(
        layerId: 'layer-1',
        classLabel: 'olives',
        limit: 900,
      );

      expect(requestedPaths, <String>['/api/v1/ai/layers/layer-1/predictions']);
      expect(requestedPaths.single.endsWith('/features'), isFalse);
      expect(requestedClassFilters, <Object?>['olives']);
      expect(collection.featureCount, 1394);
      expect(collection.matchingFeatureCount, 181);
      expect(collection.returnedFeatureCount, 1);
      expect(
        collection.features.single.properties,
        containsPair('source', 'ai_prediction'),
      );
      expect(
        collection.features.single.properties,
        containsPair('not_official_field_data', true),
      );
    });
  });
}
