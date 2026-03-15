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
                'Projects will appear here once they are published or assigned to your account.',
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
        final blockedCount =
            syncState.conflictCount + syncState.deadLetterCount;
        final syncLabel = syncState.isSyncing
            ? 'Syncing now'
            : blockedCount > 0
            ? '${syncState.pendingCount} queued • $blockedCount blocked'
            : '${syncState.pendingCount} queued';

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: widget.lockProjectSelection ? selectedProject.name : 'Lebanon Map',
              subtitle: widget.lockProjectSelection
                  ? 'Project basemap and collected feature overlays'
                  : 'Basemap, project feature overlays, and field status',
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
                        labelText: 'Project layer',
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
                      Chip(
                        avatar: const Icon(Icons.public, size: 18),
                        label: Text(
                          selectedProject.visibleToViewers
                              ? 'Viewer-visible project'
                              : 'Restricted project',
                        ),
                      ),
                      Chip(
                        avatar: const Icon(Icons.sync, size: 18),
                        label: Text(syncLabel),
                      ),
                      Chip(
                        avatar: const Icon(Icons.layers_outlined, size: 18),
                        label: Text('Features: ${featuresAsync.valueOrNull?.length ?? 0}'),
                      ),
                      Chip(
                        avatar: const Icon(Icons.gps_fixed, size: 18),
                        label: Text(
                          canCollectOnMap
                              ? 'Collection enabled'
                              : 'Read-only map access',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Expanded(
              child: featuresAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => AppEmptyState(
                  icon: Icons.error_outline,
                  title: 'Map overlays unavailable',
                  message:
                      'The map loaded, but feature overlays could not be retrieved. ${_cleanError(error)}',
                  actionLabel: 'Retry',
                  onAction: () => ref.invalidate(
                    projectMapFeaturesProvider(selectedProject.id),
                  ),
                ),
                data: (features) => Stack(
                  children: [
                    ClipRRect(
                      borderRadius: AppRadii.lg,
                      child: FlutterMap(
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
                    Positioned(
                      left: 12,
                      bottom: 12,
                      child: AppCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              selectedProject.name,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Status: ${selectedProject.status}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (features.isEmpty)
                      Center(
                        child: AppCard(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 360),
                            child: const ListTile(
                              leading: Icon(Icons.layers_clear_outlined),
                              title: Text('No mapped features yet'),
                              subtitle: Text(
                                'The Lebanon basemap is active. Feature geometry will appear here once collection records exist for the selected project.',
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (canCollectOnMap)
                      Positioned(
                        right: 18,
                        bottom: 18,
                        child: FloatingActionButton.extended(
                          onPressed: () =>
                              context.push(AppRoutes.addFeatureForProject(selectedProject.id)),
                          icon: const Icon(Icons.add_location_alt),
                          label: const Text('Add Feature'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
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
