import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../../auth/domain/auth_models.dart';
import '../../../projects/domain/project.dart';
import '../../domain/map_feature.dart';

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({
    this.initialProjectId,
    this.lockProjectSelection = false,
    super.key,
  });

  final String? initialProjectId;
  final bool lockProjectSelection;

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final MapController _mapController = MapController();

  String? _selectedProjectId;

  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(syncControllerProvider);
    final session = ref.watch(authControllerProvider).session;
    final role = session?.user.role ?? UserRole.viewer;
    final projectsAsync = ref.watch(mapProjectsProvider);

    return projectsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Map data unavailable',
        message: '$error',
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(mapProjectsProvider),
      ),
      data: (projects) {
        final availableProjects = widget.lockProjectSelection &&
                widget.initialProjectId != null
            ? projects
                  .where((project) => project.id == widget.initialProjectId)
                  .toList(growable: false)
            : projects;

        if (availableProjects.isEmpty) {
          return const AppEmptyState(
            icon: Icons.map_outlined,
            title: 'No projects available for map viewing',
            message:
                'Projects appear here once they are viewer-visible or assigned to your account.',
          );
        }

        final selectedProject = _resolveSelectedProject(
          availableProjects,
          requestedProjectId: widget.initialProjectId,
        );
        final featuresAsync = ref.watch(
          projectMapFeaturesProvider(selectedProject.id),
        );
        final canCollectOnMap =
            role == UserRole.contributor &&
            selectedProject.hasApprovedCurrentUserAssignment;
        final canReview = role == UserRole.admin;

        return ListView(
          children: [
            SectionHeader(
              title: widget.lockProjectSelection ? selectedProject.name : 'Lebanon Map',
              subtitle: widget.lockProjectSelection
                  ? 'Project basemap, feature overlays, and collection actions.'
                  : 'Basemap, live project overlays, and field collection workflow.',
            ),
            const SizedBox(height: AppSpacing.sm),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!widget.lockProjectSelection) ...[
                    DropdownButtonFormField<String>(
                      initialValue: selectedProject.id,
                      decoration: const InputDecoration(
                        labelText: 'Project',
                      ),
                      items: availableProjects
                          .map(
                            (project) => DropdownMenuItem(
                              value: project.id,
                              child: Text(project.name),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (value) {
                        if (value == null || value.isEmpty) {
                          return;
                        }
                        setState(() {
                          _selectedProjectId = value;
                        });
                      },
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      StatusChip(status: selectedProject.status),
                      Chip(
                        label: Text(
                          selectedProject.visibleToViewers
                              ? 'Viewer-visible'
                              : 'Restricted project',
                        ),
                      ),
                      if (syncState.pendingCount > 0)
                        Chip(
                          avatar: const Icon(Icons.cloud_upload_outlined, size: 18),
                          label: Text('${syncState.pendingCount} queued'),
                        ),
                      if (syncState.conflictCount > 0 || syncState.deadLetterCount > 0)
                        Chip(
                          avatar: const Icon(Icons.error_outline, size: 18),
                          label: Text(
                            '${syncState.conflictCount + syncState.deadLetterCount} sync issue(s)',
                          ),
                        ),
                      Chip(
                        avatar: const Icon(Icons.layers_outlined, size: 18),
                        label: Text(
                          'Features ${featuresAsync.valueOrNull?.length ?? 0}',
                        ),
                      ),
                      Chip(
                        avatar: Icon(
                          canCollectOnMap
                              ? Icons.edit_location_alt_outlined
                              : Icons.visibility_outlined,
                          size: 18,
                        ),
                        label: Text(
                          canCollectOnMap ? 'Collection enabled' : 'Read-only',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      if (canCollectOnMap)
                        FilledButton.icon(
                          onPressed: () => context.push(
                            AppRoutes.addFeatureForProject(selectedProject.id),
                          ),
                          icon: const Icon(Icons.add_location_alt_outlined),
                          label: const Text('Add Feature'),
                        ),
                      if (canReview)
                        FilledButton.tonalIcon(
                          onPressed: () => context.go(AppRoutes.reviewQueue),
                          icon: const Icon(Icons.rate_review_outlined),
                          label: const Text('Review Queue'),
                        ),
                      OutlinedButton.icon(
                        onPressed: () => ref.invalidate(
                          projectMapFeaturesProvider(selectedProject.id),
                        ),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Refresh Map Data'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            featuresAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, _) => AppEmptyState(
                icon: Icons.error_outline,
                title: 'Map overlays unavailable',
                message: _cleanError(error),
                actionLabel: 'Retry',
                onAction: () => ref.invalidate(
                  projectMapFeaturesProvider(selectedProject.id),
                ),
              ),
              data: (features) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppCard(
                    padding: EdgeInsets.zero,
                    child: SizedBox(
                      height: 380,
                      child: ClipRRect(
                        borderRadius: AppRadii.lg,
                        child: FlutterMap(
                          mapController: _mapController,
                          options: const MapOptions(
                            initialCenter: LatLng(33.8547, 35.8623),
                            initialZoom: 8,
                            minZoom: 6,
                            maxZoom: 18,
                          ),
                          children: [
                            TileLayer(
                              urlTemplate:
                                  'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
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
                  const SizedBox(height: AppSpacing.sm),
                  if (features.isEmpty)
                    AppEmptyState(
                      icon: Icons.layers_clear_outlined,
                      title: 'No mapped features yet',
                      message: canCollectOnMap
                          ? 'Start the collection workflow from this project map to add the first field feature.'
                          : 'Approved or draft features for this project will appear here when they are created.',
                      actionLabel: canCollectOnMap ? 'Add Feature' : null,
                      onAction: canCollectOnMap
                          ? () => context.push(
                                AppRoutes.addFeatureForProject(selectedProject.id),
                              )
                          : null,
                    )
                  else ...[
                    Text(
                      'Project Features',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    ...features.map(
                      (feature) => Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: AppCard(
                          child: InkWell(
                            onTap: () => _focusFeature(feature),
                            borderRadius: AppRadii.lg,
                            child: Padding(
                              padding: const EdgeInsets.all(AppSpacing.sm),
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
                                              'Feature ${feature.id.substring(0, 8)}',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium,
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              '${feature.geometry['type'] ?? 'Geometry'} • ${feature.photoCount} photo(s)',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall,
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: AppSpacing.sm),
                                      StatusChip(status: feature.status),
                                    ],
                                  ),
                                  const SizedBox(height: AppSpacing.xs),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      if (feature.collectedBy != null)
                                        Chip(label: Text('Collector: ${feature.collectedBy}')),
                                      if (feature.reviewedBy != null)
                                        Chip(label: Text('Reviewed by: ${feature.reviewedBy}')),
                                      TextButton.icon(
                                        onPressed: () => _focusFeature(feature),
                                        icon: const Icon(Icons.center_focus_strong, size: 18),
                                        label: const Text('Center on map'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  void _focusFeature(MapFeatureSummary feature) {
    final point = _pointFromGeometry(feature.geometry);
    if (point == null) {
      return;
    }
    _mapController.move(point, 15);
  }

  ProjectSummary _resolveSelectedProject(
    List<ProjectSummary> projects, {
    required String? requestedProjectId,
  }) {
    final candidates = <String?>[_selectedProjectId, requestedProjectId];
    for (final candidate in candidates) {
      if (candidate == null || candidate.isEmpty) {
        continue;
      }
      for (final project in projects) {
        if (project.id == candidate) {
          return project;
        }
      }
    }
    return projects.first;
  }

  String _cleanError(Object error) {
    final raw = error.toString();
    if (raw.startsWith('Exception: ')) {
      return raw.substring('Exception: '.length);
    }
    return raw;
  }

  List<Marker> _markerOverlays(List<MapFeatureSummary> features) {
    final markers = <Marker>[];
    for (final feature in features) {
      final point = _pointFromGeometry(feature.geometry);
      if (point == null) {
        continue;
      }
      markers.add(
        Marker(
          point: point,
          width: 48,
          height: 48,
          child: Tooltip(
            message: '${feature.status} • ${feature.photoCount} photo(s)',
            child: Icon(
              Icons.location_on,
              color: _statusColor(feature.status),
              size: 34,
            ),
          ),
        ),
      );
    }
    return markers;
  }

  List<Polyline> _polylineOverlays(List<MapFeatureSummary> features) {
    final polylines = <Polyline>[];
    for (final feature in features) {
      final geometryType = feature.geometry['type'] as String?;
      if (geometryType != 'LineString') {
        continue;
      }
      final rawCoordinates =
          feature.geometry['coordinates'] as List? ?? const [];
      final points = rawCoordinates
          .whereType<List>()
          .map(_toLatLng)
          .whereType<LatLng>()
          .toList(growable: false);
      if (points.length < 2) {
        continue;
      }
      polylines.add(
        Polyline(
          points: points,
          strokeWidth: 4,
          color: _statusColor(feature.status),
        ),
      );
    }
    return polylines;
  }

  List<Polygon> _polygonOverlays(List<MapFeatureSummary> features) {
    final polygons = <Polygon>[];
    for (final feature in features) {
      final geometryType = feature.geometry['type'] as String?;
      if (geometryType != 'Polygon') {
        continue;
      }
      final rawRings = feature.geometry['coordinates'] as List? ?? const [];
      if (rawRings.isEmpty) {
        continue;
      }
      final firstRing = rawRings.first;
      if (firstRing is! List) {
        continue;
      }
      final points = firstRing
          .whereType<List>()
          .map(_toLatLng)
          .whereType<LatLng>()
          .toList(growable: false);
      if (points.length < 3) {
        continue;
      }
      final color = _statusColor(feature.status);
      polygons.add(
        Polygon(
          points: points,
          borderStrokeWidth: 2,
          borderColor: color,
          color: color.withValues(alpha: 0.18),
        ),
      );
    }
    return polygons;
  }

  LatLng? _pointFromGeometry(Map<String, dynamic> geometry) {
    final type = geometry['type'] as String?;
    if (type != 'Point') {
      return null;
    }
    final coordinates = geometry['coordinates'] as List? ?? const [];
    return _toLatLng(coordinates);
  }

  LatLng? _toLatLng(List<dynamic> coordinates) {
    if (coordinates.length < 2) {
      return null;
    }
    final lon = _toDouble(coordinates[0]);
    final lat = _toDouble(coordinates[1]);
    if (lat == null || lon == null) {
      return null;
    }
    return LatLng(lat, lon);
  }

  double? _toDouble(dynamic value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'approved':
        return Colors.green.shade700;
      case 'pending_review':
        return Colors.orange.shade700;
      case 'rejected':
        return Colors.red.shade700;
      default:
        return Colors.blue.shade700;
    }
  }
}
