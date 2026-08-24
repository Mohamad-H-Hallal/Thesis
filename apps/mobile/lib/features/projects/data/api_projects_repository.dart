import '../../../core/config/app_env.dart';
import '../../../core/network/api_error_message.dart';
import '../../../core/network/api_client.dart';
import '../../../core/offline/local_models.dart';
import '../../../core/pagination/paginated_result.dart';
import 'package:dio/dio.dart';
import '../../auth/domain/auth_models.dart';
import '../domain/project.dart';
import '../domain/projects_repository.dart';

class ApiProjectsRepository implements ProjectsRepository {
  ApiProjectsRepository(this._apiClient);

  final ApiClient _apiClient;

  String get _projectsBasePath => '${AppEnv.apiVersionPrefix}/projects';

  @override
  Future<List<ProjectSummary>> fetchProjects({
    required String userId,
    required UserRole role,
    required ProjectViewScope scope,
  }) async {
    final page = await fetchProjectsPage(
      userId: userId,
      role: role,
      scope: scope,
      limit: 100,
    );
    return page.items;
  }

  @override
  Future<PaginatedResult<ProjectSummary>> fetchProjectsPage({
    required String userId,
    required UserRole role,
    required ProjectViewScope scope,
    String? query,
    String? status,
    String? categoryId,
    int page = 1,
    int limit = 20,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        _projectsBasePath,
        queryParameters: <String, dynamic>{
          'access_scope': scope.apiValue,
          'page': page,
          'limit': limit,
          if (query?.trim().isNotEmpty ?? false) 'q': query!.trim(),
          if (status?.trim().isNotEmpty ?? false) 'status': status!.trim(),
          if (categoryId?.trim().isNotEmpty ?? false)
            'category_id': categoryId!.trim(),
        },
      );
      final payload = response.data ?? const <String, dynamic>{};
      final rows = (payload['data'] as List? ?? const <dynamic>[]);
      final items = rows
          .map(
            (row) => _toProjectSummary(Map<String, dynamic>.from(row as Map)),
          )
          .toList(growable: false);
      final pagination = Map<String, dynamic>.from(
        payload['pagination'] as Map? ?? const <String, dynamic>{},
      );
      final total = (pagination['total'] as num?)?.toInt() ?? items.length;
      final hasMore =
          (pagination['has_more'] as bool?) ??
          ((page * limit) < total && items.isNotEmpty);
      return PaginatedResult<ProjectSummary>(
        items: items,
        page: (pagination['page'] as num?)?.toInt() ?? page,
        limit: (pagination['limit'] as num?)?.toInt() ?? limit,
        total: total,
        hasMore: hasMore,
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load projects right now. Please try again.',
      );
    }
  }

  @override
  Future<ProjectSummary?> byId({
    required String id,
    required String userId,
    required UserRole role,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_projectsBasePath/$id',
      );
      final payload = response.data ?? const <String, dynamic>{};
      final row = Map<String, dynamic>.from(
        payload['data'] as Map? ?? const <String, dynamic>{},
      );
      return _toProjectSummary(row);
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        return null;
      }
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load project details right now. Please try again.',
      );
    }
  }

  @override
  Future<OfflineProjectPackage> fetchOfflinePackage({
    required String projectId,
    required String ownerUserId,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/offline-package',
      );
      final payload = response.data ?? const <String, dynamic>{};
      final data = Map<String, dynamic>.from(
        payload['data'] as Map? ?? const <String, dynamic>{},
      );
      final project = _toProjectSummary(
        Map<String, dynamic>.from(
          data['project'] as Map? ?? const <String, dynamic>{},
        ),
      );
      final baseMap = Map<String, dynamic>.from(
        data['base_map'] as Map? ?? const <String, dynamic>{},
      );
      final now = DateTime.now();
      return OfflineProjectPackage(
        ownerUserId: ownerUserId,
        project: project,
        packageVersion:
            (data['package_version'] as String?) ?? 'project-package-v1',
        appResourcesVersion:
            (data['app_resources_version'] as String?) ?? 'mobile-offline-v1',
        baseMapVersion:
            (baseMap['version'] as String?) ?? 'lebanon-satellite-v1',
        downloadedAt: _toDateTime(data['downloaded_at']) ?? now,
        refreshedAt: now,
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to download this project for offline use right now.',
      );
    }
  }

  @override
  Future<ProjectSummary> updateViewerVisibility({
    required String projectId,
    required bool visibleToViewers,
  }) async {
    final response = await _apiClient.dio.put<Map<String, dynamic>>(
      '$_projectsBasePath/$projectId',
      data: <String, dynamic>{'visible_to_viewers': visibleToViewers},
    );
    final payload = response.data ?? const <String, dynamic>{};
    final row = Map<String, dynamic>.from(
      payload['data'] as Map? ?? const <String, dynamic>{},
    );
    return _toProjectSummary(row);
  }

  @override
  Future<ProjectSummary> updateContributorVisibility({
    required String projectId,
    required bool visibleToContributors,
  }) async {
    final response = await _apiClient.dio.put<Map<String, dynamic>>(
      '$_projectsBasePath/$projectId',
      data: <String, dynamic>{'visible_to_contributors': visibleToContributors},
    );
    final payload = response.data ?? const <String, dynamic>{};
    final row = Map<String, dynamic>.from(
      payload['data'] as Map? ?? const <String, dynamic>{},
    );
    return _toProjectSummary(row);
  }

  @override
  Future<void> requestProjectAccess({required String projectId}) async {
    try {
      await _apiClient.dio.post<Map<String, dynamic>>(
        '${AppEnv.apiVersionPrefix}/assignments/join/$projectId',
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to request contributor access for this project.',
      );
    }
  }

  @override
  Future<void> cancelProjectAccessRequest({required String projectId}) async {
    try {
      await _apiClient.dio.delete<Map<String, dynamic>>(
        '${AppEnv.apiVersionPrefix}/assignments/join/$projectId',
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to cancel this project access request.',
      );
    }
  }

  ProjectSummary _toProjectSummary(Map<String, dynamic> row) {
    final schemaRaw = row['collection_form_schema'];
    final schemaMap = _toMap(schemaRaw);
    final normalizedSchema = CollectionFormSchema.fromMap(schemaMap);

    return ProjectSummary(
      id: (row['id'] as String?) ?? '',
      name: (row['name'] as String?) ?? 'Unnamed project',
      category: (row['category_name'] as String?) ?? 'Uncategorized',
      categoryId: row['category_id'] as String?,
      version: _toInt(row['version']) ?? 1,
      status: (row['status'] as String?) ?? 'draft',
      approvedFeatures:
          _toInt(row['approved_features']) ??
          _toInt(row['approvedFeatures']) ??
          0,
      rejectedFeatures:
          _toInt(row['rejected_features']) ??
          _toInt(row['rejectedFeatures']) ??
          0,
      draftFeatures:
          _toInt(row['draft_features']) ?? _toInt(row['draftFeatures']) ?? 0,
      assignedCollectors:
          _toInt(row['contributor_count']) ??
          _toInt(row['assigned_collectors']) ??
          0,
      pendingReviews:
          _toInt(row['pending_features']) ??
          _toInt(row['pending_reviews']) ??
          0,
      pendingAssignmentRequests:
          _toInt(row['pending_assignment_requests']) ??
          _toInt(row['pending_assignments']) ??
          0,
      rejectedAssignmentRequests:
          _toInt(row['rejected_assignment_requests']) ?? 0,
      publishedAiLayerCount:
          _toInt(row['published_ai_layer_count']) ??
          _toInt(row['publishedAiLayerCount']) ??
          0,
      publishedAiRunId:
          (row['published_ai_run_id'] as String?) ??
          (row['publishedAiRunId'] as String?),
      publishedAiLayerName:
          (row['published_ai_layer_name'] as String?) ??
          (row['publishedAiLayerName'] as String?),
      publishedAiLayerPublishedAt:
          _toDateTime(row['published_ai_layer_published_at']) ??
          _toDateTime(row['publishedAiLayerPublishedAt']),
      description:
          (row['description'] as String?) ??
          (row['objectives'] as String?) ??
          'No description provided.',
      objectives: row['objectives'] as String?,
      startDate: _toDateTime(row['start_date']),
      endDate: _toDateTime(row['end_date']),
      assignments: const <ProjectAssignment>[],
      collectionFormSchema: normalizedSchema,
      requiresPhotos: (row['requires_photos'] as bool?) ?? false,
      minPhotos: _toInt(row['min_photos']) ?? 0,
      maxPhotos: _toInt(row['max_photos']) ?? 5,
      visibleToViewers: (row['visible_to_viewers'] as bool?) ?? false,
      visibleToContributors: (row['visible_to_contributors'] as bool?) ?? true,
      currentUserAssignmentRole: _toAssignmentRole(
        row['current_user_assignment_role'] as String?,
      ),
      currentUserAssignmentStatus: _toAssignmentStatus(
        row['current_user_assignment_status'] as String?,
      ),
      allowedGeometryTypes: defaultProjectGeometryTypes,
      maxGpsAccuracyMeters: _toDouble(schemaMap['maxGpsAccuracyMeters']) ?? 25,
    );
  }

  Map<String, dynamic> _toMap(dynamic raw) {
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    return const <String, dynamic>{};
  }

  int? _toInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  double? _toDouble(dynamic value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  DateTime? _toDateTime(dynamic value) {
    if (value is DateTime) {
      return value;
    }
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value);
    }
    return null;
  }

  ProjectAssignmentRole? _toAssignmentRole(String? value) {
    switch (value) {
      case 'admin':
        return ProjectAssignmentRole.admin;
      case 'contributor':
        return ProjectAssignmentRole.contributor;
      default:
        return null;
    }
  }

  ProjectAssignmentStatus? _toAssignmentStatus(String? value) {
    switch (value) {
      case 'pending':
        return ProjectAssignmentStatus.pending;
      case 'approved':
        return ProjectAssignmentStatus.approved;
      case 'rejected':
        return ProjectAssignmentStatus.rejected;
      default:
        return null;
    }
  }
}
