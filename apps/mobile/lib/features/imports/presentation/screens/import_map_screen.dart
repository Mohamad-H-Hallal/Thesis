import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../../map/domain/lebanon_map.dart';
import '../../../map/domain/map_feature.dart';
import '../../../map/domain/map_geometry.dart';
import '../../domain/import_models.dart';
import '../import_providers.dart';

class ImportMapScreen extends ConsumerStatefulWidget {
  const ImportMapScreen({
    required this.importId,
    required this.projectId,
    this.initialFeatureId,
    super.key,
  });

  final String importId;
  final String projectId;
  final String? initialFeatureId;

  @override
  ConsumerState<ImportMapScreen> createState() => _ImportMapScreenState();
}

class _ImportMapScreenState extends ConsumerState<ImportMapScreen> {
  LebanonBasemapStyle _style = LebanonBasemapStyle.street;
  bool _showProjectApprovedFeatures = true;
  bool _showTools = true;
  String? _selectedFeatureId;
  Set<String> _visibleStatuses = <String>{'pending_review', 'approved', 'rejected', 'failed'};

  @override
  void initState() {
    super.initState();
    _selectedFeatureId = widget.initialFeatureId;
  }

  @override
  Widget build(BuildContext context) {
    final detailsAsync = ref.watch(importDetailsProvider(widget.importId));
    return detailsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.map_outlined,
        title: 'Import map unavailable',
        message: userFacingErrorMessage(error, fallback: 'Unable to load this import map right now.'),
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(importDetailsProvider(widget.importId)),
      ),
      data: (details) {
        if (_isImportStillProcessing(details.job.status)) {
          return AppEmptyState(
            icon: Icons.hourglass_top_outlined,
            title: 'Import map pending processing',
            message: details.job.processingMessage?.trim().isNotEmpty == true
                ? details.job.processingMessage!
                : 'The import map becomes available after staging finishes.',
          );
        }
        final mapDataAsync = ref.watch(
          importMapDataProvider(
            ImportMapQuery(importId: widget.importId, projectId: widget.projectId),
          ),
        );
        return mapDataAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => AppEmptyState(
            icon: Icons.public_off_outlined,
            title: 'Import map unavailable',
            message: userFacingErrorMessage(error, fallback: 'Unable to load the staged import geometry right now.'),
          ),
          data: (mapData) {
            final staged = mapData.stagedFeatures.map(_ImportMapFeature.staged).toList(growable: false);
            final approvedContext = mapData.approvedProjectFeatures.map(_ImportMapFeature.projectApproved).toList(growable: false);
            final visibleStaged = staged.where((feature) => _visibleStatuses.contains(feature.status) && feature.hasGeometry).toList(growable: false);
            final visibleContext = _showProjectApprovedFeatures
                ? approvedContext.where((feature) => feature.hasGeometry).toList(growable: false)
                : const <_ImportMapFeature>[];
            final drawableFeatures = <_ImportMapFeature>[...visibleContext, ...visibleStaged];
            final focusedFeature = _focusedFeature(drawableFeatures);
            final outsideWorkspaceCount = staged.where((feature) => !feature.touchesLebanonWorkspace).length;
            return Stack(
              children: [
                Positioned.fill(
                  child: _ImportMapCanvas(
                    mapKey: ValueKey<String>('import-map-${widget.importId}-${widget.initialFeatureId ?? 'none'}-${_style.name}-${_showProjectApprovedFeatures ? 'context' : 'staged'}-${_visibleStatuses.join(',')}-${focusedFeature?.id ?? 'all'}-${drawableFeatures.length}'),
                    basemapStyle: _style,
                    drawableFeatures: drawableFeatures,
                    focusedFeature: focusedFeature,
                    onSelectFeature: (feature) {
                      setState(() => _selectedFeatureId = feature.id);
                      _showFeatureDetails(context, feature);
                    },
                  ),
                ),
                Positioned(
                  top: AppSpacing.md,
                  left: AppSpacing.md,
                  right: AppSpacing.md,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: _showTools
                        ? _ImportMapToolsCard(
                            key: const ValueKey<String>('import-map-tools'),
                            projectName: details.job.projectName,
                            totalStagedCount: staged.length,
                            visibleStagedCount: visibleStaged.length,
                            contextCount: approvedContext.length,
                            outsideWorkspaceCount: outsideWorkspaceCount,
                            basemapStyle: _style,
                            showProjectApprovedFeatures: _showProjectApprovedFeatures,
                            visibleStatuses: _visibleStatuses,
                            onBasemapChanged: (style) => setState(() => _style = style),
                            onToggleProjectContext: (value) => setState(() => _showProjectApprovedFeatures = value),
                            onToggleAllStatuses: _showAllStatuses,
                            onToggleStatus: _toggleStatus,
                            onHideTools: () => setState(() => _showTools = false),
                          )
                        : Align(
                            key: const ValueKey<String>('import-map-show-tools'),
                            alignment: Alignment.topRight,
                            child: FilledButton.tonalIcon(
                              onPressed: () => setState(() => _showTools = true),
                              icon: const Icon(Icons.layers_outlined),
                              label: const Text('Show tools'),
                            ),
                          ),
                  ),
                ),
                Positioned(
                  left: AppSpacing.md,
                  right: AppSpacing.md,
                  bottom: AppSpacing.md,
                  child: _ImportMapLegendBar(
                    selectedFeature: focusedFeature,
                    onClearSelection: _selectedFeatureId == null ? null : () => setState(() => _selectedFeatureId = null),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  _ImportMapFeature? _focusedFeature(List<_ImportMapFeature> features) {
    final selectedFeatureId = _selectedFeatureId;
    if (selectedFeatureId == null) {
      return null;
    }
    for (final feature in features) {
      if (feature.id == selectedFeatureId) {
        return feature;
      }
    }
    return null;
  }

  void _showAllStatuses() {
    setState(() {
      _visibleStatuses = <String>{'pending_review', 'approved', 'rejected', 'failed'};
    });
  }

  void _toggleStatus(String status) {
    setState(() {
      final next = Set<String>.from(_visibleStatuses);
      if (next.contains(status)) {
        next.remove(status);
      } else {
        next.add(status);
      }
      _visibleStatuses = next;
      if (_selectedFeatureId != null && !next.contains(status)) {
        _selectedFeatureId = null;
      }
    });
  }

  Future<void> _showFeatureDetails(BuildContext context, _ImportMapFeature feature) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
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
                        Text(feature.title, style: Theme.of(context).textTheme.titleLarge, softWrap: true),
                        const SizedBox(height: 4),
                        Text(feature.subtitle, softWrap: true),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  StatusChip(status: feature.status),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              if (feature.isProjectContext)
                const Text(
                  'This is an already-approved project feature shown only as context. It is not part of the staged import review.',
                  softWrap: true,
                )
              else ...[
                if (feature.validationWarnings.isNotEmpty)
                  ...feature.validationWarnings.map((warning) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('Warning: $warning', softWrap: true),
                      )),
                if (feature.validationErrors.isNotEmpty)
                  ...feature.validationErrors.map((error) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          'Error: $error',
                          style: TextStyle(color: Theme.of(context).colorScheme.error),
                          softWrap: true,
                        ),
                      )),
                if (feature.reviewReason?.trim().isNotEmpty ?? false)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('Review reason: ${feature.reviewReason}', softWrap: true),
                  ),
              ],
              if (feature.attributes.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                Text('Attributes', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: AppSpacing.sm),
                _ImportMapAttributeGrid(attributes: feature.attributes),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ImportMapCanvas extends StatelessWidget {
  const _ImportMapCanvas({
    required this.mapKey,
    required this.basemapStyle,
    required this.drawableFeatures,
    required this.focusedFeature,
    required this.onSelectFeature,
  });

  final ValueKey<String> mapKey;
  final LebanonBasemapStyle basemapStyle;
  final List<_ImportMapFeature> drawableFeatures;
  final _ImportMapFeature? focusedFeature;
  final ValueChanged<_ImportMapFeature> onSelectFeature;

  @override
  Widget build(BuildContext context) {
    return FlutterMap(
      key: mapKey,
      options: MapOptions(
        initialCameraFit: _cameraFit(drawableFeatures, focusedFeature: focusedFeature),
        minZoom: 3,
        maxZoom: LebanonMapConfig.fullscreenMaxZoom,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.drag | InteractiveFlag.pinchZoom | InteractiveFlag.doubleTapZoom,
        ),
      ),
      children: [
        if (LebanonMapConfig.shouldRenderTileLayers)
          TileLayer(
            urlTemplate: LebanonMapConfig.basemapUrlTemplate(basemapStyle),
            tileProvider: NetworkTileProvider(silenceExceptions: true),
            userAgentPackageName: 'lb.gov.gis_collector',
          ),
        if (LebanonMapConfig.shouldRenderTileLayers && LebanonMapConfig.referenceLabelUrlTemplate(basemapStyle) != null)
          TileLayer(
            urlTemplate: LebanonMapConfig.referenceLabelUrlTemplate(basemapStyle)!,
            tileProvider: NetworkTileProvider(silenceExceptions: true),
            userAgentPackageName: 'lb.gov.gis_collector',
          ),
        PolygonLayer(polygons: _polygons(drawableFeatures, focusedFeature)),
        PolylineLayer(polylines: _polylines(drawableFeatures, focusedFeature)),
        MarkerLayer(markers: _markers(drawableFeatures, focusedFeature, onSelectFeature)),
      ],
    );
  }

  CameraFit _cameraFit(List<_ImportMapFeature> features, {required _ImportMapFeature? focusedFeature}) {
    final points = focusedFeature == null
        ? <LatLng>[for (final feature in features) ...feature.points]
        : focusedFeature.points;
    if (points.isEmpty) {
      return LebanonMapConfig.lebanonFit(padding: const EdgeInsets.all(20));
    }
    if (points.length == 1) {
      return CameraFit.coordinates(coordinates: points, padding: const EdgeInsets.all(32), maxZoom: 13);
    }
    return CameraFit.bounds(bounds: LatLngBounds.fromPoints(points), padding: const EdgeInsets.all(36));
  }

  List<Marker> _markers(
    List<_ImportMapFeature> features,
    _ImportMapFeature? focusedFeature,
    ValueChanged<_ImportMapFeature> onSelectFeature,
  ) {
    return features
        .map((feature) {
          final point = feature.focusPoint;
          if (point == null) {
            return null;
          }
          final isFocused = focusedFeature?.id == feature.id;
          final isProjectLayer = feature.isProjectContext;
          return Marker(
            point: point,
            width: isFocused ? 24 : (isProjectLayer ? 14 : 18),
            height: isFocused ? 24 : (isProjectLayer ? 14 : 18),
            child: GestureDetector(
              onTap: () => onSelectFeature(feature),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: feature.color,
                  border: Border.all(
                    color: Colors.white,
                    width: isFocused ? 3 : (isProjectLayer ? 1.5 : 2),
                  ),
                  boxShadow: isFocused
                      ? const [BoxShadow(blurRadius: 10, color: Color(0x33000000), offset: Offset(0, 2))]
                      : null,
                ),
              ),
            ),
          );
        })
        .whereType<Marker>()
        .toList(growable: false);
  }

