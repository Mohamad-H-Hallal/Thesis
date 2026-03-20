import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';
import '../../auth/domain/auth_models.dart';
import '../../projects/domain/project.dart';
import '../domain/admin_models.dart';
import '../domain/admin_repository.dart';

class ApiAdminRepository implements AdminRepository {
  ApiAdminRepository(this._apiClient);

  final ApiClient _apiClient;

  String get _usersBasePath => '${AppEnv.apiVersionPrefix}/users';
  String get _assignmentsBasePath => '${AppEnv.apiVersionPrefix}/assignments';
  String get _projectsBasePath => '${AppEnv.apiVersionPrefix}/projects';
  String get _categoriesBasePath => '${AppEnv.apiVersionPrefix}/categories';

  @override
  Future<List<ManagedUserSummary>> fetchUsers() async {
    final response = await _apiClient.dio.get<Map<String, dynamic>>(
      _usersBasePath,
      queryParameters: const <String, dynamic>{'limit': 100},
    );
    final rows = (response.data?['data'] as List? ?? const <dynamic>[]);
    return rows
        .map((row) => _toManagedUser(Map<String, dynamic>.from(row as Map)))
        .toList(growable: false);
  }

  @override
  Future<List<ManagedUserSummary>> fetchContributorRequests({
    required ContributorRequestStatus status,
  }) async {
    final response = await _apiClient.dio.get<Map<String, dynamic>>(
      '$_usersBasePath/contributor-requests',
      queryParameters: <String, dynamic>{
        'status': status.name,
        'limit': 100,
      },
    );
    final rows = (response.data?['data'] as List? ?? const <dynamic>[]);
    return rows
        .map((row) => _toManagedUser(Map<String, dynamic>.from(row as Map)))
        .toList(growable: false);
  }

  @override
  Future<ManagedUserSummary> createAdmin({
    required String fullName,
    required String email,
    required String password,
    String? phone,
  }) async {
    final response = await _apiClient.dio.post<Map<String, dynamic>>(
      '$_usersBasePath/admin',
      data: <String, dynamic>{
        'full_name': fullName,
        'email': email,
        'password': password,
        'phone': phone,
      },
    );
    final row = Map<String, dynamic>.from(
      response.data?['data'] as Map? ?? const <String, dynamic>{},
    );
    return _toManagedUser(row);
  }

  @override
  Future<ManagedUserSummary> approveContributor(String userId) async {
    final response = await _apiClient.dio.post<Map<String, dynamic>>(
      '$_usersBasePath/$userId/approve-contributor',
    );
    final row = Map<String, dynamic>.from(
      response.data?['data'] as Map? ?? const <String, dynamic>{},
    );
    return _toManagedUser(row);
  }

  @override
  Future<ManagedUserSummary> rejectContributor(String userId) async {
    final response = await _apiClient.dio.post<Map<String, dynamic>>(
      '$_usersBasePath/$userId/reject-contributor',
    );
    final row = Map<String, dynamic>.from(
      response.data?['data'] as Map? ?? const <String, dynamic>{},
    );
    return _toManagedUser(row);
  }

  @override
  Future<List<ManagedAssignmentSummary>> fetchManagedAssignments() async {
    final response = await _apiClient.dio.get<Map<String, dynamic>>(
      '$_assignmentsBasePath/managed',
      queryParameters: const <String, dynamic>{'limit': 100},
    );
    final rows = (response.data?['data'] as List? ?? const <dynamic>[]);
    return rows
        .map(
          (row) => _toManagedAssignment(Map<String, dynamic>.from(row as Map)),
        )
        .toList(growable: false);
  }

  @override
  Future<List<ProjectCategorySummary>> fetchCategories() async {
    final response = await _apiClient.dio.get<Map<String, dynamic>>(
      _categoriesBasePath,
    );
    final rows = (response.data?['data'] as List? ?? const <dynamic>[]);
    return rows
        .map(
          (row) => _toProjectCategory(Map<String, dynamic>.from(row as Map)),
        )
        .toList(growable: false);
  }

  @override
  Future<ProjectCategorySummary> createCategory({
    required String name,
    String? description,
    String? iconUrl,
  }) async {
    final response = await _apiClient.dio.post<Map<String, dynamic>>(
      _categoriesBasePath,
      data: <String, dynamic>{
        'name': name,
        'description': description,
        'icon_url': iconUrl,
      },
    );
    final row = Map<String, dynamic>.from(
      response.data?['data'] as Map? ?? const <String, dynamic>{},
    );
    return _toProjectCategory(row);
  }

  @override
  Future<ProjectCategorySummary> updateCategory({
    required String categoryId,
    required String name,
    String? description,
    String? iconUrl,
  }) async {
    final response = await _apiClient.dio.put<Map<String, dynamic>>(
      '$_categoriesBasePath/$categoryId',
      data: <String, dynamic>{
        'name': name,
        'description': description,
        'icon_url': iconUrl,
      },
    );
    final row = Map<String, dynamic>.from(
      response.data?['data'] as Map? ?? const <String, dynamic>{},
    );
    return _toProjectCategory(row);
  }

