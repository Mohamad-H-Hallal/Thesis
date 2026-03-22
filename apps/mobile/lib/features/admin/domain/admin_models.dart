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
    this.previousAdminRole,
    this.canToggleAdminRole = false,
  });

  final String id;
  final String email;
  final String fullName;
  final String? phone;
  final UserRole role;
  final bool isActive;
  final bool isProtectedSuperAdmin;
  final ContributorRequestStatus? requestStatus;
  final UserRole? previousAdminRole;
  final bool canToggleAdminRole;

  String get roleLabel => role == UserRole.admin && isProtectedSuperAdmin
      ? 'Super Admin'
      : role.label;
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

class ProjectCategorySummary {
  const ProjectCategorySummary({
    required this.id,
    required this.name,
    this.description,
    this.iconUrl,
    this.createdAt,
  });

  final String id;
  final String name;
  final String? description;
  final String? iconUrl;
  final DateTime? createdAt;
}

class ProjectProvisioningInput {
  const ProjectProvisioningInput({
    required this.name,
    required this.description,
    required this.objectives,
    required this.categoryId,
    required this.status,
    this.startDate,
    this.endDate,
    required this.requiresPhotos,
    required this.minPhotos,
    required this.maxPhotos,
    required this.visibleToViewers,
    required this.collectionFormSchema,
  });

  final String name;
  final String description;
  final String objectives;
  final String categoryId;
  final String status;
  final DateTime? startDate;
  final DateTime? endDate;
  final bool requiresPhotos;
  final int minPhotos;
  final int maxPhotos;
  final bool visibleToViewers;
  final Map<String, dynamic> collectionFormSchema;
}

class AdminDashboardSummary {
  const AdminDashboardSummary({
    required this.totalUsers,
    required this.adminCount,
    required this.viewerCount,
    required this.activeContributorCount,
    required this.pendingContributorRequests,
    required this.rejectedContributorRequests,
    required this.totalProjects,
    required this.pendingAssignments,
  });

  final int totalUsers;
  final int adminCount;
  final int viewerCount;
  final int activeContributorCount;
  final int pendingContributorRequests;
  final int rejectedContributorRequests;
  final int totalProjects;
  final int pendingAssignments;
}
