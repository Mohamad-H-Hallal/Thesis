import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/progressive_list_section.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../../auth/domain/auth_models.dart';
import '../../../exports/presentation/export_file_actions.dart';
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
  static const Duration _refreshInterval = Duration(seconds: 15);
  bool _isSubmitting = false;
  bool _isDownloading = false;
  bool _isSavingComment = false;
  bool _isRefreshingImportDetails = false;
  GisImportDetails? _liveDetails;
  String? _downloadedImportPath;
  String? _selectedStatusFilter;
  String? _selectedIssueFilter;
  Timer? _refreshTimer;
  Future<void> Function()? _refreshImportDetails;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() {
      if (!mounted) {
        return;
      }
      ref.invalidate(importDetailsProvider(widget.importId));
    });
  }

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
      status: _selectedStatusFilter,
      issue: _selectedIssueFilter,
    );
    final detailsAsync = ref.watch(importDetailsProvider(widget.importId));
    _refreshImportDetails = () async {
      if (_isRefreshingImportDetails) {
        return;
      }
      _isRefreshingImportDetails = true;
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
            refreshedDetails.job.rejectionReason !=
                current.job.rejectionReason ||
            refreshedDetails.comments.length != current.comments.length;
        if (hasMeaningfulChange) {
          setState(() {
            _liveDetails = refreshedDetails;
          });
          if (!_isImportStillProcessing(refreshedDetails.job.status)) {
            await ref
                .read(paginatedImportFeaturesProvider(featureQuery).notifier)
                .refreshSilently();
          }
        }
      } catch (_) {
        if (!mounted) {
          return;
        }
      } finally {
        _isRefreshingImportDetails = false;
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
    final shouldLoadFeatures = !_isImportStillProcessing(details.job.status);
    final featuresAsync = shouldLoadFeatures
        ? ref.watch(paginatedImportFeaturesProvider(featureQuery))
        : null;
    final featuresController = shouldLoadFeatures
        ? ref.read(paginatedImportFeaturesProvider(featureQuery).notifier)
        : null;
    final featureState = featuresAsync?.valueOrNull;
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
    final selectedApprovableIds = _selectedFeatureIds
        .where((id) => actionableFeatures.any((item) => item.id == id))
        .where(
          (id) => features.any((item) => item.id == id && item.canBeApproved),
        )
        .toList(growable: false);
    final selectedRejectableIds = _selectedFeatureIds
        .where(
          (id) => features.any((item) => item.id == id && item.canBeRejected),
        )
        .toList(growable: false);
    final canModerateImport =
        isAdmin &&
        (details.job.reviewScope != 'protected_super_admin' ||
            isProtectedSuperAdmin);
    final canDownloadImport = canModerateImport;
    final downloadedImportPath = _downloadedImportPath;

    return ListView(
      children: [
        _ImportSummaryCard(job: details.job),
        const SizedBox(height: AppSpacing.md),
        _ImportMapActionCard(
          importId: widget.importId,
          projectId: details.job.projectId,
          isProcessing: _isImportStillProcessing(details.job.status),
        ),
        const SizedBox(height: AppSpacing.md),
        if (canDownloadImport || canModerateImport) ...[
          _ImportActionCard(
            job: details.job,
            canDownload: canDownloadImport,
            canComment: canModerateImport,
            isDownloading: _isDownloading,
            isSavingComment: _isSavingComment,
            onDownload: _downloadImport,
            onAddComment: canModerateImport ? _addComment : null,
            onOpenDownloadedFile:
                downloadedImportPath?.trim().isNotEmpty == true
                ? () => _openDownloadedImport(downloadedImportPath!)
                : null,
            onShareDownloadedFile:
                downloadedImportPath?.trim().isNotEmpty == true
                ? () => _shareDownloadedImport(downloadedImportPath!, details)
                : null,
            onCopyDownloadedPath:
                downloadedImportPath?.trim().isNotEmpty == true
                ? () => _copyDownloadedImportPath(downloadedImportPath!)
                : null,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        _ImportValidationCard(job: details.job),
        const SizedBox(height: AppSpacing.md),
        if (_isImportStillProcessing(details.job.status))
          _ImportProcessingCard(job: details.job)
        else
          _ImportPreviewMapCard(
            importId: widget.importId,
            projectId: details.job.projectId,
            features: details.previewFeatures,
            previewSummary: details.previewSummary,
          ),
        const SizedBox(height: AppSpacing.md),
        if (canModerateImport && actionableFeatures.isNotEmpty)
          _buildReviewActions(
            context,
            details: details,
            selectedFeatureCount: _selectedFeatureIds.length,
            selectedApprovableIds: selectedApprovableIds,
            selectedRejectableIds: selectedRejectableIds,
          ),
        if (canModerateImport && actionableFeatures.isNotEmpty)
          const SizedBox(height: AppSpacing.md),
        _ImportCommentsCard(
          importId: widget.importId,
          projectId: details.job.projectId,
          comments: details.comments,
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Staged features (${featureState?.total ?? details.job.geometryCount})',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: AppSpacing.sm),
        if (!shouldLoadFeatures)
          const AppCard(
            child: Text(
              'Staged features will appear here after processing finishes.',
              softWrap: true,
            ),
          )
        else ...[
          _ImportFeatureFiltersCard(
            selectedStatus: _selectedStatusFilter,
            selectedIssue: _selectedIssueFilter,
            issueFilters: issueFilters,
            onStatusChanged: (value) {
              setState(() {
                _selectedStatusFilter = value;
                _selectedFeatureIds.clear();
              });
            },
            onIssueChanged: (value) {
              setState(() {
                _selectedIssueFilter = value;
                _selectedFeatureIds.clear();
              });
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          if (features.isEmpty)
            AppEmptyState(
              icon: Icons.map_outlined,
              title:
                  _selectedIssueFilter == null && _selectedStatusFilter == null
                  ? 'No preview features available'
                  : 'No staged features match the current filters',
              message:
                  _selectedIssueFilter == null && _selectedStatusFilter == null
                  ? 'This import does not currently expose preview geometries.'
                  : 'No staged features currently match the selected status or validation issue.',
            )
          else
            ProgressiveListSection<ImportedFeature>(
              items: features,
              resetKey: Object.hash(
                widget.importId,
                details.job.updatedAt,
                _selectedStatusFilter,
                _selectedIssueFilter,
                features.length,
                featureState?.total ?? 0,
              ),
              hasMore: featureState?.hasMore ?? false,
              isLoadingMore: featureState?.isLoadingMore ?? false,
              onLoadMore: featuresController!.loadMore,
              itemBuilder: (context, feature, _) => _ImportedFeatureCard(
                feature: feature,
                selectable: canModerateImport && feature.isActionable,
                selected: _selectedFeatureIds.contains(feature.id),
                onOpenMap: feature.geometry == null
                    ? null
                    : () => context.push(
                        AppRoutes.importMap(
                          widget.importId,
                          projectId: details.job.projectId,
                          featureId: feature.id,
                        ),
                      ),
                onAddComment: canModerateImport
                    ? () => _addComment(context, feature: feature)
                    : null,
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
    final live = _liveDetails!;
    if (providerDetails.job.updatedAt.isAfter(live.job.updatedAt)) {
      return providerDetails;
    }
    if (_isImportDetailSnapshotNewer(providerDetails, live)) {
      return providerDetails;
    }
    return live;
  }

  bool _isImportDetailSnapshotNewer(
    GisImportDetails providerDetails,
    GisImportDetails liveDetails,
  ) {
    if (providerDetails.job.updatedAt.isBefore(liveDetails.job.updatedAt)) {
      return false;
    }
    if (!providerDetails.job.updatedAt.isAtSameMomentAs(
      liveDetails.job.updatedAt,
    )) {
      return false;
    }
    if (providerDetails.job.status != liveDetails.job.status) {
      return true;
    }
    if (providerDetails.job.pendingFeatureCount !=
            liveDetails.job.pendingFeatureCount ||
        providerDetails.job.approvedFeatureCount !=
            liveDetails.job.approvedFeatureCount ||
        providerDetails.job.rejectedFeatureCount !=
            liveDetails.job.rejectedFeatureCount ||
        providerDetails.job.failedFeatureCount !=
            liveDetails.job.failedFeatureCount ||
        providerDetails.job.warningCount != liveDetails.job.warningCount ||
        providerDetails.job.errorCount != liveDetails.job.errorCount) {
      return true;
    }
    if (providerDetails.previewSummary.previewFeatureCount !=
            liveDetails.previewSummary.previewFeatureCount ||
        providerDetails.previewSummary.outsideWorkspaceFeatureCount !=
            liveDetails.previewSummary.outsideWorkspaceFeatureCount ||
        providerDetails.comments.length != liveDetails.comments.length) {
      return true;
    }
    return false;
  }

  Widget _buildReviewActions(
    BuildContext context, {
    required GisImportDetails details,
    required int selectedFeatureCount,
    required List<String> selectedApprovableIds,
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
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (selectedFeatureCount > 0)
                OutlinedButton(
                  onPressed: selectedFeatureCount == 0
                      ? null
                      : () => setState(_selectedFeatureIds.clear),
                  child: const Text('Clear selection'),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            selectedFeatureCount == 0
                ? 'Selection applies to the currently visible filtered features on this page.'
                : '$selectedFeatureCount feature(s) selected on the current filtered page.',
            style: Theme.of(context).textTheme.bodySmall,
            softWrap: true,
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed:
                    _isSubmitting ||
                        (details.job.pendingFeatureCount == 0 &&
                            details.job.rejectedFeatureCount == 0)
                    ? null
                    : () => _runReviewAction(
                        context,
                        status: 'approved',
                        featureIds: const <String>[],
                      ),
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Approve all reviewable'),
              ),
              OutlinedButton.icon(
                onPressed:
                    _isSubmitting ||
                        (details.job.pendingFeatureCount == 0 &&
                            details.job.approvedFeatureCount == 0)
                    ? null
                    : () => _runRejectWithReason(
                        context,
                        featureIds: const <String>[],
                      ),
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('Reject all reviewable'),
              ),
              FilledButton.tonalIcon(
                onPressed: _isSubmitting || selectedApprovableIds.isEmpty
                    ? null
                    : () => _runReviewAction(
                        context,
                        status: 'approved',
                        featureIds: selectedApprovableIds,
                      ),
                icon: const Icon(Icons.done_all),
                label: Text(
                  'Approve selected (${selectedApprovableIds.length})',
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
      setState(() {
        _downloadedImportPath = savedPath;
      });
      AppSnackbar.showSuccess(
        context,
        'Import file downloaded. Use Open, Share, or Copy path.',
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

  Future<void> _openDownloadedImport(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      if (!mounted) {
        return;
      }
      AppSnackbar.showError(
        context,
        'The downloaded import file is no longer available at that path.',
      );
      return;
    }

    try {
      await ExportFileActions.openFile(path);
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      AppSnackbar.showError(
        context,
        error.message?.trim().isNotEmpty == true
            ? error.message!
            : 'This device could not open the downloaded import file.',
      );
    }
  }

  Future<void> _shareDownloadedImport(
    String path,
    GisImportDetails details,
  ) async {
    final file = File(path);
    if (!await file.exists()) {
      if (!mounted) {
        return;
      }
      AppSnackbar.showError(
        context,
        'The downloaded import file is no longer available at that path.',
      );
      return;
    }

    try {
      await ExportFileActions.shareFile(
        path: path,
        subject: '${details.job.projectName} import package',
        text: 'Original GIS import file for ${details.job.projectName}.',
      );
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      AppSnackbar.showError(
        context,
        error.message?.trim().isNotEmpty == true
            ? error.message!
            : 'This device could not open the share sheet for the import file.',
      );
    }
  }

  Future<void> _copyDownloadedImportPath(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) {
      return;
    }
    AppSnackbar.showInfo(context, 'Import path copied.');
  }

  Future<void> _addComment(
    BuildContext context, {
    ImportedFeature? feature,
  }) async {
    final comment = await _promptComment(context, feature: feature);
    if (comment == null ||
        comment.trim().isEmpty ||
        !mounted ||
        !context.mounted) {
      return;
    }

    setState(() {
      _isSavingComment = true;
    });
    try {
      await ref
          .read(importsRepositoryProvider)
          .addImportComment(
            importId: widget.importId,
            comment: comment.trim(),
            featureId: feature?.id,
          );
      if (!mounted) {
        return;
      }
      await _refreshImportDetails?.call();
      if (!mounted) {
        return;
      }
      AppSnackbar.showSuccess(
        this.context,
        feature == null
            ? 'Import comment saved successfully.'
            : 'Feature comment saved successfully.',
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

  Future<String?> _promptComment(
    BuildContext context, {
    ImportedFeature? feature,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => _ImportCommentDialog(feature: feature),
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
    required this.canDownload,
    required this.canComment,
    required this.isDownloading,
    required this.isSavingComment,
    required this.onDownload,
    this.onAddComment,
    this.onOpenDownloadedFile,
    this.onShareDownloadedFile,
    this.onCopyDownloadedPath,
  });

  final GisImportJob job;
  final bool canDownload;
  final bool canComment;
  final bool isDownloading;
  final bool isSavingComment;
  final Future<void> Function(BuildContext context) onDownload;
  final Future<void> Function(BuildContext context)? onAddComment;
  final Future<void> Function()? onOpenDownloadedFile;
  final Future<void> Function()? onShareDownloadedFile;
  final Future<void> Function()? onCopyDownloadedPath;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('File actions', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (canDownload)
                FilledButton.icon(
                  onPressed: isDownloading ? null : () => onDownload(context),
                  icon: const Icon(Icons.download_outlined),
                  label: Text(
                    isDownloading ? 'Downloading...' : 'Download file',
                  ),
                ),
              if (onOpenDownloadedFile != null)
                OutlinedButton.icon(
                  onPressed: onOpenDownloadedFile,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open'),
                ),
              if (onShareDownloadedFile != null)
                OutlinedButton.icon(
                  onPressed: onShareDownloadedFile,
                  icon: const Icon(Icons.share_outlined),
                  label: const Text('Share'),
                ),
              if (onCopyDownloadedPath != null)
                OutlinedButton.icon(
                  onPressed: onCopyDownloadedPath,
                  icon: const Icon(Icons.copy_all_outlined),
                  label: const Text('Copy path'),
                ),
              if (onAddComment != null)
                OutlinedButton.icon(
                  onPressed: isSavingComment
                      ? null
                      : () => onAddComment!(context),
                  icon: const Icon(Icons.comment_outlined),
                  label: Text(
                    isSavingComment ? 'Saving comment...' : 'Add comment',
                  ),
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

class _ImportMapActionCard extends StatelessWidget {
  const _ImportMapActionCard({
    required this.importId,
    required this.projectId,
    required this.isProcessing,
  });

  final String importId;
  final String projectId;
  final bool isProcessing;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Import map', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          FilledButton.icon(
            onPressed: isProcessing
                ? null
                : () => context.push(
                    AppRoutes.importMap(importId, projectId: projectId),
                  ),
            icon: const Icon(Icons.map_outlined),
            label: const Text('Open import map'),
          ),
        ],
      ),
    );
  }
}

class _ImportFeatureFiltersCard extends StatelessWidget {
  const _ImportFeatureFiltersCard({
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Feature filters',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          DropdownButtonFormField<String?>(
            initialValue: selectedStatus,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Status filter'),
            items: const <DropdownMenuItem<String?>>[
              DropdownMenuItem<String?>(
                value: null,
                child: Text('All staged features'),
              ),
              DropdownMenuItem<String?>(
                value: 'pending_review',
                child: Text('Pending'),
              ),
              DropdownMenuItem<String?>(
                value: 'approved',
                child: Text('Approved'),
              ),
              DropdownMenuItem<String?>(
                value: 'rejected',
                child: Text('Rejected'),
              ),
              DropdownMenuItem<String?>(value: 'failed', child: Text('Failed')),
            ],
            onChanged: onStatusChanged,
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
                    child: Text(
                      '${option.message} (${option.count})',
                      maxLines: 3,
                    ),
                  ),
                ),
              ],
              onChanged: onIssueChanged,
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
                padding: const EdgeInsets.only(bottom: 8),
                child: _ImportIssueSummaryBlock(issue: issue, isError: true),
              ),
            ),
            ...warningGroups.map(
              (issue) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ImportIssueSummaryBlock(issue: issue),
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
  const _ImportCommentsCard({
    required this.importId,
    required this.projectId,
    required this.comments,
  });

  final String importId;
  final String projectId;
  final List<ImportComment> comments;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Comments', style: Theme.of(context).textTheme.titleMedium),
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
                    if (comment.featureDisplayTitle?.trim().isNotEmpty ??
                        false) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Chip(
                            label: Text(
                              'Feature: ${comment.featureDisplayTitle}',
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () => context.push(
                              AppRoutes.importMap(
                                importId,
                                projectId: projectId,
                                featureId: comment.importFeatureId,
                              ),
                            ),
                            icon: const Icon(Icons.map_outlined, size: 18),
                            label: const Text('Open on map'),
                          ),
                        ],
                      ),
                    ],
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
    required this.onOpenMap,
    required this.onAddComment,
    required this.onToggleSelected,
  });

  final ImportedFeature feature;
  final bool selectable;
  final bool selected;
  final VoidCallback? onOpenMap;
  final VoidCallback? onAddComment;
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
                      _importFeatureDisplayTitle(feature),
                      style: Theme.of(context).textTheme.titleMedium,
                      softWrap: true,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _importFeatureTypeLabel(
                        feature.geometryType ??
                            feature.geometry?['type']?.toString() ??
                            'Unknown',
                      ),
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
            ...feature.validationWarnings
                .where((warning) => !_isUnknownFieldWarning(warning))
                .map(
                  (warning) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('Warning: $warning', softWrap: true),
                  ),
                ),
          ..._buildUnknownFieldWarningBlocks(feature.validationReport),
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
            _ImportAttributeGrid(attributes: feature.attributes),
          ],
          if (onOpenMap != null || onAddComment != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (onOpenMap != null)
                  TextButton.icon(
                    onPressed: onOpenMap,
                    icon: const Icon(Icons.map_outlined),
                    label: const Text('Open on map'),
                  ),
                if (onAddComment != null)
                  TextButton.icon(
                    onPressed: onAddComment,
                    icon: const Icon(Icons.comment_outlined),
                    label: const Text('Comment on feature'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ImportAttributeGrid extends StatelessWidget {
  const _ImportAttributeGrid({required this.attributes});

  final Map<String, dynamic> attributes;

  @override
  Widget build(BuildContext context) {
    final entries = _filteredImportAttributes(
      attributes,
    ).entries.toList(growable: false);
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
              .map((entry) {
                return SizedBox(
                  width: itemWidth,
                  child: _MetadataField(
                    label: _labelize(entry.key),
                    value: _formatAttributeValue(entry.value),
                  ),
                );
              })
              .toList(growable: false),
        );
      },
    );
  }
}

class _ImportIssueSummaryBlock extends StatelessWidget {
  const _ImportIssueSummaryBlock({required this.issue, this.isError = false});

  final _ValidationIssueGroup issue;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final extraFields = _parseUnknownFieldWarning(issue.message);
    final color = isError ? Theme.of(context).colorScheme.error : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${issue.count} feature(s): ${extraFields == null ? issue.message : 'Extra source attributes were kept.'}',
          style: color == null ? null : TextStyle(color: color),
          softWrap: true,
        ),
        if (extraFields != null && extraFields.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: extraFields
                .map((field) => Chip(label: Text(field)))
                .toList(growable: false),
          ),
        ],
      ],
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

const String _unknownFieldWarningPrefix =
    'Attributes not defined in the project form were kept:';

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
    required this.importId,
    required this.projectId,
    required this.features,
    required this.previewSummary,
  });

  final String importId;
  final String projectId;
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
    final previewFeatureCount = widget.previewSummary.previewFeatureCount;
    final outsideWorkspaceCount =
        widget.previewSummary.outsideWorkspaceFeatureCount;
    if (previewFeatureCount == 0 || drawable.isEmpty) {
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
              outsideWorkspaceCount > 0
                  ? 'No preview geometry is available yet. Open the import map to inspect the staged data directly.'
                  : 'This import does not include previewable geometries yet.',
              softWrap: true,
            ),
          ],
        ),
      );
    }

    final mapKey = ValueKey<String>(
      'import-preview-${_style.name}-$previewFeatureCount-$outsideWorkspaceCount-${drawable.length}',
    );
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
        ButtonSegment(value: LebanonBasemapStyle.street, label: Text('Street')),
      ],
      selected: <LebanonBasemapStyle>{_style},
      onSelectionChanged: (selection) {
        setState(() {
          _style = selection.first;
        });
      },
    );

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final title = Text(
                'Import map',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              );

              if (constraints.maxWidth >= 420) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: title),
                    const SizedBox(width: AppSpacing.sm),
                    basemapToggle,
                  ],
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title,
                  const SizedBox(height: AppSpacing.xs),
                  basemapToggle,
                ],
              );
            },
          ),
          if (outsideWorkspaceCount > 0) ...[
            const SizedBox(height: 10),
            Text(
              '$outsideWorkspaceCount staged feature(s) fall outside the Lebanon workspace and will only be visible on the full import map.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
              softWrap: true,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(22),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => context.push(
                AppRoutes.importMap(
                  widget.importId,
                  projectId: widget.projectId,
                ),
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: theme.dividerColor),
                  color: scheme.surfaceContainerLow,
                  boxShadow: AppShadows.soft,
                ),
                child: SizedBox(
                  height: 236,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: IgnorePointer(
                          child: FlutterMap(
                            key: mapKey,
                            options: MapOptions(
                              initialCenter: LebanonMapConfig.center,
                              initialZoom:
                                  LebanonMapConfig.quickInitialZoom - 0.15,
                              minZoom: LebanonMapConfig.quickMinZoom,
                              maxZoom: LebanonMapConfig.quickMaxZoom,
                              cameraConstraint:
                                  LebanonMapConfig.cameraConstraint,
                            ),
                            children: [
                              if (LebanonMapConfig.shouldRenderTileLayers)
                                TileLayer(
                                  urlTemplate:
                                      LebanonMapConfig.basemapUrlTemplate(
                                        _style,
                                      ),
                                  tileProvider: NetworkTileProvider(
                                    silenceExceptions: true,
                                  ),
                                  userAgentPackageName: 'lb.gov.gis_collector',
                                ),
                              if (LebanonMapConfig.shouldRenderTileLayers &&
                                  LebanonMapConfig.referenceLabelUrlTemplate(
                                        _style,
                                      ) !=
                                      null)
                                TileLayer(
                                  urlTemplate:
                                      LebanonMapConfig.referenceLabelUrlTemplate(
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
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.touch_app_outlined, size: 16, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Tap the preview to open the full import map.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_rounded,
                size: 18,
                color: scheme.primary,
              ),
            ],
          ),
        ],
      ),
    );
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
            width: 20,
            height: 20,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _statusColor(feature.status),
                border: Border.all(color: Colors.white, width: 1.5),
                boxShadow: const [
                  BoxShadow(
                    blurRadius: 6,
                    offset: Offset(0, 2),
                    color: Color(0x26000000),
                  ),
                ],
              ),
              child: Icon(
                _statusIcon(feature.status),
                color: Colors.white,
                size: 10,
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
  const _ImportCommentDialog({this.feature});

  final ImportedFeature? feature;

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
    final feature = widget.feature;
    return AlertDialog(
      title: Text(
        feature == null
            ? 'Add comment'
            : 'Comment on ${_importFeatureDisplayTitle(feature)}',
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: AppTextField(
          label: 'Comment',
          controller: _controller,
          hint: feature == null
              ? 'Write a review comment for the uploader.'
              : 'Write a review comment about this imported feature.',
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

String _formatAttributeValue(Object? value) {
  if (value == null) {
    return 'Not provided';
  }
  if (value is List) {
    return value.map((item) => item.toString()).join(', ');
  }
  if (value is Map) {
    return value.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join(', ');
  }
  return value.toString();
}

bool _isUnknownFieldWarning(String message) =>
    message.startsWith(_unknownFieldWarningPrefix);

List<String>? _parseUnknownFieldWarning(String message) {
  if (!_isUnknownFieldWarning(message)) {
    return null;
  }
  final suffix = message.substring(_unknownFieldWarningPrefix.length).trim();
  if (suffix.isEmpty) {
    return const <String>[];
  }
  return suffix
      .split(',')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty && !_shouldHideImportAttributeKey(part))
      .toList(growable: false);
}

List<Widget> _buildUnknownFieldWarningBlocks(
  Map<String, dynamic> validationReport,
) {
  final raw = validationReport['unknown_fields'];
  if (raw is! List || raw.isEmpty) {
    return const <Widget>[];
  }
  final fields = raw
      .map((value) => value?.toString().trim() ?? '')
      .where(
        (value) => value.isNotEmpty && !_shouldHideImportAttributeKey(value),
      )
      .toList(growable: false);
  if (fields.isEmpty) {
    return const <Widget>[];
  }

  return <Widget>[
    const Padding(
      padding: EdgeInsets.only(bottom: 4),
      child: Text(
        'Warning: Extra source attributes were kept.',
        softWrap: true,
      ),
    ),
    Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: fields
            .map((field) => Chip(label: Text(field)))
            .toList(growable: false),
      ),
    ),
  ];
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

String _importFeatureTypeLabel(String geometryType) {
  switch (geometryType) {
    case 'Point':
    case 'MultiPoint':
      return 'Point feature';
    case 'LineString':
    case 'MultiLineString':
      return 'Line feature';
    case 'Polygon':
    case 'MultiPolygon':
      return 'Polygon feature';
    default:
      return geometryType;
  }
}

String _importFeatureDisplayTitle(ImportedFeature feature) {
  final title = feature.displayTitle.trim();
  final lower = title.toLowerCase();
  final typeLabel = _importFeatureTypeLabel(
    feature.geometryType ?? feature.geometry?['type']?.toString() ?? 'Feature',
  );
  if (lower == 'point' ||
      lower == 'multipoint' ||
      lower == 'linestring' ||
      lower == 'multilinestring' ||
      lower == 'polygon' ||
      lower == 'multipolygon') {
    return typeLabel;
  }
  final replacements = <String, String>{
    'imported point ': 'Point feature ',
    'imported points ': 'Point feature ',
    'imported line ': 'Line feature ',
    'imported lines ': 'Line feature ',
    'imported area ': 'Polygon feature ',
    'imported areas ': 'Polygon feature ',
  };
  for (final entry in replacements.entries) {
    if (lower.startsWith(entry.key)) {
      return '${entry.value}${title.substring(entry.key.length)}'.trim();
    }
  }
  return title;
}

Map<String, dynamic> _filteredImportAttributes(
  Map<String, dynamic> attributes,
) {
  final filtered = <String, dynamic>{};
  for (final entry in attributes.entries) {
    if (_shouldHideImportAttributeKey(entry.key)) {
      continue;
    }
    filtered[entry.key] = entry.value;
  }
  return filtered;
}

bool _shouldHideImportAttributeKey(String key) {
  final normalized = key.trim().toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]'),
    '',
  );
  return normalized == 'accuracy' ||
      normalized == 'accuracymeter' ||
      normalized == 'accuracymeters';
}

Color _statusColor(String status) {
  switch (status.toLowerCase()) {
    case 'approved':
      return Colors.green.shade700;
    case 'rejected':
      return Colors.red.shade700;
    case 'pending_review':
    case 'partially_approved':
      return Colors.orange.shade700;
    case 'failed':
      return const Color(0xFF7B1FA2);
    default:
      return Colors.blueGrey.shade600;
  }
}

IconData _statusIcon(String status) {
  switch (status.toLowerCase()) {
    case 'approved':
      return Icons.check;
    case 'rejected':
      return Icons.close;
    case 'failed':
      return Icons.priority_high_rounded;
    case 'pending_review':
    case 'partially_approved':
      return Icons.schedule;
    default:
      return Icons.circle;
  }
}
