import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/progressive_list_section.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../../auth/domain/auth_models.dart';
import '../../domain/import_models.dart';
import '../import_providers.dart';

class ImportReviewScreen extends ConsumerStatefulWidget {
  const ImportReviewScreen({required this.importId, super.key});

  final String importId;

  @override
  ConsumerState<ImportReviewScreen> createState() => _ImportReviewScreenState();
}

class _ImportReviewScreenState extends ConsumerState<ImportReviewScreen> {
  final Set<String> _selectedFeatureIds = <String>{};
  bool _isSubmitting = false;
  String? _selectedStatus;
  String? _selectedIssue;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authControllerProvider).session;
    if (session == null) {
      return const SizedBox.shrink();
    }

    final detailsAsync = ref.watch(importDetailsProvider(widget.importId));
    return detailsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.rule_outlined,
        title: 'Import review unavailable',
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to load this import review right now.',
        ),
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(importDetailsProvider(widget.importId)),
      ),
      data: (details) {
        final isAdmin = session.user.role == UserRole.admin;
        final canModerateImport =
            isAdmin &&
            (details.job.reviewScope != 'protected_super_admin' ||
                session.user.isSuperAdmin);
        final issueFilters = _issueFilterOptions(details.job.validationSummary);
        if (_selectedIssue != null &&
            !issueFilters.any((option) => option.message == _selectedIssue)) {
          _selectedIssue = null;
        }

        final query = ImportedFeatureListQuery(
          importId: widget.importId,
          status: _selectedStatus,
          issue: _selectedIssue,
        );
        final featureStateAsync = ref.watch(paginatedImportFeaturesProvider(query));
        final featureController = ref.read(
          paginatedImportFeaturesProvider(query).notifier,
        );

        return featureStateAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => AppEmptyState(
            icon: Icons.layers_outlined,
            title: 'Staged features unavailable',
            message: userFacingErrorMessage(
              error,
              fallback: 'Unable to load staged import features right now.',
            ),
            actionLabel: 'Retry',
            onAction: featureController.refresh,
          ),
          data: (featureState) {
            final features = featureState.items;
            final selectedApprovableIds = _selectedFeatureIds
                .where(
                  (id) => features.any(
                    (feature) => feature.id == id && feature.canBeApproved,
                  ),
                )
                .toList(growable: false);
            final selectedRejectableIds = _selectedFeatureIds
                .where(
                  (id) => features.any(
                    (feature) => feature.id == id && feature.canBeRejected,
                  ),
                )
                .toList(growable: false);

            return ListView(
              children: [
                _ReviewSummaryCard(job: details.job),
                const SizedBox(height: AppSpacing.md),
                _FilterPanel(
                  selectedStatus: _selectedStatus,
                  selectedIssue: _selectedIssue,
                  issueFilters: issueFilters,
                  onStatusChanged: (value) {
                    setState(() {
                      _selectedStatus = value;
                      _selectedFeatureIds.clear();
                    });
                  },
                  onIssueChanged: (value) {
                    setState(() {
                      _selectedIssue = value;
                      _selectedFeatureIds.clear();
                    });
                  },
                ),
                const SizedBox(height: AppSpacing.md),
                if (canModerateImport)
                  _ReviewActionsCard(
                    isSubmitting: _isSubmitting,
                    pendingCount: details.job.pendingFeatureCount,
                    approvedCount: details.job.approvedFeatureCount,
                    rejectedCount: details.job.rejectedFeatureCount,
                    selectedApprovableCount: selectedApprovableIds.length,
                    selectedRejectableCount: selectedRejectableIds.length,
                    onApproveAll: () => _runReviewAction(
                      context,
                      status: 'approved',
                      featureIds: const <String>[],
                    ),
                    onRejectAll: () => _runRejectWithReason(
                      context,
                      featureIds: const <String>[],
                    ),
                    onApproveSelected: selectedApprovableIds.isEmpty
                        ? null
                        : () => _runReviewAction(
                            context,
                            status: 'approved',
                            featureIds: selectedApprovableIds,
                          ),
                    onRejectSelected: selectedRejectableIds.isEmpty
                        ? null
                        : () => _runRejectWithReason(
                            context,
                            featureIds: selectedRejectableIds,
                          ),
                  ),
                if (canModerateImport) const SizedBox(height: AppSpacing.md),
                Text(
                  'Staged features (${featureState.total})',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.sm),
                if (features.isEmpty)
                  AppEmptyState(
                    icon: Icons.map_outlined,
                    title: 'No staged features found',
                    message: _selectedStatus == null && _selectedIssue == null
                        ? 'This import does not currently contain staged features for review.'
                        : 'No staged features match the active filters.',
                  )
                else
                  ProgressiveListSection<ImportedFeature>(
                    items: features,
                    resetKey: Object.hash(
                      widget.importId,
                      _selectedStatus,
                      _selectedIssue,
                      details.job.updatedAt,
                      featureState.total,
                    ),
                    hasMore: featureState.hasMore,
                    isLoadingMore: featureState.isLoadingMore,
                    onLoadMore: featureController.loadMore,
                    itemBuilder: (context, feature, _) => _ReviewFeatureCard(
                      feature: feature,
                      selectable: canModerateImport && feature.isActionable,
                      selected: _selectedFeatureIds.contains(feature.id),
                      onToggleSelected: () {
                        setState(() {
                          if (_selectedFeatureIds.contains(feature.id)) {
                            _selectedFeatureIds.remove(feature.id);
                          } else {
                            _selectedFeatureIds.add(feature.id);
                          }
                        });
                      },
                    ),
                  ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Showing ${features.length} of ${featureState.total} staged feature(s).',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _runRejectWithReason(
    BuildContext context, {
    required List<String> featureIds,
  }) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _ImportReviewReasonDialog(),
    );
    if (reason == null || !mounted || !context.mounted) {
      return;
    }
    await _runReviewAction(
      context,
      status: 'rejected',
      reason: reason,
      featureIds: featureIds,
    );
  }

  Future<void> _runReviewAction(
    BuildContext context, {
    required String status,
    required List<String> featureIds,
    String? reason,
  }) async {
    setState(() {
      _isSubmitting = true;
    });
    try {
      await ref.read(importsRepositoryProvider).reviewImport(
            importId: widget.importId,
            status: status,
            reason: reason,
            featureIds: featureIds.isEmpty ? null : featureIds,
          );
      if (!mounted || !context.mounted) {
        return;
      }
      setState(() {
        _selectedFeatureIds.clear();
        _isSubmitting = false;
      });
      bumpWorkflowRefresh(ref);
      AppSnackbar.showSuccess(
        context,
        status == 'approved'
            ? 'Import review approval recorded successfully.'
            : 'Import review rejection recorded successfully.',
      );
    } catch (error) {
      if (!mounted || !context.mounted) {
        return;
      }
      setState(() {
        _isSubmitting = false;
      });
      AppSnackbar.showError(
        context,
        userFacingErrorMessage(
          error,
          fallback: 'Unable to update this import review right now.',
        ),
      );
    }
  }
}

class _ReviewSummaryCard extends StatelessWidget {
  const _ReviewSummaryCard({required this.job});

  final GisImportJob job;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Review imported features', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              StatusChip(status: job.status),
              Chip(label: Text('${job.pendingFeatureCount} pending')),
              Chip(label: Text('${job.approvedFeatureCount} approved')),
              Chip(label: Text('${job.rejectedFeatureCount} rejected')),
              Chip(label: Text('${job.failedFeatureCount} failed')),
            ],
          ),
        ],
      ),
    );
  }
}

