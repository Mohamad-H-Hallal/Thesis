import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/pagination/paginated_list_controller.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_action_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_dialog_actions.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_search_action_bar.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/progressive_list_section.dart';
import '../../../../core/utils/lebanese_phone.dart';
import '../../domain/admin_models.dart';

enum _RequestGroup { contributor, project }

enum _RequestStateTab { pending, rejected }

class ContributorRequestsScreen extends ConsumerStatefulWidget {
  const ContributorRequestsScreen({super.key});

  @override
  ConsumerState<ContributorRequestsScreen> createState() =>
      _ContributorRequestsScreenState();
}

class _ContributorRequestsScreenState
    extends ConsumerState<ContributorRequestsScreen> {
  final TextEditingController _searchController = TextEditingController();

  _RequestGroup _selectedGroup = _RequestGroup.contributor;
  _RequestStateTab _selectedState = _RequestStateTab.pending;
  bool _isMutating = false;
  bool _showFilters = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _invalidate() {
    bumpRealtimeScope(ref, const RealtimeScope('users', 'all'));
  }

  Future<void> _approveContributor(String userId) async {
    await _mutate(
      action: () =>
          ref.read(adminRepositoryProvider).approveContributor(userId),
      dialogTitle: 'Approve contributor request',
      dialogMessage: 'Approve this contributor request?',
      confirmLabel: 'Approve',
      successMessage: 'Contributor request approved.',
    );
  }

  Future<void> _rejectContributor(String userId) async {
    await _mutate(
      action: () => ref.read(adminRepositoryProvider).rejectContributor(userId),
      dialogTitle: 'Reject contributor request',
      dialogMessage:
          'Reject this contributor request? The contributor will remain unable to sign in until an admin changes this decision.',
      confirmLabel: 'Reject',
      successMessage: 'Contributor request rejected.',
    );
  }

  Future<void> _updateAssignmentStatus(
    ManagedAssignmentSummary assignment,
    String status,
  ) async {
    final isApprove = status == 'approved';
    await _mutate(
      action: () => ref
          .read(adminRepositoryProvider)
          .updateAssignmentStatus(assignmentId: assignment.id, status: status),
      dialogTitle: isApprove
          ? 'Approve project request'
          : 'Reject project request',
      dialogMessage: isApprove
          ? 'Approve ${assignment.fullName} for ${assignment.projectName}?'
          : 'Reject ${assignment.fullName} for ${assignment.projectName}? The contributor will stay outside this project until re-approved.',
      confirmLabel: isApprove ? 'Approve' : 'Reject',
      successMessage: isApprove
          ? 'Project request approved.'
          : 'Project request rejected.',
    );
  }

  Future<void> _mutate({
    required Future<dynamic> Function() action,
    required String dialogTitle,
    required String dialogMessage,
    required String confirmLabel,
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
              child: Text(confirmLabel),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    setState(() => _isMutating = true);
    try {
      await action();
      _invalidate();
      if (mounted) {
        AppSnackbar.showSuccess(context, successMessage);
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to update this request right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isMutating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final searchQuery = _searchController.text.trim();
    final contributorAsync = _selectedGroup == _RequestGroup.contributor
        ? ref.watch(
            paginatedContributorRequestsProvider(
              ContributorRequestsQuery(
                status: _selectedState == _RequestStateTab.pending
                    ? ContributorRequestStatus.pending
                    : ContributorRequestStatus.rejected,
                query: searchQuery.isEmpty ? null : searchQuery,
              ),
            ),
          )
        : const AsyncValue<PaginatedListState<ManagedUserSummary>>.data(
            PaginatedListState<ManagedUserSummary>.initial(),
          );
    final contributorController = ref.read(
      paginatedContributorRequestsProvider(
        ContributorRequestsQuery(
          status: _selectedState == _RequestStateTab.pending
              ? ContributorRequestStatus.pending
              : ContributorRequestStatus.rejected,
          query: searchQuery.isEmpty ? null : searchQuery,
        ),
      ).notifier,
    );
    final assignmentsAsync = _selectedGroup == _RequestGroup.project
        ? ref.watch(
            paginatedManagedAssignmentsProvider(
              ManagedAssignmentsQuery(
                status: _selectedState == _RequestStateTab.pending
                    ? 'pending'
                    : 'rejected',
                query: searchQuery.isEmpty ? null : searchQuery,
              ),
            ),
          )
        : const AsyncValue<PaginatedListState<ManagedAssignmentSummary>>.data(
            PaginatedListState<ManagedAssignmentSummary>.initial(),
          );
    final assignmentsController = ref.read(
      paginatedManagedAssignmentsProvider(
        ManagedAssignmentsQuery(
          status: _selectedState == _RequestStateTab.pending
              ? 'pending'
              : 'rejected',
          query: searchQuery.isEmpty ? null : searchQuery,
        ),
      ).notifier,
    );

    return ListView(
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppSearchActionBar(
                searchBar: SearchBar(
                  controller: _searchController,
                  hintText: _selectedGroup == _RequestGroup.contributor
                      ? 'Search contributor name, email, or phone'
                      : 'Search project, contributor, or email',
                  leading: const Icon(Icons.search),
                  onChanged: (_) => setState(() {}),
                ),
                actions: [
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
              if (_showFilters) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Request type',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _RequestGroup.values
                      .map(
                        (group) => ChoiceChip(
                          label: Text(
                            group == _RequestGroup.contributor
                                ? 'Contributor'
                                : 'Projects',
                          ),
                          selected: _selectedGroup == group,
                          onSelected: (_) =>
                              setState(() => _selectedGroup = group),
                        ),
                      )
                      .toList(growable: false),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Workflow state',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _RequestStateTab.values
                      .map(
                        (tab) => ChoiceChip(
                          label: Text(
                            tab == _RequestStateTab.pending
                                ? 'Pending'
                                : 'Rejected',
                          ),
                          selected: _selectedState == tab,
                          onSelected: (_) =>
                              setState(() => _selectedState = tab),
                        ),
                      )
                      .toList(growable: false),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (_selectedGroup == _RequestGroup.contributor)
          _buildContributorRequests(contributorAsync, contributorController)
        else
          _buildProjectRequests(assignmentsAsync, assignmentsController),
      ],
    );
  }

  Widget _buildContributorRequests(
    AsyncValue<PaginatedListState<ManagedUserSummary>> currentAsync,
    PaginatedListController<ManagedUserSummary> controller,
  ) {
    return currentAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Contributor requests unavailable',
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to load requests right now. Please try again.',
        ),
        actionLabel: 'Retry',
        onAction: controller.load,
      ),
      data: (requestsState) {
        if (requestsState.items.isEmpty) {
          return AppEmptyState(
            icon: _selectedState == _RequestStateTab.pending
                ? Icons.person_search_outlined
                : Icons.person_off_outlined,
            title: _selectedState == _RequestStateTab.pending
                ? 'No pending contributor requests'
                : 'No rejected contributor requests',
            message: _selectedState == _RequestStateTab.pending
                ? 'New contributor signups waiting for approval appear here.'
                : 'Rejected contributor requests remain here for review and later recovery.',
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${requestsState.total} request${requestsState.total == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            ProgressiveListSection<ManagedUserSummary>(
              items: requestsState.items,
              resetKey: Object.hash(
                _selectedGroup,
                _selectedState,
                _searchController.text,
                requestsState.total,
              ),
              hasMore: requestsState.hasMore,
              isLoadingMore: requestsState.isLoadingMore,
              onLoadMore: controller.loadMore,
              gridMinItemWidth: 380,
              itemBuilder: (context, request, _) => _RequestCard(
                title: request.fullName,
                subtitle: request.email,
                supporting: request.phone?.trim().isNotEmpty == true
                    ? LebanesePhone.format(request.phone)
                    : 'No phone number provided',
                chips: [
                  Chip(label: Text(request.roleLabel)),
                  Chip(label: Text(request.accountStateLabel)),
                ],
                actions: _selectedState == _RequestStateTab.pending
                    ? [
                        FilledButton.tonal(
                          onPressed: _isMutating
                              ? null
                              : () => _rejectContributor(request.id),
                          child: const Text('Reject'),
                        ),
                        FilledButton(
                          onPressed: _isMutating
                              ? null
                              : () => _approveContributor(request.id),
                          child: const Text('Approve'),
                        ),
                      ]
                    : [
                        FilledButton(
                          onPressed: _isMutating
                              ? null
                              : () => _approveContributor(request.id),
                          child: const Text('Re-accept'),
                        ),
                      ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildProjectRequests(
    AsyncValue<PaginatedListState<ManagedAssignmentSummary>> assignmentsAsync,
    PaginatedListController<ManagedAssignmentSummary> controller,
  ) {
    return assignmentsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Project requests unavailable',
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to load requests right now. Please try again.',
        ),
        actionLabel: 'Retry',
        onAction: controller.load,
      ),
      data: (assignmentsState) {
        if (assignmentsState.items.isEmpty) {
          return AppEmptyState(
            icon: _selectedState == _RequestStateTab.pending
                ? Icons.assignment_late_outlined
                : Icons.assignment_returned_outlined,
            title: _selectedState == _RequestStateTab.pending
                ? 'No pending project requests'
                : 'No rejected project requests',
            message: _selectedState == _RequestStateTab.pending
                ? 'Pending contributor project-access requests appear here.'
                : 'Rejected project-access requests remain here for audit and re-approval.',
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${assignmentsState.total} request${assignmentsState.total == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            ProgressiveListSection<ManagedAssignmentSummary>(
              items: assignmentsState.items,
              resetKey: Object.hash(
                _selectedGroup,
                _selectedState,
                _searchController.text,
                assignmentsState.total,
              ),
              hasMore: assignmentsState.hasMore,
              isLoadingMore: assignmentsState.isLoadingMore,
              onLoadMore: controller.loadMore,
              gridMinItemWidth: 380,
              itemBuilder: (context, assignment, _) => _RequestCard(
                title: assignment.projectName,
                subtitle: assignment.fullName,
                supporting: assignment.email,
                chips: [
                  Chip(label: Text('Project ${assignment.projectStatus}')),
                  Chip(label: Text('Request ${assignment.status}')),
                ],
                actions: _selectedState == _RequestStateTab.pending
                    ? [
                        FilledButton.tonal(
                          onPressed: _isMutating
                              ? null
                              : () => _updateAssignmentStatus(
                                  assignment,
                                  'rejected',
                                ),
                          child: const Text('Reject'),
                        ),
                        FilledButton(
                          onPressed: _isMutating
                              ? null
                              : () => _updateAssignmentStatus(
                                  assignment,
                                  'approved',
                                ),
                          child: const Text('Approve'),
                        ),
                      ]
                    : [
                        FilledButton(
                          onPressed: _isMutating
                              ? null
                              : () => _updateAssignmentStatus(
                                  assignment,
                                  'approved',
                                ),
                          child: const Text('Re-accept'),
                        ),
                      ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({
    required this.title,
    required this.subtitle,
    required this.supporting,
    required this.chips,
    this.actions = const <Widget>[],
  });

  final String title;
  final String subtitle;
  final String supporting;
  final List<Widget> chips;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(subtitle, softWrap: true),
          const SizedBox(height: 2),
          Text(supporting, softWrap: true),
          const SizedBox(height: AppSpacing.sm),
          Wrap(spacing: 8, runSpacing: 8, children: chips),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            AppActionButtons(maxColumns: 2, children: actions),
          ],
        ],
      ),
    );
  }
}
