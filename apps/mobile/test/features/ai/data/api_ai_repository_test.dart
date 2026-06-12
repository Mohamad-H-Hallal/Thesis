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

    test(
      'fetchMyValidationTasks uses contributor assignment endpoint',
      () async {
        final requestedPaths = <String>[];
        final requestedStatuses = <Object?>[];
        final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requestedPaths.add(options.path);
              requestedStatuses.add(options.queryParameters['status']);
              if (options.path == '/api/v1/me/ai-validation-tasks') {
                handler.resolve(
                  Response<Map<String, dynamic>>(
                    requestOptions: options,
                    statusCode: 200,
                    data: <String, dynamic>{
                      'success': true,
                      'data': <String, dynamic>{
                        'tasks': <Map<String, dynamic>>[
                          _validationTaskMap(status: 'assigned'),
                        ],
                        'status_counts': <String, dynamic>{'assigned': 1},
                        'not_official_field_data': true,
                        'no_spatial_feature_writes': true,
                      },
                      'pagination': <String, dynamic>{
                        'page': 1,
                        'limit': 50,
                        'total': 1,
                        'has_more': false,
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
                  ),
                ),
              );
            },
          ),
        );

        final repository = ApiAiRepository(ApiClient(dio: dio));

        final tasks = await repository.fetchMyValidationTasks(
          status: 'assigned',
        );

        expect(requestedPaths, <String>['/api/v1/me/ai-validation-tasks']);
        expect(requestedStatuses, <Object?>['assigned']);
        expect(tasks.tasks.single.status, 'assigned');
        expect(tasks.notOfficialFieldData, isTrue);
        expect(tasks.noSpatialFeatureWrites, isTrue);
      },
    );

    test(
      'submitValidationTask posts evidence without approving field data',
      () async {
        final requestedPaths = <String>[];
        final requestBodies = <Map<String, dynamic>>[];
        final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requestedPaths.add(options.path);
              requestBodies.add(Map<String, dynamic>.from(options.data as Map));
              if (options.path ==
                  '/api/v1/ai/prediction-validation-tasks/task-1/submissions') {
                handler.resolve(
                  Response<Map<String, dynamic>>(
                    requestOptions: options,
                    statusCode: 200,
                    data: <String, dynamic>{
                      'success': true,
                      'data': <String, dynamic>{
                        'task': _validationTaskMap(
                          status: 'submitted',
                          latestSubmission: <String, dynamic>{
                            'id': 'submission-1',
                            'result': 'wrong_class',
                            'corrected_class': 'Fruit Trees',
                            'note': 'Observed a different trained class.',
                            'evidence': <String, dynamic>{
                              'text': 'Observed a different trained class.',
                            },
                            'status': 'submitted',
                          },
                        ),
                        'not_official_field_data': true,
                        'no_spatial_feature_writes': true,
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
                  ),
                ),
              );
            },
          ),
        );

        final repository = ApiAiRepository(ApiClient(dio: dio));

        final task = await repository.submitValidationTask(
          taskId: 'task-1',
          result: 'wrong_class',
          correctedClass: 'Fruit Trees',
          note: 'Observed a different trained class.',
          evidence: const <String, dynamic>{
            'text': 'Observed a different trained class.',
          },
        );

        expect(requestedPaths, <String>[
          '/api/v1/ai/prediction-validation-tasks/task-1/submissions',
        ]);
        expect(requestBodies.single, containsPair('result', 'wrong_class'));
        expect(
          requestBodies.single,
          containsPair('corrected_class', 'Fruit Trees'),
        );
        expect(
          requestBodies.single,
          containsPair('note', 'Observed a different trained class.'),
        );
        expect(requestBodies.single.containsKey('approved'), isFalse);
        expect(task.status, 'submitted');
        expect(task.latestSubmission?.correctedClass, 'Fruit Trees');
        expect(task.noSpatialFeatureWrites, isTrue);
      },
    );
  });
}

Map<String, dynamic> _validationTaskMap({
  String status = 'assigned',
  Map<String, dynamic>? latestSubmission,
}) {
  final task = <String, dynamic>{
    'id': 'task-1',
    'project_id': 'project-1',
    'ai_run_id': 'run-1',
    'ai_prediction_feature_id': 'prediction-1',
    'status': status,
    'assigned_to': 'contributor-1',
    'assigned_user': <String, dynamic>{
      'id': 'contributor-1',
      'full_name': 'Field Contributor',
    },
    'priority': 0,
    'metadata': <String, dynamic>{'threshold_used': 0.6},
    'prediction': <String, dynamic>{
      'id': 'prediction-1',
      'geometry': <String, dynamic>{
        'type': 'Point',
        'coordinates': <double>[35.4, 33.2],
      },
      'geometry_type': 'Point',
      'predicted_class': 'Olives',
      'confidence': 0.52,
      'uncertainty_score': 0.48,
      'model_name': 'random_forest',
      'source': 'ai_prediction',
      'status': 'ready_for_review',
      'metadata': <String, dynamic>{
        'trained_classes': <String>['Olives', 'Fruit Trees'],
      },
      'not_official_field_data': true,
    },
    'not_official_field_data': true,
    'no_spatial_feature_writes': true,
  };
  if (latestSubmission != null) {
    task['latest_submission'] = latestSubmission;
  }
  return task;
}