class _FilterPanel extends StatelessWidget {
  const _FilterPanel({
    required this.selectedStatus,
    required this.selectedIssue,
    required this.issueFilters,
    required this.onStatusChanged,
    required this.onIssueChanged,
  });

  final String? selectedStatus;
  final String? selectedIssue;
  final List<_ValidationIssueGroup> issueFilters;
  final ValueChanged<String?> onStatusChanged;
  final ValueChanged<String?> onIssueChanged;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: true,
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          title: Text('Filters', style: Theme.of(context).textTheme.titleMedium),
          children: [
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _statusOptions.map((option) {
                final selected = option.value == selectedStatus;
                return FilterChip(
                  selected: selected,
                  label: Text(option.label),
                  onSelected: (_) => onStatusChanged(option.value),
                );
              }).toList(growable: false),
            ),
            if (issueFilters.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              DropdownButtonFormField<String?>(
                initialValue: selectedIssue,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Issue filter'),
                items: <DropdownMenuItem<String?>>[
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('All staged features'),
                  ),
                  ...issueFilters.map(
                    (option) => DropdownMenuItem<String?>(
                      value: option.message,
                      child: Text('${option.message} (${option.count})', maxLines: 3),
                    ),
                  ),
                ],
                onChanged: onIssueChanged,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReviewActionsCard extends StatelessWidget {
  const _ReviewActionsCard({
    required this.isSubmitting,
    required this.pendingCount,
    required this.approvedCount,
    required this.rejectedCount,
    required this.selectedApprovableCount,
    required this.selectedRejectableCount,
    required this.onApproveAll,
    required this.onRejectAll,
    this.onApproveSelected,
    this.onRejectSelected,
  });

  final bool isSubmitting;
  final int pendingCount;
  final int approvedCount;
  final int rejectedCount;
  final int selectedApprovableCount;
  final int selectedRejectableCount;
  final VoidCallback onApproveAll;
  final VoidCallback onRejectAll;
  final VoidCallback? onApproveSelected;
  final VoidCallback? onRejectSelected;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Review actions', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: isSubmitting || (pendingCount == 0 && rejectedCount == 0)
                    ? null
                    : onApproveAll,
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Approve all reviewable'),
              ),
              OutlinedButton.icon(
                onPressed: isSubmitting || (pendingCount == 0 && approvedCount == 0)
                    ? null
                    : onRejectAll,
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('Reject all reviewable'),
              ),
              FilledButton.tonalIcon(
                onPressed: isSubmitting ? null : onApproveSelected,
                icon: const Icon(Icons.done_all),
                label: Text('Approve selected ($selectedApprovableCount)'),
              ),
              FilledButton.tonalIcon(
                onPressed: isSubmitting ? null : onRejectSelected,
                icon: const Icon(Icons.remove_circle_outline),
                label: Text('Reject selected ($selectedRejectableCount)'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ReviewFeatureCard extends StatelessWidget {
  const _ReviewFeatureCard({
    required this.feature,
    required this.selectable,
    required this.selected,
    required this.onToggleSelected,
  });

  final ImportedFeature feature;
  final bool selectable;
  final bool selected;
  final VoidCallback onToggleSelected;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selectable)
                Checkbox(value: selected, onChanged: (_) => onToggleSelected()),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      feature.displayTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                      softWrap: true,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${feature.geometryType ?? 'Unknown geometry'} • source #${feature.sourceIndex + 1}',
                      softWrap: true,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              StatusChip(status: feature.status),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (feature.validationWarnings.isNotEmpty)
            ...feature.validationWarnings.map(
              (warning) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('Warning: $warning', softWrap: true),
              ),
            ),
          if (feature.validationErrors.isNotEmpty)
            ...feature.validationErrors.map(
              (error) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'Error: $error',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                  softWrap: true,
                ),
              ),
            ),
          if (feature.reviewReason?.trim().isNotEmpty ?? false)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Review reason: ${feature.reviewReason}', softWrap: true),
            ),
          if (feature.attributes.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text('Attributes', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            _AttributeGrid(attributes: feature.attributes),
          ],
        ],
      ),
    );
  }
}

