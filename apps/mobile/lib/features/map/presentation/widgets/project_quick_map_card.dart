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

    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Quick Map',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Lebanon-only preview for this project.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (onOpenFullscreen != null)
                  TextButton.icon(
                    onPressed: onOpenFullscreen,
                    icon: const Icon(Icons.open_in_full_outlined),
                    label: const Text('Open full map'),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: 240,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(20),
              ),
              child: featuresAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
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
                    cameraConstraint: LebanonMapConfig.cameraConstraint,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: LebanonMapConfig.basemapUrlTemplate(
                        LebanonBasemapStyle.satellite,
                      ),
                      userAgentPackageName: 'lb.gov.gis_collector',
                    ),
                    PolygonLayer(polygons: _polygonOverlays(features)),
                    PolylineLayer(polylines: _polylineOverlays(features)),
                    MarkerLayer(markers: _markerOverlays(features)),
                  ],
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
          final coordinates = feature.geometry['coordinates'] as List?;
          final firstRing = coordinates?.isNotEmpty == true
              ? coordinates!.first as List?
              : null;
          final points = (firstRing ?? const <dynamic>[])
              .whereType<List>()
              .where((point) => point.length >= 2)
              .map(
                (point) => LatLng(
                  (point[1] as num).toDouble(),
                  (point[0] as num).toDouble(),
                ),
              )
              .toList(growable: false);
          return Polygon(
            points: points,
            color: _statusColor(feature.status).withValues(alpha: 0.18),
            borderStrokeWidth: 2,
            borderColor: _statusColor(feature.status),
          );
        })
        .toList(growable: false);
  }

  List<Polyline> _polylineOverlays(List<MapFeatureSummary> features) {
    return features
        .where((feature) => feature.geometry['type'] == 'LineString')
        .map((feature) {
          final coordinates =
              feature.geometry['coordinates'] as List? ?? const <dynamic>[];
          final points = coordinates
              .whereType<List>()
              .where((point) => point.length >= 2)
              .map(
                (point) => LatLng(
                  (point[1] as num).toDouble(),
                  (point[0] as num).toDouble(),
                ),
              )
              .toList(growable: false);
          return Polyline(
            points: points,
            color: _statusColor(feature.status),
            strokeWidth: 3,
          );
        })
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
            width: 18,
            height: 18,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _statusColor(feature.status),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
            ),
          );
        })
        .whereType<Marker>()
        .toList(growable: false);
  }

  LatLng? _pointFromGeometry(Map<String, dynamic> geometry) {
    final type = geometry['type'] as String?;
    final coordinates = geometry['coordinates'];
    if (type == 'Point' && coordinates is List && coordinates.length >= 2) {
      return LatLng(
        (coordinates[1] as num).toDouble(),
        (coordinates[0] as num).toDouble(),
      );
    }
    return null;
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