  @override
  Future<ProjectSummary> createProject(ProjectProvisioningInput input) async {
    final initialInput = input.status == 'draft'
        ? input
        : ProjectProvisioningInput(
            name: input.name,
            description: input.description,
            objectives: input.objectives,
            categoryId: input.categoryId,
            status: 'draft',
            startDate: input.startDate,
            endDate: input.endDate,
            requiresPhotos: input.requiresPhotos,
            minPhotos: input.minPhotos,
            maxPhotos: input.maxPhotos,
            visibleToViewers: input.visibleToViewers,
            collectionFormSchema: input.collectionFormSchema,
          );

    final response = await _apiClient.dio.post<Map<String, dynamic>>(
      _projectsBasePath,
      data: _projectPayload(initialInput),
    );
    final row = Map<String, dynamic>.from(
      response.data?['data'] as Map? ?? const <String, dynamic>{},
    );
    final createdProject = _toProjectSummary(row);

    if (input.status == 'draft') {
      return createdProject;
    }

    return updateProject(projectId: createdProject.id, input: input);
  }

  @override
  Future<ProjectSummary> updateProject({
    required String projectId,
    required ProjectProvisioningInput input,
  }) async {
    final response = await _apiClient.dio.put<Map<String, dynamic>>(
      '$_projectsBasePath/$projectId',
      data: _projectPayload(input),
    );
    final row = Map<String, dynamic>.from(
      response.data?['data'] as Map? ?? const <String, dynamic>{},
    );
    return _toProjectSummary(row);
  }

  @override
  Future<void> archiveProject(String projectId) async {
    await _apiClient.dio.delete<void>('$_projectsBasePath/$projectId');
  }

