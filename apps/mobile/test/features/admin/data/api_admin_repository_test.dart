import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/features/admin/data/api_admin_repository.dart';
import 'package:lebanese_gis_mobile/features/admin/domain/admin_models.dart';

void main() {
  group('ApiAdminRepository', () {
    test(
      'parses project responses with numeric collection schema version',
      () async {
        final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.endsWith('/projects') &&
                  options.method.toUpperCase() == 'POST') {
                handler.resolve(
                  Response<Map<String, dynamic>>(
                    requestOptions: options,
                    statusCode: 201,
                    data: const <String, dynamic>{
                      'success': true,
                      'data': <String, dynamic>{
                        'id': '4b159cbf-b218-44e7-bf29-7bbc3be9d091',
                        'name': 'AI Fruit Trees Smoke Test Project',
                        'category_id': 'category-1',
                        'category_name': 'AI Smoke Test Category',
                        'status': 'draft',
                        'description': 'Smoke dataset',
                        'objectives': 'Validate AI-readiness data',
                        'approved_features': 300,
                        'pending_features': 0,
                        'rejected_features': 0,
                        'draft_features': 0,
                        'contributor_count': 1,
                        'pending_assignment_requests': 0,
                        'rejected_assignment_requests': 0,
                        'collection_form_schema': <String, dynamic>{
                          'version': 1,
                          'fields': <Map<String, dynamic>>[
                            <String, dynamic>{
                              'key': 'crop_type',
                              'label': 'Crop type',
                              'type': 'select',
                              'required': true,
                              'options': <String>['apple', 'olive'],
                            },
                          ],
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

        final repository = ApiAdminRepository(ApiClient(dio: dio));

        final project = await repository.createProject(
          const ProjectProvisioningInput(
            name: 'AI Fruit Trees Smoke Test Project',
            description: 'Smoke dataset',
            objectives: 'Validate AI-readiness data',
            categoryId: 'category-1',
            status: 'draft',
            requiresPhotos: false,
            minPhotos: 0,
            maxPhotos: 5,
            visibleToViewers: true,
            visibleToContributors: true,
            collectionFormSchema: <String, dynamic>{
              'version': 'v1.0',
              'fields': <dynamic>[],
            },
          ),
        );

        expect(project.collectionFormSchema.version, '1');
        expect(project.collectionFormSchema.fields.single.key, 'crop_type');
        expect(project.approvedFeatures, 300);
      },
    );
  });
}
