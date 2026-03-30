import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/animated_reveal.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../../auth/domain/auth_models.dart';
import '../../domain/project.dart';

class ProjectDetailsScreen extends ConsumerStatefulWidget {
  const ProjectDetailsScreen({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<ProjectDetailsScreen> createState() =>
      _ProjectDetailsScreenState();
}

class _ProjectDetailsScreenState extends ConsumerState<ProjectDetailsScreen> {
  bool _updatingVisibility = false;
  bool _requestingAccess = false;

  void _showCollectionUnavailableMessage(String status) {
    final normalized = status.trim().toLowerCase();
    final message = switch (normalized) {
      'paused' =>
        'This project is paused. Feature collection is unavailable until the project returns to active status.',
      'completed' =>
        'This project is completed. New features cannot be added unless an admin reopens the project.',
      'archived' =>
        'This project is archived. Feature collection is unavailable.',
      'draft' =>
        'This project is still in draft status. Feature collection is unavailable until the project becomes active.',
      _ => 'Feature collection is unavailable for this project right now.',
    };
    AppSnackbar.showError(context, message);
  }

  Future<void> _toggleViewerVisibility(bool value) async {
    setState(() {
      _updatingVisibility = true;
    });

    try {
      await ref
          .read(projectsRepositoryProvider)
          .updateViewerVisibility(
            projectId: widget.projectId,
            visibleToViewers: value,
          );
      ref.invalidate(projectsProvider);
      ref.invalidate(projectListProvider(ProjectViewScope.public));
      ref.invalidate(projectListProvider(ProjectViewScope.assigned));
      ref.invalidate(projectListProvider(ProjectViewScope.all));
      ref.invalidate(projectByIdProvider(widget.projectId));
      if (mounted) {
        AppSnackbar.showSuccess(
          context,
          value
              ? 'Project is now visible to viewers.'
              : 'Project is now restricted to admins and contributors.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(context, error.toString());
      }
    } finally {
      if (mounted) {
        setState(() {
          _updatingVisibility = false;
        });
      }
    }
  }

  Future<void> _requestProjectAccess() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Request contributor access'),
        content: const Text(
          'Send a contributor access request for this project?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Send request'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    setState(() => _requestingAccess = true);
    try {
      await ref
          .read(projectsRepositoryProvider)
          .requestProjectAccess(projectId: widget.projectId);
      ref.invalidate(projectByIdProvider(widget.projectId));
      ref.invalidate(projectListProvider(ProjectViewScope.public));
      ref.invalidate(projectListProvider(ProjectViewScope.assigned));
      ref.invalidate(managedAssignmentsProvider);
      if (mounted) {
        AppSnackbar.showSuccess(
          context,
          'Project access request submitted successfully.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(context, error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _requestingAccess = false);
      }
    }
  }

  Future<void> _cancelProjectAccessRequest() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel project request'),
        content: const Text(
          'Cancel your pending contributor access request for this project?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep request'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel request'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    setState(() => _requestingAccess = true);
    try {
      await ref
          .read(projectsRepositoryProvider)
          .cancelProjectAccessRequest(projectId: widget.projectId);
      ref.invalidate(projectByIdProvider(widget.projectId));
      ref.invalidate(projectListProvider(ProjectViewScope.public));
      ref.invalidate(projectListProvider(ProjectViewScope.assigned));
      ref.invalidate(managedAssignmentsProvider);
      if (mounted) {
        AppSnackbar.showSuccess(
          context,
          'Project access request cancelled successfully.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(context, error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _requestingAccess = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authControllerProvider).session;
    final role = session?.user.role ?? UserRole.viewer;
    final projectAsync = ref.watch(projectByIdProvider(widget.projectId));

    return projectAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Could not load project',
        message: 'Error: $error',
        actionLabel: 'Back',
        onAction: () => Navigator.of(context).maybePop(),
      ),
      data: (project) {
        if (project == null) {
          return const AppEmptyState(
            icon: Icons.search_off,
            title: 'Project not found',
            message:
                'The requested project is unavailable or no longer assigned.',
          );
        }

        final hasContributorAssignment =
            role == UserRole.contributor &&
            project.hasApprovedCurrentUserAssignment;
        final isPaused = project.status == 'paused';
        final canCollectFeatures =
            role == UserRole.contributor &&
            hasContributorAssignment &&
            project.status == 'active';
        final contributorRequestStatus = project.currentUserAssignmentStatus;
        final canRequestAccess =
            role == UserRole.contributor &&
            contributorRequestStatus == null &&
            !project.hasApprovedCurrentUserAssignment &&
            project.status == 'active';

        return ListView(
          children: [
            const SectionHeader(
              title: 'Project Details',
              subtitle: 'Operational summary and field actions',
            ),
            const SizedBox(height: AppSpacing.md),
            AnimatedReveal(
              child: AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      project.name,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(project.description),
                    if ((project.objectives ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'Objectives',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(project.objectives!, softWrap: true),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        StatusChip(status: project.status),
                        Chip(label: Text(project.category)),
                        if (project.startDate != null || project.endDate != null)
                          Chip(
                            label: Text(
                              'Schedule ${_formatDate(project.startDate)} -> ${_formatDate(project.endDate)}',
                            ),
                          ),
                        Chip(
                          label: Text(
                            project.visibleToViewers
                                ? 'Viewer visible'
                                : 'Contributor only',
                          ),
                        ),
                        Chip(
                          label: Text(
                            'Pending reviews: ${project.pendingReviews}',
                          ),
                        ),
                        Chip(
                          label: Text(
                            project.requiresPhotos
                                ? 'Photos ${project.minPhotos}-${project.maxPhotos}'
                                : 'Photos optional',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (role == UserRole.admin) ...[
              const SizedBox(height: AppSpacing.sm),
              AnimatedReveal(
                delay: const Duration(milliseconds: 100),
                child: AppCard(
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: project.visibleToViewers,
                    onChanged: _updatingVisibility
                        ? null
                        : (value) => _toggleViewerVisibility(value),
                    title: const Text('Visible to viewers'),
                    subtitle: Text(
                      project.visibleToViewers
                          ? 'Viewers can see this project while it stays active or completed.'
                          : 'Only admins and assigned contributors can access this project.',
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            AnimatedReveal(
              delay: const Duration(milliseconds: 80),
              child: AppCard(
                child: Wrap(
                  spacing: AppSpacing.md,
                  runSpacing: AppSpacing.sm,
                  children: [
                    _MetaTile(
                      label: 'Assigned collectors',
                      value: '${project.assignedCollectors}',
                      icon: Icons.groups_outlined,
                    ),
                    _MetaTile(
                      label: 'Queue',
                      value: '${project.pendingReviews}',
                      icon: Icons.pending_actions_outlined,
                    ),
                    if (role == UserRole.viewer ||
                        (role == UserRole.contributor &&
                            !hasContributorAssignment))
                      const _MetaTile(
                        label: 'Access',
                        value: 'Read only',
                        icon: Icons.visibility_outlined,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            AnimatedReveal(
              delay: const Duration(milliseconds: 130),
              child: Wrap(
                spacing: 14,
                runSpacing: 12,
                children: [
                  if (role != UserRole.viewer)
                    FilledButton.icon(
                      onPressed: () =>
                          context.push(AppRoutes.mapForProject(project.id)),
                      icon: const Icon(Icons.map_outlined),
                      label: const Text('Open Map'),
                    ),
                  if (role == UserRole.contributor && hasContributorAssignment)
                    FilledButton.icon(
                      onPressed: () {
                        if (canCollectFeatures) {
                          context.push(AppRoutes.addFeatureForProject(project.id));
                          return;
                        }
                        _showCollectionUnavailableMessage(project.status);
                      },
                      icon: const Icon(Icons.add_location_alt_outlined),
                      label: const Text('New Feature'),
                    ),
                  if (canRequestAccess)
                    FilledButton.tonalIcon(
                      onPressed: _requestingAccess ? null : _requestProjectAccess,
                      icon: const Icon(Icons.how_to_reg_outlined),
                      label: Text(
                        _requestingAccess ? 'Submitting...' : 'Request Access',
                      ),
                    ),
                  if (role == UserRole.contributor &&
                      contributorRequestStatus ==
                          ProjectAssignmentStatus.pending)
                    OutlinedButton.icon(
                      onPressed: _requestingAccess
                          ? null
                          : _cancelProjectAccessRequest,
                      icon: const Icon(Icons.cancel_outlined),
                      label: const Text('Cancel Request'),
                    ),
                ],
              ),
            ),
            if (role == UserRole.admin)
              AnimatedReveal(
                delay: const Duration(milliseconds: 160),
                child: Wrap(
                  spacing: 14,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: () =>
                          context.push(AppRoutes.projectEdit(project.id)),
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit Project'),
                    ),
                    FilledButton.icon(
                      onPressed: () => context.push(
                        AppRoutes.projectAssignments(project.id),
                      ),
                      icon: const Icon(Icons.assignment_outlined),
                      label: const Text('Assignments'),
                    ),
                    FilledButton.icon(
                      onPressed: () => context.go(AppRoutes.reviewQueue),
                      icon: const Icon(Icons.rate_review_outlined),
                      label: const Text('Review Queue'),
                    ),
                    FilledButton.icon(
                      onPressed: () => context.go(AppRoutes.exports),
                      icon: const Icon(Icons.file_download_outlined),
                      label: const Text('Exports'),
                    ),
                  ],
                ),
              ),
            if (role == UserRole.contributor && !hasContributorAssignment)
              AnimatedReveal(
                delay: Duration(milliseconds: 190),
                child: AppCard(
                  child: ListTile(
                    leading: Icon(
                      contributorRequestStatus == ProjectAssignmentStatus.rejected
                          ? Icons.cancel_outlined
                          : contributorRequestStatus == ProjectAssignmentStatus.pending
                              ? Icons.hourglass_bottom
                              : Icons.lock_outline,
                    ),
                    title: Text(
                      contributorRequestStatus == ProjectAssignmentStatus.rejected
                          ? 'Project access was rejected'
                          : contributorRequestStatus == ProjectAssignmentStatus.pending
                              ? 'Project access pending'
                              : 'Assignment required',
                    ),
                    subtitle: Text(
                      contributorRequestStatus == ProjectAssignmentStatus.rejected
                          ? 'An admin rejected your previous request. The request stays visible in Requests until it is re-approved.'
                          : contributorRequestStatus == ProjectAssignmentStatus.pending
                              ? 'Your access request is waiting for admin approval.'
                              : project.status != 'active'
                                  ? 'This project is not accepting contributor access requests while it is ${project.status}.'
                              : 'This public project is visible to you, but collection actions stay disabled until an admin approves your assignment.',
                    ),
                  ),
                ),
              ),
            if (isPaused)
              const AnimatedReveal(
                delay: Duration(milliseconds: 180),
                child: AppCard(
                  child: ListTile(
                    leading: Icon(Icons.pause_circle_outline),
                    title: Text('Project paused'),
                    subtitle: Text(
                      'The map and project details remain viewable, but feature collection and submission are disabled until the project returns to active status.',
                    ),
                  ),
                ),
              ),
            if (role == UserRole.viewer)
              const AnimatedReveal(
                delay: Duration(milliseconds: 190),
                child: AppCard(
                  child: ListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text('Viewer access'),
                    subtitle: Text(
                      'This project is visible in read-only mode. Editing and submission actions are disabled.',
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  String _formatDate(DateTime? value) {
    if (value == null) {
      return 'Not set';
    }
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }
}

class _MetaTile extends StatelessWidget {
  const _MetaTile({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 180),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        borderRadius: AppRadii.md,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodySmall),
                Text(value, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
