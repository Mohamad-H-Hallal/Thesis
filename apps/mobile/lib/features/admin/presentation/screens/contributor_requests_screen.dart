import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/section_header.dart';
import '../../domain/admin_models.dart';

class ContributorRequestsScreen extends ConsumerStatefulWidget {
  const ContributorRequestsScreen({super.key});

  @override
  ConsumerState<ContributorRequestsScreen> createState() =>
      _ContributorRequestsScreenState();
}

class _ContributorRequestsScreenState
    extends ConsumerState<ContributorRequestsScreen> {
  bool _isMutating = false;

  Future<void> _approve(String userId) async {
    setState(() => _isMutating = true);
    try {
      await ref.read(adminRepositoryProvider).approveContributor(userId);
      _invalidate();
      if (mounted) {
        AppSnackbar.showSuccess(context, 'Contributor request approved.');
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

  Future<void> _reject(String userId) async {
    setState(() => _isMutating = true);
    try {
      await ref.read(adminRepositoryProvider).rejectContributor(userId);
      _invalidate();
      if (mounted) {
        AppSnackbar.showSuccess(context, 'Contributor request rejected.');
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

  Future<void> _updateAssignmentStatus(
    ManagedAssignmentSummary assignment,
    String status,
  ) async {
    setState(() => _isMutating = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .updateAssignmentStatus(assignmentId: assignment.id, status: status);
      _invalidate();
      if (mounted) {
        AppSnackbar.showSuccess(context, 'Assignment $status successfully.');
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

  @override
  Widget build(BuildContext context) {
    final pendingRequestsAsync = ref.watch(
      contributorRequestsProvider(ContributorRequestStatus.pending),
    );
    final rejectedRequestsAsync = ref.watch(
      contributorRequestsProvider(ContributorRequestStatus.rejected),
    );
    final assignmentsAsync = ref.watch(managedAssignmentsProvider);

    return ListView(
      children: [
        const SectionHeader(
          title: 'Requests',
          subtitle:
              'Approve contributor access and resolve assignment approvals before field work begins.',
        ),
        const SizedBox(height: AppSpacing.md),
        _SectionBlock(
          title: 'Pending contributor requests',
          child: pendingRequestsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => AppEmptyState(
              icon: Icons.error_outline,
              title: 'Contributor requests unavailable',
              message: '$error',
              actionLabel: 'Retry',
              onAction: () => ref.invalidate(
                contributorRequestsProvider(ContributorRequestStatus.pending),
              ),
            ),
            data: (requests) {
              if (requests.isEmpty) {
                return const AppEmptyState(
                  icon: Icons.person_search_outlined,
                  title: 'No pending contributor requests',
                  message:
                      'New contributor signups waiting for approval will appear here.',
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
                          supporting:
                              request.phone ?? 'No phone number provided',
                          chips: [
                            Chip(label: Text(request.roleLabel)),
                            Chip(
                              label: Text(
                                request.isActive ? 'Active' : 'Inactive',
                              ),
                            ),
                          ],
                          trailing: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton.tonal(
                                onPressed: _isMutating
                                    ? null
                                    : () => _reject(request.id),
                                child: const Text('Reject'),
                              ),
                              FilledButton(
                                onPressed: _isMutating
                                    ? null
                                    : () => _approve(request.id),
                                child: const Text('Approve'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                    .toList(growable: false),
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        _SectionBlock(
          title: 'Pending project assignments',
          child: assignmentsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => AppEmptyState(
              icon: Icons.error_outline,
              title: 'Assignments unavailable',
              message: '$error',
              actionLabel: 'Retry',
              onAction: () => ref.invalidate(managedAssignmentsProvider),
            ),
            data: (assignments) {
              final pendingAssignments = assignments
                  .where((item) => item.status == 'pending')
                  .toList(growable: false);
              if (pendingAssignments.isEmpty) {
                return const AppEmptyState(
                  icon: Icons.assignment_turned_in_outlined,
                  title: 'No pending assignments',
                  message:
                      'Project assignment approvals will appear here when they need action.',
                );
              }
              return Column(
                children: pendingAssignments
                    .map(
                      (assignment) => Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: _RequestCard(
                          title: assignment.projectName,
                          subtitle: assignment.fullName,
                          supporting:
                              '${assignment.email} • ${assignment.role}',
                          chips: [
                            Chip(label: Text('Status: ${assignment.status}')),
                          ],
                          trailing: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
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
                        ),
                      ),
                    )
                    .toList(growable: false),
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        _SectionBlock(
          title: 'Rejected contributor requests',
          child: rejectedRequestsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => AppEmptyState(
              icon: Icons.error_outline,
              title: 'Rejected requests unavailable',
              message: '$error',
              actionLabel: 'Retry',
              onAction: () => ref.invalidate(
                contributorRequestsProvider(ContributorRequestStatus.rejected),
              ),
            ),
            data: (requests) {
              if (requests.isEmpty) {
                return const AppEmptyState(
                  icon: Icons.person_off_outlined,
                  title: 'No rejected contributor requests',
                  message:
                      'Rejected requests are kept here for audit visibility.',
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
                          supporting:
                              request.phone ?? 'No phone number provided',
                          chips: const [Chip(label: Text('Rejected'))],
                        ),
                      ),
                    )
                    .toList(growable: false),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SectionBlock extends StatelessWidget {
  const _SectionBlock({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          child,
        ],
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({
    required this.title,
    required this.subtitle,
    required this.supporting,
    required this.chips,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final String supporting;
  final List<Widget> chips;
  final Widget? trailing;

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
          if (trailing != null) ...[
            const SizedBox(height: AppSpacing.sm),
            trailing!,
          ],
        ],
      ),
    );
  }
}