  List<Polyline> _polylines(List<_ImportMapFeature> features, _ImportMapFeature? focusedFeature) {
    final polylines = <Polyline>[];
    for (final feature in features) {
      if (!feature.isLine) {
        continue;
      }
      final isFocused = focusedFeature?.id == feature.id;
      for (final segment in feature.lineSegments) {
        if (segment.isEmpty) {
          continue;
        }
        polylines.add(
          Polyline(
            points: segment,
            strokeWidth: isFocused ? 5 : (feature.isProjectContext ? 2 : 3),
            color: feature.color.withValues(alpha: feature.isProjectContext ? 0.82 : 1),
          ),
        );
      }
    }
    return polylines;
  }

  List<Polygon> _polygons(List<_ImportMapFeature> features, _ImportMapFeature? focusedFeature) {
    final polygons = <Polygon>[];
    for (final feature in features) {
      if (!feature.isPolygon) {
        continue;
      }
      final isFocused = focusedFeature?.id == feature.id;
      for (final ring in feature.polygonSegments) {
        if (ring.isEmpty) {
          continue;
        }
        polygons.add(
          Polygon(
            points: ring,
            borderStrokeWidth: isFocused ? 4 : (feature.isProjectContext ? 1.5 : 2),
            borderColor: feature.color,
            color: feature.color.withValues(alpha: feature.isProjectContext ? 0.06 : 0.16),
          ),
        );
      }
    }
    return polygons;
  }
}

