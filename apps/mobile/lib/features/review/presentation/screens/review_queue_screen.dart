import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/utils/lebanon_time.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_action_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_dialog_actions.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_search_action_bar.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/progressive_list_section.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../domain/review_item.dart';

enum _ReviewFilter { pending, rejected }

class ReviewQueueScreen extends ConsumerStatefulWidget {
  const ReviewQueueScreen({this.projectId, this.projectName, super.key});

  final String? projectId;
  final String? projectName;

  @override
  ConsumerState<ReviewQueueScreen> createState() => _ReviewQueueScreenState();
}

class _ReviewQueueScreenState extends ConsumerState<ReviewQueueScreen> {
  final TextEditingController _searchController = TextEditingController();
  _ReviewFilter _filter = _ReviewFilter.pending;
  bool _showFilters = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fixedProjectId = widget.projectId?.trim();
    final hasFixedProject = fixedProjectId != null && fixedProjectId.isNotEmpty;
    final searchText = _searchController.text.trim();
    final query = ReviewQueueQuery(
      status: _filter == _ReviewFilter.pending ? 'pending_review' : 'rejected',
      projectId: hasFixedProject ? fixedProjectId : null,
      search: searchText.isEmpty ? null : searchText,
    );
    final currentAsync = ref.watch(paginatedReviewQueueProvider(query));
    final controller = ref.read(paginatedReviewQueueProvider(query).notifier);

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
        onAction: controller.load,
      ),
      data: (itemsState) {
        final filtered = itemsState.items;

        return ListView(
          children: [
            Text(
              hasFixedProject
                  ? _filter == _ReviewFilter.pending
                        ? '${itemsState.total} feature(s) awaiting review for ${widget.projectName ?? 'this project'}'
                        : '${itemsState.total} rejected feature(s) for ${widget.projectName ?? 'this project'}'
                  : _filter == _ReviewFilter.pending
                  ? '${itemsState.total} feature(s) awaiting admin review'
                  : '${itemsState.total} rejected feature(s) available for re-review',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppSearchActionBar(
                    searchBar: SearchBar(
                      controller: _searchController,
                      hintText: hasFixedProject
                          ? 'Search reviews by collector or feature ID'
                          : 'Search reviews by project, collector, or ID',
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
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '${itemsState.total} review item${itemsState.total == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            if (filtered.isEmpty)
              AppEmptyState(
                icon: _filter == _ReviewFilter.pending
                    ? Icons.rate_review_outlined
                    : Icons.cancel_outlined,
                title: _filter == _ReviewFilter.pending
                    ? 'No pending reviews'
                    : 'No rejected reviews',
                message: hasFixedProject
                    ? _filter == _ReviewFilter.pending
                          ? 'Submitted features for ${widget.projectName ?? 'this project'} will appear here when they need review.'
                          : 'Rejected items for ${widget.projectName ?? 'this project'} remain here for re-review.'
                    : _filter == _ReviewFilter.pending
                    ? 'Submitted features awaiting moderation will appear here.'
                    : 'Rejected items remain here so admins can reopen them when needed.',
              )
            else
              ProgressiveListSection<ReviewQueueItem>(
                items: filtered,
                resetKey: Object.hash(
                  widget.projectId,
                  _filter,
                  searchText,
                  itemsState.total,
                ),
                hasMore: itemsState.hasMore,
                isLoadingMore: itemsState.isLoadingMore,
                onLoadMore: controller.loadMore,
                gridMinItemWidth: 420,
                itemBuilder: (context, item, _) => _ReviewItemCard(
                  item: item,
                  onOpenMap: () => context.push(
                    AppRoutes.mapForProject(
                      item.projectId,
                      featureId: item.id,
                      focusSource: AppRoutes.focusSourceReviewFeature,
                    ),
                  ),
                  onApprove: () =>
                      _review(context, ref, item: item, status: 'approved'),
                  onReject: () =>
                      _review(context, ref, item: item, status: 'rejected'),
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
          : 'Optional context for the contributor.',
    );
    if (note == null) {
      return;
    }

    try {
      await ref
          .read(reviewRepositoryProvider)
          .reviewFeature(
            featureId: item.id,
            status: status,
            reviewNotes: note.trim().isEmpty ? null : note.trim(),
          );
      bumpRealtimeScope(ref, const RealtimeScope('reviews', 'all'));
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
  }) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _ReviewNoteDialog(title: title, hint: hint),
    );
  }
}

class _ReviewNoteDialog extends StatefulWidget {
  const _ReviewNoteDialog({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  State<_ReviewNoteDialog> createState() => _ReviewNoteDialogState();
}

class _ReviewNoteDialogState extends State<_ReviewNoteDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(_controller.text.trim());
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
            AppTextField(
              label: 'Review note',
              controller: _controller,
              hint: widget.hint,
              minLines: 2,
              maxLines: 4,
            ),
          ],
        ),
      ),
      actions: [
        AppDialogActions(
          cancel: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          confirm: FilledButton(onPressed: _submit, child: const Text('Save')),
        ),
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
                      item.collectedBy ?? 'Unknown collector',
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
              Chip(label: Text(_friendlyGeometryType(item.geometryType))),
              Chip(label: Text('${item.photoCount} photo(s)')),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          AppActionButtons(
            maxColumns: 1,
            compactBreakpoint: 360,
            fillRows: true,
            children: [
              OutlinedButton.icon(
                onPressed: onOpenMap,
                icon: const Icon(Icons.map_outlined, size: 18),
                label: const Text('Open map'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          AppActionButtons(
            maxColumns: 2,
            compactBreakpoint: 360,
            fillRows: true,
            children: [
              FilledButton.icon(
                onPressed: onApprove,
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: Text(isRejected ? 'Re-approve' : 'Approve'),
              ),
              if (!isRejected)
                FilledButton.tonalIcon(
                  onPressed: onReject,
                  icon: const Icon(Icons.cancel_outlined, size: 18),
                  label: const Text('Reject'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime value) {
    return formatLebanonDateTime(value);
  }
}

class ProjectApprovedReviewsScreen extends ConsumerWidget {
  const ProjectApprovedReviewsScreen({
    required this.projectId,
    required this.projectName,
    required this.onOpenMap,
    required this.onReject,
    super.key,
  });

  final String projectId;
  final String projectName;
  final ValueChanged<ReviewQueueItem> onOpenMap;
  final Future<void> Function(ReviewQueueItem item) onReject;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final approvedAsync = ref.watch(
      paginatedReviewQueueProvider(
        ReviewQueueQuery(status: 'approved', projectId: projectId),
      ),
    );
    final controller = ref.read(
      paginatedReviewQueueProvider(
        ReviewQueueQuery(status: 'approved', projectId: projectId),
      ).notifier,
    );

    return approvedAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Approved reviews unavailable',
        message: userFacingErrorMessage(
          error,
          fallback:
              'Unable to load approved reviews right now. Please try again.',
        ),
        actionLabel: 'Retry',
        onAction: controller.load,
      ),
      data: (state) {
        final visibleItems = state.items
            .where((item) => item.projectId == projectId)
            .toList(growable: false);
        return _ApprovedReviewList(
          projectName: projectName,
          items: visibleItems,
          total: state.total,
          hasMore: state.hasMore,
          isLoadingMore: state.isLoadingMore,
          onLoadMore: controller.loadMore,
          onOpenMap: onOpenMap,
          onReject: onReject,
        );
      },
    );
  }
}

class _ApprovedReviewList extends StatelessWidget {
  const _ApprovedReviewList({
    required this.projectName,
    required this.items,
    required this.total,
    required this.hasMore,
    required this.isLoadingMore,
    required this.onLoadMore,
    required this.onOpenMap,
    required this.onReject,
  });

  final String projectName;
  final List<ReviewQueueItem> items;
  final int total;
  final bool hasMore;
  final bool isLoadingMore;
  final Future<void> Function() onLoadMore;
  final ValueChanged<ReviewQueueItem> onOpenMap;
  final Future<void> Function(ReviewQueueItem item) onReject;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        Text(
          '$total approved feature(s) for $projectName',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: AppSpacing.sm),
        if (items.isEmpty)
          AppEmptyState(
            icon: Icons.verified_outlined,
            title: 'No approved reviews',
            message:
                'Approved reviews for $projectName will appear here after moderation.',
          )
        else
          ProgressiveListSection<ReviewQueueItem>(
            items: items,
            resetKey: Object.hash(projectName, total),
            hasMore: hasMore,
            isLoadingMore: isLoadingMore,
            onLoadMore: onLoadMore,
            gridMinItemWidth: 420,
            itemBuilder: (context, item, _) => AppCard(
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
                              item.collectedBy ?? 'Unknown collector',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      const StatusChip(status: 'approved'),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Chip(
                        label: Text(_friendlyGeometryType(item.geometryType)),
                      ),
                      Chip(label: Text('${item.photoCount} photo(s)')),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppActionButtons(
                    maxColumns: 1,
                    compactBreakpoint: 360,
                    fillRows: true,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => onOpenMap(item),
                        icon: const Icon(Icons.map_outlined, size: 18),
                        label: const Text('Open map'),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppActionButtons(
                    maxColumns: 2,
                    compactBreakpoint: 360,
                    fillRows: true,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () => onReject(item),
                        icon: const Icon(Icons.cancel_outlined, size: 18),
                        label: const Text('Reject'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

String _friendlyGeometryType(String rawType) {
  switch (rawType) {
    case 'LineString':
      return 'Line';
    case 'MultiLineString':
      return 'Multi-line';
    case 'MultiPoint':
      return 'Multi-point';
    case 'MultiPolygon':
      return 'Multi-polygon';
    case 'Point':
    case 'Polygon':
      return rawType;
    default:
      return rawType.replaceAll('_', ' ').trim().isEmpty
          ? 'Geometry'
          : rawType.replaceAll('_', ' ');
  }
}