class _AttributeGrid extends StatelessWidget {
  const _AttributeGrid({required this.attributes});

  final Map<String, dynamic> attributes;

  @override
  Widget build(BuildContext context) {
    final entries = attributes.entries.toList(growable: false);
    return LayoutBuilder(
      builder: (context, constraints) {
        final useTwoColumns = constraints.maxWidth >= 520;
        final itemWidth = useTwoColumns
            ? (constraints.maxWidth - AppSpacing.sm) / 2
            : constraints.maxWidth;

        return Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: entries
              .map(
                (entry) => SizedBox(
                  width: itemWidth,
                  child: _MetadataField(
                    label: _labelize(entry.key),
                    value: _formatAttributeValue(entry.value),
                  ),
                ),
              )
              .toList(growable: false),
        );
      },
    );
  }
}

class _MetadataField extends StatelessWidget {
  const _MetadataField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 2),
          Text(value, softWrap: true, maxLines: null),
        ],
      ),
    );
  }
}

class _ImportReviewReasonDialog extends StatefulWidget {
  const _ImportReviewReasonDialog();

  @override
  State<_ImportReviewReasonDialog> createState() => _ImportReviewReasonDialogState();
}

class _ImportReviewReasonDialogState extends State<_ImportReviewReasonDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Review reason'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: AppTextField(
          label: 'Reason',
          controller: _controller,
          hint: 'Explain why the selected staged features are being rejected.',
          minLines: 3,
          maxLines: 5,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ValidationIssueGroup {
  const _ValidationIssueGroup({required this.message, required this.count});

  final String message;
  final int count;
}

