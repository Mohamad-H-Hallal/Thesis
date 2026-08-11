import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../domain/app_tile_provider.dart';
import '../../domain/lebanon_map.dart';
import '../../domain/map_feature.dart';
import '../../domain/map_geometry.dart';

class ProjectQuickMapCard extends ConsumerStatefulWidget {
  const ProjectQuickMapCard({
    required this.projectId,
    this.onOpenFullscreen,
    super.key,
  });

  final String projectId;
  final VoidCallback? onOpenFullscreen;

  @override
  ConsumerState<ProjectQuickMapCard> createState() =>
      _ProjectQuickMapCardState();
}

class _ProjectQuickMapCardState extends ConsumerState<ProjectQuickMapCard> {
  LebanonBasemapStyle _previewBasemapStyle = LebanonBasemapStyle.street;

  @override
  Widget build(BuildContext context) {
    final featuresAsync = ref.watch(
      projectMapFeaturesProvider(widget.projectId),
    );
    final featureCount = featuresAsync.valueOrNull?.length;
    final featureCountLabel = featuresAsync.hasError
        ? 'Map unavailable'
        : featureCount == null
        ? 'Loading map'
        : featureCount == 1
        ? '1 mapped feature'
        : '$featureCount mapped features';
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
      selected: <LebanonBasemapStyle>{_previewBasemapStyle},
      onSelectionChanged: (selection) {
        setState(() {
          _previewBasemapStyle = selection.first;
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
                'Project map',
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
          const SizedBox(height: 10),
          _QuickMapPill(icon: Icons.place_outlined, label: featureCountLabel),
          const SizedBox(height: AppSpacing.md),
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(22),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onOpenFullscreen,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: theme.dividerColor),
                  color: scheme.surfaceContainerLow,
                  boxShadow: AppShadows.soft,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 236,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: featuresAsync.when(
                              loading: () => const Center(
                                child: CircularProgressIndicator(),
                              ),
                              error: (error, _) => AppEmptyState(
                                icon: Icons.map_outlined,
                                title: 'Map preview unavailable',
                                message: userFacingErrorMessage(
                                  error,
                                  fallback:
                                      'Unable to load the project preview map right now.',
                                ),
                              ),
                              data: (features) => IgnorePointer(
                                child: FlutterMap(
                                  options: MapOptions(
                                    initialCenter: LebanonMapConfig.center,
                                    initialZoom:
                                        LebanonMapConfig.quickInitialZoom -
                                        0.15,
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
                                              _previewBasemapStyle,
                                            ),
                                        tileProvider: appNetworkTileProvider(),
                                        userAgentPackageName:
                                            'lb.gov.gis_collector',
                                      ),
                                    if (LebanonMapConfig
                                            .shouldRenderTileLayers &&
                                        LebanonMapConfig.referenceLabelUrlTemplate(
                                              _previewBasemapStyle,
                                            ) !=
                                            null)
                                      TileLayer(
                                        urlTemplate:
                                            LebanonMapConfig.referenceLabelUrlTemplate(
                                              _previewBasemapStyle,
                                            )!,
                                        tileProvider: appNetworkTileProvider(),
                                        userAgentPackageName:
                                            'lb.gov.gis_collector',
                                      ),
                                    PolygonLayer(
                                      polygons: _polygonOverlays(features),
                                    ),
                                    PolylineLayer(
                                      polylines: _polylineOverlays(features),
                                    ),
                                    MarkerLayer(
                                      markers: _markerOverlays(features),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (widget.onOpenFullscreen != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.touch_app_outlined, size: 16, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Tap the preview to open the full project map.',
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
        ],
      ),
    );
  }

  List<Polygon> _polygonOverlays(List<MapFeatureSummary> features) {
    final polygons = <Polygon>[];
    for (final feature in features) {
      if (!isPolygonGeometry(feature.geometry)) {
        continue;
      }
      final color = _statusColor(feature.status);
      for (final points in polygonGeometrySegments(feature.geometry)) {
        if (points.isEmpty) {
          continue;
        }
        polygons.add(
          Polygon(
            points: points,
            color: color.withValues(alpha: 0.12),
            borderStrokeWidth: 2,
            borderColor: color.withValues(alpha: 0.95),
          ),
        );
      }
    }
    return polygons;
  }

  List<Polyline> _polylineOverlays(List<MapFeatureSummary> features) {
    final polylines = <Polyline>[];
    for (final feature in features) {
      if (!isLineGeometry(feature.geometry)) {
        continue;
      }
      final color = _statusColor(feature.status);
      for (final points in lineGeometrySegments(feature.geometry)) {
        if (points.isEmpty) {
          continue;
        }
        polylines.add(
          Polyline(
            points: points,
            color: color.withValues(alpha: 0.9),
            strokeWidth: 2.5,
          ),
        );
      }
    }
    return polylines;
  }

  List<Marker> _markerOverlays(List<MapFeatureSummary> features) {
    final markers = <Marker>[];
    for (final feature in features) {
      if (!isPointGeometry(feature.geometry)) {
        continue;
      }
      final color = _statusColor(feature.status);
      for (final point in pointGeometryPoints(feature.geometry)) {
        markers.add(
          Marker(
            point: point,
            width: 16,
            height: 16,
            child: Container(
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.2),
                boxShadow: const [
                  BoxShadow(
                    blurRadius: 5,
                    offset: Offset(0, 2),
                    color: Color(0x26000000),
                  ),
                ],
              ),
            ),
          ),
        );
      }
    }
    return markers;
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'approved':
        return const Color(0xFF1E7A46);
      case 'pending_review':
      case 'partially_approved':
        return const Color(0xFFCB7A00);
      case 'rejected':
        return const Color(0xFFB3261E);
      case 'failed':
        return const Color(0xFF7B1FA2);
      default:
        return const Color(0xFF1A73E8);
    }
  }
}

class _QuickMapPill extends StatelessWidget {
  const _QuickMapPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 180),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: scheme.primary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
