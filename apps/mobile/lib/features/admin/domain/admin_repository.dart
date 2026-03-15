import 'admin_models.dart';

abstract class AdminRepository {
  Future<List<ManagedUserSummary>> fetchUsers();

  Future<List<ManagedUserSummary>> fetchContributorRequests({
    required ContributorRequestStatus status,
  });

  Future<ManagedUserSummary> createAdmin({
    required String fullName,
    required String email,
    required String password,
    String? phone,
  });

  Future<ManagedUserSummary> approveContributor(String userId);

  Future<ManagedUserSummary> rejectContributor(String userId);

  Future<List<ManagedAssignmentSummary>> fetchManagedAssignments();

  Future<AdminDashboardSummary> fetchDashboardSummary();
}
