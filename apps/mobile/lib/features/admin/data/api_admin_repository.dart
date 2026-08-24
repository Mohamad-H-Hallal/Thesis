import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../../core/config/app_env.dart';
import '../../../core/network/api_error_message.dart';
import '../../../core/network/api_client.dart';
import '../../../core/pagination/paginated_result.dart';
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
  String get _settingsBasePath => '${AppEnv.apiVersionPrefix}/settings';

  @override
  Future<List<ManagedUserSummary>> fetchUsers({
    String? query,
    UserRole? role,
    UserAccountState? state,
    bool? isActive,
  }) async {
    final page = await fetchUsersPage(
      query: query,
      role: role,
      state: state,
      isActive: isActive,
      limit: 100,
    );
    return page.items;
  }

  @override
  Future<PaginatedResult<ManagedUserSummary>> fetchUsersPage({
    String? query,
    UserRole? role,
    UserAccountState? state,
    bool? isActive,
    int page = 1,
    int limit = 20,
  }) async {
    return _run(() async {
      final queryParameters = <String, dynamic>{'page': page, 'limit': limit};
      if (query?.trim().isNotEmpty ?? false) {
        queryParameters['q'] = query!.trim();
      }
      if (role != null) {
        queryParameters['role'] = _roleValue(role);
      }
      if (state != null) {
        queryParameters['state'] = state.name;
      }
      if (isActive != null) {
        queryParameters['is_active'] = isActive;
      }
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        _usersBasePath,
        queryParameters: queryParameters,
      );
      final rows = (response.data?['data'] as List? ?? const <dynamic>[]);
      final items = rows
          .map((row) => _toManagedUser(Map<String, dynamic>.from(row as Map)))
          .toList(growable: false);
      final pagination = Map<String, dynamic>.from(
        response.data?['pagination'] as Map? ?? const <String, dynamic>{},
      );
      final total = (pagination['total'] as num?)?.toInt() ?? items.length;
      final hasMore =
          (pagination['has_more'] as bool?) ??
          ((page * limit) < total && items.isNotEmpty);
      return PaginatedResult<ManagedUserSummary>(
        items: items,
        page: (pagination['page'] as num?)?.toInt() ?? page,
        limit: (pagination['limit'] as num?)?.toInt() ?? limit,
        total: total,
        hasMore: hasMore,
      );
    }, fallback: 'Unable to load users.');
  }

  @override
  Future<List<ManagedUserSummary>> fetchContributorRequests({
    required ContributorRequestStatus status,
  }) async {
    final page = await fetchContributorRequestsPage(status: status, limit: 100);
    return page.items;
  }

  @override
  Future<PaginatedResult<ManagedUserSummary>> fetchContributorRequestsPage({
    required ContributorRequestStatus status,
    String? query,
    int page = 1,
    int limit = 20,
  }) async {
    return _run(() async {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_usersBasePath/contributor-requests',
        queryParameters: <String, dynamic>{
          'status': status.name,
          if (query?.trim().isNotEmpty ?? false) 'q': query!.trim(),
          'page': page,
          'limit': limit,
        },
      );
      final rows = (response.data?['data'] as List? ?? const <dynamic>[]);
      final items = rows
          .map((row) => _toManagedUser(Map<String, dynamic>.from(row as Map)))
          .toList(growable: false);
      final pagination = Map<String, dynamic>.from(
        response.data?['pagination'] as Map? ?? const <String, dynamic>{},
      );
      final total = (pagination['total'] as num?)?.toInt() ?? items.length;
      final hasMore =
          (pagination['has_more'] as bool?) ??
          ((page * limit) < total && items.isNotEmpty);
      return PaginatedResult<ManagedUserSummary>(
        items: items,
        page: (pagination['page'] as num?)?.toInt() ?? page,
        limit: (pagination['limit'] as num?)?.toInt() ?? limit,
        total: total,
        hasMore: hasMore,
      );
    }, fallback: 'Unable to load contributor requests.');
  }

  @override
  Future<ManagedUserSummary> createAdmin({
    required String fullName,
    required String email,
    required String password,
    String? phone,
  }) async {
    return _run(() async {
      final payload = <String, dynamic>{
        'full_name': fullName,
        'email': email,
        'password': password,
      };
      if (phone?.trim().isNotEmpty ?? false) {
        payload['phone'] = phone!.trim();
      }
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_usersBasePath/admin',
        data: payload,
      );
      final row = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return _toManagedUser(row);
    }, fallback: 'Unable to create admin account.');
  }

  @override
  Future<ManagedUserSummary> approveContributor(String userId) async {
    return _run(() async {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_usersBasePath/$userId/approve-contributor',
      );
      final row = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return _toManagedUser(row);
    }, fallback: 'Unable to approve contributor request.');
  }

  @override
  Future<ManagedUserSummary> rejectContributor(String userId) async {
    return _run(() async {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_usersBasePath/$userId/reject-contributor',
      );
      final row = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return _toManagedUser(row);
    }, fallback: 'Unable to reject contributor request.');
  }

  @override
  Future<ManagedUserSummary> toggleAdminRole(
    String userId, {
    bool forceUnassign = false,
  }) async {
    return _run(() async {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_usersBasePath/$userId/toggle-admin-role',
        data: <String, dynamic>{'force_unassign': forceUnassign},
      );
      final row = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return _toManagedUser(row);
    }, fallback: 'Unable to update admin role.');
  }

  @override
  Future<ManagedUserSummary> blockUser(String userId) async {
    return _run(() async {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_usersBasePath/$userId/block',
      );
      final row = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return _toManagedUser(row);
    }, fallback: 'Unable to block user.');
  }

  @override
  Future<ManagedUserSummary> unblockUser(String userId) async {
    return _run(() async {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_usersBasePath/$userId/unblock',
      );
      final row = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return _toManagedUser(row);
    }, fallback: 'Unable to unblock user.');
  }

  @override
  Future<List<ManagedAssignmentSummary>> fetchManagedAssignments({
    String? status,
  }) async {
    final page = await fetchManagedAssignmentsPage(status: status, limit: 100);
    return page.items;
  }

  @override
  Future<PaginatedResult<ManagedAssignmentSummary>>
  fetchManagedAssignmentsPage({
    String? status,
    String? query,
    int page = 1,
    int limit = 20,
  }) async {
    return _run(() async {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_assignmentsBasePath/managed',
        queryParameters: <String, dynamic>{
          'page': page,
          'limit': limit,
          if (status != null && status.trim().isNotEmpty) 'status': status,
          if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
        },
      );
      final rows = (response.data?['data'] as List? ?? const <dynamic>[]);
      final items = rows
          .map(
            (row) =>
                _toManagedAssignment(Map<String, dynamic>.from(row as Map)),
          )
          .toList(growable: false);
      final pagination = Map<String, dynamic>.from(
        response.data?['pagination'] as Map? ?? const <String, dynamic>{},
      );
      final total = (pagination['total'] as num?)?.toInt() ?? items.length;
      final hasMore =
          (pagination['has_more'] as bool?) ??
          ((page * limit) < total && items.isNotEmpty);
      return PaginatedResult<ManagedAssignmentSummary>(
        items: items,
        page: (pagination['page'] as num?)?.toInt() ?? page,
        limit: (pagination['limit'] as num?)?.toInt() ?? limit,
        total: total,
        hasMore: hasMore,
      );
    }, fallback: 'Unable to load project requests.');
  }

  @override
  Future<List<ProjectCategorySummary>> fetchCategories() async {
    final page = await fetchCategoriesPage(limit: 100);
    return page.items;
  }

  @override
  Future<PaginatedResult<ProjectCategorySummary>> fetchCategoriesPage({
    String? query,
    int page = 1,
    int limit = 20,
  }) async {
    return _run(() async {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        _categoriesBasePath,
        queryParameters: <String, dynamic>{
          'page': page,
          'limit': limit,
          if (query?.trim().isNotEmpty ?? false) 'q': query!.trim(),
        },
      );
      final rows = (response.data?['data'] as List? ?? const <dynamic>[]);
      final items = rows
          .map(
            (row) => _toProjectCategory(Map<String, dynamic>.from(row as Map)),
          )
          .toList(growable: false);
      final pagination = Map<String, dynamic>.from(
        response.data?['pagination'] as Map? ?? const <String, dynamic>{},
      );
      final total = (pagination['total'] as num?)?.toInt() ?? items.length;
      final hasMore =
          (pagination['has_more'] as bool?) ??
          ((page * limit) < total && items.isNotEmpty);
      return PaginatedResult<ProjectCategorySummary>(
        items: items,
        page: (pagination['page'] as num?)?.toInt() ?? page,
        limit: (pagination['limit'] as num?)?.toInt() ?? limit,
        total: total,
        hasMore: hasMore,
      );
    }, fallback: 'Unable to load categories.');
  }

  @override
  Future<ProjectCategorySummary> createCategory({
    required String name,
    String? description,
    String? iconUrl,
  }) async {
    return _run(() async {
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
    }, fallback: 'Unable to create category.');
  }

  @override
  Future<String> uploadCategoryIcon({
    required String filePath,
    String? fileName,
    List<int>? bytes,
  }) async {
    return _run(() async {
      final resolvedFileName = fileName ?? p.basename(filePath);
      final iconFile = bytes == null
          ? await MultipartFile.fromFile(filePath, filename: resolvedFileName)
          : MultipartFile.fromBytes(bytes, filename: resolvedFileName);
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_categoriesBasePath/icon',
        data: FormData.fromMap(<String, dynamic>{'icon': iconFile}),
      );
      final row = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      final iconUrl = row['icon_url'] as String?;
      if (iconUrl == null || iconUrl.trim().isEmpty) {
        throw const FormatException(
          'Category icon upload did not return an icon URL.',
        );
      }
      return iconUrl.trim();
    }, fallback: 'Unable to upload category icon.');
  }

  @override
  Future<ProjectCategorySummary> updateCategory({
    required String categoryId,
    required String name,
    String? description,
    String? iconUrl,
    int? expectedVersion,
  }) async {
    return _run(() async {
      final payload = <String, dynamic>{
        'name': name,
        'description': description,
        'icon_url': iconUrl,
      };
      if (expectedVersion != null) {
        payload['expected_version'] = expectedVersion;
      }
      final response = await _apiClient.dio.put<Map<String, dynamic>>(
        '$_categoriesBasePath/$categoryId',
        data: payload,
      );
      final row = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return _toProjectCategory(row);
    }, fallback: 'Unable to update category.');
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
            visibleToContributors: input.visibleToContributors,
            collectionFormSchema: input.collectionFormSchema,
          );

    return _run(() async {
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

      return updateProject(
        projectId: createdProject.id,
        input: input,
        expectedVersion: createdProject.version,
      );
    }, fallback: 'Unable to create project.');
  }

  @override
  Future<ProjectSummary> updateProject({
    required String projectId,
    required ProjectProvisioningInput input,
    int? expectedVersion,
  }) async {
    return _run(() async {
      final payload = _projectPayload(input);
      if (expectedVersion != null) {
        payload['expected_version'] = expectedVersion;
      }
      final response = await _apiClient.dio.put<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId',
        data: payload,
      );
      final row = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return _toProjectSummary(row);
    }, fallback: 'Unable to update project.');
  }

  @override
  Future<ProjectSummary> updateProjectStatus({
    required String projectId,
    required String status,
  }) async {
    return _run(() async {
      final response = await _apiClient.dio.put<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId',
        data: <String, dynamic>{'status': status},
      );
      final row = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return _toProjectSummary(row);
    }, fallback: 'Unable to update project status.');
  }

  @override
  Future<void> archiveProject(String projectId) async {
    return _run(() async {
      await _apiClient.dio.delete<void>('$_projectsBasePath/$projectId');
    }, fallback: 'Unable to archive project.');
  }

  @override
  Future<List<ManagedAssignmentSummary>> fetchProjectAssignments(
    String projectId,
  ) async {
    final page = await fetchProjectAssignmentsPage(
      projectId: projectId,
      status: '',
      limit: 100,
    );
    return page.items;
  }

  @override
  Future<PaginatedResult<ManagedAssignmentSummary>>
  fetchProjectAssignmentsPage({
    required String projectId,
    required String status,
    String? query,
    int page = 1,
    int limit = 20,
  }) async {
    return _run(() async {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_assignmentsBasePath/project/$projectId',
        queryParameters: <String, dynamic>{
          'page': page,
          'limit': limit,
          if (status.trim().isNotEmpty) 'status': status.trim(),
          if (query?.trim().isNotEmpty ?? false) 'q': query!.trim(),
        },
      );
      final rows = (response.data?['data'] as List? ?? const <dynamic>[]);
      final items = rows
          .map(
            (row) => _toManagedAssignment(
              Map<String, dynamic>.from(row as Map)
                ..putIfAbsent('project_id', () => projectId)
                ..putIfAbsent('project_name', () => '')
                ..putIfAbsent('project_status', () => ''),
            ),
          )
          .toList(growable: false);
      final pagination = Map<String, dynamic>.from(
        response.data?['pagination'] as Map? ?? const <String, dynamic>{},
      );
      final total = (pagination['total'] as num?)?.toInt() ?? items.length;
      final hasMore =
          (pagination['has_more'] as bool?) ??
          ((page * limit) < total && items.isNotEmpty);
      return PaginatedResult<ManagedAssignmentSummary>(
        items: items,
        page: (pagination['page'] as num?)?.toInt() ?? page,
        limit: (pagination['limit'] as num?)?.toInt() ?? limit,
        total: total,
        hasMore: hasMore,
      );
    }, fallback: 'Unable to load project assignments.');
  }

  @override
  Future<PaginatedResult<ManagedUserSummary>> fetchAvailableContributorsPage({
    required String projectId,
    String? query,
    int page = 1,
    int limit = 20,
  }) async {
    return _run(() async {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_assignmentsBasePath/project/$projectId/available-contributors',
        queryParameters: <String, dynamic>{
          'page': page,
          'limit': limit,
          if (query?.trim().isNotEmpty ?? false) 'q': query!.trim(),
        },
      );
      final rows = (response.data?['data'] as List? ?? const <dynamic>[]);
      final items = rows
          .map((row) => _toManagedUser(Map<String, dynamic>.from(row as Map)))
          .toList(growable: false);
      final pagination = Map<String, dynamic>.from(
        response.data?['pagination'] as Map? ?? const <String, dynamic>{},
      );
      final total = (pagination['total'] as num?)?.toInt() ?? items.length;
      final hasMore =
          (pagination['has_more'] as bool?) ??
          ((page * limit) < total && items.isNotEmpty);
      return PaginatedResult<ManagedUserSummary>(
        items: items,
        page: (pagination['page'] as num?)?.toInt() ?? page,
        limit: (pagination['limit'] as num?)?.toInt() ?? limit,
        total: total,
        hasMore: hasMore,
      );
    }, fallback: 'Unable to load available contributors.');
  }

  @override
  Future<ManagedAssignmentSummary> createAssignment({
    required String projectId,
    required String userId,
    required String role,
  }) async {
    return _run(() async {
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
    }, fallback: 'Unable to create project assignment.');
  }

  @override
  Future<ManagedAssignmentSummary> updateAssignmentStatus({
    required String assignmentId,
    required String status,
  }) async {
    return _run(() async {
      final response = await _apiClient.dio.put<Map<String, dynamic>>(
        '$_assignmentsBasePath/$assignmentId',
        data: <String, dynamic>{'status': status},
      );
      final row = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return _toManagedAssignment(row);
    }, fallback: 'Unable to update assignment status.');
  }

  @override
  Future<void> removeAssignment(String assignmentId) async {
    return _run(() async {
      await _apiClient.dio.delete<void>('$_assignmentsBasePath/$assignmentId');
    }, fallback: 'Unable to remove assignment.');
  }

  @override
  Future<AdminDashboardSummary> fetchDashboardSummary() async {
    return _run(() async {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_usersBasePath/dashboard-summary',
      );
      final row = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return AdminDashboardSummary(
        totalUsers: _toInt(row['total_users']) ?? 0,
        adminCount: _toInt(row['admin_count']) ?? 0,
        viewerCount: _toInt(row['viewer_count']) ?? 0,
        activeContributorCount: _toInt(row['active_contributor_count']) ?? 0,
        blockedCount: _toInt(row['blocked_count']) ?? 0,
        pendingContributorRequests:
            _toInt(row['pending_contributor_requests']) ?? 0,
        rejectedContributorRequests:
            _toInt(row['rejected_contributor_requests']) ?? 0,
        totalProjects: _toInt(row['total_projects']) ?? 0,
        pendingAssignments: _toInt(row['pending_assignments']) ?? 0,
      );
    }, fallback: 'Unable to load the admin dashboard right now.');
  }

  @override
  Future<SupportContactSettings> fetchSupportSettings() async {
    return _run(() async {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_settingsBasePath/support',
      );
      final row = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return _toSupportSettings(row);
    }, fallback: 'Unable to load support settings.');
  }

  @override
  Future<SupportContactSettings> updateSupportSettings({
    String? supportEmail,
    String? supportPhone,
    String? officeHours,
    String? helpText,
  }) async {
    return _run(() async {
      final response = await _apiClient.dio.put<Map<String, dynamic>>(
        '$_settingsBasePath/support',
        data: <String, dynamic>{
          'support_email': supportEmail,
          'support_phone': supportPhone,
          'office_hours': officeHours,
          'help_text': helpText,
        },
      );
      final row = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return _toSupportSettings(row);
    }, fallback: 'Unable to update support settings.');
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
      accountState: _toAccountState(row['account_state'] as String?),
      isBlocked: (row['is_blocked'] as bool?) ?? false,
      previousAdminRole: _toOptionalRole(row['previous_admin_role'] as String?),
      canToggleAdminRole: (row['can_toggle_admin_role'] as bool?) ?? false,
      canBlock:
          ((row['is_active'] as bool?) ?? false) &&
          !((row['is_blocked'] as bool?) ?? false) &&
          !((row['is_protected_super_admin'] as bool?) ?? false),
      canUnblock: (row['is_blocked'] as bool?) ?? false,
      approvedAssignmentCount: _toInt(row['approved_assignment_count']) ?? 0,
      unassignedAssignmentCount:
          _toInt(row['unassigned_assignment_count']) ?? 0,
      requestStatus: requestStatusRaw == null
          ? null
          : ContributorRequestStatus.values.byName(requestStatusRaw),
    );
  }

  ManagedAssignmentSummary _toManagedAssignment(Map<String, dynamic> row) {
    return ManagedAssignmentSummary(
      id: (row['id'] as String?) ?? '',
      projectId: (row['project_id'] as String?) ?? '',
      projectName: (row['project_name'] as String?)?.isNotEmpty == true
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
      version: _toInt(row['version']) ?? 1,
    );
  }

  SupportContactSettings _toSupportSettings(Map<String, dynamic> row) {
    return SupportContactSettings(
      supportEmail: row['support_email'] as String?,
      supportPhone: row['support_phone'] as String?,
      officeHours: row['office_hours'] as String?,
      helpText: row['help_text'] as String?,
      updatedAt: _toDateTime(row['updated_at']),
    );
  }

  ProjectSummary _toProjectSummary(Map<String, dynamic> row) {
    final schemaMap = _toMap(row['collection_form_schema']);

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
      description: (row['description'] as String?) ?? '',
      objectives: row['objectives'] as String?,
      startDate: _toDateTime(row['start_date']),
      endDate: _toDateTime(row['end_date']),
      collectionFormSchema: CollectionFormSchema.fromMap(schemaMap),
      requiresPhotos: (row['requires_photos'] as bool?) ?? false,
      minPhotos: _toInt(row['min_photos']) ?? 0,
      maxPhotos: _toInt(row['max_photos']) ?? 5,
      visibleToViewers: (row['visible_to_viewers'] as bool?) ?? false,
      visibleToContributors: (row['visible_to_contributors'] as bool?) ?? true,
      allowedGeometryTypes: defaultProjectGeometryTypes,
      maxGpsAccuracyMeters: _toDouble(schemaMap['maxGpsAccuracyMeters']) ?? 25,
    );
  }

  Map<String, dynamic> _projectPayload(ProjectProvisioningInput input) {
    return <String, dynamic>{
      'name': input.name,
      'description': input.description,
      'objectives': input.objectives,
      'category_id': input.categoryId,
      'status': input.status,
      'start_date': input.startDate == null
          ? null
          : _toIsoDate(input.startDate!),
      'end_date': input.endDate == null ? null : _toIsoDate(input.endDate!),
      'requires_photos': input.requiresPhotos,
      'min_photos': input.minPhotos,
      'max_photos': input.maxPhotos,
      'visible_to_viewers': input.visibleToViewers,
      'visible_to_contributors': input.visibleToContributors,
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

  UserRole? _toOptionalRole(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    return _toRole(raw);
  }

  UserAccountState _toAccountState(String? raw) {
    switch (raw) {
      case 'pending':
        return UserAccountState.pending;
      case 'rejected':
        return UserAccountState.rejected;
      case 'blocked':
        return UserAccountState.blocked;
      case 'inactive':
        return UserAccountState.inactive;
      default:
        return UserAccountState.active;
    }
  }

  String _roleValue(UserRole role) {
    switch (role) {
      case UserRole.admin:
        return 'admin';
      case UserRole.viewer:
        return 'viewer';
      case UserRole.contributor:
        return 'contributor';
    }
  }

  Future<T> _run<T>(
    Future<T> Function() action, {
    required String fallback,
  }) async {
    try {
      return await action();
    } on DioException catch (error) {
      throw _messageFrom(error, fallback);
    }
  }

  String _messageFrom(DioException error, String fallback) {
    return userFacingDioMessage(error, fallback: fallback);
  }
}
