import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../../projects/domain/project.dart';

class AssignmentsScreen extends ConsumerStatefulWidget {
  const AssignmentsScreen({super.key});

  @override
  ConsumerState<AssignmentsScreen> createState() => _AssignmentsScreenState();
}

class _AssignmentsScreenState extends ConsumerState<AssignmentsScreen> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final projectsAsync = ref.watch(projectListProvider(ProjectViewScope.all));
    final assignmentsAsync = ref.watch(managedAssignmentsProvider);

    return projectsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Assignments unavailable',
        message: '$error',
        actionLabel: 'Retry',
        onAction: () =>
            ref.invalidate(projectListProvider(ProjectViewScope.all)),
      ),
      data: (projects) => assignmentsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => AppEmptyState(
          icon: Icons.error_outline,
          title: 'Assignment data unavailable',
          message: '$error',
          actionLabel: 'Retry',
          onAction: () => ref.invalidate(managedAssignmentsProvider),
        ),
        data: (allAssignments) {
          final activeProjects = projects
              .where((project) => project.status == 'active')
              .where((project) {
                final query = _searchController.text.trim().toLowerCase();
                if (query.isEmpty) {
                  return true;
                }
                return project.name.toLowerCase().contains(query) ||
                    project.category.toLowerCase().contains(query);
              })
              .toList(growable: false);

          return ListView(
            children: [
              const SectionHeader(
                title: 'Assignments',
                subtitle:
                    'Open an active project to assign, unassign, and reassign contributors.',
              ),
              const SizedBox(height: AppSpacing.sm),
              AppCard(
                child: SearchBar(
                  controller: _searchController,
                  hintText: 'Search active projects',
                  leading: const Icon(Icons.search),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              if (activeProjects.isEmpty)
                const AppEmptyState(
                  icon: Icons.assignment_outlined,
                  title: 'No active projects available',
                  message:
                      'Assignments are managed per active project. Activate a project first, then open it here.',
                )
              else
                ...activeProjects.map(
                  (project) {
                    final approvedCount = allAssignments
                        .where(
                          (item) =>
                              item.projectId == project.id &&
                              item.status == 'approved',
                        )
                        .length;
                    final pendingCount = allAssignments
                        .where(
                          (item) =>
                              item.projectId == project.id &&
                              item.status == 'pending',
                        )
                        .length;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: AppCard(
                        onTap: () =>
                            context.push(AppRoutes.projectAssignments(project.id)),
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
                                        softWrap: true,
                                      ),
                                      const SizedBox(height: AppSpacing.xs),
                                      Text(
                                        project.description.isEmpty
                                            ? 'No description provided.'
                                            : project.description,
                                        softWrap: true,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                StatusChip(status: project.status),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                Chip(label: Text(project.category)),
                                Chip(
                                  label: Text(
                                    '$approvedCount assigned contributors',
                                  ),
                                ),
                                Chip(
                                  label: Text('$pendingCount pending requests'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}
