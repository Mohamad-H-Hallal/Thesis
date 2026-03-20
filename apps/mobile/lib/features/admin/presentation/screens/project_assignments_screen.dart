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
              (user.role == UserRole.admin || user.role == UserRole.contributor),
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
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      final selected = eligibleUsers.firstWhere(
                        (user) => user.id == value,
                      );
                      setSheetState(() {
                        selectedUserId = value;
                        if (selected.role != UserRole.admin) {
                          selectedRole = 'contributor';
                        } else if (selectedRole != 'admin' &&
                            selectedRole != 'contributor') {
                          selectedRole = 'admin';
                        }
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
                      if (eligibleUsers
                              .firstWhere((user) => user.id == selectedUserId)
                              .role ==
                          UserRole.admin)
                        const ButtonSegment(
                          value: 'admin',
                          label: Text('Admin'),
                        ),
                    ],
                    selected: <String>{selectedRole},
                    onSelectionChanged: (selection) {
                      setSheetState(() {
                        selectedRole = selection.first;
                      });
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

    setState(() {
      _isSaving = true;
    });
    try {
      await ref.read(adminRepositoryProvider).createAssignment(
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
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _updateAssignmentStatus(
    ManagedAssignmentSummary assignment,
    String status,
  ) async {
    setState(() {
      _isSaving = true;
    });
    try {
      await ref.read(adminRepositoryProvider).updateAssignmentStatus(
        assignmentId: assignment.id,
        status: status,
      );
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
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _removeAssignment(ManagedAssignmentSummary assignment) async {
    setState(() {
      _isSaving = true;
    });
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
        setState(() {
          _isSaving = false;
        });
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
    final assignmentsAsync = ref.watch(projectAssignmentsProvider(widget.projectId));
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
                    title: 'Assignments',
                    subtitle:
                        'Manage admin and contributor access for ${project.name}.',
                  ),
                ),
                usersAsync.maybeWhen(
                  data: (users) => AppButton(
                    label: 'Assign user',
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
                onAction: () =>
                    ref.invalidate(projectAssignmentsProvider(widget.projectId)),
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

                return Column(
                  children: assignments
                      .map(
                        (assignment) => Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: AppCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  assignment.fullName,
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                                const SizedBox(height: AppSpacing.xs),
                                Text(assignment.email),
                                const SizedBox(height: AppSpacing.sm),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    Chip(label: Text(assignment.role)),
                                    Chip(label: Text(assignment.status)),
                                  ],
                                ),
                                const SizedBox(height: AppSpacing.sm),
                                Wrap(
                                  spacing: AppSpacing.sm,
                                  runSpacing: AppSpacing.sm,
                                  children: [
                                    if (assignment.status == 'pending')
                                      FilledButton.tonal(
                                        onPressed: _isSaving
                                            ? null
                                            : () => _updateAssignmentStatus(
                                                  assignment,
                                                  'approved',
                                                ),
                                        child: const Text('Approve'),
                                      ),
                                    if (assignment.status == 'pending')
                                      FilledButton.tonal(
                                        onPressed: _isSaving
                                            ? null
                                            : () => _updateAssignmentStatus(
                                                  assignment,
                                                  'rejected',
                                                ),
                                        child: const Text('Reject'),
                                      ),
                                    OutlinedButton(
                                      onPressed: _isSaving
                                          ? null
                                          : () => _removeAssignment(assignment),
                                      child: const Text('Remove'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                      .toList(growable: false),
                );
              },
            ),
          ],
        );
      },
    );
  }
}
