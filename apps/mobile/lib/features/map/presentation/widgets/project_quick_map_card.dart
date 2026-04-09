import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../domain/lebanon_map.dart';
import '../../domain/map_feature.dart';
import '../../domain/map_geometry.dart';

class ProjectQuickMapCard extends ConsumerWidget {
  const ProjectQuickMapCard({
    required this.projectId,
    this.onOpenFullscreen,
    super.key,
  });

  final String projectId;
  final VoidCallback? onOpenFullscreen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final featuresAsync = ref.watch(projectMapFeaturesProvider(projectId));
    final featureCount = featuresAsync.valueOrNull?.length;
    final featureCountLabel = featureCount == null
        ? 'Loading map'
        : featureCount == 1
        ? '1 feature'
        : '$featureCount features';
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Project map',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _QuickMapPill(
                icon: Icons.place_outlined,
                label: featureCountLabel,
              ),
              if (onOpenFullscreen != null) ...[
                const SizedBox(width: AppSpacing.sm),
                TextButton.icon(
                  onPressed: onOpenFullscreen,
                  icon: const Icon(Icons.open_in_full_outlined),
                  label: const Text('Open map'),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Preview the Lebanon workspace before opening the full map.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(22),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onOpenFullscreen,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: theme.dividerColor),
                  color: scheme.surfaceContainerLow,
                ),
                child: SizedBox(
                  height: 236,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: featuresAsync.when(
                          loading: () =>
                              const Center(child: CircularProgressIndicator()),
                          error: (error, _) => AppEmptyState(
                            icon: Icons.map_outlined,
                            title: 'Map preview unavailable',
                            message: userFacingErrorMessage(
                              error,
                              fallback:
                                  'Unable to load the project preview map right now.',
                            ),
                          ),
                          data: (features) => FlutterMap(
                            options: MapOptions(
                              initialCenter: LebanonMapConfig.center,
                              initialZoom: LebanonMapConfig.quickInitialZoom,
                              initialCameraFit: LebanonMapConfig.quickFit,
                              minZoom: LebanonMapConfig.quickMinZoom,
                              maxZoom: LebanonMapConfig.quickMaxZoom,
                              cameraConstraint:
                                  LebanonMapConfig.cameraConstraint,
                            ),
                            children: [
                              TileLayer(
                                urlTemplate:
                                    LebanonMapConfig.basemapUrlTemplate(
                                      LebanonBasemapStyle.satellite,
                                    ),
                                tileProvider: NetworkTileProvider(
                                  silenceExceptions: true,
                                ),
                                userAgentPackageName: 'lb.gov.gis_collector',
                              ),
                              TileLayer(
                                urlTemplate:
                                    LebanonMapConfig.referenceLabelUrlTemplate(
                                      LebanonBasemapStyle.satellite,
                                    )!,
                                tileProvider: NetworkTileProvider(
                                  silenceExceptions: true,
                                ),
                                userAgentPackageName: 'lb.gov.gis_collector',
                              ),
                              PolygonLayer(
                                polygons: _polygonOverlays(features),
                              ),
                              PolylineLayer(
                                polylines: _polylineOverlays(features),
                              ),
                              MarkerLayer(markers: _markerOverlays(features)),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        left: 12,
                        top: 12,
                        child: _QuickMapPill(
                          icon: Icons.public_outlined,
                          label: 'Lebanon workspace',
                        ),
                      ),
                      if (onOpenFullscreen != null)
                        Positioned(
                          right: 12,
                          bottom: 12,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: scheme.surface.withValues(alpha: 0.92),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.touch_app_outlined,
                                    size: 16,
                                    color: scheme.primary,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Tap to open',
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Polygon> _polygonOverlays(List<MapFeatureSummary> features) {
    return features
        .where((feature) => feature.geometry['type'] == 'Polygon')
        .map((feature) {
          final points = polygonGeometryPoints(feature.geometry);
          if (points.isEmpty) {
            return null;
          }
          return Polygon(
            points: points,
            color: _statusColor(feature.status).withValues(alpha: 0.18),
            borderStrokeWidth: 2,
            borderColor: _statusColor(feature.status),
          );
        })
        .whereType<Polygon>()
        .toList(growable: false);
  }

  List<Polyline> _polylineOverlays(List<MapFeatureSummary> features) {
    return features
        .where((feature) => feature.geometry['type'] == 'LineString')
        .map((feature) {
          final points = lineGeometryPoints(feature.geometry);
          if (points.isEmpty) {
            return null;
          }
          return Polyline(
            points: points,
            color: _statusColor(feature.status),
            strokeWidth: 3,
          );
        })
        .whereType<Polyline>()
        .toList(growable: false);
  }

  List<Marker> _markerOverlays(List<MapFeatureSummary> features) {
    return features
        .map((feature) {
          final point = _pointFromGeometry(feature.geometry);
          if (point == null) {
            return null;
          }
          return Marker(
            point: point,
            width: 20,
            height: 20,
            child: Container(
              decoration: BoxDecoration(
                color: _statusColor(feature.status),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
                boxShadow: const [
                  BoxShadow(
                    blurRadius: 6,
                    offset: Offset(0, 2),
                    color: Color(0x26000000),
                  ),
                ],
              ),
            ),
          );
        })
        .whereType<Marker>()
        .toList(growable: false);
  }

  LatLng? _pointFromGeometry(Map<String, dynamic> geometry) {
    return geometryFocusPoint(geometry);
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'approved':
        return const Color(0xFF1E7A46);
      case 'pending_review':
        return const Color(0xFFCB7A00);
      case 'rejected':
        return const Color(0xFFB3261E);
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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: scheme.primary),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
