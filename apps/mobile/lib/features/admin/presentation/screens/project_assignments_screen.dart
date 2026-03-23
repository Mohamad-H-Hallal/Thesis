import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_button.dart';
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

  Future<void> _assignUser(List<ManagedUserSummary> users) async {
    final eligibleUsers = users
        .where(
          (user) =>
              user.isActive &&
              (user.role == UserRole.admin ||
                  user.role == UserRole.contributor),
        )
        .toList(growable: false);
    if (eligibleUsers.isEmpty) {
      AppSnackbar.showError(
        context,
        'No active admin or contributor users are available for assignment.',
      );
      return;
    }

    String selectedUserId = eligibleUsers.first.id;
    String selectedRole = eligibleUsers.first.role == UserRole.admin
        ? 'admin'
        : 'contributor';

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: AppSpacing.md,
            right: AppSpacing.md,
            top: AppSpacing.md,
            bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.md,
          ),
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              final selectedUser = eligibleUsers.firstWhere(
                (user) => user.id == selectedUserId,
              );
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Assign user',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  DropdownButtonFormField<String>(
                    initialValue: selectedUserId,
                    decoration: const InputDecoration(labelText: 'User'),
                    items: eligibleUsers
                        .map(
                          (user) => DropdownMenuItem(
                            value: user.id,
                            child: Text(
                              '${user.fullName} • ${user.roleLabel}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      final user = eligibleUsers.firstWhere(
                        (item) => item.id == value,
                      );
                      setSheetState(() {
                        selectedUserId = value;
                        selectedRole = user.role == UserRole.admin
                            ? 'admin'
                            : 'contributor';
                      });
                    },
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  SegmentedButton<String>(
                    segments: [
                      const ButtonSegment(
                        value: 'contributor',
                        label: Text('Contributor'),
                      ),
                      if (selectedUser.role == UserRole.admin)
                        const ButtonSegment(
                          value: 'admin',
                          label: Text('Admin'),
                        ),
                    ],
                    selected: <String>{selectedRole},
                    onSelectionChanged: (selection) {
                      setSheetState(() => selectedRole = selection.first);
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        child: const Text('Assign'),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        );
      },
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
            userId: selectedUserId,
            role: selectedRole,
          );
      _invalidate();
      if (mounted) {
        AppSnackbar.showSuccess(context, 'Assignment created successfully.');
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

  Future<void> _updateAssignmentStatus(
    ManagedAssignmentSummary assignment,
    String status,
  ) async {
    setState(() => _isSaving = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .updateAssignmentStatus(assignmentId: assignment.id, status: status);
      _invalidate();
      if (mounted) {
        AppSnackbar.showSuccess(context, 'Assignment $status successfully.');
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
        AppSnackbar.showSuccess(context, 'Assignment removed successfully.');
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
    ref.invalidate(projectByIdProvider(widget.projectId));
    ref.invalidate(projectListProvider(ProjectViewScope.all));
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
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: SectionHeader(
                    title: 'Project Assignments',
                    subtitle:
                        'Manage admin and contributor access for ${project.name}.',
                  ),
                ),
                usersAsync.maybeWhen(
                  data: (users) => AppButton(
                    label: 'Assign User',
                    icon: Icons.person_add_alt_1_outlined,
                    expand: false,
                    isLoading: _isSaving,
                    onPressed: _isSaving ? null : () => _assignUser(users),
                  ),
                  orElse: () => const SizedBox.shrink(),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            assignmentsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => AppEmptyState(
                icon: Icons.error_outline,
                title: 'Assignment list unavailable',
                message: '$error',
                actionLabel: 'Retry',
                onAction: () => ref.invalidate(
                  projectAssignmentsProvider(widget.projectId),
                ),
              ),
              data: (assignments) {
                if (assignments.isEmpty) {
                  return const AppEmptyState(
                    icon: Icons.assignment_late_outlined,
                    title: 'No assignments yet',
                    message:
                        'Assign admins or contributors to this project to enable delivery.',
                  );
                }

                final approved = assignments
                    .where((item) => item.status == 'approved')
                    .toList(growable: false);
                final pending = assignments
                    .where((item) => item.status == 'pending')
                    .toList(growable: false);
                final rejected = assignments
                    .where((item) => item.status == 'rejected')
                    .toList(growable: false);

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (pending.isNotEmpty)
                      _AssignmentSection(
                        title: 'Pending requests',
                        children: pending
                            .map((assignment) => _AssignmentCard(
                                  assignment: assignment,
                                  isSaving: _isSaving,
                                  onApprove: () => _updateAssignmentStatus(
                                    assignment,
                                    'approved',
                                  ),
                                  onReject: () => _updateAssignmentStatus(
                                    assignment,
                                    'rejected',
                                  ),
                                  onRemove: () => _removeAssignment(assignment),
                                ))
                            .toList(growable: false),
                      ),
                    if (approved.isNotEmpty)
                      _AssignmentSection(
                        title: 'Approved assignments',
                        children: approved
                            .map((assignment) => _AssignmentCard(
                                  assignment: assignment,
                                  isSaving: _isSaving,
                                  onRemove: () => _removeAssignment(assignment),
                                ))
                            .toList(growable: false),
                      ),
                    if (rejected.isNotEmpty)
                      _AssignmentSection(
                        title: 'Rejected requests',
                        children: rejected
                            .map((assignment) => _AssignmentCard(
                                  assignment: assignment,
                                  isSaving: _isSaving,
                                  onApprove: () => _updateAssignmentStatus(
                                    assignment,
                                    'approved',
                                  ),
                                  onRemove: () => _removeAssignment(assignment),
                                ))
                            .toList(growable: false),
                      ),
                  ],
                );
              },
            ),
          ],
        );
      },
    );
  }
}

class _AssignmentSection extends StatelessWidget {
  const _AssignmentSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          ...children.map(
            (child) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

class _AssignmentCard extends StatelessWidget {
  const _AssignmentCard({
    required this.assignment,
    required this.isSaving,
    this.onApprove,
    this.onReject,
    this.onRemove,
  });

  final ManagedAssignmentSummary assignment;
  final bool isSaving;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;
  final VoidCallback? onRemove;

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
          Text(assignment.email),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(label: Text('Role: ${assignment.role}')),
              Chip(label: Text('Status: ${assignment.status}')),
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
                  child: const Text('Reject'),
                ),
              if (onApprove != null)
                FilledButton(
                  onPressed: isSaving ? null : onApprove,
                  child: Text(
                    assignment.status == 'rejected' ? 'Re-approve' : 'Approve',
                  ),
                ),
              if (onRemove != null)
                OutlinedButton.icon(
                  onPressed: isSaving ? null : onRemove,
                  icon: const Icon(Icons.delete_outline),
                  label: Text(
                    assignment.status == 'approved' ? 'Unassign' : 'Remove',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
