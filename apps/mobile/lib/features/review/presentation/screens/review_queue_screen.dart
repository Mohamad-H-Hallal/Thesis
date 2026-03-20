import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../domain/review_item.dart';

class ReviewQueueScreen extends ConsumerWidget {
  const ReviewQueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queueAsync = ref.watch(reviewQueueProvider);

    return queueAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Review queue unavailable',
        message: '$error',
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(reviewQueueProvider),
      ),
      data: (items) {
        if (items.isEmpty) {
          return ListView(
            children: const [
              SectionHeader(
                title: 'Review Queue',
                subtitle: 'Server-side feature submissions awaiting moderation.',
              ),
              SizedBox(height: 24),
              AppEmptyState(
                icon: Icons.rate_review_outlined,
                title: 'No items in queue',
                message:
                    'Submitted features awaiting moderation will appear here.',
              ),
            ],
          );
        }

        return ListView(
          children: [
            SectionHeader(
              title: 'Review Queue',
              subtitle: '${items.length} feature(s) awaiting admin review',
            ),
            const SizedBox(height: AppSpacing.md),
            ...items.map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
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
                                  item.projectName,
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${item.geometryType} • ${item.collectedBy ?? 'Unknown collector'}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                if (item.collectedAt != null)
                                  Text(
                                    'Collected ${_formatDateTime(item.collectedAt!)}',
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          StatusChip(status: item.status),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          Chip(label: Text('Feature ${item.id.substring(0, 8)}')),
                          Chip(label: Text('${item.photoCount} photo(s)')),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: () => _review(
                              context,
                              ref,
                              item: item,
                              status: 'approved',
                            ),
                            icon: const Icon(Icons.check_circle_outline, size: 18),
                            label: const Text('Approve'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: () => _review(
                              context,
                              ref,
                              item: item,
                              status: 'rejected',
                            ),
                            icon: const Icon(Icons.cancel_outlined, size: 18),
                            label: const Text('Reject'),
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

  Future<void> _review(
    BuildContext context,
    WidgetRef ref, {
    required ReviewQueueItem item,
    required String status,
  }) async {
    final note = await _promptNote(
      context,
      title: status == 'approved' ? 'Approval note' : 'Rejection note',
      hint: status == 'approved'
          ? 'Optional context for the contributor.'
          : 'Required reason for rejection.',
      requiredNote: status == 'rejected',
    );
    if (note == null) {
      return;
    }

    try {
      await ref.read(reviewRepositoryProvider).reviewFeature(
            featureId: item.id,
            status: status,
            reviewNotes: note,
          );
      ref.invalidate(reviewQueueProvider);
      ref.invalidate(projectMapFeaturesProvider(item.projectId));
      if (context.mounted) {
        AppSnackbar.showSuccess(
          context,
          status == 'approved'
              ? 'Feature approved successfully.'
              : 'Feature rejected successfully.',
        );
      }
    } catch (error) {
      if (context.mounted) {
        AppSnackbar.showError(context, error.toString());
      }
    }
  }

  Future<String?> _promptNote(
    BuildContext context, {
    required String title,
    required String hint,
    bool requiredNote = false,
  }) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(hintText: hint),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (requiredNote && value.isEmpty) {
                  return;
                }
                Navigator.of(context).pop(value);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  String _formatDateTime(DateTime value) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$month-$day $hour:$minute';
  }
}
