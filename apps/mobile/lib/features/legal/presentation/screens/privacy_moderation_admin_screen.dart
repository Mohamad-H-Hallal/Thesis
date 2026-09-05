import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/pagination/paginated_list_controller.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_action_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_dialog_controller_host.dart';
import '../../../../core/widgets/app_dialog_actions.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_search_action_bar.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/progressive_list_section.dart';
import '../../domain/legal_models.dart';
import '../legal_providers.dart';

enum _WorkspaceSection { privacy, reports }

enum _QueueItemState { actionRequired, inProgress, closed }

const _privacyQueueStatuses = <String>[
  'pending_verification',
  'submitted',
  'in_review',
  'scheduled',
  'processing',
  'failed',
  'completed',
  'rejected',
  'cancelled',
];

const _reportQueueStatuses = <String>[
  'submitted',
  'in_review',
  'resolved',
  'dismissed',
];

class PrivacyModerationAdminScreen extends ConsumerStatefulWidget {
  const PrivacyModerationAdminScreen({super.key});

  @override
  ConsumerState<PrivacyModerationAdminScreen> createState() =>
      _PrivacyModerationAdminScreenState();
}

class _PrivacyModerationAdminScreenState
    extends ConsumerState<PrivacyModerationAdminScreen> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  _WorkspaceSection _section = _WorkspaceSection.privacy;
  String? _status;
  String _query = '';
  bool _showFilters = false;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).session?.user;
    if (user?.isSuperAdmin != true) {
      return const AppEmptyState(
        icon: Icons.lock_outline,
        title: 'Protected workspace',
        message: 'This workspace is limited to the protected administrator.',
      );
    }
    final counts = ref.watch(privacyQueueCountsProvider);
    final countData = counts.asData?.value;
    final overdueCount = _section == _WorkspaceSection.privacy
        ? countData?.overduePrivacyRequests ?? 0
        : countData?.overdueContentReports ?? 0;
    return ListView(
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppSearchActionBar(
                searchBar: SearchBar(
                  controller: _searchController,
                  leading: const Icon(Icons.search),
                  hintText: _section == _WorkspaceSection.privacy
                      ? 'Search request or requester'
                      : 'Search report or item',
                  onChanged: _onSearchChanged,
                  onSubmitted: (value) {
                    _searchDebounce?.cancel();
                    setState(() => _query = value.trim());
                  },
                  trailing: [
                    if (_searchController.text.isNotEmpty)
                      IconButton(
                        tooltip: 'Clear search',
                        onPressed: _clearSearch,
                        icon: const Icon(Icons.close),
                      ),
                  ],
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
                const SizedBox(height: AppSpacing.md),
                Text(
                  'Queue type',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    FilterChip(
                      avatar: const Icon(Icons.privacy_tip_outlined, size: 18),
                      label: Text(
                        _queueFilterLabel(
                          'Privacy',
                          counts.asData?.value.openPrivacyRequests,
                        ),
                      ),
                      selected: _section == _WorkspaceSection.privacy,
                      onSelected: (_) => setState(() {
                        _section = _WorkspaceSection.privacy;
                        _status = null;
                      }),
                    ),
                    FilterChip(
                      avatar: const Icon(Icons.flag_outlined, size: 18),
                      label: Text(
                        _queueFilterLabel(
                          'Reports',
                          counts.asData?.value.openContentReports,
                        ),
                      ),
                      selected: _section == _WorkspaceSection.reports,
                      onSelected: (_) => setState(() {
                        _section = _WorkspaceSection.reports;
                        _status = null;
                      }),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text('Status', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    FilterChip(
                      label: const Text('All'),
                      selected: _status == null,
                      onSelected: (_) => setState(() => _status = null),
                    ),
                    for (final value
                        in _section == _WorkspaceSection.privacy
                            ? _privacyQueueStatuses
                            : _reportQueueStatuses)
                      FilterChip(
                        label: Text(_humanize(value)),
                        selected: _status == value,
                        onSelected: (_) => setState(() => _status = value),
                      ),
                  ],
                ),
                if (counts.hasError) ...[
                  const SizedBox(height: AppSpacing.xs),
                  const Text('Queue counters are temporarily unavailable.'),
                ] else if (overdueCount > 0) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text(
                      '$overdueCount overdue in this queue',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (_section == _WorkspaceSection.privacy)
          _PrivacyQueue(
            filter: PrivacyAdminQuery(
              status: _status,
              query: _query.isEmpty ? null : _query,
            ),
            onOpen: _openPrivacyRequest,
          )
        else
          _ReportsQueue(
            filter: ContentReportAdminQuery(
              status: _status,
              query: _query.isEmpty ? null : _query,
            ),
            onOpen: _openContentReport,
          ),
      ],
    );
  }

  Future<void> _openPrivacyRequest(PrivacyAdminRequest item) async {
    late final PrivacyAdminRequestDetail detail;
    try {
      detail = await ref
          .read(legalRepositoryProvider)
          .fetchPrivacyAdminRequest(item.id);
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to load this request.',
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    final canUpdate = _privacyNextStatuses(detail.request).isNotEmpty;
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(item.type.label),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: SingleChildScrollView(
            child: _RequestDetailBody(detail: detail),
          ),
        ),
        actions: [
          if (canUpdate)
            AppDialogActions(
              cancel: TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
              confirm: FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop('update'),
                child: const Text('Update'),
              ),
            )
          else
            AppDialogActions.single(
              confirm: FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
            ),
        ],
      ),
    );
    if (selected == 'update' && mounted) {
      await _updatePrivacyRequest(detail);
    }
  }

  Future<void> _updatePrivacyRequest(PrivacyAdminRequestDetail detail) async {
    final item = detail.request;
    final nextStatuses = _privacyNextStatuses(item);
    if (nextStatuses.isEmpty) {
      AppSnackbar.showError(
        context,
        'This status is controlled by the execution workflow or is already final.',
      );
      return;
    }
    String status = nextStatuses.first;
    String? unfinishedWorkDecision;
    String? responsibilityDecision;
    final submission =
        await showDialog<
          ({
            String status,
            String userMessage,
            String? unfinishedWorkDecision,
            String? responsibilityDecision,
          })
        >(
          context: context,
          builder: (dialogContext) => AppDialogControllerHost(
            initialValues: [_defaultPrivacyMessage(item.type, status)],
            builder: (dialogContext, controllers) => StatefulBuilder(
              builder: (context, setDialogState) => AlertDialog(
                title: const Text('Update privacy request'),
                content: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: status,
                          decoration: const InputDecoration(
                            labelText: 'Next status',
                          ),
                          items: nextStatuses
                              .map(
                                (value) => DropdownMenuItem(
                                  value: value,
                                  child: Text(_humanize(value)),
                                ),
                              )
                              .toList(growable: false),
                          onChanged: (value) {
                            if (value == null) return;
                            final previousDefault = _defaultPrivacyMessage(
                              item.type,
                              status,
                            );
                            setDialogState(() {
                              status = value;
                              if (status != 'approved') {
                                unfinishedWorkDecision = null;
                                responsibilityDecision = null;
                              }
                              if (controllers[0].text.trim().isEmpty ||
                                  controllers[0].text == previousDefault) {
                                controllers[0].text = _defaultPrivacyMessage(
                                  item.type,
                                  status,
                                );
                              }
                            });
                          },
                        ),
                        if (item.type == PrivacyRequestType.deletion &&
                            status == 'approved') ...[
                          const SizedBox(height: AppSpacing.sm),
                          DropdownButtonFormField<String>(
                            isExpanded: true,
                            initialValue: unfinishedWorkDecision,
                            decoration: const InputDecoration(
                              labelText: 'Unfinished work',
                            ),
                            hint: const Text('Choose an action'),
                            items: const [
                              DropdownMenuItem(
                                value: 'require_resolution',
                                child: Text('Require resolution first'),
                              ),
                              DropdownMenuItem(
                                value: 'discard_unapproved',
                                child: Text(
                                  'Discard drafts and unapproved work',
                                ),
                              ),
                            ],
                            onChanged: (value) => setDialogState(
                              () => unfinishedWorkDecision = value,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          DropdownButtonFormField<String>(
                            isExpanded: true,
                            initialValue: responsibilityDecision,
                            decoration: const InputDecoration(
                              labelText: 'Responsibilities',
                            ),
                            hint: const Text('Choose an action'),
                            items: const [
                              DropdownMenuItem(
                                value: 'release',
                                child: Text(
                                  'Release assignments and open cases',
                                ),
                              ),
                              DropdownMenuItem(
                                value: 'confirmed_transferred',
                                child: Text(
                                  'Already transferred in admin tools',
                                ),
                              ),
                            ],
                            onChanged: (value) => setDialogState(
                              () => responsibilityDecision = value,
                            ),
                          ),
                          if (unfinishedWorkDecision ==
                              'discard_unapproved') ...[
                            const SizedBox(height: AppSpacing.sm),
                            Text(
                              'Drafts, pending items, rejected items, and their files will be permanently removed.',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                            ),
                          ],
                        ],
                        const SizedBox(height: AppSpacing.sm),
                        AppTextField(
                          label: 'Message to requester',
                          controller: controllers[0],
                          minLines: 2,
                          maxLines: 3,
                          maxLength: 1000,
                        ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  AppDialogActions(
                    cancel: TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('Cancel'),
                    ),
                    confirm: FilledButton(
                      onPressed:
                          item.type == PrivacyRequestType.deletion &&
                              status == 'approved' &&
                              (unfinishedWorkDecision == null ||
                                  responsibilityDecision == null)
                          ? null
                          : () => Navigator.of(dialogContext).pop((
                              status: status,
                              userMessage: controllers[0].text,
                              unfinishedWorkDecision: unfinishedWorkDecision,
                              responsibilityDecision: responsibilityDecision,
                            )),
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
    if (submission == null || !mounted) return;
    if (submission.userMessage.trim().isEmpty) {
      AppSnackbar.showError(context, 'Add a clear message for the requester.');
      return;
    }
    try {
      await ref
          .read(legalRepositoryProvider)
          .updatePrivacyAdminRequest(
            requestId: item.id,
            status: submission.status,
            userMessage: submission.userMessage,
            unfinishedWorkDecision: submission.unfinishedWorkDecision,
            responsibilityDecision: submission.responsibilityDecision,
          );
      bumpRealtimeScope(ref, const RealtimeScope('privacy_admin_queue', 'all'));
      ref.invalidate(paginatedPrivacyAdminRequestsProvider);
      ref.invalidate(privacyQueueCountsProvider);
      if (mounted) AppSnackbar.showSuccess(context, 'Request updated.');
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(error, fallback: 'Unable to update request.'),
        );
      }
    }
  }

  Future<void> _openContentReport(ContentReportRecord item) async {
    late final ContentReportDetail detail;
    try {
      detail = await ref
          .read(legalRepositoryProvider)
          .fetchContentReportForAdmin(item.id);
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(error, fallback: 'Unable to load report.'),
        );
      }
      return;
    }
    if (!mounted) return;
    final canUpdate = _reportNextStatuses(detail.report.status).isNotEmpty;
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Report review'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: SingleChildScrollView(
            child: _ReportDetailBody(
              detail: detail,
              onOpenItem: detail.report.entityAvailable == true
                  ? () => Navigator.of(
                      dialogContext,
                    ).pop(_reportItemRoute(detail.report))
                  : null,
            ),
          ),
        ),
        actions: [
          if (canUpdate)
            AppDialogActions(
              cancel: TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
              confirm: FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop('update'),
                child: const Text('Update'),
              ),
            )
          else
            AppDialogActions.single(
              confirm: FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
            ),
        ],
      ),
    );
    if (selected == 'update' && mounted) {
      await _updateContentReport(detail.report);
    } else if (selected?.startsWith('/') == true && mounted) {
      await context.push(selected!);
    }
  }

  Future<void> _updateContentReport(ContentReportRecord item) async {
    final nextStatuses = _reportNextStatuses(item.status);
    if (nextStatuses.isEmpty) {
      AppSnackbar.showError(context, 'This report is already final.');
      return;
    }
    String status = nextStatuses.first;
    String? outcome = status == 'resolved'
        ? _reportOutcomesForStatus(status).first
        : null;
    final submission =
        await showDialog<
          ({String status, String? outcome, String userMessage})
        >(
          context: context,
          builder: (dialogContext) => AppDialogControllerHost(
            initialValues: [_defaultReportMessage(status, outcome)],
            builder: (dialogContext, controllers) => StatefulBuilder(
              builder: (context, setDialogState) {
                final outcomes = _reportOutcomesForStatus(status);
                if (outcome != null && !outcomes.contains(outcome)) {
                  outcome = null;
                }
                return AlertDialog(
                  title: const Text('Report decision'),
                  content: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DropdownButtonFormField<String>(
                            isExpanded: true,
                            initialValue: status,
                            decoration: const InputDecoration(
                              labelText: 'Decision',
                            ),
                            items: nextStatuses
                                .map(
                                  (value) => DropdownMenuItem(
                                    value: value,
                                    child: Text(_reportDecisionLabel(value)),
                                  ),
                                )
                                .toList(growable: false),
                            onChanged: (value) => setDialogState(() {
                              if (value == null) return;
                              final previousDefault = _defaultReportMessage(
                                status,
                                outcome,
                              );
                              status = value;
                              outcome = status == 'resolved'
                                  ? _reportOutcomesForStatus(status).first
                                  : null;
                              if (controllers[0].text.trim().isEmpty ||
                                  controllers[0].text == previousDefault) {
                                controllers[0].text = _defaultReportMessage(
                                  status,
                                  outcome,
                                );
                              }
                            }),
                          ),
                          if (status == 'resolved' && outcomes.isNotEmpty) ...[
                            const SizedBox(height: AppSpacing.sm),
                            const Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'Resolve only after completing the change from the reported item screen.',
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            DropdownButtonFormField<String?>(
                              isExpanded: true,
                              initialValue: outcome,
                              decoration: const InputDecoration(
                                labelText: 'Action completed',
                              ),
                              items: outcomes
                                  .map(
                                    (value) => DropdownMenuItem(
                                      value: value,
                                      child: Text(_reportOutcomeLabel(value)),
                                    ),
                                  )
                                  .toList(growable: false),
                              onChanged: (value) {
                                final previousDefault = _defaultReportMessage(
                                  status,
                                  outcome,
                                );
                                setDialogState(() {
                                  outcome = value;
                                  if (controllers[0].text.trim().isEmpty ||
                                      controllers[0].text == previousDefault) {
                                    controllers[0].text = _defaultReportMessage(
                                      status,
                                      outcome,
                                    );
                                  }
                                });
                              },
                            ),
                          ],
                          const SizedBox(height: AppSpacing.sm),
                          AppTextField(
                            label: 'Message to reporter',
                            controller: controllers[0],
                            minLines: 2,
                            maxLines: 3,
                            maxLength: 1000,
                          ),
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    AppDialogActions(
                      cancel: TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: const Text('Cancel'),
                      ),
                      confirm: FilledButton(
                        onPressed: () => Navigator.of(dialogContext).pop((
                          status: status,
                          outcome: outcome,
                          userMessage: controllers[0].text,
                        )),
                        child: const Text('Save'),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
    if (submission == null || !mounted) return;
    if (submission.userMessage.trim().isEmpty) {
      AppSnackbar.showError(context, 'Add a clear message for the reporter.');
      return;
    }
    if (submission.status == 'resolved' && submission.outcome == null) {
      AppSnackbar.showError(context, 'Select the action completed.');
      return;
    }
    try {
      await ref
          .read(legalRepositoryProvider)
          .updateContentReportForAdmin(
            reportId: item.id,
            status: submission.status,
            outcomeCode: submission.outcome,
            userMessage: submission.userMessage,
          );
      bumpRealtimeScope(
        ref,
        const RealtimeScope('moderation_admin_queue', 'all'),
      );
      ref.invalidate(paginatedContentReportsAdminProvider);
      ref.invalidate(privacyQueueCountsProvider);
      if (mounted) AppSnackbar.showSuccess(context, 'Report updated.');
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(error, fallback: 'Unable to update report.'),
        );
      }
    }
  }
}

class _PrivacyQueue extends ConsumerWidget {
  const _PrivacyQueue({required this.filter, required this.onOpen});
  final PrivacyAdminQuery filter;
  final Future<void> Function(PrivacyAdminRequest) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(paginatedPrivacyAdminRequestsProvider(filter));
    final controller = ref.read(
      paginatedPrivacyAdminRequestsProvider(filter).notifier,
    );
    return _buildQueue<PrivacyAdminRequest>(
      context,
      state,
      controller,
      emptyTitle: 'No privacy requests',
      itemBuilder: (item) => _QueueCard(
        title: item.type.label,
        subtitle: item.requesterLabel,
        status: item.status,
        overdue: item.overdue,
        supporting: item.requesterContact ?? _date(item.requestedAt),
        itemState: !item.isActive
            ? _QueueItemState.closed
            : _privacyNextStatuses(item).isNotEmpty
            ? _QueueItemState.actionRequired
            : _QueueItemState.inProgress,
        onOpen: () => onOpen(item),
      ),
    );
  }
}

class _ReportsQueue extends ConsumerWidget {
  const _ReportsQueue({required this.filter, required this.onOpen});
  final ContentReportAdminQuery filter;
  final Future<void> Function(ContentReportRecord) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(paginatedContentReportsAdminProvider(filter));
    final controller = ref.read(
      paginatedContentReportsAdminProvider(filter).notifier,
    );
    return _buildQueue<ContentReportRecord>(
      context,
      state,
      controller,
      emptyTitle: 'No content reports',
      itemBuilder: (item) => _QueueCard(
        title: _humanize(item.reasonCode),
        subtitle:
            '${item.projectTitle ?? _humanize(item.entityType)} · ${item.reporterLabel ?? 'Reporter'}',
        status: item.status,
        overdue: item.overdue,
        supporting: item.reporterContact ?? _date(item.createdAt),
        itemState: item.status == 'resolved' || item.status == 'dismissed'
            ? _QueueItemState.closed
            : _QueueItemState.actionRequired,
        onOpen: () => onOpen(item),
      ),
    );
  }
}

Widget _buildQueue<T>(
  BuildContext context,
  AsyncValue<PaginatedListState<T>> state,
  PaginatedListController<T> controller, {
  required String emptyTitle,
  required Widget Function(T item) itemBuilder,
}) => state.when(
  loading: () => const Center(child: CircularProgressIndicator()),
  error: (error, _) => AppEmptyState(
    icon: Icons.error_outline,
    title: 'Queue unavailable',
    message: userFacingErrorMessage(error, fallback: 'Try again shortly.'),
    actionLabel: 'Retry',
    onAction: controller.load,
  ),
  data: (queue) => queue.items.isEmpty
      ? AppEmptyState(
          icon: Icons.inbox_outlined,
          title: emptyTitle,
          message: 'Items that match the current filters appear here.',
        )
      : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ProgressiveListSection<T>(
              items: queue.items,
              resetKey: Object.hash(queue.total, queue.items.first.hashCode),
              hasMore: queue.hasMore,
              isLoadingMore: queue.isLoadingMore,
              onLoadMore: controller.loadMore,
              itemBuilder: (_, item, _) => itemBuilder(item),
            ),
          ],
        ),
);