class _ImportMapToolsCard extends StatelessWidget {
  const _ImportMapToolsCard({
    super.key,
    required this.projectName,
    required this.totalStagedCount,
    required this.visibleStagedCount,
    required this.contextCount,
    required this.outsideWorkspaceCount,
    required this.basemapStyle,
    required this.showProjectApprovedFeatures,
    required this.visibleStatuses,
    required this.onBasemapChanged,
    required this.onToggleProjectContext,
    required this.onToggleAllStatuses,
    required this.onToggleStatus,
    required this.onHideTools,
  });

  final String projectName;
  final int totalStagedCount;
  final int visibleStagedCount;
  final int contextCount;
  final int outsideWorkspaceCount;
  final LebanonBasemapStyle basemapStyle;
  final bool showProjectApprovedFeatures;
  final Set<String> visibleStatuses;
  final ValueChanged<LebanonBasemapStyle> onBasemapChanged;
  final ValueChanged<bool> onToggleProjectContext;
  final VoidCallback onToggleAllStatuses;
  final ValueChanged<String> onToggleStatus;
  final VoidCallback onHideTools;

  @override
  Widget build(BuildContext context) {
    final allSelected = visibleStatuses.length == 4;
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
                    Text('Import map', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(projectName, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(
                      'This map is separate from the project map. Staged import features are visible here for review. Approved project features appear only as context when enabled.',
                      style: Theme.of(context).textTheme.bodySmall,
                      softWrap: true,
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'hide') {
                    onHideTools();
                  }
                },
                itemBuilder: (context) => const [PopupMenuItem<String>(value: 'hide', child: Text('Hide tools'))],
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          LayoutBuilder(
            builder: (context, constraints) {
              final toggle = SegmentedButton<LebanonBasemapStyle>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: const [
                  ButtonSegment(value: LebanonBasemapStyle.satellite, label: Text('Hybrid')),
                  ButtonSegment(value: LebanonBasemapStyle.street, label: Text('Street')),
                ],
                selected: <LebanonBasemapStyle>{basemapStyle},
                onSelectionChanged: (selection) => onBasemapChanged(selection.first),
              );
              if (constraints.maxWidth < 420) {
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_summaryChips(), const SizedBox(height: AppSpacing.sm), toggle]);
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [Expanded(child: _summaryChips()), const SizedBox(width: AppSpacing.sm), toggle],
              );
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilterChip(selected: allSelected, label: const Text('All'), onSelected: (_) => onToggleAllStatuses()),
              _StatusFilterChip(label: 'Pending', selected: visibleStatuses.contains('pending_review'), onSelected: () => onToggleStatus('pending_review'), color: Colors.orange.shade700),
              _StatusFilterChip(label: 'Approved', selected: visibleStatuses.contains('approved'), onSelected: () => onToggleStatus('approved'), color: Colors.green.shade700),
              _StatusFilterChip(label: 'Rejected', selected: visibleStatuses.contains('rejected'), onSelected: () => onToggleStatus('rejected'), color: Colors.red.shade700),
              _StatusFilterChip(label: 'Failed', selected: visibleStatuses.contains('failed'), onSelected: () => onToggleStatus('failed'), color: Colors.purple.shade700),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show approved project features for context'),
            value: showProjectApprovedFeatures,
            onChanged: onToggleProjectContext,
          ),
        ],
      ),
    );
  }

  Widget _summaryChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        Chip(label: Text('$visibleStagedCount of $totalStagedCount staged shown')),
        if (contextCount > 0) Chip(label: Text('$contextCount approved project features')),
        if (outsideWorkspaceCount > 0) Chip(label: Text('$outsideWorkspaceCount outside Lebanon workspace')),
      ],
    );
  }
}

