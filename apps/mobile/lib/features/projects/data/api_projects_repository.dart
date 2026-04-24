import '../../../core/config/app_env.dart';
import '../../../core/network/api_error_message.dart';
import '../../../core/network/api_client.dart';
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
    final fieldsRaw = (schemaMap['fields'] as List?) ?? const <dynamic>[];
    final normalizedSchema = CollectionFormSchema(
      version:
          (schemaMap['version'] as String?) ??
          (schemaMap['schemaVersion'] as String?) ??
          'v0.0',
      fields: fieldsRaw
          .map(
            (field) => _toFieldSchema(Map<String, dynamic>.from(field as Map)),
          )
          .toList(growable: false),
    );

    return ProjectSummary(
      id: (row['id'] as String?) ?? '',
      name: (row['name'] as String?) ?? 'Unnamed project',
      category: (row['category_name'] as String?) ?? 'Uncategorized',
      categoryId: row['category_id'] as String?,
      status: (row['status'] as String?) ?? 'draft',
      approvedFeatures:
          _toInt(row['approved_features']) ??
          _toInt(row['approvedFeatures']) ??
          0,
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
          _toInt(row['rejected_assignment_requests']) ??
          0,
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

  CollectionFormFieldSchema _toFieldSchema(Map<String, dynamic> raw) {
    final typeRaw = (raw['type'] as String?) ?? 'text';
    CollectionFieldType normalizedType = CollectionFieldType.text;
    if (typeRaw == 'textarea') {
      normalizedType = CollectionFieldType.multiline;
    } else if (typeRaw == 'float' || typeRaw == 'int') {
      normalizedType = CollectionFieldType.number;
    } else {
      for (final candidate in CollectionFieldType.values) {
        if (candidate.name == typeRaw) {
          normalizedType = candidate;
          break;
        }
      }
    }

    return CollectionFormFieldSchema(
      key: (raw['key'] as String?) ?? '',
      label: (raw['label'] as String?) ?? (raw['key'] as String?) ?? 'Field',
      type: normalizedType,
      required: (raw['required'] as bool?) ?? false,
      options: ((raw['options'] as List?) ?? const <dynamic>[])
          .map((value) => value.toString())
          .toList(growable: false),
      hint: raw['hint'] as String?,
      min: raw['min'] as num?,
      max: raw['max'] as num?,
      unit: raw['unit'] as String?,
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
