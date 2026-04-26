import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

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
import '../../../map/domain/lebanon_map.dart';
import '../../../map/domain/map_geometry.dart';
import '../../domain/import_models.dart';
import '../import_providers.dart';

class ImportDetailScreen extends ConsumerStatefulWidget {
  const ImportDetailScreen({required this.importId, super.key});

  final String importId;

  @override
  ConsumerState<ImportDetailScreen> createState() => _ImportDetailScreenState();
}

class _ImportDetailScreenState extends ConsumerState<ImportDetailScreen> {
  final Set<String> _selectedFeatureIds = <String>{};
  static const Duration _refreshInterval = Duration(seconds: 5);
  bool _isSubmitting = false;
  bool _isDownloading = false;
  bool _isSavingComment = false;
  GisImportDetails? _liveDetails;
  String? _selectedIssueFilter;
  Timer? _refreshTimer;
  Future<void> Function()? _refreshImportDetails;

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authControllerProvider).session;
    if (session == null) {
      return const SizedBox.shrink();
    }
    final isAdmin = session.user.role == UserRole.admin;
    final isProtectedSuperAdmin = session.user.isSuperAdmin;
    final featureQuery = ImportedFeatureListQuery(
      importId: widget.importId,
      issue: _selectedIssueFilter,
    );
    final detailsAsync = ref.watch(importDetailsProvider(widget.importId));
    final featuresAsync = ref.watch(
      paginatedImportFeaturesProvider(featureQuery),
    );
    final featuresController = ref.read(
      paginatedImportFeaturesProvider(featureQuery).notifier,
    );
    _refreshImportDetails = () async {
      try {
        final refreshedDetails = await ref
            .read(importsRepositoryProvider)
            .fetchImportDetails(widget.importId);
        if (!mounted) {
          return;
        }
        final current = _liveDetails;
        final hasMeaningfulChange =
            current == null ||
            refreshedDetails.job.status != current.job.status ||
            refreshedDetails.job.pendingFeatureCount !=
                current.job.pendingFeatureCount ||
            refreshedDetails.job.approvedFeatureCount !=
                current.job.approvedFeatureCount ||
            refreshedDetails.job.rejectedFeatureCount !=
                current.job.rejectedFeatureCount ||
            refreshedDetails.job.failedFeatureCount !=
                current.job.failedFeatureCount ||
            refreshedDetails.previewSummary.previewFeatureCount !=
                current.previewSummary.previewFeatureCount ||
            refreshedDetails.previewSummary.outsideWorkspaceFeatureCount !=
                current.previewSummary.outsideWorkspaceFeatureCount ||
            refreshedDetails.job.rejectionReason != current.job.rejectionReason ||
            refreshedDetails.comments.length != current.comments.length;
        if (hasMeaningfulChange) {
          setState(() {
            _liveDetails = refreshedDetails;
          });
          await featuresController.refreshSilently();
        }
      } catch (_) {
        if (!mounted) {
          return;
        }
      }
    };

    final providerDetails = detailsAsync.valueOrNull;
    final details = _latestDetails(providerDetails);
    if (providerDetails != null &&
        (_liveDetails == null ||
            providerDetails.job.updatedAt.isAfter(
              _liveDetails!.job.updatedAt,
            ))) {
      _liveDetails = providerDetails;
    }

    if (details == null) {
      return detailsAsync.when(
        loading: () {
          _configureAutoRefresh(false);
          return const Center(child: CircularProgressIndicator());
        },
        error: (error, _) => AppEmptyState(
          icon: Icons.error_outline,
          title: 'Import details unavailable',
          message: userFacingErrorMessage(
            error,
            fallback: 'Unable to load this import right now.',
          ),
          actionLabel: 'Retry',
          onAction: () =>
              ref.invalidate(importDetailsProvider(widget.importId)),
        ),
        data: (_) => const SizedBox.shrink(),
      );
    }

    _configureAutoRefresh(_isImportStillProcessing(details.job.status));
    final featureState = featuresAsync.valueOrNull;
    final features =
        featureState?.items ??
        (_selectedIssueFilter == null
            ? details.previewFeatures
            : const <ImportedFeature>[]);
    final issueFilters = _issueFilterOptions(details.job.validationSummary);
    if (_selectedIssueFilter != null &&
        !issueFilters.any((option) => option.message == _selectedIssueFilter)) {
      _selectedIssueFilter = null;
    }
    final actionableFeatures = features
        .where((item) => item.isActionable)
        .toList(growable: false);
    final selectedActionableIds = _selectedFeatureIds
        .where((id) => actionableFeatures.any((item) => item.id == id))
        .toList(growable: false);
    final selectedRejectableIds = _selectedFeatureIds
        .where(
          (id) => features.any(
            (item) => item.id == id && item.status == 'pending_review',
          ),
        )
        .toList(growable: false);
    final canModerateImport =
        isAdmin &&
        (details.job.reviewScope != 'protected_super_admin' ||
            isProtectedSuperAdmin);

    return ListView(
      children: [
        _ImportSummaryCard(job: details.job),
        const SizedBox(height: AppSpacing.md),
        _ImportActionCard(
          job: details.job,
          canComment: canModerateImport,
          isDownloading: _isDownloading,
          isSavingComment: _isSavingComment,
          onDownload: _downloadImport,
          onAddComment: canModerateImport ? _addComment : null,
        ),
        const SizedBox(height: AppSpacing.md),
        _ImportValidationCard(job: details.job),
        const SizedBox(height: AppSpacing.md),
        if (_isImportStillProcessing(details.job.status))
          _ImportProcessingCard(job: details.job)
        else
          _ImportPreviewMapCard(
            features: details.previewFeatures,
            previewSummary: details.previewSummary,
          ),
        const SizedBox(height: AppSpacing.md),
        if (canModerateImport && actionableFeatures.isNotEmpty)
          _buildReviewActions(
            context,
            details: details,
            selectedActionableIds: selectedActionableIds,
            selectedRejectableIds: selectedRejectableIds,
          ),
        if (canModerateImport && actionableFeatures.isNotEmpty)
          const SizedBox(height: AppSpacing.md),
        _ImportCommentsCard(comments: details.comments),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Staged features (${featureState?.total ?? details.job.geometryCount})',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: AppSpacing.sm),
        if (issueFilters.isNotEmpty) ...[
          DropdownButtonFormField<String?>(
            initialValue: _selectedIssueFilter,
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
                  child: Text(
                    '${option.message} (${option.count})',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
            onChanged: (value) {
              setState(() {
                _selectedIssueFilter = value;
                _selectedFeatureIds.clear();
              });
            },
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        if (features.isEmpty)
          AppEmptyState(
            icon: Icons.map_outlined,
            title: _selectedIssueFilter == null
                ? 'No preview features available'
                : 'No staged features match this issue',
            message: _selectedIssueFilter == null
                ? 'This import does not currently expose preview geometries.'
                : 'No staged features currently match the selected validation issue.',
          )
        else
          ProgressiveListSection<ImportedFeature>(
            items: features,
            resetKey: Object.hash(
              widget.importId,
              details.job.updatedAt,
              _selectedIssueFilter,
              features.length,
              featureState?.total ?? 0,
            ),
            hasMore: featureState?.hasMore ?? false,
            isLoadingMore: featureState?.isLoadingMore ?? false,
            onLoadMore: featuresController.loadMore,
            itemBuilder: (context, feature, _) => _ImportedFeatureCard(
              feature: feature,
              selectable: isAdmin && feature.isActionable,
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
        if ((featureState?.total ?? details.job.geometryCount) >
            features.length) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Showing ${features.length} of ${featureState?.total ?? details.job.geometryCount} staged feature(s) for this import.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  void _configureAutoRefresh(bool enabled) {
    if (!enabled) {
      _refreshTimer?.cancel();
      _refreshTimer = null;
      return;
    }
    _refreshTimer ??= Timer.periodic(_refreshInterval, (_) {
      if (!mounted) {
        return;
      }
      unawaited(_refreshImportDetails?.call());
    });
  }

  GisImportDetails? _latestDetails(GisImportDetails? providerDetails) {
    if (providerDetails == null) {
      return _liveDetails;
    }
    if (_liveDetails == null) {
      return providerDetails;
    }
    return providerDetails.job.updatedAt.isAfter(_liveDetails!.job.updatedAt)
        ? providerDetails
        : _liveDetails;
  }

  Widget _buildReviewActions(
    BuildContext context, {
    required GisImportDetails details,
    required List<String> selectedActionableIds,
    required List<String> selectedRejectableIds,
  }) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Review actions',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _isSubmitting || details.job.pendingFeatureCount == 0
                    ? null
                    : () => _runReviewAction(
                        context,
                        status: 'approved',
                        featureIds: const <String>[],
                      ),
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Approve all pending'),
              ),
              OutlinedButton.icon(
                onPressed: _isSubmitting || details.job.pendingFeatureCount == 0
                    ? null
                    : () => _runRejectWithReason(
                        context,
                        featureIds: const <String>[],
                      ),
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('Reject all pending'),
              ),
              FilledButton.tonalIcon(
                onPressed: _isSubmitting || selectedActionableIds.isEmpty
                    ? null
                    : () => _runReviewAction(
                        context,
                        status: 'approved',
                        featureIds: selectedActionableIds,
                      ),
                icon: const Icon(Icons.done_all),
                label: Text(
                  'Approve selected (${selectedActionableIds.length})',
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: _isSubmitting || selectedRejectableIds.isEmpty
                    ? null
                    : () => _runRejectWithReason(
                        context,
                        featureIds: selectedRejectableIds,
                      ),
                icon: const Icon(Icons.remove_circle_outline),
                label: Text(
                  'Reject selected (${selectedRejectableIds.length})',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _downloadImport(BuildContext context) async {
    setState(() {
      _isDownloading = true;
    });
    try {
      final savedPath = await ref
          .read(importsRepositoryProvider)
          .downloadImport(widget.importId);
      if (!mounted || !context.mounted) {
        return;
      }
      AppSnackbar.showSuccess(
        context,
        'Import file downloaded to $savedPath',
      );
    } catch (error) {
      if (!mounted || !context.mounted) {
        return;
      }
      AppSnackbar.showError(
        context,
        userFacingErrorMessage(
          error,
          fallback: 'Unable to download this import file right now.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isDownloading = false;
        });
      }
    }
  }

  Future<void> _addComment(BuildContext context) async {
    final comment = await _promptComment(context);
    if (comment == null || comment.trim().isEmpty || !mounted || !context.mounted) {
      return;
    }

    setState(() {
      _isSavingComment = true;
    });
    try {
      await ref
          .read(importsRepositoryProvider)
          .addImportComment(importId: widget.importId, comment: comment.trim());
      if (!mounted) {
        return;
      }
      await _refreshImportDetails?.call();
      if (!mounted) {
        return;
      }
      AppSnackbar.showSuccess(
        this.context,
        'Import comment saved successfully.',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnackbar.showError(
        this.context,
        userFacingErrorMessage(
          error,
          fallback: 'Unable to save this import comment right now.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSavingComment = false;
        });
      }
    }
  }

  Future<void> _runRejectWithReason(
    BuildContext context, {
    required List<String> featureIds,
  }) async {
    final reason = await _promptReason(context);
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
      await ref
          .read(importsRepositoryProvider)
          .reviewImport(
            importId: widget.importId,
            status: status,
            reason: reason,
            featureIds: featureIds.isEmpty ? null : featureIds,
          );
      if (!mounted || !context.mounted) {
        return;
      }
      setState(() {
        _isSubmitting = false;
        _selectedFeatureIds.clear();
      });
      bumpWorkflowRefresh(ref);
      AppSnackbar.showSuccess(
        context,
        status == 'approved'
            ? 'Import approval recorded successfully.'
            : 'Import rejection recorded successfully.',
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
          fallback: 'Unable to update this import right now.',
        ),
      );
    }
  }

  Future<String?> _promptReason(BuildContext context) {
    return showDialog<String>(
      context: context,
      builder: (_) => const _ImportReasonDialog(),
    );
  }

  Future<String?> _promptComment(BuildContext context) {
    return showDialog<String>(
      context: context,
      builder: (_) => const _ImportCommentDialog(),
    );
  }
}

class _ImportSummaryCard extends StatelessWidget {
  const _ImportSummaryCard({required this.job});

  final GisImportJob job;

  @override
  Widget build(BuildContext context) {
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
                      job.originalFilename,
                      style: Theme.of(context).textTheme.titleLarge,
                      softWrap: true,
                    ),
                    const SizedBox(height: 4),
                    Text(job.projectName, softWrap: true),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              StatusChip(status: job.status),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(label: Text('${job.geometryCount} geometries')),
              Chip(label: Text(job.fileType.toUpperCase())),
              if (job.geometryTypes.isNotEmpty)
                Chip(label: Text(job.geometryTypes.join(', '))),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('Uploaded by ${job.uploadedByName}'),
          Text('Uploaded ${_formatDateTime(job.uploadedAt)}'),
          if (job.reviewedByName?.trim().isNotEmpty ?? false)
            Text('Reviewed by ${job.reviewedByName}'),
          if (job.sourceCrs?.trim().isNotEmpty ?? false) ...[
            const SizedBox(height: AppSpacing.sm),
            _MetadataField(label: 'Source CRS', value: job.sourceCrs!),
          ],
          if (job.possibleDuplicate) ...[
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'Possible duplicate of an earlier import for this project.',
              softWrap: true,
            ),
          ],
          if (job.processingMessage?.trim().isNotEmpty ?? false) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(job.processingMessage!, softWrap: true),
          ],
          if (job.rejectionReason?.trim().isNotEmpty ?? false) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Review reason: ${job.rejectionReason}',
              style: Theme.of(context).textTheme.bodyMedium,
              softWrap: true,
            ),
          ],
        ],
      ),
    );
  }
}