class _ImportMapLegendBar extends StatelessWidget {
  const _ImportMapLegendBar({required this.selectedFeature, required this.onClearSelection});

  final _ImportMapFeature? selectedFeature;
  final VoidCallback? onClearSelection;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _LegendChip(label: 'Pending', color: Colors.orange.shade700),
              _LegendChip(label: 'Approved', color: Colors.green.shade700),
              _LegendChip(label: 'Rejected', color: Colors.red.shade700),
              _LegendChip(label: 'Failed', color: Colors.purple.shade700),
              _LegendChip(label: 'Project context', color: Colors.blueGrey.shade700),
            ],
          ),
          if (selectedFeature != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(child: Text('Focused feature: ${selectedFeature!.title}', softWrap: true)),
                if (onClearSelection != null) TextButton(onPressed: onClearSelection, child: const Text('Clear focus')),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusFilterChip extends StatelessWidget {
  const _StatusFilterChip({required this.label, required this.selected, required this.onSelected, required this.color});

  final String label;
  final bool selected;
  final VoidCallback onSelected;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      selected: selected,
      label: Text(label),
      selectedColor: color.withValues(alpha: 0.18),
      checkmarkColor: color,
      onSelected: (_) => onSelected(),
    );
  }
}

class _ImportMapAttributeGrid extends StatelessWidget {
  const _ImportMapAttributeGrid({required this.attributes});

