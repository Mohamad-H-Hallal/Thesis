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
  bool _isSubmitting = false;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authControllerProvider).session;
    if (session == null) {
      return const SizedBox.shrink();
    }
    final isAdmin = session.user.role == UserRole.admin;
    final detailsAsync = ref.watch(importDetailsProvider(widget.importId));
    final featuresAsync = ref.watch(
      paginatedImportFeaturesProvider(
        ImportedFeatureListQuery(importId: widget.importId),
      ),
    );
    final featuresController = ref.read(
      paginatedImportFeaturesProvider(
        ImportedFeatureListQuery(importId: widget.importId),
      ).notifier,
    );

    return detailsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Import details unavailable',
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to load this import right now.',
        ),
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(importDetailsProvider(widget.importId)),
      ),
      data: (details) {
        final featureState = featuresAsync.valueOrNull;
        final features = featureState?.items ?? details.previewFeatures;
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

        return ListView(
          children: [
            _ImportSummaryCard(job: details.job),
            const SizedBox(height: AppSpacing.md),
            _ImportValidationCard(job: details.job),
            const SizedBox(height: AppSpacing.md),
            _ImportPreviewMapCard(features: features),
            const SizedBox(height: AppSpacing.md),
            if (isAdmin && actionableFeatures.isNotEmpty)
              _buildReviewActions(
                context,
                details: details,
                selectedActionableIds: selectedActionableIds,
                selectedRejectableIds: selectedRejectableIds,
              ),
            if (isAdmin && actionableFeatures.isNotEmpty)
              const SizedBox(height: AppSpacing.md),
            Text(
              'Staged features (${featureState?.total ?? details.job.geometryCount})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            if (features.isEmpty)
              const AppEmptyState(
                icon: Icons.map_outlined,
                title: 'No preview features available',
                message:
                    'This import does not currently expose preview geometries.',
              )
            else
              ProgressiveListSection<ImportedFeature>(
                items: features,
                resetKey: Object.hash(
                  widget.importId,
                  details.job.updatedAt,
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
      },
    );
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
                    ),
                    const SizedBox(height: 4),
                    Text(job.projectName),
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
              if (job.sourceCrs?.trim().isNotEmpty ?? false)
                Chip(label: Text(job.sourceCrs!)),
              if (job.geometryTypes.isNotEmpty)
                Chip(label: Text(job.geometryTypes.join(', '))),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('Uploaded by ${job.uploadedByName}'),
          Text('Uploaded ${_formatDateTime(job.uploadedAt)}'),
          if (job.reviewedByName?.trim().isNotEmpty ?? false)
            Text('Reviewed by ${job.reviewedByName}'),
          if (job.processingMessage?.trim().isNotEmpty ?? false) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(job.processingMessage!),
          ],
          if (job.rejectionReason?.trim().isNotEmpty ?? false) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Review reason: ${job.rejectionReason}',
              style: Theme.of(context).textTheme.bodyMedium,
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
          if (summary.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            ...summary.entries
                .take(6)
                .map(
                  (entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('${_labelize(entry.key)}: ${entry.value}'),
                  ),
                ),
          ],
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
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${feature.geometryType ?? 'Unknown geometry'} • source #${feature.sourceIndex + 1}',
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
                child: Text('Warning: $warning'),
              ),
            ),
          if (feature.validationErrors.isNotEmpty)
            ...feature.validationErrors.map(
              (error) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'Error: $error',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          if (feature.reviewReason?.trim().isNotEmpty ?? false)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Review note: ${feature.reviewReason}'),
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

class _ImportPreviewMapCard extends StatefulWidget {
  const _ImportPreviewMapCard({required this.features});

  final List<ImportedFeature> features;

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
    if (drawable.isEmpty) {
      return const AppEmptyState(
        icon: Icons.map_outlined,
        title: 'Preview map unavailable',
        message: 'This import does not include previewable geometries yet.',
      );
    }

    final bounds = _boundsFor(drawable);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final title = Text(
                'Preview map',
                style: Theme.of(context).textTheme.titleMedium,
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
                options: MapOptions(
                  initialCameraFit: bounds != null
                      ? CameraFit.bounds(
                          bounds: bounds,
                          padding: const EdgeInsets.all(24),
                        )
                      : LebanonMapConfig.quickFit,
                  minZoom: LebanonMapConfig.quickMinZoom,
                  maxZoom: LebanonMapConfig.quickMaxZoom,
                  cameraConstraint: LebanonMapConfig.cameraConstraint,
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
      final type = geometry['type'] as String?;
      if (type == 'Point') {
        final point = geometryFocusPoint(geometry);
        if (point != null) {
          points.add(point);
        }
      } else if (type == 'LineString') {
        points.addAll(lineGeometryPoints(geometry));
      } else if (type == 'Polygon') {
        points.addAll(polygonGeometryPoints(geometry));
      }
    }
    if (points.isEmpty) {
      return null;
    }
    return LatLngBounds.fromPoints(points);
  }

  List<Marker> _markers(List<ImportedFeature> features) {
    return features
        .map((feature) {
          final geometry = feature.geometry;
          if (geometry == null) {
            return null;
          }
          final point = geometryFocusPoint(geometry);
          if (point == null || geometry['type'] != 'Point') {
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
    return features
        .map((feature) {
          final geometry = feature.geometry;
          if (geometry == null || geometry['type'] != 'LineString') {
            return null;
          }
          final points = lineGeometryPoints(geometry);
          if (points.isEmpty) {
            return null;
          }
          return Polyline(
            points: points,
            strokeWidth: 3,
            color: _statusColor(feature.status),
          );
        })
        .whereType<Polyline>()
        .toList(growable: false);
  }

  List<Polygon> _polygons(List<ImportedFeature> features) {
    return features
        .map((feature) {
          final geometry = feature.geometry;
          if (geometry == null || geometry['type'] != 'Polygon') {
            return null;
          }
          final points = polygonGeometryPoints(geometry);
          if (points.isEmpty) {
            return null;
          }
          final color = _statusColor(feature.status);
          return Polygon(
            points: points,
            borderStrokeWidth: 2,
            borderColor: color,
            color: color.withValues(alpha: 0.18),
          );
        })
        .whereType<Polygon>()
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
