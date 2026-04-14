import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/animated_reveal.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../../auth/domain/auth_models.dart';
import '../../../map/presentation/widgets/project_quick_map_card.dart';
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
      bumpWorkflowRefresh(ref);
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
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to update project visibility right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _updatingVisibility = false;
        });
      }
    }
  }

  Future<void> _toggleContributorVisibility(bool value) async {
    setState(() {
      _updatingVisibility = true;
    });

    try {
      await ref
          .read(projectsRepositoryProvider)
          .updateContributorVisibility(
            projectId: widget.projectId,
            visibleToContributors: value,
          );
      bumpWorkflowRefresh(ref);
      if (mounted) {
        AppSnackbar.showSuccess(
          context,
          value
              ? 'Project is now visible to contributors.'
              : 'Project is now hidden from contributor discovery.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to update contributor visibility right now.',
          ),
        );
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
      bumpWorkflowRefresh(ref);
      if (mounted) {
        AppSnackbar.showSuccess(
          context,
          'Project access request submitted successfully.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to request contributor access right now.',
          ),
        );
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
      bumpWorkflowRefresh(ref);
      if (mounted) {
        AppSnackbar.showSuccess(
          context,
          'Project access request cancelled successfully.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to cancel this project request right now.',
          ),
        );
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
        message: userFacingErrorMessage(
          error,
          fallback:
              'Unable to load project details right now. Please try again.',
        ),
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

        final isUserRole = role == UserRole.viewer;
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
          padding: EdgeInsets.only(
            bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.xl,
          ),
          children: [
            const SectionHeader(
              title: 'Project Details',
              subtitle: 'Field summary, status, and map access',
            ),
            const SizedBox(height: AppSpacing.md),
            AnimatedReveal(
              child: AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Project summary',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      project.name,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        StatusChip(status: project.status),
                        Chip(label: Text(project.category)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(project.description),
                    if ((project.objectives ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        'Objectives',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(project.objectives!, softWrap: true),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (project.startDate != null ||
                            project.endDate != null)
                          Chip(
                            label: Text(
                              'Schedule ${_formatDate(project.startDate)} -> ${_formatDate(project.endDate)}',
                            ),
                          ),
                        if (!isUserRole)
                          Chip(label: Text(project.visibilitySummaryLabel)),
                        if (!isUserRole)
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
                  child: Column(
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: project.visibleToViewers,
                        onChanged: _updatingVisibility
                            ? null
                            : (value) => _toggleViewerVisibility(value),
                        title: const Text('Visible to viewers'),
                        subtitle: Text(
                          project.visibleToViewers
                              ? 'Shows in the viewer project list.'
                              : 'Hidden from viewers.',
                        ),
                      ),
                      const Divider(height: 1),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: project.visibleToContributors,
                        onChanged: _updatingVisibility
                            ? null
                            : (value) => _toggleContributorVisibility(value),
                        title: const Text('Visible to contributors'),
                        subtitle: Text(
                          project.visibleToContributors
                              ? 'Shows in the contributor project list.'
                              : 'Only assigned contributors can reach this project.',
                        ),
                      ),
                    ],
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
                      label: 'Approved features',
                      value: '${project.approvedFeatures}',
                      icon: Icons.check_circle_outline,
                    ),
                    if (!isUserRole)
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
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    FilledButton.icon(
                      onPressed: () =>
                          context.push(AppRoutes.mapForProject(project.id)),
                      icon: const Icon(Icons.map_outlined),
                      label: const Text('Open Map'),
                    ),
                    if (role == UserRole.contributor &&
                        hasContributorAssignment)
                      FilledButton.icon(
                        onPressed: () {
                          if (canCollectFeatures) {
                            context.push(
                              AppRoutes.mapForProject(
                                project.id,
                                startCapture: true,
                              ),
                            );
                            return;
                          }
                          _showCollectionUnavailableMessage(project.status);
                        },
                        icon: const Icon(Icons.add_location_alt_outlined),
                        label: const Text('New Feature'),
                      ),
                    if (canRequestAccess)
                      FilledButton.tonalIcon(
                        onPressed: _requestingAccess
                            ? null
                            : _requestProjectAccess,
                        icon: const Icon(Icons.how_to_reg_outlined),
                        label: Text(
                          _requestingAccess
                              ? 'Submitting...'
                              : 'Request Access',
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
            ),
            const SizedBox(height: AppSpacing.lg),
            AnimatedReveal(
              delay: const Duration(milliseconds: 150),
              child: const SectionHeader(
                title: 'Map Preview',
                subtitle:
                    'Check the Lebanon workspace before opening the full project map.',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            AnimatedReveal(
              delay: const Duration(milliseconds: 160),
              child: ProjectQuickMapCard(
                projectId: project.id,
                onOpenFullscreen: () =>
                    context.push(AppRoutes.mapForProject(project.id)),
              ),
            ),
            if (role == UserRole.admin)
              AnimatedReveal(
                delay: const Duration(milliseconds: 170),
                child: Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(
                        title: 'Admin tools',
                        subtitle:
                            'Manage this project and its workflow from one place.',
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      _ProjectActionGroupCard(
                        icon: Icons.settings_suggest_outlined,
                        title: 'Project setup',
                        subtitle: 'Update details and assignments.',
                        actions: [
                          FilledButton.icon(
                            onPressed: () =>
                                context.push(AppRoutes.projectEdit(project.id)),
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('Edit details'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => context.push(
                              AppRoutes.projectAssignments(project.id),
                            ),
                            icon: const Icon(Icons.assignment_outlined),
                            label: const Text('Assignments'),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      _ProjectActionGroupCard(
                        icon: Icons.rule_folder_outlined,
                        title: 'Review workflows',
                        subtitle:
                            'Moderate submissions and prepare exports without leaving this project.',
                        actions: [
                          FilledButton.icon(
                            onPressed: () => context.push(
                              AppRoutes.projectReviewQueue(project.id),
                              extra: project.name,
                            ),
                            icon: const Icon(Icons.rate_review_outlined),
                            label: const Text('Pending review'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: () => context.push(
                              AppRoutes.projectApprovedReviews(project.id),
                              extra: project.name,
                            ),
                            icon: const Icon(Icons.verified_outlined),
                            label: const Text('Approved'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => context.push(
                              AppRoutes.projectExports(project.id),
                              extra: project.name,
                            ),
                            icon: const Icon(Icons.file_download_outlined),
                            label: const Text('Exports'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            if (role == UserRole.contributor && !hasContributorAssignment)
              AnimatedReveal(
                delay: Duration(milliseconds: 200),
                child: AppCard(
                  child: ListTile(
                    leading: Icon(
                      contributorRequestStatus ==
                              ProjectAssignmentStatus.rejected
                          ? Icons.cancel_outlined
                          : contributorRequestStatus ==
                                ProjectAssignmentStatus.pending
                          ? Icons.hourglass_bottom
                          : Icons.lock_outline,
                    ),
                    title: Text(
                      contributorRequestStatus ==
                              ProjectAssignmentStatus.rejected
                          ? 'Project access was rejected'
                          : contributorRequestStatus ==
                                ProjectAssignmentStatus.pending
                          ? 'Project access pending'
                          : 'Assignment required',
                    ),
                    subtitle: Text(
                      contributorRequestStatus ==
                              ProjectAssignmentStatus.rejected
                          ? 'An admin rejected your previous request. The request stays visible in Requests until it is re-approved.'
                          : contributorRequestStatus ==
                                ProjectAssignmentStatus.pending
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
                delay: Duration(milliseconds: 210),
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
                delay: Duration(milliseconds: 220),
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

class _ProjectActionGroupCard extends StatelessWidget {
  const _ProjectActionGroupCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.actions,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Icon(icon, size: 18, color: scheme.onPrimaryContainer),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          LayoutBuilder(
            builder: (context, constraints) {
              final canSplit = constraints.maxWidth >= 520;
              final buttonWidth = canSplit
                  ? (constraints.maxWidth - 12) / 2
                  : constraints.maxWidth;

              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: actions
                    .map(
                      (action) => SizedBox(width: buttonWidth, child: action),
                    )
                    .toList(growable: false),
              );
            },
          ),
        ],
      ),
    );
  }
}