  final Map<String, dynamic> attributes;

  @override
  Widget build(BuildContext context) {
    final entries = attributes.entries.toList(growable: false);
    return LayoutBuilder(
      builder: (context, constraints) {
        final useTwoColumns = constraints.maxWidth >= 520;
        final itemWidth = useTwoColumns ? (constraints.maxWidth - AppSpacing.sm) / 2 : constraints.maxWidth;
        return Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: entries.map((entry) => SizedBox(width: itemWidth, child: _ImportMapMetadataField(label: _labelize(entry.key), value: _formatValue(entry.value)))).toList(growable: false),
        );
      },
    );
  }
}

class _ImportMapMetadataField extends StatelessWidget {
  const _ImportMapMetadataField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        Text(value, softWrap: true, maxLines: null),
      ],
    );
  }
}

class _ImportMapFeature {
  _ImportMapFeature({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.color,
    required this.geometry,
    required this.attributes,
    required this.validationWarnings,
    required this.validationErrors,
    required this.reviewReason,
    required this.isProjectContext,
  }) : points = geometry == null ? const <LatLng>[] : geometryPoints(geometry),
       lineSegments = geometry == null ? const <List<LatLng>>[] : _lineSegments(geometry),
       polygonSegments = geometry == null ? const <List<LatLng>>[] : _polygonSegments(geometry),
       focusPoint = geometry == null ? null : geometryFocusPoint(geometry),
       touchesLebanonWorkspace = geometry == null ? false : geometryPoints(geometry).any(LebanonMapConfig.contains),
       isLine = geometry?['type'] == 'LineString' || geometry?['type'] == 'MultiLineString',
       isPolygon = geometry?['type'] == 'Polygon' || geometry?['type'] == 'MultiPolygon';

  factory _ImportMapFeature.staged(ImportedFeature feature) {
    return _ImportMapFeature(
      id: feature.id,
      title: feature.displayTitle,
      subtitle: '${feature.geometryType ?? 'Unknown geometry'} • source #${feature.sourceIndex + 1}',
      status: feature.status,
      color: _stagedStatusColor(feature.status),
      geometry: feature.geometry,
      attributes: feature.attributes,
      validationWarnings: feature.validationWarnings,
      validationErrors: feature.validationErrors,
      reviewReason: feature.reviewReason,
      isProjectContext: false,
    );
  }