  @override
  Future<List<ManagedAssignmentSummary>> fetchProjectAssignments(
    String projectId,
  ) async {
    final response = await _apiClient.dio.get<Map<String, dynamic>>(
      '$_assignmentsBasePath/project/$projectId',
      queryParameters: const <String, dynamic>{'limit': 100},
    );
    final rows = (response.data?['data'] as List? ?? const <dynamic>[]);
    return rows
        .map(
          (row) => _toManagedAssignment(
            Map<String, dynamic>.from(row as Map)
              ..putIfAbsent('project_id', () => projectId)
              ..putIfAbsent('project_name', () => '')
              ..putIfAbsent('project_status', () => ''),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<ManagedAssignmentSummary> createAssignment({
    required String projectId,
    required String userId,
    required String role,
  }) async {
    final response = await _apiClient.dio.post<Map<String, dynamic>>(
      _assignmentsBasePath,
      data: <String, dynamic>{
        'project_id': projectId,
        'user_id': userId,
        'role': role,
      },
    );
    final row = Map<String, dynamic>.from(
      response.data?['data'] as Map? ?? const <String, dynamic>{},
    );
    return _toManagedAssignment(
      row
        ..putIfAbsent('project_id', () => projectId)
        ..putIfAbsent('project_name', () => '')
        ..putIfAbsent('project_status', () => ''),
    );
  }

  @override
  Future<ManagedAssignmentSummary> updateAssignmentStatus({
    required String assignmentId,
    required String status,
  }) async {
    final response = await _apiClient.dio.put<Map<String, dynamic>>(
      '$_assignmentsBasePath/$assignmentId',
      data: <String, dynamic>{'status': status},
    );
    final row = Map<String, dynamic>.from(
      response.data?['data'] as Map? ?? const <String, dynamic>{},
    );
    return _toManagedAssignment(row);
  }

  @override
  Future<void> removeAssignment(String assignmentId) async {
    await _apiClient.dio.delete<void>('$_assignmentsBasePath/$assignmentId');
  }

  @override
  Future<AdminDashboardSummary> fetchDashboardSummary() async {
    final results = await Future.wait([
      fetchUsers(),
      fetchContributorRequests(status: ContributorRequestStatus.pending),
      fetchContributorRequests(status: ContributorRequestStatus.rejected),
      fetchManagedAssignments(),
      _apiClient.dio.get<Map<String, dynamic>>(
        _projectsBasePath,
        queryParameters: const <String, dynamic>{'access_scope': 'all'},
      ),
    ]);

    final users = results[0] as List<ManagedUserSummary>;
    final pendingRequests = results[1] as List<ManagedUserSummary>;
    final rejectedRequests = results[2] as List<ManagedUserSummary>;
    final assignments = results[3] as List<ManagedAssignmentSummary>;
    final projectRows =
        (((results[4] as dynamic).data ?? const <String, dynamic>{})['data']
                as List? ??
            const <dynamic>[]);

    return AdminDashboardSummary(
      totalUsers: users.length,
      adminCount: users.where((user) => user.role == UserRole.admin).length,
      pendingContributorRequests: pendingRequests.length,
      rejectedContributorRequests: rejectedRequests.length,
      totalProjects: projectRows.length,
      pendingAssignments: assignments.where((item) => item.status == 'pending').length,
    );
  }

  ManagedUserSummary _toManagedUser(Map<String, dynamic> row) {
    final requestStatusRaw = row['request_status'] as String?;
    return ManagedUserSummary(
      id: (row['id'] as String?) ?? '',
      email: (row['email'] as String?) ?? '',
      fullName: (row['full_name'] as String?) ?? 'Unknown User',
      phone: row['phone'] as String?,
      role: _toRole(row['role'] as String?),
      isActive: (row['is_active'] as bool?) ?? false,
      isProtectedSuperAdmin:
          (row['is_protected_super_admin'] as bool?) ?? false,
      requestStatus: requestStatusRaw == null
          ? null
          : ContributorRequestStatus.values.byName(requestStatusRaw),
    );
  }

  ManagedAssignmentSummary _toManagedAssignment(Map<String, dynamic> row) {
    return ManagedAssignmentSummary(
      id: (row['id'] as String?) ?? '',
      projectId: (row['project_id'] as String?) ?? '',
      projectName:
          (row['project_name'] as String?)?.isNotEmpty == true
          ? row['project_name'] as String
          : 'Project assignment',
      projectStatus: (row['project_status'] as String?) ?? 'draft',
      userId: (row['user_id'] as String?) ?? '',
      fullName: (row['full_name'] as String?) ?? 'Unknown user',
      email: (row['email'] as String?) ?? '',
      role: (row['role'] as String?) ?? 'contributor',
      status: (row['status'] as String?) ?? 'pending',
    );
  }

  ProjectCategorySummary _toProjectCategory(Map<String, dynamic> row) {
    return ProjectCategorySummary(
      id: (row['id'] as String?) ?? '',
      name: (row['name'] as String?) ?? 'Unnamed category',
      description: row['description'] as String?,
      iconUrl: row['icon_url'] as String?,
      createdAt: _toDateTime(row['created_at']),
    );
  }

  ProjectSummary _toProjectSummary(Map<String, dynamic> row) {
    final schemaMap = _toMap(row['collection_form_schema']);
    final fieldsRaw = (schemaMap['fields'] as List?) ?? const <dynamic>[];

    return ProjectSummary(
      id: (row['id'] as String?) ?? '',
      name: (row['name'] as String?) ?? 'Unnamed project',
      category: (row['category_name'] as String?) ?? 'Uncategorized',
      categoryId: row['category_id'] as String?,
      status: (row['status'] as String?) ?? 'draft',
      assignedCollectors:
          _toInt(row['contributor_count']) ??
          _toInt(row['assigned_collectors']) ??
          0,
      pendingReviews:
          _toInt(row['pending_features']) ??
          _toInt(row['pending_reviews']) ??
          0,
      description: (row['description'] as String?) ?? '',
      objectives: row['objectives'] as String?,
      startDate: _toDateTime(row['start_date']),
      endDate: _toDateTime(row['end_date']),
      collectionFormSchema: CollectionFormSchema(
        version:
            (schemaMap['version'] as String?) ??
            (schemaMap['schemaVersion'] as String?) ??
            'v0.0',
        fields: fieldsRaw
            .map(
              (field) => _toFieldSchema(Map<String, dynamic>.from(field as Map)),
            )
            .toList(growable: false),
      ),
      requiresPhotos: (row['requires_photos'] as bool?) ?? false,
      minPhotos: _toInt(row['min_photos']) ?? 0,
      maxPhotos: _toInt(row['max_photos']) ?? 5,
      visibleToViewers: (row['visible_to_viewers'] as bool?) ?? false,
      allowedGeometryTypes:
          (schemaMap['allowedGeometryTypes'] as List?)?.cast<String>().toList(
            growable: false,
          ) ??
          const <String>['Point'],
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

  Map<String, dynamic> _projectPayload(ProjectProvisioningInput input) {
    return <String, dynamic>{
      'name': input.name,
      'description': input.description,
      'objectives': input.objectives,
      'category_id': input.categoryId,
      'status': input.status,
      'start_date': input.startDate == null ? null : _toIsoDate(input.startDate!),
      'end_date': input.endDate == null ? null : _toIsoDate(input.endDate!),
      'requires_photos': input.requiresPhotos,
      'min_photos': input.minPhotos,
      'max_photos': input.maxPhotos,
      'visible_to_viewers': input.visibleToViewers,
      'collection_form_schema': input.collectionFormSchema,
    };
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

  String _toIsoDate(DateTime value) {
    final normalized = DateTime(value.year, value.month, value.day);
    final month = normalized.month.toString().padLeft(2, '0');
    final day = normalized.day.toString().padLeft(2, '0');
    return '${normalized.year}-$month-$day';
  }

  UserRole _toRole(String? raw) {
    switch (raw) {
      case 'admin':
        return UserRole.admin;
      case 'viewer':
        return UserRole.viewer;
      default:
        return UserRole.contributor;
    }
  }
}
