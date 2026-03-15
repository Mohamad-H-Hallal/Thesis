import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';
import '../../auth/domain/auth_models.dart';
import '../domain/admin_models.dart';
import '../domain/admin_repository.dart';

class ApiAdminRepository implements AdminRepository {
  ApiAdminRepository(this._apiClient);

  final ApiClient _apiClient;

  String get _usersBasePath => '${AppEnv.apiVersionPrefix}/users';
  String get _assignmentsBasePath => '${AppEnv.apiVersionPrefix}/assignments';
  String get _projectsBasePath => '${AppEnv.apiVersionPrefix}/projects';

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
      projectName: (row['project_name'] as String?) ?? 'Unnamed project',
      projectStatus: (row['project_status'] as String?) ?? 'draft',
      userId: (row['user_id'] as String?) ?? '',
      fullName: (row['full_name'] as String?) ?? 'Unknown user',
      email: (row['email'] as String?) ?? '',
      role: (row['role'] as String?) ?? 'contributor',
      status: (row['status'] as String?) ?? 'pending',
    );
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