  factory _ImportMapFeature.projectApproved(MapFeatureSummary feature) {
    return _ImportMapFeature(
      id: feature.id,
      title: _projectFeatureTitle(feature),
      subtitle: '${feature.geometry['type'] ?? 'Unknown geometry'} • approved project feature',
      status: 'approved',
      color: Colors.blueGrey.shade700,
      geometry: feature.geometry,
      attributes: feature.attributes,
      validationWarnings: const <String>[],
      validationErrors: const <String>[],
      reviewReason: feature.reviewNotes,
      isProjectContext: true,
    );
  }

  final String id;
  final String title;
  final String subtitle;
  final String status;
  final Color color;
  final Map<String, dynamic>? geometry;
  final Map<String, dynamic> attributes;
  final List<String> validationWarnings;
  final List<String> validationErrors;
  final String? reviewReason;
  final bool isProjectContext;
  final List<LatLng> points;
  final List<List<LatLng>> lineSegments;
  final List<List<LatLng>> polygonSegments;
  final LatLng? focusPoint;
  final bool touchesLebanonWorkspace;
  final bool isLine;
  final bool isPolygon;

  bool get hasGeometry => geometry != null && points.isNotEmpty;
}

class _LegendChip extends StatelessWidget {
  const _LegendChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Chip(avatar: Icon(Icons.circle, color: color, size: 12), label: Text(label));
  }
}

List<List<LatLng>> _lineSegments(Map<String, dynamic> geometry) {
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
  return coordinates.whereType<List>().map((segment) => segment.map(_decodeCoordinatePair).whereType<LatLng>().toList(growable: false)).where((points) => points.isNotEmpty).toList(growable: false);
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
  return coordinates.whereType<List>().map((polygon) {
    if (polygon.isEmpty) {
      return const <LatLng>[];
    }
    final firstRing = polygon.first;
    if (firstRing is! List) {
      return const <LatLng>[];
    }
    return firstRing.map(_decodeCoordinatePair).whereType<LatLng>().toList(growable: false);
  }).where((points) => points.isNotEmpty).toList(growable: false);
}

LatLng? _decodeCoordinatePair(Object? raw) {
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

String _projectFeatureTitle(MapFeatureSummary feature) {
  String? attributeValue(bool Function(String key) matcher, {int maxLength = 80}) {
    for (final entry in feature.attributes.entries) {
      final value = '${entry.value}'.trim();
      if (!matcher(entry.key) || value.isEmpty || value.length > maxLength) {
        continue;
      }
      return value;
    }
    return null;
  }

  bool looksLikeName(String key) {
    final normalized = key.toLowerCase();
    return normalized.contains('name') || normalized.contains('title') || normalized.contains('label');
  }

  bool looksLikeType(String key) {
    final normalized = key.toLowerCase();
    return normalized.contains('type') || normalized.contains('class') || normalized.contains('category');
  }

  final nameValue = attributeValue(looksLikeName);
  if (nameValue != null) {
    return nameValue;
  }
  final typeValue = attributeValue(looksLikeType, maxLength: 40);
  if (typeValue != null) {
    return typeValue;
  }
  return switch (feature.geometry['type']) {
    'LineString' => 'Approved line feature',
    'MultiLineString' => 'Approved line feature',
    'Polygon' => 'Approved area feature',
    'MultiPolygon' => 'Approved area feature',
    _ => 'Approved point feature',
  };
}

String _labelize(String key) {
  return key.replaceAll('_', ' ').split(' ').where((part) => part.isNotEmpty).map((part) => '${part[0].toUpperCase()}${part.substring(1)}').join(' ');
}

String _formatValue(Object? value) {
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

bool _isImportStillProcessing(String status) {
  final normalized = status.trim().toLowerCase();
  return normalized == 'uploaded' || normalized == 'processing';
}

Color _stagedStatusColor(String status) {
  switch (status.toLowerCase()) {
    case 'approved':
      return Colors.green.shade700;
    case 'rejected':
      return Colors.red.shade700;
    case 'failed':
      return Colors.purple.shade700;
    case 'pending_review':
    case 'partially_approved':
      return Colors.orange.shade700;
    default:
      return Colors.blueGrey.shade600;
  }
}
