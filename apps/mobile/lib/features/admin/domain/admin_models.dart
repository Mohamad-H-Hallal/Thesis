import '../../auth/domain/auth_models.dart';

enum ContributorRequestStatus { pending, rejected }

enum UserAccountState { active, pending, rejected, blocked, inactive }

class ContributorRequestsQuery {
  const ContributorRequestsQuery({required this.status, this.query});

  final ContributorRequestStatus status;
  final String? query;

  @override
  bool operator ==(Object other) {
    return other is ContributorRequestsQuery &&
        other.status == status &&
        other.query == query;
  }

  @override
  int get hashCode => Object.hash(status, query);
}

class ManagedUsersQuery {
  const ManagedUsersQuery({this.query, this.role, this.state, this.isActive});

  final String? query;
  final UserRole? role;
  final UserAccountState? state;
  final bool? isActive;

  @override
  bool operator ==(Object other) {
    return other is ManagedUsersQuery &&
        other.query == query &&
        other.role == role &&
        other.state == state &&
        other.isActive == isActive;
  }

  @override
  int get hashCode => Object.hash(query, role, state, isActive);
}

class ManagedAssignmentsQuery {
  const ManagedAssignmentsQuery({this.status, this.query});

  final String? status;
  final String? query;

  @override
  bool operator ==(Object other) {
    return other is ManagedAssignmentsQuery &&
        other.status == status &&
        other.query == query;
  }

  @override
  int get hashCode => Object.hash(status, query);
}

class ProjectAssignmentsQuery {
  const ProjectAssignmentsQuery({
    required this.projectId,
    required this.status,
    this.query,
  });

  final String projectId;
  final String status;
  final String? query;

  @override
  bool operator ==(Object other) {
    return other is ProjectAssignmentsQuery &&
        other.projectId == projectId &&
        other.status == status &&
        other.query == query;
  }

  @override
  int get hashCode => Object.hash(projectId, status, query);
}

class AvailableContributorsQuery {
  const AvailableContributorsQuery({required this.projectId, this.query});

  final String projectId;
  final String? query;

  @override
  bool operator ==(Object other) {
    return other is AvailableContributorsQuery &&
        other.projectId == projectId &&
        other.query == query;
  }

  @override
  int get hashCode => Object.hash(projectId, query);
}

class ProjectCategoriesQuery {
  const ProjectCategoriesQuery({this.query});

  final String? query;

  @override
  bool operator ==(Object other) {
    return other is ProjectCategoriesQuery && other.query == query;
  }

  @override
  int get hashCode => query.hashCode;
}

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
    this.approvedAssignmentCount = 0,
    this.unassignedAssignmentCount = 0,
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
  final int approvedAssignmentCount;
  final int unassignedAssignmentCount;

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
    this.version = 1,
  });

  final String id;
  final String name;
  final String? description;
  final String? iconUrl;
  final DateTime? createdAt;
  final int version;
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
    required this.visibleToContributors,
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
  final bool visibleToContributors;
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
    this.hybridBasemapEnabled = true,
    this.updatedAt,
  });

  final String? supportEmail;
  final String? supportPhone;
  final String? officeHours;
  final String? helpText;
  final bool hybridBasemapEnabled;
  final DateTime? updatedAt;

  bool get isConfigured =>
      (supportEmail?.trim().isNotEmpty ?? false) ||
      (supportPhone?.trim().isNotEmpty ?? false) ||
      (officeHours?.trim().isNotEmpty ?? false) ||
      (helpText?.trim().isNotEmpty ?? false);
}
