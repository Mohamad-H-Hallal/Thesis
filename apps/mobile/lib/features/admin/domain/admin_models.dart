import '../../auth/domain/auth_models.dart';

enum ContributorRequestStatus { pending, rejected }

class ManagedUserSummary {
  const ManagedUserSummary({
    required this.id,
    required this.email,
    required this.fullName,
    required this.phone,
    required this.role,
    required this.isActive,
    required this.isProtectedSuperAdmin,
    this.requestStatus,
  });

  final String id;
  final String email;
  final String fullName;
  final String? phone;
  final UserRole role;
  final bool isActive;
  final bool isProtectedSuperAdmin;
  final ContributorRequestStatus? requestStatus;

  String get roleLabel =>
      role == UserRole.admin && isProtectedSuperAdmin ? 'Super Admin' : role.label;
}

class ManagedAssignmentSummary {
  const ManagedAssignmentSummary({
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.projectStatus,
    required this.userId,
    required this.fullName,
    required this.email,
    required this.role,
    required this.status,
  });

  final String id;
  final String projectId;
  final String projectName;
  final String projectStatus;
  final String userId;
  final String fullName;
  final String email;
  final String role;
  final String status;
}

class AdminDashboardSummary {
  const AdminDashboardSummary({
    required this.totalUsers,
    required this.adminCount,
    required this.pendingContributorRequests,
    required this.rejectedContributorRequests,
    required this.totalProjects,
    required this.pendingAssignments,
  });

  final int totalUsers;
  final int adminCount;
  final int pendingContributorRequests;
  final int rejectedContributorRequests;
  final int totalProjects;
  final int pendingAssignments;
}
