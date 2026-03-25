import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../auth/domain/auth_models.dart';
import '../../../projects/domain/project.dart';
import '../../domain/admin_models.dart';

class ProjectAssignmentsScreen extends ConsumerStatefulWidget {
  const ProjectAssignmentsScreen({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<ProjectAssignmentsScreen> createState() =>
      _ProjectAssignmentsScreenState();
}

class _ProjectAssignmentsScreenState
    extends ConsumerState<ProjectAssignmentsScreen> {
  bool _isSaving = false;
  bool _showFilters = false;
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _assignContributor(ManagedUserSummary user) async {
    setState(() => _isSaving = true);
    try {
      await ref.read(adminRepositoryProvider).createAssignment(
            projectId: widget.projectId,
            userId: user.id,
            role: 'contributor',
          );
      _invalidate();
      if (mounted) {
        AppSnackbar.showSuccess(
          context,
          '${user.fullName} was assigned successfully.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(context, error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _removeAssignment(ManagedAssignmentSummary assignment) async {
    setState(() => _isSaving = true);
    try {
      await ref.read(adminRepositoryProvider).removeAssignment(assignment.id);
      _invalidate();
      if (mounted) {
        AppSnackbar.showSuccess(context, 'Contributor unassigned successfully.');
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(context, error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  void _invalidate() {
    ref.invalidate(projectAssignmentsProvider(widget.projectId));
    ref.invalidate(managedAssignmentsProvider);
    ref.invalidate(managedUsersProvider);
    ref.invalidate(projectByIdProvider(widget.projectId));
    ref.invalidate(projectListProvider(ProjectViewScope.all));
  }

  List<ManagedUserSummary> _filterUsers(List<ManagedUserSummary> users) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      return users;
    }
    return users.where((user) {
      return user.fullName.toLowerCase().contains(query) ||
          user.email.toLowerCase().contains(query) ||
          (user.phone?.toLowerCase().contains(query) ?? false);
    }).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final projectAsync = ref.watch(projectByIdProvider(widget.projectId));
    final assignmentsAsync = ref.watch(projectAssignmentsProvider(widget.projectId));
    final usersAsync = ref.watch(managedUsersProvider);
    final requestsAsync = ref.watch(managedAssignmentsProvider);

    return projectAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Assignments unavailable',
        message: '$error',
        actionLabel: 'Back',
        onAction: () => Navigator.of(context).maybePop(),
      ),
      data: (project) {
        if (project == null) {
          return const AppEmptyState(
            icon: Icons.folder_off_outlined,
            title: 'Project unavailable',
            message: 'The selected project could not be loaded.',
          );
        }

        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final filterAction = OutlinedButton.icon(
                  onPressed: () => setState(() => _showFilters = !_showFilters),
                  icon: Icon(
                    _showFilters
                        ? Icons.filter_alt_off_outlined
                        : Icons.filter_alt_outlined,
                  ),
                  label: Text(_showFilters ? 'Hide filters' : 'Filter'),
                );
                if (constraints.maxWidth < 720) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionHeader(
                        title: 'Project Assignments',
                        subtitle:
                            'Assign and unassign contributors for ${project.name}. Project requests stay in Requests.',
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      filterAction,
                    ],
                  );
                }
                return SectionHeader(
                  title: 'Project Assignments',
                  subtitle:
                      'Assign and unassign contributors for ${project.name}. Project requests stay in Requests.',
                  trailing: filterAction,
                );
              },
            ),
            const SizedBox(height: AppSpacing.sm),
            requestsAsync.when(
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
              data: (requests) {
                final projectRequests = requests
                    .where((item) => item.projectId == widget.projectId)
                    .toList(growable: false);
                final pendingCount =
                    projectRequests.where((item) => item.status == 'pending').length;
                final rejectedCount =
                    projectRequests.where((item) => item.status == 'rejected').length;

                return AppCard(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.assignment_late_outlined),
                    title: const Text('Project request queue'),
                    subtitle: Text(
                      'Pending: $pendingCount • Rejected: $rejectedCount. Review project access requests from the Requests screen.',
                    ),
                    trailing: OutlinedButton(
                      onPressed: () => context.push(AppRoutes.contributorRequests),
                      child: const Text('Open Requests'),
                    ),
                  ),
                );
              },
            ),
            if (_showFilters) ...[
              const SizedBox(height: AppSpacing.sm),
              AppCard(
                child: SearchBar(
                  controller: _searchController,
                  hintText: 'Search contributors by name, email, or phone',
                  leading: const Icon(Icons.search),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            assignmentsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => AppEmptyState(
                icon: Icons.error_outline,
                title: 'Assigned contributors unavailable',
                message: '$error',
                actionLabel: 'Retry',
                onAction: () => ref.invalidate(
                  projectAssignmentsProvider(widget.projectId),
                ),
              ),
              data: (assignments) => usersAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => AppEmptyState(
                  icon: Icons.error_outline,
                  title: 'Contributors unavailable',
                  message: '$error',
                  actionLabel: 'Retry',
                  onAction: () => ref.invalidate(managedUsersProvider),
                ),
                data: (users) {
                  final assignedContributorIds = assignments
                      .map((assignment) => assignment.userId)
                      .toSet();
                  final approvedAssignments = assignments
                      .where((assignment) => assignment.status == 'approved')
                      .toList(growable: false);
                  final availableContributors = _filterUsers(
                    users
                        .where(
                          (user) =>
                              user.role == UserRole.contributor &&
                              user.isActive &&
                              !user.isBlocked &&
                              !assignedContributorIds.contains(user.id),
                        )
                        .toList(growable: false),
                  );

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _AssignmentSection(
                        title: 'Assigned contributors',
                        emptyTitle: 'No contributors assigned',
                        emptyMessage:
                            'Assigned contributors will appear here and can be unassigned at any time.',
                        children: approvedAssignments
                            .map(
                              (assignment) => _AssignedContributorCard(
                                assignment: assignment,
                                isSaving: _isSaving,
                                onUnassign: () => _removeAssignment(assignment),
                              ),
                            )
                            .toList(growable: false),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      _AssignmentSection(
                        title: 'Available contributors',
                        emptyTitle: 'No eligible contributors available',
                        emptyMessage:
                            'Active contributors who are not currently assigned to this project will appear here, including previously unassigned contributors.',
                        children: availableContributors
                            .map(
                              (user) => _AvailableContributorCard(
                                user: user,
                                isSaving: _isSaving,
                                onAssign: () => _assignContributor(user),
                              ),
                            )
                            .toList(growable: false),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AssignmentSection extends StatelessWidget {
  const _AssignmentSection({
    required this.title,
    required this.emptyTitle,
    required this.emptyMessage,
    required this.children,
  });

  final String title;
  final String emptyTitle;
  final String emptyMessage;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        if (children.isEmpty)
          AppEmptyState(
            icon: Icons.group_off_outlined,
            title: emptyTitle,
            message: emptyMessage,
          )
        else
          ...children.map(
            (child) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: child,
            ),
          ),
      ],
    );
  }
}

class _AssignedContributorCard extends StatelessWidget {
  const _AssignedContributorCard({
    required this.assignment,
    required this.isSaving,
    required this.onUnassign,
  });

  final ManagedAssignmentSummary assignment;
  final bool isSaving;
  final VoidCallback onUnassign;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            assignment.fullName,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(assignment.email, softWrap: true),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: const [
              Chip(label: Text('Contributor')),
              Chip(label: Text('Assigned')),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: isSaving ? null : onUnassign,
            icon: const Icon(Icons.person_remove_outlined),
            label: const Text('Unassign'),
          ),
        ],
      ),
    );
  }
}

class _AvailableContributorCard extends StatelessWidget {
  const _AvailableContributorCard({
    required this.user,
    required this.isSaving,
    required this.onAssign,
  });

  final ManagedUserSummary user;
  final bool isSaving;
  final VoidCallback onAssign;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            user.fullName,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(user.email, softWrap: true),
          if ((user.phone ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(user.phone!, softWrap: true),
          ],
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(label: Text(user.accountStateLabel)),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          FilledButton.icon(
            onPressed: isSaving ? null : onAssign,
            icon: const Icon(Icons.person_add_alt_1_outlined),
            label: const Text('Assign contributor'),
          ),
        ],
      ),
    );
  }
}
