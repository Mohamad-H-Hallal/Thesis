import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
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
  bool _showFilters = false;

  Future<void> _changeProjectStatus(
    ProjectSummary project, {
    required String nextStatus,
    required String dialogTitle,
    required String dialogMessage,
    required String successMessage,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(dialogTitle),
        content: Text(dialogMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(dialogTitle),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    try {
      if (nextStatus == 'archived') {
        await ref.read(adminRepositoryProvider).archiveProject(project.id);
      } else {
        await ref
            .read(adminRepositoryProvider)
            .updateProjectStatus(projectId: project.id, status: nextStatus);
      }
      bumpWorkflowRefresh(ref);
      if (!mounted) {
        return;
      }
      AppSnackbar.showSuccess(context, successMessage);
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
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to load projects right now. Please try again.',
        ),
        actionLabel: 'Retry',
        onAction: () =>
            ref.invalidate(projectListProvider(ProjectViewScope.all)),
      ),
      data: (projects) {
        final filtered = projects
            .where((project) {
              final matchesQuery = project.name.toLowerCase().contains(
                _query.toLowerCase(),
              );
              final matchesStatus =
                  _statusFilter == 'all' || project.status == _statusFilter;
              return matchesQuery && matchesStatus;
            })
            .toList(growable: false);

        return RefreshIndicator(
          onRefresh: () async =>
              ref.invalidate(projectListProvider(ProjectViewScope.all)),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final action = FilledButton.icon(
                    onPressed: () => context.push(AppRoutes.projectCreate),
                    icon: const Icon(Icons.add),
                    label: const Text('Create'),
                  );
                  if (constraints.maxWidth < 680) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SectionHeader(
                          title: 'Projects',
                          subtitle:
                              'Provision, update, and route projects into assignments, map collection, reviews, and exports.',
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        action,
                      ],
                    );
                  }
                  return SectionHeader(
                    title: 'Projects',
                    subtitle:
                        'Provision, update, and route projects into assignments, map collection, reviews, and exports.',
                    trailing: action,
                  );
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final filterButton = OutlinedButton.icon(
                          onPressed: () =>
                              setState(() => _showFilters = !_showFilters),
                          icon: Icon(
                            _showFilters
                                ? Icons.filter_alt_off_outlined
                                : Icons.filter_alt_outlined,
                          ),
                          label: Text(_showFilters ? 'Hide' : 'Filter'),
                        );

                        final searchBar = SearchBar(
                          hintText: 'Search projects',
                          leading: const Icon(Icons.search),
                          onChanged: (value) {
                            setState(() {
                              _query = value.trim();
                            });
                          },
                        );

                        if (constraints.maxWidth < 560) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              searchBar,
                              const SizedBox(height: AppSpacing.sm),
                              filterButton,
                            ],
                          );
                        }

                        return Row(
                          children: [
                            Expanded(child: searchBar),
                            const SizedBox(width: AppSpacing.sm),
                            filterButton,
                          ],
                        );
                      },
                    ),
                    if (_showFilters) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Wrap(
                        spacing: AppSpacing.xs,
                        runSpacing: AppSpacing.xs,
                        children: [
                          for (final status in const [
                            'all',
                            'draft',
                            'active',
                            'paused',
                            'completed',
                            'archived',
                          ])
                            ChoiceChip(
                              label: Text(
                                status == 'all' ? 'All statuses' : status,
                              ),
                              selected: _statusFilter == status,
                              onSelected: (_) {
                                setState(() {
                                  _statusFilter = status;
                                });
                              },
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
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
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final menu = PopupMenuButton<String>(
                            onSelected: (value) {
                              if (value == 'activate') {
                                _changeProjectStatus(
                                  project,
                                  nextStatus: 'active',
                                  dialogTitle: 'Activate project',
                                  dialogMessage:
                                      'Move "${project.name}" from draft into active field operations?',
                                  successMessage:
                                      'Project activated successfully.',
                                );
                              }
                              if (value == 'pause') {
                                _changeProjectStatus(
                                  project,
                                  nextStatus: 'paused',
                                  dialogTitle: 'Pause project',
                                  dialogMessage:
                                      'Pause "${project.name}"? Viewing stays available, but feature collection and submission are disabled until the project returns to active status.',
                                  successMessage:
                                      'Project paused successfully.',
                                );
                              }
                              if (value == 'resume') {
                                _changeProjectStatus(
                                  project,
                                  nextStatus: 'active',
                                  dialogTitle: 'Resume project',
                                  dialogMessage:
                                      'Return "${project.name}" to active field operations?',
                                  successMessage:
                                      'Project resumed successfully.',
                                );
                              }
                              if (value == 'complete') {
                                _changeProjectStatus(
                                  project,
                                  nextStatus: 'completed',
                                  dialogTitle: 'Mark project completed',
                                  dialogMessage:
                                      'Mark "${project.name}" as completed? Collection will stop until the project is reopened.',
                                  successMessage:
                                      'Project marked completed successfully.',
                                );
                              }
                              if (value == 'reopen-active') {
                                _changeProjectStatus(
                                  project,
                                  nextStatus: 'active',
                                  dialogTitle: 'Reopen project',
                                  dialogMessage:
                                      'Return "${project.name}" to active status?',
                                  successMessage:
                                      'Project reopened successfully.',
                                );
                              }
                              if (value == 'reopen-paused') {
                                _changeProjectStatus(
                                  project,
                                  nextStatus: 'paused',
                                  dialogTitle: 'Restore paused project',
                                  dialogMessage:
                                      'Restore "${project.name}" to paused status?',
                                  successMessage:
                                      'Project restored to paused status.',
                                );
                              }
                              if (value == 'archive') {
                                _changeProjectStatus(
                                  project,
                                  nextStatus: 'archived',
                                  dialogTitle: 'Archive project',
                                  dialogMessage:
                                      'Archive "${project.name}"? This removes it from active operations and contributor lists.',
                                  successMessage:
                                      'Project archived successfully.',
                                );
                              }
                              if (value == 'unarchive') {
                                _changeProjectStatus(
                                  project,
                                  nextStatus: 'completed',
                                  dialogTitle: 'Unarchive project',
                                  dialogMessage:
                                      'Restore "${project.name}" to completed so it becomes viewable again and can be managed normally.',
                                  successMessage:
                                      'Project restored to completed status.',
                                );
                              }
                            },
                            itemBuilder: (context) => [
                              if (project.status == 'draft')
                                const PopupMenuItem(
                                  value: 'activate',
                                  child: Text('Activate project'),
                                ),
                              if (project.status == 'active')
                                const PopupMenuItem(
                                  value: 'pause',
                                  child: Text('Pause project'),
                                ),
                              if (project.status == 'active' ||
                                  project.status == 'paused')
                                const PopupMenuItem(
                                  value: 'complete',
                                  child: Text('Mark completed'),
                                ),
                              if (project.status == 'paused')
                                const PopupMenuItem(
                                  value: 'resume',
                                  child: Text('Resume project'),
                                ),
                              if (project.status == 'completed')
                                const PopupMenuItem(
                                  value: 'reopen-active',
                                  child: Text('Reopen as active'),
                                ),
                              if (project.status == 'completed')
                                const PopupMenuItem(
                                  value: 'reopen-paused',
                                  child: Text('Restore paused state'),
                                ),
                              if (project.status == 'completed')
                                const PopupMenuItem(
                                  value: 'archive',
                                  child: Text('Archive project'),
                                ),
                              if (project.status == 'archived')
                                const PopupMenuItem(
                                  value: 'unarchive',
                                  child: Text('Unarchive project'),
                                ),
                            ],
                          );

                          final summary = Column(
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
                          );

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (constraints.maxWidth < 460) ...[
                                summary,
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: menu,
                                ),
                              ] else
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(child: summary),
                                    menu,
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
                                          ? 'User visible'
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
                                    onPressed: () => context.push(
                                      AppRoutes.projectEdit(project.id),
                                    ),
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
                                    onPressed: () => context.push(
                                      AppRoutes.projectDetails(project.id),
                                    ),
                                    icon: const Icon(Icons.visibility_outlined),
                                    label: const Text('Open'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: () => context.push(
                                      AppRoutes.mapForProject(project.id),
                                    ),
                                    icon: const Icon(Icons.map_outlined),
                                    label: const Text('Map'),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
