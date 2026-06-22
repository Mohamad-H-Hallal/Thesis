import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/pagination/paginated_list_controller.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_action_buttons.dart';
import '../../../../core/widgets/app_dialog_actions.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_search_action_bar.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/utils/lebanese_phone.dart';
import '../../domain/admin_models.dart';

enum _AssignmentSection {
  assigned,
  available,
  pendingRequests,
  rejectedRequests,
}

class ProjectAssignmentsScreen extends ConsumerStatefulWidget {
  const ProjectAssignmentsScreen({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<ProjectAssignmentsScreen> createState() =>
      _ProjectAssignmentsScreenState();
}

class _ProjectAssignmentsScreenState
    extends ConsumerState<ProjectAssignmentsScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _isSaving = false;
  bool _showFilters = false;
  _AssignmentSection _selectedSection = _AssignmentSection.assigned;
  bool _appliedInitialSection = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _assignContributor(ManagedUserSummary user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Assign contributor'),
        content: Text(
          'Assign ${user.fullName} to this project as a contributor?',
        ),
        actions: [
          AppDialogActions(
            cancel: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            confirm: FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Assign'),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .createAssignment(
            projectId: widget.projectId,
            userId: user.id,
            role: 'contributor',
          );
      bumpWorkflowRefresh(ref);
      if (mounted) {
        AppSnackbar.showSuccess(
          context,
          '${user.fullName} was assigned successfully.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to assign this contributor right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _removeAssignment(ManagedAssignmentSummary assignment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unassign contributor'),
        content: Text(
          'Remove ${assignment.fullName} from this project? They can be reassigned later.',
        ),
        actions: [
          AppDialogActions(
            cancel: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            confirm: FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Unassign'),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      await ref.read(adminRepositoryProvider).removeAssignment(assignment.id);
      bumpWorkflowRefresh(ref);
      if (mounted) {
        AppSnackbar.showSuccess(
          context,
          'Contributor unassigned successfully.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to update this assignment right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _updateAssignmentRequest(
    ManagedAssignmentSummary assignment, {
    required String status,
  }) async {
    final isApprove = status == 'approved';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          isApprove ? 'Approve project request' : 'Reject project request',
        ),
        content: Text(
          isApprove
              ? 'Approve ${assignment.fullName} for this project?'
              : 'Reject ${assignment.fullName} for this project? They will remain outside this project until an admin re-accepts the request.',
        ),
        actions: [
          AppDialogActions(
            cancel: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            confirm: FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(isApprove ? 'Approve' : 'Reject'),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .updateAssignmentStatus(assignmentId: assignment.id, status: status);
      bumpWorkflowRefresh(ref);
      if (mounted) {
        AppSnackbar.showSuccess(
          context,
          isApprove
              ? 'Project request approved successfully.'
              : 'Project request rejected successfully.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to update this project request right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final projectAsync = ref.watch(projectByIdProvider(widget.projectId));
    final searchQuery = _searchController.text.trim();
    final normalizedQuery = searchQuery.isEmpty ? null : searchQuery;

    return projectAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Assignments unavailable',
        message: userFacingErrorMessage(
          error,
          fallback:
              'Unable to load project assignments right now. Please try again.',
        ),
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

        final isViewOnlyProject =
            project.status == 'completed' || project.status == 'archived';
        final assignedQuery = ProjectAssignmentsQuery(
          projectId: widget.projectId,
          status: 'approved',
          query: normalizedQuery,
        );
        final assignedAsync = ref.watch(
          paginatedProjectAssignmentsProvider(assignedQuery),
        );
        final assignedController = ref.read(
          paginatedProjectAssignmentsProvider(assignedQuery).notifier,
        );
        final assignedState =
            assignedAsync.valueOrNull ??
            const PaginatedListState<ManagedAssignmentSummary>.initial();

        final pendingQuery = ProjectAssignmentsQuery(
          projectId: widget.projectId,
          status: 'pending',
          query: normalizedQuery,
        );
        final rejectedQuery = ProjectAssignmentsQuery(
          projectId: widget.projectId,
          status: 'rejected',
          query: normalizedQuery,
        );
        final availableQuery = AvailableContributorsQuery(
          projectId: widget.projectId,
          query: normalizedQuery,
        );

        final pendingAsync = isViewOnlyProject
            ? AsyncData<PaginatedListState<ManagedAssignmentSummary>>(
                const PaginatedListState<ManagedAssignmentSummary>.initial(),
              )
            : ref.watch(paginatedProjectAssignmentsProvider(pendingQuery));
        final pendingController = ref.read(
          paginatedProjectAssignmentsProvider(pendingQuery).notifier,
        );
        final pendingState =
            pendingAsync.valueOrNull ??
            const PaginatedListState<ManagedAssignmentSummary>.initial();

        final rejectedAsync = isViewOnlyProject
            ? AsyncData<PaginatedListState<ManagedAssignmentSummary>>(
                const PaginatedListState<ManagedAssignmentSummary>.initial(),
              )
            : ref.watch(paginatedProjectAssignmentsProvider(rejectedQuery));
        final rejectedController = ref.read(
          paginatedProjectAssignmentsProvider(rejectedQuery).notifier,
        );
        final rejectedState =
            rejectedAsync.valueOrNull ??
            const PaginatedListState<ManagedAssignmentSummary>.initial();

        final availableAsync = isViewOnlyProject
            ? AsyncData<PaginatedListState<ManagedUserSummary>>(
                const PaginatedListState<ManagedUserSummary>.initial(),
              )
            : ref.watch(paginatedAvailableContributorsProvider(availableQuery));
        final availableController = ref.read(
          paginatedAvailableContributorsProvider(availableQuery).notifier,
        );
        final availableState =
            availableAsync.valueOrNull ??
            const PaginatedListState<ManagedUserSummary>.initial();

        if (!_appliedInitialSection &&
            !isViewOnlyProject &&
            !assignedAsync.isLoading &&
            !availableAsync.isLoading) {
          _appliedInitialSection = true;
          if (assignedState.total == 0 && availableState.total > 0) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _selectedSection == _AssignmentSection.assigned) {
                setState(() => _selectedSection = _AssignmentSection.available);
              }
            });
          }
        }

        final effectiveSection = isViewOnlyProject
            ? _AssignmentSection.assigned
            : _selectedSection;

        final currentError = switch (effectiveSection) {
          _AssignmentSection.assigned =>
            assignedAsync.hasError
                ? userFacingErrorMessage(
                    assignedAsync.asError?.error ??
                        StateError(
                          'Assigned contributors failed without an error payload.',
                        ),
                    fallback: 'Unable to load assigned contributors right now.',
                  )
                : null,
          _AssignmentSection.available =>
            availableAsync.hasError
                ? userFacingErrorMessage(
                    availableAsync.asError?.error ??
                        StateError(
                          'Available contributors failed without an error payload.',
                        ),
                    fallback:
                        'Unable to load available contributors right now.',
                  )
                : null,
          _AssignmentSection.pendingRequests =>
            pendingAsync.hasError
                ? userFacingErrorMessage(
                    pendingAsync.asError?.error ??
                        StateError(
                          'Pending requests failed without an error payload.',
                        ),
                    fallback: 'Unable to load pending requests right now.',
                  )
                : null,
          _AssignmentSection.rejectedRequests =>
            rejectedAsync.hasError
                ? userFacingErrorMessage(
                    rejectedAsync.asError?.error ??
                        StateError(
                          'Rejected requests failed without an error payload.',
                        ),
                    fallback: 'Unable to load rejected requests right now.',
                  )
                : null,
        };
        final isCurrentLoading = switch (effectiveSection) {
          _AssignmentSection.assigned =>
            assignedAsync.isLoading && assignedState.items.isEmpty,
          _AssignmentSection.available =>
            availableAsync.isLoading && availableState.items.isEmpty,
          _AssignmentSection.pendingRequests =>
            pendingAsync.isLoading && pendingState.items.isEmpty,
          _AssignmentSection.rejectedRequests =>
            rejectedAsync.isLoading && rejectedState.items.isEmpty,
        };

        return ListView(
          children: [
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppSearchActionBar(
                    searchBar: SearchBar(
                      controller: _searchController,
                      hintText: isViewOnlyProject
                          ? 'Search assigned contributors'
                          : 'Search contributors and project requests',
                      leading: const Icon(Icons.search),
                      onChanged: (_) => setState(() {}),
                    ),
                    actions: isViewOnlyProject
                        ? const <Widget>[]
                        : [
                            OutlinedButton.icon(
                              onPressed: () =>
                                  setState(() => _showFilters = !_showFilters),
                              icon: Icon(
                                _showFilters
                                    ? Icons.filter_alt_off_outlined
                                    : Icons.filter_alt_outlined,
                              ),
                              label: Text(_showFilters ? 'Hide' : 'Filter'),
                            ),
                          ],
                  ),
                  if (isViewOnlyProject)
                    Text(
                      'Assignment changes are disabled for completed and archived projects.',
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  else if (_showFilters) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _AssignmentSection.values
                          .map((section) {
                            final (label, count) = switch (section) {
                              _AssignmentSection.assigned => (
                                'Assigned',
                                assignedState.total,
                              ),
                              _AssignmentSection.available => (
                                'Available',
                                availableState.total,
                              ),
                              _AssignmentSection.pendingRequests => (
                                'Pending requests',
                                pendingState.total,
                              ),
                              _AssignmentSection.rejectedRequests => (
                                'Rejected requests',
                                rejectedState.total,
                              ),
                            };
                            return ChoiceChip(
                              label: Text('$label ($count)'),
                              selected: effectiveSection == section,
                              onSelected: (_) =>
                                  setState(() => _selectedSection = section),
                            );
                          })
                          .toList(growable: false),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (currentError != null && !_isSaving)
              AppEmptyState(
                icon: Icons.error_outline,
                title: 'Assignments unavailable',
                message: currentError,
                actionLabel: 'Retry',
                onAction: () {
                  switch (effectiveSection) {
                    case _AssignmentSection.assigned:
                      assignedController.refresh();
                      break;
                    case _AssignmentSection.available:
                      availableController.refresh();
                      break;
                    case _AssignmentSection.pendingRequests:
                      pendingController.refresh();
                      break;
                    case _AssignmentSection.rejectedRequests:
                      rejectedController.refresh();
                      break;
                  }
                },
              )
            else if (isCurrentLoading)
              const Center(child: CircularProgressIndicator())
            else
              switch (effectiveSection) {
                _AssignmentSection.assigned => _AssignmentListSection(
                  title: 'Assigned Contributors',
                  totalCount: assignedState.total,
                  resetKey: assignedQuery,
                  emptyTitle: 'No contributors assigned',
                  emptyMessage: isViewOnlyProject
                      ? 'Approved contributors assigned to this project remain visible here for reference.'
                      : 'Approved contributors assigned to this project appear here and can be unassigned at any time.',
                  hasMore: assignedState.hasMore,
                  isLoadingMore: assignedState.isLoadingMore,
                  onLoadMore: assignedController.loadMore,
                  children: assignedState.items
                      .map(
                        (assignment) => _AssignedContributorCard(
                          assignment: assignment,
                          isSaving: _isSaving,
                          isViewOnly: isViewOnlyProject,
                          onUnassign: () => _removeAssignment(assignment),
                        ),
                      )
                      .toList(growable: false),
                ),
                _AssignmentSection.available => _AssignmentListSection(
                  title: 'Available Approved Contributors',
                  totalCount: availableState.total,
                  resetKey: availableQuery,
                  emptyTitle: 'No eligible contributors available',
                  emptyMessage:
                      'Only active approved contributors who are not currently assigned to this project appear here.',
                  hasMore: availableState.hasMore,
                  isLoadingMore: availableState.isLoadingMore,
                  onLoadMore: availableController.loadMore,
                  children: availableState.items
                      .map(
                        (user) => _AvailableContributorCard(
                          user: user,
                          isSaving: _isSaving,
                          onAssign: () => _assignContributor(user),
                        ),
                      )
                      .toList(growable: false),
                ),
                _AssignmentSection.pendingRequests => _AssignmentListSection(
                  title: 'Pending Project Requests',
                  totalCount: pendingState.total,
                  resetKey: pendingQuery,
                  emptyTitle: 'No pending project requests',
                  emptyMessage:
                      'Contributor self-service requests for this project appear here until an admin approves or rejects them.',
                  hasMore: pendingState.hasMore,
                  isLoadingMore: pendingState.isLoadingMore,
                  onLoadMore: pendingController.loadMore,
                  children: pendingState.items
                      .map(
                        (assignment) => _PendingRequestCard(
                          assignment: assignment,
                          isSaving: _isSaving,
                          approveLabel: 'Approve',
                          rejectLabel: 'Reject',
                          onApprove: () => _updateAssignmentRequest(
                            assignment,
                            status: 'approved',
                          ),
                          onReject: () => _updateAssignmentRequest(
                            assignment,
                            status: 'rejected',
                          ),
                        ),
                      )
                      .toList(growable: false),
                ),
                _AssignmentSection.rejectedRequests => _AssignmentListSection(
                  title: 'Rejected Project Requests',
                  totalCount: rejectedState.total,
                  resetKey: rejectedQuery,
                  emptyTitle: 'No rejected project requests',
                  emptyMessage:
                      'Rejected project requests stay here so admins can re-approve them later if needed.',
                  hasMore: rejectedState.hasMore,
                  isLoadingMore: rejectedState.isLoadingMore,
                  onLoadMore: rejectedController.loadMore,
                  children: rejectedState.items
                      .map(
                        (assignment) => _PendingRequestCard(
                          assignment: assignment,
                          isSaving: _isSaving,
                          approveLabel: 'Re-accept',
                          rejectLabel: 'Keep rejected',
                          onApprove: () => _updateAssignmentRequest(
                            assignment,
                            status: 'approved',
                          ),
                          onReject: null,
                        ),
                      )
                      .toList(growable: false),
                ),
              },
          ],
        );
      },
    );
  }
}

class _AssignmentListSection extends StatelessWidget {
  const _AssignmentListSection({
    required this.title,
    required this.totalCount,
    required this.resetKey,
    required this.emptyTitle,
    required this.emptyMessage,
    required this.children,
    this.hasMore = false,
    this.isLoadingMore = false,
    this.onLoadMore,
  });

  final String title;
  final int totalCount;
  final Object resetKey;
  final String emptyTitle;
  final String emptyMessage;
  final List<Widget> children;
  final bool hasMore;
  final bool isLoadingMore;
  final Future<void> Function()? onLoadMore;

  @override
  Widget build(BuildContext context) {
    final _ = resetKey;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$title ($totalCount)',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: AppSpacing.sm),
        if (children.isEmpty)
          AppEmptyState(
            icon: Icons.group_off_outlined,
            title: emptyTitle,
            message: emptyMessage,
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 1120
                  ? 3
                  : constraints.maxWidth >= 720
                  ? 2
                  : 1;
              const gap = AppSpacing.sm;
              if (columns == 1) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var index = 0; index < children.length; index++) ...[
                      children[index],
                      if (index != children.length - 1)
                        const SizedBox(height: gap),
                    ],
                    if (hasMore) ...[
                      const SizedBox(height: AppSpacing.md),
                      Center(
                        child: OutlinedButton.icon(
                          onPressed: isLoadingMore ? null : onLoadMore,
                          icon: isLoadingMore
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.expand_more_outlined),
                          label: const Text('Show more'),
                        ),
                      ),
                    ],
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ..._buildResponsiveRows(children, columns: columns),
                  if (hasMore) ...[
                    const SizedBox(height: AppSpacing.md),
                    Center(
                      child: OutlinedButton.icon(
                        onPressed: isLoadingMore ? null : onLoadMore,
                        icon: isLoadingMore
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.expand_more_outlined),
                        label: const Text('Show more'),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
      ],
    );
  }

  List<Widget> _buildResponsiveRows(
    List<Widget> cards, {
    required int columns,
  }) {
    const gap = AppSpacing.sm;
    final rows = <Widget>[];
    for (var start = 0; start < cards.length; start += columns) {
      final end = (start + columns).clamp(0, cards.length);
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var index = start; index < start + columns; index++) ...[
              if (index > start) const SizedBox(width: gap),
              Expanded(
                child: index < end ? cards[index] : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      );
      if (end < cards.length) {
        rows.add(const SizedBox(height: gap));
      }
    }
    return rows;
  }
}

class _AssignedContributorCard extends StatelessWidget {
  const _AssignedContributorCard({
    required this.assignment,
    required this.isSaving,
    required this.isViewOnly,
    required this.onUnassign,
  });

  final ManagedAssignmentSummary assignment;
  final bool isSaving;
  final bool isViewOnly;
  final VoidCallback onUnassign;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            assignment.fullName,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(assignment.email, softWrap: true),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: const [
              Chip(label: Text('Contributor')),
              Chip(label: Text('Assigned')),
            ],
          ),
          if (!isViewOnly) ...[
            const SizedBox(height: AppSpacing.sm),
            AppActionButtons(
              maxColumns: 1,
              maxItemWidth: 190,
              children: [
                OutlinedButton.icon(
                  onPressed: isSaving ? null : onUnassign,
                  icon: const Icon(Icons.person_remove_outlined),
                  label: const Text('Unassign'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _AvailableContributorCard extends StatelessWidget {
  const _AvailableContributorCard({
    required this.user,
    required this.isSaving,
    required this.onAssign,
  });

  final ManagedUserSummary user;
  final bool isSaving;
  final VoidCallback onAssign;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(user.fullName, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(user.email, softWrap: true),
          if ((user.phone ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(LebanesePhone.format(user.phone), softWrap: true),
          ],
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [Chip(label: Text(user.accountStateLabel))],
          ),
          const SizedBox(height: AppSpacing.sm),
          AppActionButtons(
            maxColumns: 1,
            maxItemWidth: 240,
            children: [
              FilledButton.icon(
                onPressed: isSaving ? null : onAssign,
                icon: const Icon(Icons.person_add_alt_1_outlined),
                label: const Text('Assign contributor'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PendingRequestCard extends StatelessWidget {
  const _PendingRequestCard({
    required this.assignment,
    required this.isSaving,
    required this.approveLabel,
    required this.rejectLabel,
    required this.onApprove,
    this.onReject,
  });

  final ManagedAssignmentSummary assignment;
  final bool isSaving;
  final String approveLabel;
  final String rejectLabel;
  final VoidCallback onApprove;
  final VoidCallback? onReject;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            assignment.fullName,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(assignment.email, softWrap: true),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              const Chip(label: Text('Contributor')),
              Chip(label: Text('Request ${assignment.status}')),
              if (assignment.projectStatus.trim().isNotEmpty)
                Chip(label: Text('Project ${assignment.projectStatus}')),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          AppActionButtons(
            maxColumns: 2,
            maxItemWidth: 190,
            children: [
              if (onReject != null)
                FilledButton.tonal(
                  onPressed: isSaving ? null : onReject,
                  child: Text(rejectLabel),
                ),
              FilledButton(
                onPressed: isSaving ? null : onApprove,
                child: Text(approveLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