class _StatusFilterOption {
  const _StatusFilterOption(this.label, this.value);

  final String label;
  final String? value;
}

const List<_StatusFilterOption> _statusOptions = <_StatusFilterOption>[
  _StatusFilterOption('All', null),
  _StatusFilterOption('Pending', 'pending_review'),
  _StatusFilterOption('Approved', 'approved'),
  _StatusFilterOption('Rejected', 'rejected'),
  _StatusFilterOption('Failed', 'failed'),
];

List<_ValidationIssueGroup> _issueFilterOptions(Map<String, dynamic> summary) {
  final groups = <_ValidationIssueGroup>[
    ..._issueGroups(summary['error_breakdown'] ?? summary['top_errors']),
    ..._issueGroups(summary['warning_breakdown'] ?? summary['top_warnings']),
  ];
  final byMessage = <String, _ValidationIssueGroup>{};
  for (final group in groups) {
    byMessage[group.message] = group;
  }
  return byMessage.values.toList(growable: false)..sort((left, right) {
    if (right.count != left.count) {
      return right.count.compareTo(left.count);
    }
    return left.message.compareTo(right.message);
  });
}

List<_ValidationIssueGroup> _issueGroups(Object? value) {
  if (value is List) {
    return value
        .map((item) {
          if (item is! Map) {
            return null;
          }
          final row = Map<String, dynamic>.from(item);
          final message = row['message']?.toString().trim() ?? '';
          final count = (row['count'] as num?)?.toInt() ?? 0;
          if (message.isEmpty || count <= 0) {
            return null;
          }
          return _ValidationIssueGroup(message: message, count: count);
        })
        .whereType<_ValidationIssueGroup>()
        .toList(growable: false);
  }
  if (value is Map) {
    return value.entries
        .map((entry) {
          final message = entry.key.toString().trim();
          final count = (entry.value as num?)?.toInt() ?? 0;
          if (message.isEmpty || count <= 0) {
            return null;
          }
          return _ValidationIssueGroup(message: message, count: count);
        })
        .whereType<_ValidationIssueGroup>()
        .toList(growable: false);
  }
  return const <_ValidationIssueGroup>[];
}

String _labelize(String key) {
  return key
      .replaceAll('_', ' ')
      .split(' ')
      .where((part) => part.isNotEmpty)
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');
}

String _formatAttributeValue(Object? value) {
  if (value == null) {
    return 'Not provided';
  }
  if (value is List) {
    return value.map((item) => item.toString()).join(', ');
  }
  if (value is Map) {
    return value.entries.map((entry) => '${entry.key}: ${entry.value}').join(', ');
  }
  return value.toString();
}
