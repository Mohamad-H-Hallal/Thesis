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
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../domain/review_item.dart';

enum _ReviewFilter { pending, rejected }

class ReviewQueueScreen extends ConsumerStatefulWidget {
  const ReviewQueueScreen({super.key});

  @override
  ConsumerState<ReviewQueueScreen> createState() => _ReviewQueueScreenState();
}

class _ReviewQueueScreenState extends ConsumerState<ReviewQueueScreen> {
  final TextEditingController _searchController = TextEditingController();
  _ReviewFilter _filter = _ReviewFilter.pending;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pendingAsync = ref.watch(reviewQueueProvider);
    final rejectedAsync = ref.watch(rejectedReviewQueueProvider);

    final currentAsync = _filter == _ReviewFilter.pending
        ? pendingAsync
        : rejectedAsync;

    return currentAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Review queue unavailable',
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to load review items right now. Please try again.',
        ),
        actionLabel: 'Retry',
        onAction: () => _filter == _ReviewFilter.pending
            ? ref.invalidate(reviewQueueProvider)
            : ref.invalidate(rejectedReviewQueueProvider),
      ),
      data: (items) {
        final query = _searchController.text.trim().toLowerCase();
        final filtered = items
            .where((item) {
              if (query.isEmpty) {
                return true;
              }
              return item.projectName.toLowerCase().contains(query) ||
                  (item.collectedBy ?? '').toLowerCase().contains(query) ||
                  item.id.toLowerCase().contains(query);
            })
            .toList(growable: false);

        return ListView(
          children: [
            SectionHeader(
              title: 'Reviews',
              subtitle: _filter == _ReviewFilter.pending
                  ? '${items.length} feature(s) awaiting admin review'
                  : '${items.length} rejected feature(s) available for re-review',
            ),
            const SizedBox(height: AppSpacing.sm),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SearchBar(
                    controller: _searchController,
                    hintText: 'Search reviews by project, collector, or ID',
                    leading: const Icon(Icons.search),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('Pending'),
                        selected: _filter == _ReviewFilter.pending,
                        onSelected: (_) =>
                            setState(() => _filter = _ReviewFilter.pending),
                      ),
                      ChoiceChip(
                        label: const Text('Rejected'),
                        selected: _filter == _ReviewFilter.rejected,
                        onSelected: (_) =>
                            setState(() => _filter = _ReviewFilter.rejected),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (filtered.isEmpty)
              AppEmptyState(
                icon: _filter == _ReviewFilter.pending
                    ? Icons.rate_review_outlined
                    : Icons.cancel_outlined,
                title: _filter == _ReviewFilter.pending
                    ? 'No pending reviews'
                    : 'No rejected reviews',
                message: _filter == _ReviewFilter.pending
                    ? 'Submitted features awaiting moderation will appear here.'
                    : 'Rejected items remain here so admins can reopen them when needed.',
              )
            else
              ...filtered.map(
                (item) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: _ReviewItemCard(
                    item: item,
                    onOpenMap: () => context.push(
                      AppRoutes.mapForProject(
                        item.projectId,
                        featureId: item.id,
                      ),
                    ),
                    onApprove: () =>
                        _review(context, ref, item: item, status: 'approved'),
                    onReject: () =>
                        _review(context, ref, item: item, status: 'rejected'),
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
      await ref
          .read(reviewRepositoryProvider)
          .reviewFeature(featureId: item.id, status: status, reviewNotes: note);
      bumpWorkflowRefresh(ref);
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
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to update this review right now.',
          ),
        );
      }
    }
  }

  Future<String?> _promptNote(
    BuildContext context, {
    required String title,
    required String hint,
    bool requiredNote = false,
  }) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _ReviewNoteDialog(
        title: title,
        hint: hint,
        requiredNote: requiredNote,
      ),
    );
  }
}

class _ReviewNoteDialog extends StatefulWidget {
  const _ReviewNoteDialog({
    required this.title,
    required this.hint,
    required this.requiredNote,
  });

  final String title;
  final String hint;
  final bool requiredNote;

  @override
  State<_ReviewNoteDialog> createState() => _ReviewNoteDialogState();
}

class _ReviewNoteDialogState extends State<_ReviewNoteDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (widget.requiredNote && value.isEmpty) {
      setState(() {
        _errorText = 'A review note is required before you can continue.';
      });
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_errorText != null) ...[
              Text(
                _errorText!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
                softWrap: true,
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            AppTextField(
              label: 'Review note',
              controller: _controller,
              hint: widget.hint,
              minLines: 2,
              maxLines: 4,
              onChanged: (_) {
                if (_errorText != null) {
                  setState(() => _errorText = null);
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

class _ReviewItemCard extends StatelessWidget {
  const _ReviewItemCard({
    required this.item,
    required this.onOpenMap,
    required this.onApprove,
    required this.onReject,
  });

  final ReviewQueueItem item;
  final VoidCallback onOpenMap;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final isRejected = item.status == 'rejected';
    return AppCard(
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
              OutlinedButton.icon(
                onPressed: onOpenMap,
                icon: const Icon(Icons.map_outlined, size: 18),
                label: const Text('Open on map'),
              ),
              FilledButton.icon(
                onPressed: onApprove,
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: Text(isRejected ? 'Re-approve' : 'Approve'),
              ),
              FilledButton.tonalIcon(
                onPressed: onReject,
                icon: const Icon(Icons.cancel_outlined, size: 18),
                label: Text(isRejected ? 'Keep rejected' : 'Reject'),
              ),
            ],
          ),
        ],
      ),
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