class _QueueCard extends StatelessWidget {
  const _QueueCard({
    required this.title,
    required this.subtitle,
    required this.status,
    required this.overdue,
    required this.supporting,
    required this.itemState,
    required this.onOpen,
  });
  final String title;
  final String subtitle;
  final String status;
  final bool overdue;
  final String supporting;
  final _QueueItemState itemState;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isClosed = itemState == _QueueItemState.closed;
    final needsAction = itemState == _QueueItemState.actionRequired;
    final stateBackground = switch (itemState) {
      _QueueItemState.actionRequired => colors.tertiaryContainer,
      _QueueItemState.inProgress => colors.secondaryContainer,
      _QueueItemState.closed => colors.surfaceContainerHighest,
    };
    final stateForeground = switch (itemState) {
      _QueueItemState.actionRequired => colors.onTertiaryContainer,
      _QueueItemState.inProgress => colors.onSecondaryContainer,
      _QueueItemState.closed => colors.onSurfaceVariant,
    };
    final stateIcon = switch (itemState) {
      _QueueItemState.actionRequired => Icons.priority_high_rounded,
      _QueueItemState.inProgress => Icons.autorenew_rounded,
      _QueueItemState.closed => Icons.task_alt_rounded,
    };
    final stateLabel = switch (itemState) {
      _QueueItemState.actionRequired => 'OPEN',
      _QueueItemState.inProgress => 'IN PROGRESS',
      _QueueItemState.closed => 'CLOSED',
    };
    return AppCard(
      color: isClosed
          ? colors.surfaceContainerLow
          : Color.alphaBlend(stateBackground.withAlpha(55), colors.surface),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            decoration: BoxDecoration(
              color: stateBackground,
              borderRadius: AppRadii.sm,
            ),
            child: Row(
              children: [
                Icon(stateIcon, size: 18, color: stateForeground),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    stateLabel,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: stateForeground,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(subtitle),
          const SizedBox(height: 4),
          Text(supporting, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(
                avatar: Icon(
                  isClosed ? Icons.task_alt : Icons.schedule_outlined,
                  size: 18,
                ),
                label: Text(_humanize(status)),
              ),
              if (overdue)
                Chip(
                  avatar: const Icon(Icons.schedule, size: 18),
                  label: const Text('Overdue'),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          AppActionButtons(
            maxColumns: 1,
            fillRows: true,
            children: [
              if (needsAction)
                FilledButton.icon(
                  onPressed: onOpen,
                  icon: const Icon(Icons.rate_review_outlined),
                  label: const Text('Review'),
                )
              else
                OutlinedButton.icon(
                  onPressed: onOpen,
                  icon: Icon(
                    isClosed
                        ? Icons.visibility_outlined
                        : Icons.monitor_heart_outlined,
                  ),
                  label: Text(isClosed ? 'View decision' : 'View progress'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RequestDetailBody extends StatelessWidget {
  const _RequestDetailBody({required this.detail});
  final PrivacyAdminRequestDetail detail;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        detail.request.requesterLabel,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      if (detail.request.requesterContact != null)
        Text(detail.request.requesterContact!),
      const SizedBox(height: AppSpacing.sm),
      Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        children: [
          Chip(label: Text(_humanize(detail.request.status))),
          Chip(
            label: Text(_humanize(detail.request.requesterRole ?? 'unknown')),
          ),
        ],
      ),
      if (detail.request.failureCode?.isNotEmpty ?? false)
        Text('Execution issue: ${_humanize(detail.request.failureCode!)}'),
      if (detail.request.userMessage?.isNotEmpty ?? false) ...[
        const SizedBox(height: AppSpacing.sm),
        Text('Latest message: ${detail.request.userMessage!}'),
      ],
      if (detail.request.requestDetails.isNotEmpty) ...[
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Submitted details',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        Text(_safeDetails(detail.request.requestDetails)),
      ],
    ],
  );
}

class _ReportDetailBody extends StatelessWidget {
  const _ReportDetailBody({required this.detail, this.onOpenItem});
  final ContentReportDetail detail;
  final VoidCallback? onOpenItem;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        detail.report.projectTitle ?? 'Project',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 4),
      Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        children: [
          Chip(label: Text(_humanize(detail.report.status))),
          Chip(label: Text(_humanize(detail.report.entityType))),
        ],
      ),
      const SizedBox(height: AppSpacing.sm),
      Text('Reported by', style: Theme.of(context).textTheme.labelLarge),
      if (detail.report.reporterLabel != null)
        Text(detail.report.reporterLabel!),
      if (detail.report.reporterContact != null)
        Text(detail.report.reporterContact!),
      const SizedBox(height: AppSpacing.sm),
      Text('Reason', style: Theme.of(context).textTheme.labelLarge),
      Text(_humanize(detail.report.reasonCode)),
      if (detail.report.description?.isNotEmpty ?? false) ...[
        const SizedBox(height: AppSpacing.xs),
        Text(detail.report.description!),
      ],
      const SizedBox(height: AppSpacing.sm),
      Text(
        detail.report.entityAvailable == false
            ? 'The reported item is no longer available.'
            : 'Open the reported item to inspect it before deciding.',
      ),
      if (onOpenItem != null) ...[
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: onOpenItem,
            icon: const Icon(Icons.open_in_new),
            label: Text(
              detail.report.entityType == 'project'
                  ? 'Open project'
                  : 'Open item',
            ),
          ),
        ),
      ],
    ],
  );
}

String _reportItemRoute(ContentReportRecord report) =>
    switch (report.entityType) {
      'feature' => AppRoutes.mapForProject(
        report.projectId,
        featureId: report.entityId,
      ),
      'import' => AppRoutes.importDetails(report.entityId),
      _ => AppRoutes.projectDetails(report.projectId),
    };

String _humanize(String value) => value
    .split('_')
    .where((part) => part.isNotEmpty)
    .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
    .join(' ');

String _queueFilterLabel(String label, int? count) =>
    count == null ? label : '$label ($count)';

List<String> _privacyNextStatuses(PrivacyAdminRequest request) {
  return switch (request.status) {
    'submitted' => const ['in_review'],
    'in_review' => const ['approved', 'rejected'],
    'failed' => const ['approved', 'rejected'],
    _ => const <String>[],
  };
}

List<String> _reportNextStatuses(String status) => switch (status) {
  'submitted' => const ['in_review'],
  'in_review' => const ['resolved', 'dismissed'],
  _ => const <String>[],
};

List<String> _reportOutcomesForStatus(String status) => switch (status) {
  'resolved' => const [
    'corrected_existing_workflow',
    'restricted_existing_workflow',
    'unpublished_existing_workflow',
    'independent_action_confirmed',
  ],
  _ => const <String>[],
};

String _reportDecisionLabel(String status) => switch (status) {
  'in_review' => 'Start review',
  'resolved' => 'Resolve report',
  'dismissed' => 'Dismiss report',
  _ => _humanize(status),
};

String _reportOutcomeLabel(String outcome) => switch (outcome) {
  'corrected_existing_workflow' => 'Corrected the reported item',
  'restricted_existing_workflow' => 'Restricted access',
  'unpublished_existing_workflow' => 'Unpublished the reported item',
  'independent_action_confirmed' => 'Completed another appropriate action',
  _ => _humanize(outcome),
};

String _defaultPrivacyMessage(PrivacyRequestType type, String status) =>
    switch (status) {
      'in_review' => 'We are reviewing your request.',
      'approved' => switch (type) {
        PrivacyRequestType.correction =>
          'Your correction was approved and applied.',
        PrivacyRequestType.accessExport =>
          'Your data request was approved and is being prepared.',
        PrivacyRequestType.deletion =>
          'Your deletion request was approved and scheduled.',
        _ => 'Your privacy request was approved.',
      },
      'rejected' => 'Your request was reviewed and was not approved.',
      'completed' => 'Your request has been completed.',
      _ => 'Your privacy request was updated.',
    };

String _defaultReportMessage(
  String status, [
  String? outcome,
]) => switch (status) {
  'in_review' => 'We are reviewing your report.',
  'resolved' => switch (outcome) {
    'corrected_existing_workflow' =>
      'Your report was confirmed. The reported item was corrected.',
    'restricted_existing_workflow' =>
      'Your report was confirmed. Access to the reported item was restricted.',
    'unpublished_existing_workflow' =>
      'Your report was confirmed. The reported item was unpublished.',
    _ => 'Your report was confirmed and the appropriate action was completed.',
  },
  'dismissed' =>
    'Your report was reviewed. No issue requiring action was found.',
  _ => 'Your content report was updated.',
};

String _date(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

String _safeDetails(Map<String, dynamic> details) {
  if (details['field'] == 'full_name') {
    return 'Profile name correction requested.';
  }
  if (details.containsKey('operational_eligibility_at_request')) {
    final eligibility = details['operational_eligibility_at_request'];
    if (eligibility is Map) {
      final blockers = eligibility['blocker_codes'] ?? eligibility['blockers'];
      if (blockers is List && blockers.isNotEmpty) {
        final labels = blockers
            .map((item) => item is Map ? item['code'] : item)
            .whereType<String>()
            .map(_humanize)
            .join(', ');
        if (labels.isNotEmpty) return 'Eligibility blockers: $labels.';
      }
    }
    return 'No blockers were recorded when the request was submitted.';
  }
  return details['reason'] is String && (details['reason'] as String).isNotEmpty
      ? details['reason'] as String
      : 'No additional details.';
}