class _ImportProcessingCard extends StatelessWidget {
  const _ImportProcessingCard({required this.job});

  final GisImportJob job;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Spatial preview',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            job.processingMessage?.trim().isNotEmpty == true
                ? job.processingMessage!
                : 'The import is still processing. The preview map will appear after staging finishes.',
            softWrap: true,
          ),
        ],
      ),
    );
  }
}

class _ImportActionCard extends StatelessWidget {
  const _ImportActionCard({
    required this.job,
    required this.canComment,
    required this.isDownloading,
    required this.isSavingComment,
    required this.onDownload,
    this.onAddComment,
  });

  final GisImportJob job;
  final bool canComment;
  final bool isDownloading;
  final bool isSavingComment;
  final Future<void> Function(BuildContext context) onDownload;
  final Future<void> Function(BuildContext context)? onAddComment;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'File actions',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: isDownloading ? null : () => onDownload(context),
                icon: const Icon(Icons.download_outlined),
                label: Text(isDownloading ? 'Downloading...' : 'Download file'),
              ),
              if (onAddComment != null)
                OutlinedButton.icon(
                  onPressed: isSavingComment ? null : () => onAddComment!(context),
                  icon: const Icon(Icons.comment_outlined),
                  label: Text(isSavingComment ? 'Saving comment...' : 'Add comment'),
                ),
            ],
          ),
          if (job.reviewScope == 'protected_super_admin' && !canComment) ...[
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'This admin-submitted import requires protected super administrator review and comments.',
              softWrap: true,
            ),
          ],
        ],
      ),
    );
  }
}

