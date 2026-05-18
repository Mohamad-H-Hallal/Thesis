import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_action_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_dialog_actions.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/progressive_list_section.dart';
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
          AppDialogActions(
            cancel: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            confirm: FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(dialogTitle),
            ),
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
    final projectQuery = ProjectListQuery(
      scope: ProjectViewScope.all,
      query: _query.trim().isEmpty ? null : _query.trim(),
      status: _statusFilter == 'all' ? null : _statusFilter,
    );
    final projectsAsync = ref.watch(paginatedProjectsProvider(projectQuery));
    final projectsController = ref.read(
      paginatedProjectsProvider(projectQuery).notifier,
    );

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
        onAction: projectsController.load,
      ),
      data: (projectsState) {
        final filtered = projectsState.items;

        return RefreshIndicator(
          onRefresh: projectsController.refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final createButton = FilledButton.icon(
                          onPressed: () =>
                              context.push(AppRoutes.projectCreate),
                          icon: const Icon(Icons.add),
                          label: const Text('Create'),
                        );
                        final filterButton = OutlinedButton.icon(
                          onPressed: () =>
                              setState(() => _showFilters = !_showFilters),
                          icon: Icon(
                            _showFilters
                                ? Icons.filter_alt_off_outlined
                                : Icons.filter_alt_outlined,
                          ),
                          label: Text(_showFilters ? 'Hide filters' : 'Filter'),
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
                              SizedBox(
                                width: double.infinity,
                                child: createButton,
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              SizedBox(
                                width: double.infinity,
                                child: filterButton,
                              ),
                            ],
                          );
                        }

                        return Row(
                          children: [
                            Expanded(child: searchBar),
                            const SizedBox(width: AppSpacing.sm),
                            SizedBox(width: 180, child: createButton),
                            const SizedBox(width: AppSpacing.sm),
                            SizedBox(width: 160, child: filterButton),
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
              Text(
                '${projectsState.total} project${projectsState.total == 1 ? '' : 's'}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.sm),
              if (filtered.isEmpty)
                AppEmptyState(
                  icon: Icons.folder_off_outlined,
                  title: 'No projects found',
                  message: projectsState.total == 0
                      ? 'Create your first project to start the mobile-first workflow.'
                      : 'No projects match the current search and status filter.',
                  actionLabel: projectsState.total == 0
                      ? 'Create project'
                      : null,
                  onAction: projectsState.total == 0
                      ? () => context.push(AppRoutes.projectCreate)
                      : null,
                )
              else
                ProgressiveListSection<ProjectSummary>(
                  items: filtered,
                  resetKey: Object.hash(
                    _query,
                    _statusFilter,
                    projectsState.total,
                  ),
                  hasMore: projectsState.hasMore,
                  isLoadingMore: projectsState.isLoadingMore,
                  onLoadMore: projectsController.loadMore,
                  gridMinItemWidth: 420,
                  itemBuilder: (context, project, _) => AppCard(
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
                                successMessage: 'Project paused successfully.',
                              );
                            }
                            if (value == 'resume') {
                              _changeProjectStatus(
                                project,
                                nextStatus: 'active',
                                dialogTitle: 'Resume project',
                                dialogMessage:
                                    'Return "${project.name}" to active field operations?',
                                successMessage: 'Project resumed successfully.',
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
                            if (project.description.isNotEmpty)
                              Text(project.description),
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
                                  label: Text(project.visibilitySummaryLabel),
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
                            AppActionButtons(
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
            ],
          ),
        );
      },
    );
  }
}
