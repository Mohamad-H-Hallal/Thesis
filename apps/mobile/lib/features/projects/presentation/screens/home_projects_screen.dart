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
  const HomeProjectsScreen({super.key});

  @override
  ConsumerState<HomeProjectsScreen> createState() => _HomeProjectsScreenState();
}

class _HomeProjectsScreenState extends ConsumerState<HomeProjectsScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final projectsAsync = ref.watch(projectsProvider);
    final session = ref.watch(authControllerProvider).session;
    final currentUserId = session?.user.id;
    final role = session?.user.role ?? UserRole.viewer;

    return Column(
      children: [
        SectionHeader(
          title: _titleForRole(role),
          subtitle: _subtitleForRole(role),
        ),
        const SizedBox(height: AppSpacing.sm),
        SearchBar(
          leading: const Icon(Icons.search),
          hintText: _searchHintForRole(role),
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
                onAction: () => ref.invalidate(projectsProvider),
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
                  message: _emptyMessageForRole(role),
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
                          label: _metricLabelForRole(role),
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
                    return Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: AnimatedReveal(
                        delay: Duration(milliseconds: index * 70),
                        child: AppCard(
                          onTap: () =>
                              context.go(AppRoutes.projectDetails(project.id)),
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
                                      currentUserId != null)
                                    Chip(
                                      label: Text(
                                        _assignmentLabel(
                                          project: project,
                                          userId: currentUserId,
                                        ),
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
    for (final assignment in project.assignments) {
      if (assignment.userId == userId) {
        return 'Assignment: ${assignment.status.name}';
      }
    }
    return 'Assignment: not set';
  }

  String _titleForRole(UserRole role) {
    switch (role) {
      case UserRole.admin:
        return 'All Projects';
      case UserRole.viewer:
        return 'Visible Projects';
      case UserRole.contributor:
        return 'Assigned Projects';
    }
  }

  String _subtitleForRole(UserRole role) {
    switch (role) {
      case UserRole.admin:
        return 'Management view across every project, assignment, and review workload.';
      case UserRole.viewer:
        return 'Projects published by admins for viewer access.';
      case UserRole.contributor:
        return 'Operational overview for your assigned collection campaigns.';
    }
  }

  String _searchHintForRole(UserRole role) {
    switch (role) {
      case UserRole.admin:
        return 'Search all projects';
      case UserRole.viewer:
        return 'Search visible projects';
      case UserRole.contributor:
        return 'Search assigned projects';
    }
  }

  String _metricLabelForRole(UserRole role) {
    switch (role) {
      case UserRole.admin:
        return 'Total projects';
      case UserRole.viewer:
        return 'Visible now';
      case UserRole.contributor:
        return 'Assigned';
    }
  }

  String _emptyMessageForRole(UserRole role) {
    switch (role) {
      case UserRole.admin:
        return 'No projects match your search filters.';
      case UserRole.viewer:
        return 'No viewer-visible projects match your search right now.';
      case UserRole.contributor:
        return 'No assigned projects match your search. Try another keyword.';
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
