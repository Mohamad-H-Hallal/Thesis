import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/progressive_list_section.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../../projects/domain/project.dart';

class AssignmentsScreen extends ConsumerStatefulWidget {
  const AssignmentsScreen({super.key});

  @override
  ConsumerState<AssignmentsScreen> createState() => _AssignmentsScreenState();
}

class _AssignmentsScreenState extends ConsumerState<AssignmentsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _statusFilter = 'all';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final projectQuery = ProjectListQuery(
      scope: ProjectViewScope.all,
      query: _searchController.text.trim().isEmpty
          ? null
          : _searchController.text.trim(),
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
        title: 'Assignments unavailable',
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to load assignments right now. Please try again.',
        ),
        actionLabel: 'Retry',
        onAction: projectsController.load,
      ),
      data: (projectsState) {
          const statusOptions = <String>[
            'all',
            'draft',
            'active',
            'paused',
            'completed',
            'archived',
          ];

          return ListView(
            children: [
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final searchBar = SearchBar(
                          controller: _searchController,
                          hintText: 'Search assignment projects',
                          leading: const Icon(Icons.search),
                          onChanged: (_) => setState(() {}),
                        );

                        if (constraints.maxWidth < 560) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              searchBar,
                              const SizedBox(height: AppSpacing.sm),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: statusOptions
                                    .map(
                                      (status) => ChoiceChip(
                                        label: Text(
                                          status == 'all'
                                              ? 'All projects'
                                              : '${status[0].toUpperCase()}${status.substring(1)}',
                                        ),
                                        selected: _statusFilter == status,
                                        onSelected: (_) => setState(
                                          () => _statusFilter = status,
                                        ),
                                      ),
                                    )
                                    .toList(growable: false),
                              ),
                            ],
                          );
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            searchBar,
                            const SizedBox(height: AppSpacing.sm),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: statusOptions
                                  .map(
                                    (status) => ChoiceChip(
                                      label: Text(
                                        status == 'all'
                                            ? 'All projects'
                                            : '${status[0].toUpperCase()}${status.substring(1)}',
                                      ),
                                      selected: _statusFilter == status,
                                      onSelected: (_) => setState(
                                        () => _statusFilter = status,
                                      ),
                                    ),
                                  )
                                  .toList(growable: false),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                '${projectsState.total} project${projectsState.total == 1 ? '' : 's'}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.sm),
              if (projectsState.items.isEmpty)
                AppEmptyState(
                  icon: Icons.assignment_outlined,
                  title: 'No projects found',
                  message:
                      'No projects match the current search and status filter.',
                )
              else
                ProgressiveListSection<ProjectSummary>(
                  items: projectsState.items,
                  resetKey: Object.hash(
                    _searchController.text,
                    _statusFilter,
                    projectsState.total,
                  ),
                  hasMore: projectsState.hasMore,
                  isLoadingMore: projectsState.isLoadingMore,
                  onLoadMore: projectsController.loadMore,
                  itemBuilder: (context, project, _) {
                    return AppCard(
                      onTap: () => context.push(
                        AppRoutes.projectAssignments(project.id),
                      ),
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
                                    Text(project.description, softWrap: true),
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
                                  '${project.assignedCollectors} assigned',
                                ),
                              ),
                              Chip(
                                label: Text(
                                  '${project.pendingAssignmentRequests} pending requests',
                                ),
                              ),
                              if (project.rejectedAssignmentRequests > 0)
                                Chip(
                                  label: Text(
                                    '${project.rejectedAssignmentRequests} rejected requests',
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          );
      },
    );
  }
}