class _ImportValidationCard extends StatelessWidget {
  const _ImportValidationCard({required this.job});

  final GisImportJob job;

  @override
  Widget build(BuildContext context) {
    final summary = job.validationSummary;
    final warningGroups = _issueGroups(
      summary['top_warnings'] ?? summary['warning_breakdown'],
    );
    final errorGroups = _issueGroups(
      summary['top_errors'] ?? summary['error_breakdown'],
    );
    final detailEntries = summary.entries
        .where((entry) {
          const hiddenKeys = <String>{
            'feature_count',
            'reviewable_feature_count',
            'failed_feature_count',
            'warning_count',
            'error_count',
            'file_type',
            'source_crs',
            'source_layer_name',
            'duplicate_of_import_job_id',
            'top_warnings',
            'top_errors',
            'warning_breakdown',
            'error_breakdown',
          };
          return !hiddenKeys.contains(entry.key);
        })
        .toList(growable: false);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Validation summary',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(label: Text('${job.pendingFeatureCount} pending review')),
              Chip(label: Text('${job.approvedFeatureCount} approved')),
              Chip(label: Text('${job.rejectedFeatureCount} rejected')),
              Chip(label: Text('${job.failedFeatureCount} failed')),
              Chip(label: Text('${job.warningCount} warnings')),
              Chip(label: Text('${job.errorCount} errors')),
            ],
          ),
          if (warningGroups.isNotEmpty || errorGroups.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'File-wide issues',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: AppSpacing.xs),
            ...errorGroups.map(
              (issue) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${issue.count} feature(s): ${issue.message}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                  softWrap: true,
                ),
              ),
            ),
            ...warningGroups.map(
              (issue) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${issue.count} feature(s): ${issue.message}',
                  softWrap: true,
                ),
              ),
            ),
          ],
          if (detailEntries.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            ...detailEntries.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: _MetadataField(
                  label: _labelize(entry.key),
                  value: entry.value?.toString() ?? '',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ImportCommentsCard extends StatelessWidget {
  const _ImportCommentsCard({required this.comments});

  final List<ImportComment> comments;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Comments',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          if (comments.isEmpty)
            const Text(
              'No review comments have been added to this import yet.',
              softWrap: true,
            )
          else
            ...comments.map(
              (comment) => Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${comment.authorName} • ${_formatDateTime(comment.createdAt)}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(comment.commentText, softWrap: true),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ImportedFeatureCard extends StatelessWidget {
  const _ImportedFeatureCard({
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
              child: Text(
                'Review note: ${feature.reviewReason}',
                softWrap: true,
              ),
            ),
          if (feature.attributes.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text('Attributes', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: feature.attributes.entries
                  .take(8)
                  .map((entry) {
                    return Chip(label: Text('${entry.key}: ${entry.value}'));
                  })
                  .toList(growable: false),
            ),
          ],
        ],
      ),
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

class _ValidationIssueGroup {
  const _ValidationIssueGroup({required this.message, required this.count});

  final String message;
  final int count;
}

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

class _ImportPreviewMapCard extends StatefulWidget {
  const _ImportPreviewMapCard({
    required this.features,
    required this.previewSummary,
  });

  final List<ImportedFeature> features;
  final ImportPreviewSummary previewSummary;

  @override
  State<_ImportPreviewMapCard> createState() => _ImportPreviewMapCardState();
}

class _ImportPreviewMapCardState extends State<_ImportPreviewMapCard> {
  LebanonBasemapStyle _style = LebanonBasemapStyle.street;

  @override
  Widget build(BuildContext context) {
    final drawable = widget.features
        .where((feature) => feature.geometry != null)
        .toList(growable: false);
    final outsideWorkspaceCount =
        widget.previewSummary.outsideWorkspaceFeatureCount;
    final containsOnlyLebanonGeometry = _containsOnlyLebanonGeometry(drawable);
    if (drawable.isEmpty ||
        outsideWorkspaceCount > 0 ||
        !containsOnlyLebanonGeometry) {
      return AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Spatial preview',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              outsideWorkspaceCount > 0 || !containsOnlyLebanonGeometry
                  ? 'The staged geometry is outside the Lebanon workspace. No preview map is shown.'
                  : 'This import does not include previewable geometries yet.',
              softWrap: true,
            ),
          ],
        ),
      );
    }

    final bounds = _boundsFor(drawable);
    final mapKey = ValueKey<String>(
      'import-preview-${_style.name}-${drawable.length}-${_boundsSignature(bounds)}',
    );

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final title = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Spatial preview',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Shows staged geometry positions inside the Lebanon workspace before approval.',
                    style: Theme.of(context).textTheme.bodySmall,
                    softWrap: true,
                  ),
                  if (outsideWorkspaceCount > 0) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '$outsideWorkspaceCount staged feature(s) remain outside the Lebanon workspace and are excluded from this preview.',
                      style: Theme.of(context).textTheme.bodySmall,
                      softWrap: true,
                    ),
                  ],
                ],
              );
              final basemapToggle = SegmentedButton<LebanonBasemapStyle>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: const [
                  ButtonSegment(
                    value: LebanonBasemapStyle.satellite,
                    label: Text('Hybrid'),
                  ),
                  ButtonSegment(
                    value: LebanonBasemapStyle.street,
                    label: Text('Street'),
                  ),
                ],
                selected: <LebanonBasemapStyle>{_style},
                onSelectionChanged: (selection) {
                  setState(() {
                    _style = selection.first;
                  });
                },
              );

              if (constraints.maxWidth < 420) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    title,
                    const SizedBox(height: AppSpacing.xs),
                    basemapToggle,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: title),
                  const SizedBox(width: AppSpacing.sm),
                  basemapToggle,
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: 260,
            child: ClipRRect(
              borderRadius: AppRadii.lg,
              child: FlutterMap(
                key: mapKey,
                options: MapOptions(
                  initialCameraFit: bounds != null
                      ? CameraFit.bounds(
                          bounds: bounds,
                          padding: const EdgeInsets.all(24),
                        )
                      : LebanonMapConfig.quickFit,
                  minZoom: LebanonMapConfig.quickMinZoom,
                  maxZoom: LebanonMapConfig.quickMaxZoom,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.drag | InteractiveFlag.pinchZoom,
                  ),
                ),
                children: [
                  if (LebanonMapConfig.shouldRenderTileLayers)
                    TileLayer(
                      urlTemplate: LebanonMapConfig.basemapUrlTemplate(_style),
                      tileProvider: NetworkTileProvider(
                        silenceExceptions: true,
                      ),
                      userAgentPackageName: 'lb.gov.gis_collector',
                    ),
                  if (LebanonMapConfig.shouldRenderTileLayers &&
                      LebanonMapConfig.referenceLabelUrlTemplate(_style) !=
                          null)
                    TileLayer(
                      urlTemplate: LebanonMapConfig.referenceLabelUrlTemplate(
                        _style,
                      )!,
                      tileProvider: NetworkTileProvider(
                        silenceExceptions: true,
                      ),
                      userAgentPackageName: 'lb.gov.gis_collector',
                    ),
                  PolygonLayer(polygons: _polygons(drawable)),
                  PolylineLayer(polylines: _polylines(drawable)),
                  MarkerLayer(markers: _markers(drawable)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  LatLngBounds? _boundsFor(List<ImportedFeature> features) {
    final points = <LatLng>[];
    for (final feature in features) {
      final geometry = feature.geometry;
      if (geometry == null) {
        continue;
      }
      points.addAll(geometryPoints(geometry));
    }
    if (points.isEmpty) {
      return null;
    }
    return LatLngBounds.fromPoints(points);
  }

  String _boundsSignature(LatLngBounds? bounds) {
    if (bounds == null) {
      return 'none';
    }
    return [
      bounds.southWest.latitude.toStringAsFixed(4),
      bounds.southWest.longitude.toStringAsFixed(4),
      bounds.northEast.latitude.toStringAsFixed(4),
      bounds.northEast.longitude.toStringAsFixed(4),
    ].join(':');
  }

  bool _containsOnlyLebanonGeometry(List<ImportedFeature> features) {
    for (final feature in features) {
      final geometry = feature.geometry;
      if (geometry == null) {
        continue;
      }
      for (final point in geometryPoints(geometry)) {
        if (!LebanonMapConfig.contains(point)) {
          return false;
        }
      }
    }
    return true;
  }

  List<Marker> _markers(List<ImportedFeature> features) {
    return features
        .map((feature) {
          final geometry = feature.geometry;
          if (geometry == null) {
            return null;
          }
          final point = geometryFocusPoint(geometry);
          if (point == null ||
              (geometry['type'] != 'Point' &&
                  geometry['type'] != 'MultiPoint')) {
            return null;
          }
          return Marker(
            point: point,
            width: 18,
            height: 18,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _statusColor(feature.status),
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          );
        })
        .whereType<Marker>()
        .toList(growable: false);
  }

  List<Polyline> _polylines(List<ImportedFeature> features) {
    final polylines = <Polyline>[];
    for (final feature in features) {
      final geometry = feature.geometry;
      if (geometry == null ||
          (geometry['type'] != 'LineString' &&
              geometry['type'] != 'MultiLineString')) {
        continue;
      }
      for (final points in _polylineSegments(geometry)) {
        if (points.isEmpty) {
          continue;
        }
        polylines.add(
          Polyline(
            points: points,
            strokeWidth: 3,
            color: _statusColor(feature.status),
          ),
        );
      }
    }
    return polylines;
  }

  List<Polygon> _polygons(List<ImportedFeature> features) {
    final polygons = <Polygon>[];
    for (final feature in features) {
      final geometry = feature.geometry;
      if (geometry == null ||
          (geometry['type'] != 'Polygon' &&
              geometry['type'] != 'MultiPolygon')) {
        continue;
      }
      final color = _statusColor(feature.status);
      for (final points in _polygonSegments(geometry)) {
        if (points.isEmpty) {
          continue;
        }
        polygons.add(
          Polygon(
            points: points,
            borderStrokeWidth: 2,
            borderColor: color,
            color: color.withValues(alpha: 0.18),
          ),
        );
      }
    }
    return polygons;
  }

  List<List<LatLng>> _polylineSegments(Map<String, dynamic> geometry) {
    if (geometry['type'] == 'LineString') {
      final points = lineGeometryPoints(geometry);
      return points.isEmpty ? const <List<LatLng>>[] : <List<LatLng>>[points];
    }
    if (geometry['type'] != 'MultiLineString') {
      return const <List<LatLng>>[];
    }
    final coordinates = geometry['coordinates'];
    if (coordinates is! List) {
      return const <List<LatLng>>[];
    }
    return coordinates
        .whereType<List>()
        .map(
          (segment) => segment
              .map(_decodePreviewCoordinatePair)
              .whereType<LatLng>()
              .toList(growable: false),
        )
        .where((points) => points.isNotEmpty)
        .toList(growable: false);
  }

  List<List<LatLng>> _polygonSegments(Map<String, dynamic> geometry) {
    if (geometry['type'] == 'Polygon') {
      final points = polygonGeometryPoints(geometry);
      return points.isEmpty ? const <List<LatLng>>[] : <List<LatLng>>[points];
    }
    if (geometry['type'] != 'MultiPolygon') {
      return const <List<LatLng>>[];
    }
    final coordinates = geometry['coordinates'];
    if (coordinates is! List) {
      return const <List<LatLng>>[];
    }
    return coordinates
        .whereType<List>()
        .map((polygon) {
          if (polygon.isEmpty) {
            return const <LatLng>[];
          }
          final firstRing = polygon.first;
          if (firstRing is! List) {
            return const <LatLng>[];
          }
          return firstRing
              .map(_decodePreviewCoordinatePair)
              .whereType<LatLng>()
              .toList(growable: false);
        })
        .where((points) => points.isNotEmpty)
        .toList(growable: false);
  }
}

class _ImportReasonDialog extends StatefulWidget {
  const _ImportReasonDialog();

  @override
  State<_ImportReasonDialog> createState() => _ImportReasonDialogState();
}

class _ImportReasonDialogState extends State<_ImportReasonDialog> {
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
          hint: 'Explain why this staged import is being rejected.',
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

class _ImportCommentDialog extends StatefulWidget {
  const _ImportCommentDialog();

  @override
  State<_ImportCommentDialog> createState() => _ImportCommentDialogState();
}

class _ImportCommentDialogState extends State<_ImportCommentDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add comment'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: AppTextField(
          label: 'Comment',
          controller: _controller,
          hint: 'Write a review comment for the uploader.',
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

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.year}-$month-$day $hour:$minute';
}

String _labelize(String key) {
  return key
      .replaceAll('_', ' ')
      .split(' ')
      .where((part) => part.isNotEmpty)
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');
}

LatLng? _decodePreviewCoordinatePair(Object? raw) {
  if (raw is! List || raw.length < 2) {
    return null;
  }
  final lon = raw[0];
  final lat = raw[1];
  if (lon is! num || lat is! num) {
    return null;
  }
  return LatLng(lat.toDouble(), lon.toDouble());
}

bool _isImportStillProcessing(String status) {
  final normalized = status.trim().toLowerCase();
  return normalized == 'uploaded' || normalized == 'processing';
}

Color _statusColor(String status) {
  switch (status.toLowerCase()) {
    case 'approved':
      return Colors.green.shade700;
    case 'rejected':
    case 'failed':
      return Colors.red.shade700;
    case 'pending_review':
    case 'partially_approved':
      return Colors.orange.shade700;
    default:
      return Colors.blueGrey.shade600;
  }
}
