import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/projects/data/api_projects_repository.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/project.dart';

void main() {
  group('CollectionFormSchema', () {
    test('accepts numeric schema versions from persisted project JSON', () {
      final schema = CollectionFormSchema.fromMap(<String, dynamic>{
        'version': 1,
        'fields': <Map<String, dynamic>>[
          <String, dynamic>{
            'key': 'crop_type',
            'label': 'Crop type',
            'type': 'select',
            'required': true,
            'options': <String>['olive', 'citrus'],
          },
        ],
      });

      expect(schema.version, '1');
      expect(schema.fields.single.key, 'crop_type');
      expect(schema.fields.single.options, <String>['olive', 'citrus']);
    });

    test('accepts numeric schemaVersion fallback from API payloads', () {
      final schema = CollectionFormSchema.fromMap(<String, dynamic>{
        'schemaVersion': 2,
        'fields': const <dynamic>[],
      });

      expect(schema.version, '2');
    });
  });

  group('ApiProjectsRepository', () {
    test('marks an unpublished offline basemap as unavailable', () async {
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
                    'package_version':
                        'project-id:active:v1.0:photos-optional:0:5:no-offline-basemap',
                    'app_resources_version': 'mobile-offline-v1',
                    'downloaded_at': '2026-08-26T00:00:00.000Z',
                    'project': <String, dynamic>{
                      'id': 'project-id',
                      'name': 'Offline project',
                      'status': 'active',
                    },
                    'base_map': null,
                  },
                },
              ),
            );
          },
        ),
      );

      final repository = ApiProjectsRepository(ApiClient(dio: dio));
      final package = await repository.fetchOfflinePackage(
        projectId: 'project-id',
        ownerUserId: 'contributor-id',
      );

      expect(package.baseMapVersion, 'no-offline-basemap');
    });

    test(
      'parses project pages with numeric collection schema version',
      () async {
        final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.endsWith('/projects')) {
                handler.resolve(
                  Response<Map<String, dynamic>>(
                    requestOptions: options,
                    statusCode: 200,
                    data: const <String, dynamic>{
                      'success': true,
                      'data': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'id': '4b159cbf-b218-44e7-bf29-7bbc3be9d091',
                          'name': 'AI Fruit Trees Smoke Test Project',
                          'category_name': 'AI Smoke Test Category',
                          'status': 'active',
                          'description': 'Smoke dataset',
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
                      ],
                      'pagination': <String, dynamic>{
                        'page': 1,
                        'limit': 20,
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
                    data: const <String, dynamic>{
                      'message': 'Unhandled test request',
                    },
                  ),
                ),
              );
            },
          ),
        );

        final repository = ApiProjectsRepository(ApiClient(dio: dio));

        final page = await repository.fetchProjectsPage(
          userId: 'admin-user',
          role: UserRole.admin,
          scope: ProjectViewScope.all,
        );

        expect(page.items.single.collectionFormSchema.version, '1');
        expect(
          page.items.single.collectionFormSchema.fields.single.key,
          'crop_type',
        );
        expect(page.items.single.approvedFeatures, 300);
      },
    );
  });
}
