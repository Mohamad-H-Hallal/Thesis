import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/features/map/data/api_feature_workflow_repository.dart';

void main() {
  group('ApiFeatureWorkflowRepository', () {
    test('maps transport failures to the shared offline copy', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                error: const SocketException('Connection refused'),
              ),
            );
          },
        ),
      );
      final repository = ApiFeatureWorkflowRepository(ApiClient(dio: dio));

      await expectLater(
        repository.createDraft(
          projectId: 'project-1',
          geometry: const <String, dynamic>{
            'type': 'Point',
            'coordinates': <double>[35.5, 33.9],
          },
          attributes: const <String, dynamic>{'notes': 'offline'},
          collectedOffline: false,
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('Unable to reach the server right now. Please try again.'),
          ),
        ),
      );
    });

    test('preserves field-level validation messages', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response<dynamic>(
                  requestOptions: options,
                  statusCode: 400,
                  data: <String, dynamic>{
                    'message': 'Validation failed',
                    'errors': <Map<String, String>>[
                      <String, String>{'message': 'Project is required.'},
                    ],
                  },
                ),
                type: DioExceptionType.badResponse,
              ),
            );
          },
        ),
      );
      final repository = ApiFeatureWorkflowRepository(ApiClient(dio: dio));

      await expectLater(
        repository.createDraft(
          projectId: 'project-1',
          geometry: const <String, dynamic>{
            'type': 'Point',
            'coordinates': <double>[35.5, 33.9],
          },
          attributes: const <String, dynamic>{'notes': 'bad'},
          collectedOffline: false,
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('Project is required.'),
          ),
        ),
      );
    });
  });
}
