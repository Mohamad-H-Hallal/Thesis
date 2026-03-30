import '../../auth/domain/auth_models.dart';

enum ContributorRequestStatus { pending, rejected }
enum UserAccountState { active, pending, rejected, blocked, inactive }

class ManagedUserSummary {
  const ManagedUserSummary({
    required this.id,
    required this.email,
    required this.fullName,
    required this.phone,
    required this.role,
    required this.isActive,
    required this.isProtectedSuperAdmin,
    required this.accountState,
    required this.isBlocked,
    this.requestStatus,
    this.previousAdminRole,
    this.canToggleAdminRole = false,
    this.canBlock = false,
    this.canUnblock = false,
  });

  final String id;
  final String email;
  final String fullName;
  final String? phone;
  final UserRole role;
  final bool isActive;
  final bool isProtectedSuperAdmin;
  final UserAccountState accountState;
  final bool isBlocked;
  final ContributorRequestStatus? requestStatus;
  final UserRole? previousAdminRole;
  final bool canToggleAdminRole;
  final bool canBlock;
  final bool canUnblock;

  String get roleLabel => role.label;

  String get accountStateLabel {
    switch (accountState) {
      case UserAccountState.active:
        return 'Active';
      case UserAccountState.pending:
        return 'Pending';
      case UserAccountState.rejected:
        return 'Rejected';
      case UserAccountState.blocked:
        return 'Blocked';
      case UserAccountState.inactive:
        return 'Inactive';
    }
  }
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
    required this.blockedCount,
    required this.pendingContributorRequests,
    required this.rejectedContributorRequests,
    required this.totalProjects,
    required this.pendingAssignments,
  });

  final int totalUsers;
  final int adminCount;
  final int viewerCount;
  final int activeContributorCount;
  final int blockedCount;
  final int pendingContributorRequests;
  final int rejectedContributorRequests;
  final int totalProjects;
  final int pendingAssignments;
}

class SupportContactSettings {
  const SupportContactSettings({
    required this.supportEmail,
    required this.supportPhone,
    required this.officeHours,
    required this.helpText,
    this.updatedAt,
  });

  final String? supportEmail;
  final String? supportPhone;
  final String? officeHours;
  final String? helpText;
  final DateTime? updatedAt;

  bool get isConfigured =>
      (supportEmail?.trim().isNotEmpty ?? false) ||
      (supportPhone?.trim().isNotEmpty ?? false) ||
      (officeHours?.trim().isNotEmpty ?? false) ||
      (helpText?.trim().isNotEmpty ?? false);
}
