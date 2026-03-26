import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/section_header.dart';
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
  _RequestGroup _selectedGroup = _RequestGroup.contributor;
  _RequestStateTab _selectedState = _RequestStateTab.pending;
  bool _isMutating = false;

  void _invalidate() {
    ref.invalidate(
      contributorRequestsProvider(ContributorRequestStatus.pending),
    );
    ref.invalidate(
      contributorRequestsProvider(ContributorRequestStatus.rejected),
    );
    ref.invalidate(managedAssignmentsProvider);
    ref.invalidate(managedUsersProvider);
    ref.invalidate(adminDashboardProvider);
  }

  Future<void> _approveContributor(String userId) async {
    await _mutate(
      action: () =>
          ref.read(adminRepositoryProvider).approveContributor(userId),
      dialogTitle: 'Approve contributor request',
      dialogMessage: 'Approve this contributor request?',
      successMessage: 'Contributor request approved.',
    );
  }

  Future<void> _rejectContributor(String userId) async {
    await _mutate(
      action: () => ref.read(adminRepositoryProvider).rejectContributor(userId),
      dialogTitle: 'Reject contributor request',
      dialogMessage: 'Reject this contributor request?',
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
          : 'Reject ${assignment.fullName} for ${assignment.projectName}?',
      successMessage: isApprove
          ? 'Project request approved.'
          : 'Project request rejected.',
    );
  }

  Future<void> _mutate({
    required Future<dynamic> Function() action,
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
            child: const Text('Confirm'),
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
        AppSnackbar.showError(context, error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _isMutating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pendingContributorAsync = ref.watch(
      contributorRequestsProvider(ContributorRequestStatus.pending),
    );
    final rejectedContributorAsync = ref.watch(
      contributorRequestsProvider(ContributorRequestStatus.rejected),
    );
    final assignmentsAsync = ref.watch(managedAssignmentsProvider);

    return ListView(
      children: [
        const SectionHeader(
          title: 'Requests',
          subtitle:
              'Review contributor account requests and project access requests.',
        ),
        const SizedBox(height: AppSpacing.sm),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<_RequestGroup>(
                segments: const [
                  ButtonSegment(
                    value: _RequestGroup.contributor,
                    label: Text('Contributor'),
                    icon: Icon(Icons.person_add_alt_1_outlined),
                  ),
                  ButtonSegment(
                    value: _RequestGroup.project,
                    label: Text('Projects'),
                    icon: Icon(Icons.assignment_outlined),
                  ),
                ],
                selected: <_RequestGroup>{_selectedGroup},
                onSelectionChanged: (selection) {
                  if (selection.isEmpty) {
                    return;
                  }
                  setState(() => _selectedGroup = selection.first);
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              SegmentedButton<_RequestStateTab>(
                segments: const [
                  ButtonSegment(
                    value: _RequestStateTab.pending,
                    label: Text('Pending'),
                  ),
                  ButtonSegment(
                    value: _RequestStateTab.rejected,
                    label: Text('Rejected'),
                  ),
                ],
                selected: <_RequestStateTab>{_selectedState},
                onSelectionChanged: (selection) {
                  if (selection.isEmpty) {
                    return;
                  }
                  setState(() => _selectedState = selection.first);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (_selectedGroup == _RequestGroup.contributor)
          _buildContributorRequests(
            pendingContributorAsync: pendingContributorAsync,
            rejectedContributorAsync: rejectedContributorAsync,
          )
        else
          _buildProjectRequests(assignmentsAsync),
      ],
    );
  }

  Widget _buildContributorRequests({
    required AsyncValue<List<ManagedUserSummary>> pendingContributorAsync,
    required AsyncValue<List<ManagedUserSummary>> rejectedContributorAsync,
  }) {
    final currentAsync = _selectedState == _RequestStateTab.pending
        ? pendingContributorAsync
        : rejectedContributorAsync;

    return currentAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Contributor requests unavailable',
        message: '$error',
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(
          contributorRequestsProvider(
            _selectedState == _RequestStateTab.pending
                ? ContributorRequestStatus.pending
                : ContributorRequestStatus.rejected,
          ),
        ),
      ),
      data: (requests) {
        if (requests.isEmpty) {
          return AppEmptyState(
            icon: _selectedState == _RequestStateTab.pending
                ? Icons.person_search_outlined
                : Icons.person_off_outlined,
            title: _selectedState == _RequestStateTab.pending
                ? 'No pending contributor requests'
                : 'No rejected contributor requests',
            message: _selectedState == _RequestStateTab.pending
                ? 'New contributor signups waiting for approval appear here.'
                : 'Rejected contributor requests remain here for audit and later recovery.',
          );
        }

        return Column(
          children: requests
              .map(
                (request) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: _RequestCard(
                    title: request.fullName,
                    subtitle: request.email,
                    supporting: request.phone?.trim().isNotEmpty == true
                        ? request.phone!
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
              )
              .toList(growable: false),
        );
      },
    );
  }

  Widget _buildProjectRequests(
    AsyncValue<List<ManagedAssignmentSummary>> assignmentsAsync,
  ) {
    return assignmentsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Project requests unavailable',
        message: '$error',
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(managedAssignmentsProvider),
      ),
      data: (assignments) {
        final filtered = assignments
            .where(
              (item) =>
                  item.status ==
                  (_selectedState == _RequestStateTab.pending
                      ? 'pending'
                      : 'rejected'),
            )
            .toList(growable: false);

        if (filtered.isEmpty) {
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
          children: filtered
              .map(
                (assignment) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: _RequestCard(
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
              )
              .toList(growable: false),
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
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );
  }
}
