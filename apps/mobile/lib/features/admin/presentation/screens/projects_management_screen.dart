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
import '../../../../core/widgets/status_chip.dart';
import '../../../projects/domain/project.dart';

class ProjectsManagementScreen extends ConsumerStatefulWidget {
  const ProjectsManagementScreen({super.key});

  @override
  ConsumerState<ProjectsManagementScreen> createState() =>
      _ProjectsManagementScreenState();
}

class _ProjectsManagementScreenState
    extends ConsumerState<ProjectsManagementScreen> {
  String _query = '';
  String _statusFilter = 'all';

  Future<void> _archiveProject(ProjectSummary project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Archive project'),
        content: Text(
          'Archive "${project.name}"? This removes it from active operations and contributor lists.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    try {
      await ref.read(adminRepositoryProvider).archiveProject(project.id);
      ref.invalidate(projectListProvider(ProjectViewScope.all));
      ref.invalidate(projectByIdProvider(project.id));
      if (!mounted) {
        return;
      }
      AppSnackbar.showSuccess(context, 'Project archived successfully.');
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(context, error.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final projectsAsync = ref.watch(projectListProvider(ProjectViewScope.all));

    return projectsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Projects unavailable',
        message: '$error',
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(projectListProvider(ProjectViewScope.all)),
      ),
      data: (projects) {
        final filtered = projects.where((project) {
          final matchesQuery = project.name.toLowerCase().contains(
                _query.toLowerCase(),
              );
          final matchesStatus =
              _statusFilter == 'all' || project.status == _statusFilter;
          return matchesQuery && matchesStatus;
        }).toList(growable: false);

        return ListView(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Expanded(
                  child: SectionHeader(
                    title: 'Projects',
                    subtitle:
                        'Provision, update, and route projects into assignments, map collection, reviews, and exports.',
                  ),
                ),
                FilledButton.icon(
                  onPressed: () => context.push(AppRoutes.projectCreate),
                  icon: const Icon(Icons.add),
                  label: const Text('Create'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            SearchBar(
              hintText: 'Search projects',
              leading: const Icon(Icons.search),
              onChanged: (value) {
                setState(() {
                  _query = value.trim();
                });
              },
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                for (final status in const [
                  'all',
                  'draft',
                  'active',
                  'completed',
                  'archived',
                ])
                  ChoiceChip(
                    label: Text(status == 'all' ? 'All statuses' : status),
                    selected: _statusFilter == status,
                    onSelected: (_) {
                      setState(() {
                        _statusFilter = status;
                      });
                    },
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (filtered.isEmpty)
              AppEmptyState(
                icon: Icons.folder_off_outlined,
                title: 'No projects found',
                message: projects.isEmpty
                    ? 'Create your first project to start the mobile-first workflow.'
                    : 'No projects match the current search and status filter.',
                actionLabel: projects.isEmpty ? 'Create project' : null,
                onAction: projects.isEmpty
                    ? () => context.push(AppRoutes.projectCreate)
                    : null,
              )
            else
              ...filtered.map(
                (project) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: AppCard(
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
                                    style: Theme.of(context).textTheme.titleLarge,
                                  ),
                                  const SizedBox(height: AppSpacing.xs),
                                  Text(
                                    project.description.isEmpty
                                        ? 'No description provided.'
                                        : project.description,
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuButton<String>(
                              onSelected: (value) {
                                if (value == 'archive') {
                                  _archiveProject(project);
                                }
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                  value: 'archive',
                                  child: Text('Archive project'),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            StatusChip(status: project.status),
                            Chip(label: Text(project.category)),
                            Chip(
                              label: Text(
                                project.visibleToViewers
                                    ? 'Viewer visible'
                                    : 'Contributor only',
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
                        const SizedBox(height: AppSpacing.sm),
                        Wrap(
                          spacing: AppSpacing.sm,
                          runSpacing: AppSpacing.sm,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () =>
                                  context.push(AppRoutes.projectEdit(project.id)),
                              icon: const Icon(Icons.edit_outlined),
                              label: const Text('Edit'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => context.push(
                                AppRoutes.projectAssignments(project.id),
                              ),
                              icon: const Icon(Icons.assignment_outlined),
                              label: const Text('Assignments'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () =>
                                  context.push(AppRoutes.projectDetails(project.id)),
                              icon: const Icon(Icons.visibility_outlined),
                              label: const Text('Open'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () =>
                                  context.push(AppRoutes.mapForProject(project.id)),
                              icon: const Icon(Icons.map_outlined),
                              label: const Text('Map'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
