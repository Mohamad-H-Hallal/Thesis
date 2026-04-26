import 'admin_models.dart';
import '../../auth/domain/auth_models.dart';
import '../../projects/domain/project.dart';
import '../../../core/pagination/paginated_result.dart';

abstract class AdminRepository {
  Future<List<ManagedUserSummary>> fetchUsers({
    String? query,
    UserRole? role,
    UserAccountState? state,
    bool? isActive,
  });

  Future<PaginatedResult<ManagedUserSummary>> fetchUsersPage({
    String? query,
    UserRole? role,
    UserAccountState? state,
    bool? isActive,
    int page = 1,
    int limit = 20,
  });

  Future<List<ManagedUserSummary>> fetchContributorRequests({
    required ContributorRequestStatus status,
  });

  Future<PaginatedResult<ManagedUserSummary>> fetchContributorRequestsPage({
    required ContributorRequestStatus status,
    String? query,
    int page = 1,
    int limit = 20,
  });

  Future<ManagedUserSummary> createAdmin({
    required String fullName,
    required String email,
    required String password,
    String? phone,
  });

  Future<ManagedUserSummary> approveContributor(String userId);

  Future<ManagedUserSummary> rejectContributor(String userId);

  Future<ManagedUserSummary> toggleAdminRole(
    String userId, {
    bool forceUnassign = false,
  });

  Future<ManagedUserSummary> blockUser(String userId);

  Future<ManagedUserSummary> unblockUser(String userId);

  Future<List<ManagedAssignmentSummary>> fetchManagedAssignments({
    String? status,
  });

  Future<PaginatedResult<ManagedAssignmentSummary>> fetchManagedAssignmentsPage({
    String? status,
    String? query,
    int page = 1,
    int limit = 20,
  });

  Future<List<ProjectCategorySummary>> fetchCategories();

  Future<PaginatedResult<ProjectCategorySummary>> fetchCategoriesPage({
    String? query,
    int page = 1,
    int limit = 20,
  });

  Future<ProjectCategorySummary> createCategory({
    required String name,
    String? description,
    String? iconUrl,
  });

  Future<String> uploadCategoryIcon({
    required String filePath,
    String? fileName,
  });

  Future<ProjectCategorySummary> updateCategory({
    required String categoryId,
    required String name,
    String? description,
    String? iconUrl,
  });

  Future<ProjectSummary> createProject(ProjectProvisioningInput input);

  Future<ProjectSummary> updateProject({
    required String projectId,
    required ProjectProvisioningInput input,
  });

  Future<ProjectSummary> updateProjectStatus({
    required String projectId,
    required String status,
  });

  Future<void> archiveProject(String projectId);

  Future<List<ManagedAssignmentSummary>> fetchProjectAssignments(
    String projectId,
  );

  Future<PaginatedResult<ManagedAssignmentSummary>> fetchProjectAssignmentsPage({
    required String projectId,
    required String status,
    String? query,
    int page = 1,
    int limit = 20,
  });

  Future<PaginatedResult<ManagedUserSummary>> fetchAvailableContributorsPage({
    required String projectId,
    String? query,
    int page = 1,
    int limit = 20,
  });

  Future<ManagedAssignmentSummary> createAssignment({
    required String projectId,
    required String userId,
    required String role,
  });

  Future<ManagedAssignmentSummary> updateAssignmentStatus({
    required String assignmentId,
    required String status,
  });

  Future<void> removeAssignment(String assignmentId);

  Future<AdminDashboardSummary> fetchDashboardSummary();

  Future<SupportContactSettings> fetchSupportSettings();

  Future<SupportContactSettings> updateSupportSettings({
    String? supportEmail,
    String? supportPhone,
    String? officeHours,
    String? helpText,
  });
}
