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
  ContributorRequestStatus _selectedStatus = ContributorRequestStatus.pending;

  Future<void> _approve(String userId) async {
    try {
      await ref.read(adminRepositoryProvider).approveContributor(userId);
      ref.invalidate(contributorRequestsProvider(ContributorRequestStatus.pending));
      ref.invalidate(managedUsersProvider);
      if (mounted) {
        AppSnackbar.showSuccess(context, 'Contributor request approved.');
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(context, error.toString());
      }
    }
  }

  Future<void> _reject(String userId) async {
    try {
      await ref.read(adminRepositoryProvider).rejectContributor(userId);
      ref.invalidate(contributorRequestsProvider(ContributorRequestStatus.pending));
      ref.invalidate(contributorRequestsProvider(ContributorRequestStatus.rejected));
      ref.invalidate(managedUsersProvider);
      if (mounted) {
        AppSnackbar.showSuccess(context, 'Contributor request rejected.');
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(context, error.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final requestsAsync = ref.watch(contributorRequestsProvider(_selectedStatus));

    return ListView(
      children: [
        const SectionHeader(
          title: 'Contributor Requests',
          subtitle: 'Approve or reject contributor access before field access is granted.',
        ),
        const SizedBox(height: AppSpacing.sm),
        SegmentedButton<ContributorRequestStatus>(
          segments: const [
            ButtonSegment(
              value: ContributorRequestStatus.pending,
              label: Text('Pending'),
            ),
            ButtonSegment(
              value: ContributorRequestStatus.rejected,
              label: Text('Rejected'),
            ),
          ],
          selected: {_selectedStatus},
          onSelectionChanged: (selection) {
            setState(() {
              _selectedStatus = selection.first;
            });
          },
        ),
        const SizedBox(height: AppSpacing.md),
        requestsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => AppEmptyState(
            icon: Icons.error_outline,
            title: 'Requests unavailable',
            message: '$error',
            actionLabel: 'Retry',
            onAction: () => ref.invalidate(
              contributorRequestsProvider(_selectedStatus),
            ),
          ),
          data: (requests) {
            if (requests.isEmpty) {
              return AppEmptyState(
                icon: Icons.person_search_outlined,
                title: 'No ${_selectedStatus.name} requests',
                message: _selectedStatus == ContributorRequestStatus.pending
                    ? 'New contributor requests will appear here for approval.'
                    : 'Rejected contributor requests will appear here for audit visibility.',
              );
            }
            return Column(
              children: requests
                  .map(
                    (request) => Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: AppCard(
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(request.fullName),
                          subtitle: Text('${request.email}\n${request.phone ?? 'No phone'}'),
                          isThreeLine: true,
                          trailing: _selectedStatus == ContributorRequestStatus.pending
                              ? Wrap(
                                  spacing: 8,
                                  children: [
                                    FilledButton.tonal(
                                      onPressed: () => _reject(request.id),
                                      child: const Text('Reject'),
                                    ),
                                    FilledButton(
                                      onPressed: () => _approve(request.id),
                                      child: const Text('Approve'),
                                    ),
                                  ],
                                )
                              : const Chip(label: Text('Rejected')),
                        ),
                      ),
                    ),
                  )
                  .toList(growable: false),
            );
          },
        ),
      ],
    );
  }
}
