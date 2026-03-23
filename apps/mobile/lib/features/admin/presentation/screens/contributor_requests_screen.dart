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

class ContributorRequestsScreen extends ConsumerStatefulWidget {
  const ContributorRequestsScreen({super.key});

  @override
  ConsumerState<ContributorRequestsScreen> createState() =>
      _ContributorRequestsScreenState();
}

class _ContributorRequestsScreenState
    extends ConsumerState<ContributorRequestsScreen> {
  _RequestGroup _selectedGroup = _RequestGroup.contributor;
  bool _isMutating = false;

  void _invalidate() {
    ref.invalidate(contributorRequestsProvider(ContributorRequestStatus.pending));
    ref.invalidate(contributorRequestsProvider(ContributorRequestStatus.rejected));
    ref.invalidate(managedAssignmentsProvider);
    ref.invalidate(managedUsersProvider);
    ref.invalidate(adminDashboardProvider);
  }

  Future<void> _approveContributor(String userId) async {
    await _mutate(
      () => ref.read(adminRepositoryProvider).approveContributor(userId),
      successMessage: 'Contributor request approved.',
    );
  }

  Future<void> _rejectContributor(String userId) async {
    await _mutate(
      () => ref.read(adminRepositoryProvider).rejectContributor(userId),
      successMessage: 'Contributor request rejected.',
    );
  }

  Future<void> _updateAssignmentStatus(
    ManagedAssignmentSummary assignment,
    String status,
  ) async {
    await _mutate(
      () => ref.read(adminRepositoryProvider).updateAssignmentStatus(
            assignmentId: assignment.id,
            status: status,
          ),
      successMessage: 'Project request $status successfully.',
    );
  }

  Future<void> _mutate(
    Future<dynamic> Function() action, {
    required String successMessage,
  }) async {
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

    return DefaultTabController(
      length: 2,
      child: ListView(
        children: [
          const SectionHeader(
            title: 'Requests',
            subtitle:
                'Review contributor access and project assignment requests in one place.',
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
                      label: Text('Contributor Requests'),
                      icon: Icon(Icons.person_add_alt_1_outlined),
                    ),
                    ButtonSegment(
                      value: _RequestGroup.project,
                      label: Text('Project Requests'),
                      icon: Icon(Icons.assignment_outlined),
                    ),
                  ],
                  selected: <_RequestGroup>{_selectedGroup},
                  onSelectionChanged: (selection) {
                    setState(() => _selectedGroup = selection.first);
                  },
                ),
                const SizedBox(height: AppSpacing.sm),
                if (_selectedGroup == _RequestGroup.contributor) ...[
                  const TabBar(
                    tabs: [
                      Tab(text: 'Pending'),
                      Tab(text: 'Rejected'),
                    ],
                  ),
                  SizedBox(
                    height: 560,
                    child: TabBarView(
                      children: [
                        pendingContributorAsync.when(
                          loading: () => const Center(
                            child: CircularProgressIndicator(),
                          ),
                          error: (error, _) => AppEmptyState(
                            icon: Icons.error_outline,
                            title: 'Contributor requests unavailable',
                            message: '$error',
                            actionLabel: 'Retry',
                            onAction: () => ref.invalidate(
                              contributorRequestsProvider(
                                ContributorRequestStatus.pending,
                              ),
                            ),
                          ),
                          data: (requests) => _RequestList(
                            emptyIcon: Icons.person_search_outlined,
                            emptyTitle: 'No pending contributor requests',
                            emptyMessage:
                                'New contributor signups waiting for approval will appear here.',
                            children: requests
                                .map(
                                  (request) => _RequestCard(
                                    title: request.fullName,
                                    subtitle: request.email,
                                    supporting:
                                        request.phone ?? 'No phone number provided',
                                    chips: [
                                      Chip(label: Text(request.roleLabel)),
                                      Chip(
                                        label: Text(request.accountStateLabel),
                                      ),
                                    ],
                                    actions: [
                                      FilledButton.tonal(
                                        onPressed: _isMutating
                                            ? null
                                            : () => _rejectContributor(
                                                request.id,
                                              ),
                                        child: const Text('Reject'),
                                      ),
                                      FilledButton(
                                        onPressed: _isMutating
                                            ? null
                                            : () => _approveContributor(
                                                request.id,
                                              ),
                                        child: const Text('Approve'),
                                      ),
                                    ],
                                  ),
                                )
                                .toList(growable: false),
                          ),
                        ),
                        rejectedContributorAsync.when(
                          loading: () => const Center(
                            child: CircularProgressIndicator(),
                          ),
                          error: (error, _) => AppEmptyState(
                            icon: Icons.error_outline,
                            title: 'Rejected requests unavailable',
                            message: '$error',
                            actionLabel: 'Retry',
                            onAction: () => ref.invalidate(
                              contributorRequestsProvider(
                                ContributorRequestStatus.rejected,
                              ),
                            ),
                          ),
                          data: (requests) => _RequestList(
                            emptyIcon: Icons.person_off_outlined,
                            emptyTitle: 'No rejected contributor requests',
                            emptyMessage:
                                'Rejected contributor requests stay visible here for recovery and audit.',
                            children: requests
                                .map(
                                  (request) => _RequestCard(
                                    title: request.fullName,
                                    subtitle: request.email,
                                    supporting:
                                        request.phone ?? 'No phone number provided',
                                    chips: const [
                                      Chip(label: Text('Rejected')),
                                    ],
                                    actions: [
                                      FilledButton(
                                        onPressed: _isMutating
                                            ? null
                                            : () => _approveContributor(
                                                request.id,
                                              ),
                                        child: const Text('Re-accept'),
                                      ),
                                    ],
                                  ),
                                )
                                .toList(growable: false),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  const TabBar(
                    tabs: [
                      Tab(text: 'Pending'),
                      Tab(text: 'Rejected'),
                    ],
                  ),
                  SizedBox(
                    height: 560,
                    child: assignmentsAsync.when(
                      loading: () => const Center(
                        child: CircularProgressIndicator(),
                      ),
                      error: (error, _) => AppEmptyState(
                        icon: Icons.error_outline,
                        title: 'Project requests unavailable',
                        message: '$error',
                        actionLabel: 'Retry',
                        onAction: () => ref.invalidate(managedAssignmentsProvider),
                      ),
                      data: (assignments) {
                        final pendingAssignments = assignments
                            .where((item) => item.status == 'pending')
                            .toList(growable: false);
                        final rejectedAssignments = assignments
                            .where((item) => item.status == 'rejected')
                            .toList(growable: false);

                        return TabBarView(
                          children: [
                            _RequestList(
                              emptyIcon: Icons.assignment_late_outlined,
                              emptyTitle: 'No pending project requests',
                              emptyMessage:
                                  'Pending assignment requests will appear here when contributors or admins request access.',
                              children: pendingAssignments
                                  .map(
                                    (assignment) => _RequestCard(
                                      title: assignment.projectName,
                                      subtitle: assignment.fullName,
                                      supporting:
                                          '${assignment.email} • ${assignment.role}',
                                      chips: [
                                        Chip(
                                          label: Text(
                                            'Project status: ${assignment.projectStatus}',
                                          ),
                                        ),
                                        Chip(
                                          label: Text(
                                            'Request: ${assignment.status}',
                                          ),
                                        ),
                                      ],
                                      actions: [
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
                                      ],
                                    ),
                                  )
                                  .toList(growable: false),
                            ),
                            _RequestList(
                              emptyIcon: Icons.assignment_returned_outlined,
                              emptyTitle: 'No rejected project requests',
                              emptyMessage:
                                  'Rejected assignment requests stay visible here for audit and later re-approval.',
                              children: rejectedAssignments
                                  .map(
                                    (assignment) => _RequestCard(
                                      title: assignment.projectName,
                                      subtitle: assignment.fullName,
                                      supporting:
                                          '${assignment.email} • ${assignment.role}',
                                      chips: const [
                                        Chip(label: Text('Rejected')),
                                      ],
                                      actions: [
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
                                  )
                                  .toList(growable: false),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RequestList extends StatelessWidget {
  const _RequestList({
    required this.emptyIcon,
    required this.emptyTitle,
    required this.emptyMessage,
    required this.children,
  });

  final IconData emptyIcon;
  final String emptyTitle;
  final String emptyMessage;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) {
      return AppEmptyState(
        icon: emptyIcon,
        title: emptyTitle,
        message: emptyMessage,
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      itemCount: children.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (_, index) => children[index],
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
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        borderRadius: AppRadii.md,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 2),
          Text(supporting, style: Theme.of(context).textTheme.bodySmall),
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
