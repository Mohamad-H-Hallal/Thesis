import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../../../core/utils/lebanese_phone.dart';
import '../../../auth/domain/auth_models.dart';
import '../../domain/admin_models.dart';

enum _AssignmentSection { assigned, available, requests }
enum _ProjectRequestTab { pending, rejected }

class ProjectAssignmentsScreen extends ConsumerStatefulWidget {
  const ProjectAssignmentsScreen({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<ProjectAssignmentsScreen> createState() =>
      _ProjectAssignmentsScreenState();
}

class _ProjectAssignmentsScreenState
    extends ConsumerState<ProjectAssignmentsScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _isSaving = false;
  _AssignmentSection _selectedSection = _AssignmentSection.assigned;
  _ProjectRequestTab _selectedRequestTab = _ProjectRequestTab.pending;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _assignContributor(ManagedUserSummary user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Assign contributor'),
        content: Text(
          'Assign ${user.fullName} to this project as a contributor?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Assign'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .createAssignment(
            projectId: widget.projectId,
            userId: user.id,
            role: 'contributor',
          );
      bumpWorkflowRefresh(ref);
      if (mounted) {
        AppSnackbar.showSuccess(
          context,
          '${user.fullName} was assigned successfully.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to assign this contributor right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _removeAssignment(ManagedAssignmentSummary assignment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unassign contributor'),
        content: Text(
          'Remove ${assignment.fullName} from this project? They can be reassigned later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Unassign'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      await ref.read(adminRepositoryProvider).removeAssignment(assignment.id);
      bumpWorkflowRefresh(ref);
      if (mounted) {
        AppSnackbar.showSuccess(
          context,
          'Contributor unassigned successfully.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to update this assignment right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _updateAssignmentRequest(
    ManagedAssignmentSummary assignment, {
    required String status,
  }) async {
    final isApprove = status == 'approved';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          isApprove ? 'Approve project request' : 'Reject project request',
        ),
        content: Text(
          isApprove
              ? 'Approve ${assignment.fullName} for this project?'
              : 'Reject ${assignment.fullName} for this project? They will remain outside this project until an admin re-accepts the request.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(isApprove ? 'Approve' : 'Reject'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .updateAssignmentStatus(assignmentId: assignment.id, status: status);
      bumpWorkflowRefresh(ref);
      if (mounted) {
        AppSnackbar.showSuccess(
          context,
          isApprove
              ? 'Project request approved successfully.'
              : 'Project request rejected successfully.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to update this project request right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  bool _matchesQuery(Iterable<String?> values) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      return true;
    }
    return values.any(
      (value) => (value ?? '').trim().toLowerCase().contains(query),
    );
  }

  @override
  Widget build(BuildContext context) {
    final projectAsync = ref.watch(projectByIdProvider(widget.projectId));
    final assignmentsAsync = ref.watch(
      projectAssignmentsProvider(widget.projectId),
    );
    final usersAsync = ref.watch(managedUsersProvider);

    return projectAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Assignments unavailable',
        message: userFacingErrorMessage(
          error,
          fallback:
              'Unable to load project assignments right now. Please try again.',
        ),
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

        return assignmentsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => AppEmptyState(
            icon: Icons.error_outline,
            title: 'Assignment data unavailable',
            message: userFacingErrorMessage(
              error,
              fallback:
                  'Unable to load project assignments right now. Please try again.',
            ),
            actionLabel: 'Retry',
            onAction: () =>
                ref.invalidate(projectAssignmentsProvider(widget.projectId)),
          ),
          data: (assignments) => usersAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => AppEmptyState(
              icon: Icons.error_outline,
              title: 'Available contributors unavailable',
              message: userFacingErrorMessage(
                error,
                fallback:
                    'Unable to load project assignments right now. Please try again.',
              ),
              actionLabel: 'Retry',
              onAction: () => ref.invalidate(managedUsersProvider),
            ),
            data: (users) {
              final isViewOnlyProject =
                  project.status == 'completed' || project.status == 'archived';
              final effectiveSection = isViewOnlyProject
                  ? _AssignmentSection.assigned
                  : _selectedSection;
              final approvedAssignments = assignments
                  .where((assignment) => assignment.status == 'approved')
                  .where(
                    (assignment) => _matchesQuery(<String?>[
                      assignment.fullName,
                      assignment.email,
                    ]),
                  )
                  .toList(growable: false);
              final pendingRequests = assignments
                  .where((assignment) => assignment.status == 'pending')
                  .where(
                    (assignment) => _matchesQuery(<String?>[
                      assignment.fullName,
                      assignment.email,
                    ]),
                  )
                  .toList(growable: false);
              final rejectedRequests = assignments
                  .where((assignment) => assignment.status == 'rejected')
                  .where(
                    (assignment) => _matchesQuery(<String?>[
                      assignment.fullName,
                      assignment.email,
                    ]),
                  )
                  .toList(growable: false);
              final reservedContributorIds = assignments
                  .where((assignment) => assignment.status != 'rejected')
                  .map((assignment) => assignment.userId)
                  .toSet();
              final availableContributors = users
                  .where((user) => user.role == UserRole.contributor)
                  .where((user) => user.isActive && !user.isBlocked)
                  .where((user) => user.accountState == UserAccountState.active)
                  .where((user) => !reservedContributorIds.contains(user.id))
                  .where(
                    (user) => _matchesQuery(<String?>[
                      user.fullName,
                      user.email,
                      user.phone,
                    ]),
                  )
                  .toList(growable: false);
              final effectiveRequestTab =
                  _selectedRequestTab == _ProjectRequestTab.pending
                  ? (pendingRequests.isEmpty && rejectedRequests.isNotEmpty
                        ? _ProjectRequestTab.rejected
                        : _ProjectRequestTab.pending)
                  : (rejectedRequests.isEmpty && pendingRequests.isNotEmpty
                        ? _ProjectRequestTab.pending
                        : _ProjectRequestTab.rejected);

              return ListView(
                children: [
                  SectionHeader(
                    title: 'Project Assignments',
                    subtitle: isViewOnlyProject
                        ? 'Assignments are view-only for ${project.status} projects.'
                        : 'Manage contributor assignments and project-specific access requests for ${project.name}.',
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    project.name,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            StatusChip(status: project.status),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Chip(label: Text(project.category)),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SearchBar(
                          controller: _searchController,
                          hintText: isViewOnlyProject
                              ? 'Search assigned contributors'
                              : 'Search contributors and project requests',
                          leading: const Icon(Icons.search),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        if (isViewOnlyProject)
                          Text(
                            'Completed and archived projects keep assignment history visible, but assignment changes are disabled.',
                            style: Theme.of(context).textTheme.bodySmall,
                          )
                        else
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _AssignmentSection.values
                                .map((section) {
                                  final (label, count) = switch (section) {
                                    _AssignmentSection.assigned => (
                                      'Assigned',
                                      approvedAssignments.length,
                                    ),
                                    _AssignmentSection.available => (
                                      'Available',
                                      availableContributors.length,
                                    ),
                                    _AssignmentSection.requests => (
                                      'Requests',
                                      pendingRequests.length +
                                          rejectedRequests.length,
                                    ),
                                  };
                                  return ChoiceChip(
                                    label: Text('$label ($count)'),
                                    selected: effectiveSection == section,
                                    onSelected: (_) => setState(
                                      () => _selectedSection = section,
                                    ),
                                  );
                                })
                                .toList(growable: false),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  switch (effectiveSection) {
                    _AssignmentSection.assigned => _AssignmentListSection(
                      title: 'Assigned Contributors',
                      emptyTitle: 'No contributors assigned',
                      emptyMessage: isViewOnlyProject
                          ? 'Approved contributors assigned to this project remain visible here for reference.'
                          : 'Approved contributors assigned to this project appear here and can be unassigned at any time.',
                      children: approvedAssignments
                          .map(
                            (assignment) => Padding(
                              padding: const EdgeInsets.only(
                                bottom: AppSpacing.sm,
                              ),
                              child: _AssignedContributorCard(
                                assignment: assignment,
                                isSaving: _isSaving,
                                isViewOnly: isViewOnlyProject,
                                onUnassign: () => _removeAssignment(assignment),
                              ),
                            ),
                          )
                          .toList(growable: false),
                    ),
                    _AssignmentSection.available => _AssignmentListSection(
                      title: 'Available Approved Contributors',
                      emptyTitle: 'No eligible contributors available',
                      emptyMessage:
                          'Only active approved contributors who are not currently assigned to this project appear here.',
                      children: availableContributors
                          .map(
                            (user) => Padding(
                              padding: const EdgeInsets.only(
                                bottom: AppSpacing.sm,
                              ),
                              child: _AvailableContributorCard(
                                user: user,
                                isSaving: _isSaving,
                                onAssign: () => _assignContributor(user),
                              ),
                            ),
                          )
                          .toList(growable: false),
                    ),
                    _AssignmentSection.requests => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Project Request States',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  ChoiceChip(
                                    label: Text(
                                      'Pending (${pendingRequests.length})',
                                    ),
                                    selected:
                                        effectiveRequestTab ==
                                        _ProjectRequestTab.pending,
                                    onSelected: (_) => setState(
                                      () => _selectedRequestTab =
                                          _ProjectRequestTab.pending,
                                    ),
                                  ),
                                  ChoiceChip(
                                    label: Text(
                                      'Rejected (${rejectedRequests.length})',
                                    ),
                                    selected:
                                        effectiveRequestTab ==
                                        _ProjectRequestTab.rejected,
                                    onSelected: (_) => setState(
                                      () => _selectedRequestTab =
                                          _ProjectRequestTab.rejected,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        if (effectiveRequestTab == _ProjectRequestTab.pending)
                          _AssignmentListSection(
                            title: 'Pending Project Requests',
                            emptyTitle: 'No pending project requests',
                            emptyMessage:
                                'Contributor self-service requests for this project appear here until an admin approves or rejects them.',
                            children: pendingRequests
                                .map(
                                  (assignment) => Padding(
                                    padding: const EdgeInsets.only(
                                      bottom: AppSpacing.sm,
                                    ),
                                    child: _PendingRequestCard(
                                      assignment: assignment,
                                      isSaving: _isSaving,
                                      approveLabel: 'Approve',
                                      rejectLabel: 'Reject',
                                      onApprove: () => _updateAssignmentRequest(
                                        assignment,
                                        status: 'approved',
                                      ),
                                      onReject: () => _updateAssignmentRequest(
                                        assignment,
                                        status: 'rejected',
                                      ),
                                    ),
                                  ),
                                )
                                .toList(growable: false),
                          )
                        else
                          _AssignmentListSection(
                            title: 'Rejected Project Requests',
                            emptyTitle: 'No rejected project requests',
                            emptyMessage:
                                'Rejected project requests stay here so admins can re-approve them later if needed.',
                            children: rejectedRequests
                                .map(
                                  (assignment) => Padding(
                                    padding: const EdgeInsets.only(
                                      bottom: AppSpacing.sm,
                                    ),
                                    child: _PendingRequestCard(
                                      assignment: assignment,
                                      isSaving: _isSaving,
                                      approveLabel: 'Re-accept',
                                      rejectLabel: 'Keep rejected',
                                      onApprove: () => _updateAssignmentRequest(
                                        assignment,
                                        status: 'approved',
                                      ),
                                      onReject: null,
                                    ),
                                  ),
                                )
                                .toList(growable: false),
                          ),
                      ],
                    ),
                  },
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _AssignmentListSection extends StatelessWidget {
  const _AssignmentListSection({
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
          ...children,
      ],
    );
  }
}

class _AssignedContributorCard extends StatelessWidget {
  const _AssignedContributorCard({
    required this.assignment,
    required this.isSaving,
    required this.isViewOnly,
    required this.onUnassign,
  });

  final ManagedAssignmentSummary assignment;
  final bool isSaving;
  final bool isViewOnly;
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
          if (!isViewOnly) ...[
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: isSaving ? null : onUnassign,
                icon: const Icon(Icons.person_remove_outlined),
                label: const Text('Unassign'),
              ),
            ),
          ],
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
          Text(user.fullName, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(user.email, softWrap: true),
          if ((user.phone ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(LebanesePhone.format(user.phone), softWrap: true),
          ],
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [Chip(label: Text(user.accountStateLabel))],
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: isSaving ? null : onAssign,
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: const Text('Assign contributor'),
            ),
          ),
        ],
      ),
    );
  }
}

class _PendingRequestCard extends StatelessWidget {
  const _PendingRequestCard({
    required this.assignment,
    required this.isSaving,
    required this.approveLabel,
    required this.rejectLabel,
    required this.onApprove,
    this.onReject,
  });

  final ManagedAssignmentSummary assignment;
  final bool isSaving;
  final String approveLabel;
  final String rejectLabel;
  final VoidCallback onApprove;
  final VoidCallback? onReject;

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
            children: [
              const Chip(label: Text('Contributor')),
              Chip(label: Text('Request ${assignment.status}')),
              if (assignment.projectStatus.trim().isNotEmpty)
                Chip(label: Text('Project ${assignment.projectStatus}')),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (onReject != null)
                FilledButton.tonal(
                  onPressed: isSaving ? null : onReject,
                  child: Text(rejectLabel),
                ),
              FilledButton(
                onPressed: isSaving ? null : onApprove,
                child: Text(approveLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
