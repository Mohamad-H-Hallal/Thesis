import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/animated_reveal.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../../auth/domain/auth_models.dart';
import '../../domain/project.dart';

class HomeProjectsScreen extends ConsumerStatefulWidget {
  const HomeProjectsScreen({
    required this.scope,
    this.title = 'Projects',
    super.key,
  });

  final ProjectViewScope scope;
  final String title;

  @override
  ConsumerState<HomeProjectsScreen> createState() => _HomeProjectsScreenState();
}

class _HomeProjectsScreenState extends ConsumerState<HomeProjectsScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final projectsAsync = ref.watch(projectListProvider(widget.scope));
    final session = ref.watch(authControllerProvider).session;
    final currentUserId = session?.user.id;
    final role = session?.user.role ?? UserRole.viewer;
    final isAssignedView = widget.scope == ProjectViewScope.assigned;

    return Column(
      children: [
        SectionHeader(
          title: widget.title,
          subtitle: _subtitleForScope(role, widget.scope),
        ),
        const SizedBox(height: AppSpacing.sm),
        SearchBar(
          leading: const Icon(Icons.search),
          hintText: _searchHintForScope(role, widget.scope),
          onChanged: (value) =>
              setState(() => _query = value.trim().toLowerCase()),
        ),
        const SizedBox(height: AppSpacing.md),
        Expanded(
          child: projectsAsync.when(
            loading: () => ListView.builder(
              itemCount: 4,
              itemBuilder: (_, index) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: AnimatedReveal(
                  delay: Duration(milliseconds: index * 70),
                  child: const LinearProgressIndicator(minHeight: 56),
                ),
              ),
            ),
            error: (error, _) => Center(
              child: AppEmptyState(
                icon: Icons.error_outline,
                title: 'Unable to load projects',
                message: 'Error: $error',
                actionLabel: 'Retry',
                onAction: () =>
                    ref.invalidate(projectListProvider(widget.scope)),
              ),
            ),
            data: (projects) {
              final filtered = projects
                  .where(
                    (project) => project.name.toLowerCase().contains(_query),
                  )
                  .toList(growable: false);

              if (filtered.isEmpty) {
                return AppEmptyState(
                  icon: Icons.folder_off_outlined,
                  title: 'No projects found',
                  message: _emptyMessageForScope(role, widget.scope),
                );
              }

              return ListView(
                children: [
                  AppCard(
                    child: Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: [
                        _MetricPill(
                          label: _metricLabelForScope(role, widget.scope),
                          value: '${filtered.length}',
                          icon: Icons.folder_shared_outlined,
                        ),
                        _MetricPill(
                          label: 'Pending reviews',
                          value:
                              '${filtered.fold<int>(0, (sum, p) => sum + p.pendingReviews)}',
                          icon: Icons.rate_review_outlined,
                        ),
                        _MetricPill(
                          label: 'Collectors',
                          value:
                              '${filtered.fold<int>(0, (sum, p) => sum + p.assignedCollectors)}',
                          icon: Icons.groups_outlined,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  ...List<Widget>.generate(filtered.length, (index) {
                    final project = filtered[index];
                    final contributorReadOnly =
                        role == UserRole.contributor &&
                        !project.hasApprovedCurrentUserAssignment;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: AnimatedReveal(
                        delay: Duration(milliseconds: index * 70),
                        child: AppCard(
                          onTap: () => context.push(
                            AppRoutes.projectDetails(project.id),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Text(
                                      project.name,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleLarge,
                                    ),
                                  ),
                                  const SizedBox(width: AppSpacing.xs),
                                  StatusChip(status: project.status),
                                ],
                              ),
                              const SizedBox(height: AppSpacing.xs),
                              Text(
                                project.description,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  Chip(label: Text(project.category)),
                                  if (role == UserRole.contributor &&
                                      currentUserId != null &&
                                      isAssignedView)
                                    Chip(
                                      label: Text(
                                        _assignmentLabel(
                                          project: project,
                                          userId: currentUserId,
                                        ),
                                      ),
                                    ),
                                  if (role == UserRole.contributor &&
                                      !isAssignedView)
                                    Chip(
                                      label: Text(
                                        project.currentUserAssignmentStatus ==
                                                ProjectAssignmentStatus.pending
                                            ? 'Access request pending'
                                            : project.currentUserAssignmentStatus ==
                                                    ProjectAssignmentStatus.rejected
                                                ? 'Access request rejected'
                                                : contributorReadOnly
                                                    ? 'Read-only public view'
                                                    : 'Also assigned',
                                      ),
                                    ),
                                  if (role == UserRole.admin)
                                    Chip(
                                      label: Text(
                                        project.visibleToViewers
                                            ? 'Viewer visible'
                                            : 'Contributor only',
                                      ),
                                    ),
                                  Chip(
                                    label: Text(
                                      '${project.assignedCollectors} collectors',
                                    ),
                                  ),
                                  Chip(
                                    label: Text(
                                      '${project.pendingReviews} pending reviews',
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  String _assignmentLabel({
    required ProjectSummary project,
    required String userId,
  }) {
    if (project.currentUserAssignmentStatus != null) {
      return 'Assignment: ${project.currentUserAssignmentStatus!.name}';
    }
    for (final assignment in project.assignments) {
      if (assignment.userId == userId) {
        return 'Assignment: ${assignment.status.name}';
      }
    }
    return 'Assignment: not set';
  }

  String _subtitleForScope(UserRole role, ProjectViewScope scope) {
    switch (scope) {
      case ProjectViewScope.public:
        return 'Projects published by admins for read-only public and viewer access.';
      case ProjectViewScope.assigned:
        return role == UserRole.admin
            ? 'Project operations and assignment-linked workstreams.'
            : 'Projects where you have an approved contributor assignment.';
      case ProjectViewScope.all:
        return 'Management view across every project, assignment, and review workload.';
    }
  }

  String _searchHintForScope(UserRole role, ProjectViewScope scope) {
    switch (scope) {
      case ProjectViewScope.public:
        return 'Search visible projects';
      case ProjectViewScope.assigned:
        return role == UserRole.admin
            ? 'Search all managed projects'
            : 'Search assigned projects';
      case ProjectViewScope.all:
        return 'Search all projects';
    }
  }

  String _metricLabelForScope(UserRole role, ProjectViewScope scope) {
    switch (scope) {
      case ProjectViewScope.public:
        return 'Published';
      case ProjectViewScope.assigned:
        return role == UserRole.admin ? 'Managed' : 'Assigned';
      case ProjectViewScope.all:
        return 'Total projects';
    }
  }

  String _emptyMessageForScope(UserRole role, ProjectViewScope scope) {
    switch (scope) {
      case ProjectViewScope.public:
        return 'No published projects match your search right now.';
      case ProjectViewScope.assigned:
        return role == UserRole.admin
            ? 'No projects match your current search.'
            : 'No assigned projects match your search. Try another keyword.';
      case ProjectViewScope.all:
        return 'No projects match your search filters.';
    }
  }
}

class _MetricPill extends StatelessWidget {
  const _MetricPill({
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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: AppRadii.md,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: AppSpacing.xs),
          Text('$label: ', style: Theme.of(context).textTheme.bodySmall),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
