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
        final availableProjects =
            widget.lockProjectSelection && widget.initialProjectId != null
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

        final project = _resolveSelectedProject(
          availableProjects,
          requestedProjectId: widget.initialProjectId,
        );
        final featuresAsync = ref.watch(projectMapFeaturesProvider(project.id));
        final canCollectOnMap =
            role == UserRole.contributor &&
            project.hasApprovedCurrentUserAssignment;
        final canReview = role == UserRole.admin;

        return Column(
          children: [
            SectionHeader(
              title: widget.lockProjectSelection ? project.name : 'Project Map',
              subtitle: widget.lockProjectSelection
                  ? 'Project workspace for feature collection, review, and export.'
                  : 'Lebanon basemap with project-specific field features.',
            ),
            const SizedBox(height: AppSpacing.sm),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!widget.lockProjectSelection) ...[
                    DropdownButtonFormField<String>(
                      initialValue: project.id,
                      decoration: const InputDecoration(labelText: 'Project'),
                      items: availableProjects
                          .map(
                            (item) => DropdownMenuItem(
                              value: item.id,
                              child: Text(
                                item.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (value) {
                        if (value == null || value.isEmpty) {
                          return;
                        }
                        setState(() => _selectedProjectId = value);
                      },
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      StatusChip(status: project.status),
                      Chip(
                        label: Text(
                          project.visibleToViewers
                              ? 'Viewer-visible'
                              : 'Restricted',
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
                            AppRoutes.addFeatureForProject(project.id),
                          ),
                          icon: const Icon(Icons.add_location_alt_outlined),
                          label: const Text('Add Feature'),
                        ),
                      if (canReview)
                        FilledButton.tonalIcon(
                          onPressed: () => context.push(AppRoutes.reviewQueue),
                          icon: const Icon(Icons.rate_review_outlined),
                          label: const Text('Review Queue'),
                        ),
                      OutlinedButton.icon(
                        onPressed: () => ref.invalidate(
                          projectMapFeaturesProvider(project.id),
                        ),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Refresh'),
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
                  title: 'Project map unavailable',
                  message: '$error',
                  actionLabel: 'Retry',
                  onAction: () =>
                      ref.invalidate(projectMapFeaturesProvider(project.id)),
                ),
                data: (features) => Column(
                  children: [
                    Expanded(
                      flex: 3,
                      child: AppCard(
                        padding: EdgeInsets.zero,
                        child: Stack(
                          children: [
                            ClipRRect(
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
                            Positioned(
                              right: 12,
                              top: 12,
                              child: Column(
                                children: [
                                  FloatingActionButton.small(
                                    heroTag: 'map_zoom_in',
                                    onPressed: () => _mapController.move(
                                      _mapController.camera.center,
                                      _mapController.camera.zoom + 1,
                                    ),
                                    child: const Icon(Icons.add),
                                  ),
                                  const SizedBox(height: 8),
                                  FloatingActionButton.small(
                                    heroTag: 'map_zoom_out',
                                    onPressed: () => _mapController.move(
                                      _mapController.camera.center,
                                      _mapController.camera.zoom - 1,
                                    ),
                                    child: const Icon(Icons.remove),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Expanded(
                      flex: 2,
                      child: features.isEmpty
                          ? AppEmptyState(
                              icon: Icons.layers_clear_outlined,
                              title: 'No mapped features yet',
                              message: canCollectOnMap
                                  ? 'Use Add Feature to start collecting orchard, field, or tree records for this project.'
                                  : 'Approved or submitted project features will appear here when they exist.',
                              actionLabel: canCollectOnMap
                                  ? 'Add Feature'
                                  : null,
                              onAction: canCollectOnMap
                                  ? () => context.push(
                                      AppRoutes.addFeatureForProject(
                                        project.id,
                                      ),
                                    )
                                  : null,
                            )
                          : ListView(
                              children: [
                                Text(
                                  'Project Features',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                const SizedBox(height: AppSpacing.sm),
                                ...features.map(
                                  (feature) => Padding(
                                    padding: const EdgeInsets.only(
                                      bottom: AppSpacing.sm,
                                    ),
                                    child: AppCard(
                                      onTap: () => _openFeatureDetails(feature),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      'Feature ${feature.id.substring(0, 8)}',
                                                      style: Theme.of(
                                                        context,
                                                      ).textTheme.titleMedium,
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      '${feature.geometry['type'] ?? 'Geometry'} • ${feature.photoCount} photo(s)',
                                                      style: Theme.of(
                                                        context,
                                                      ).textTheme.bodySmall,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(
                                                width: AppSpacing.sm,
                                              ),
                                              StatusChip(
                                                status: feature.status,
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: AppSpacing.xs),
                                          Wrap(
                                            spacing: 8,
                                            runSpacing: 8,
                                            children: [
                                              if (feature.collectedBy != null)
                                                Chip(
                                                  label: Text(
                                                    'Collector: ${feature.collectedBy}',
                                                  ),
                                                ),
                                              if (feature.accuracyMeters !=
                                                  null)
                                                Chip(
                                                  label: Text(
                                                    'GPS ${feature.accuracyMeters!.toStringAsFixed(1)}m',
                                                  ),
                                                ),
                                              TextButton.icon(
                                                onPressed: () {
                                                  _focusFeature(feature);
                                                  _openFeatureDetails(feature);
                                                },
                                                icon: const Icon(
                                                  Icons.center_focus_strong,
                                                  size: 18,
                                                ),
                                                label: const Text(
                                                  'View details',
                                                ),
                                              ),
                                            ],
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
          ],
        );
      },
    );
  }

  void _openFeatureDetails(MapFeatureSummary feature) {
    _focusFeature(feature);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.7,
            minChildSize: 0.45,
            maxChildSize: 0.92,
            builder: (context, controller) {
              return ListView(
                controller: controller,
                padding: const EdgeInsets.all(AppSpacing.md),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Feature ${feature.id.substring(0, 8)}',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      StatusChip(status: feature.status),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (feature.collectedBy != null)
                        Chip(label: Text('Collector: ${feature.collectedBy}')),
                      if (feature.reviewedBy != null)
                        Chip(label: Text('Reviewed by: ${feature.reviewedBy}')),
                      if (feature.accuracyMeters != null)
                        Chip(
                          label: Text(
                            'Accuracy ${feature.accuracyMeters!.toStringAsFixed(1)}m',
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (feature.attributes.isNotEmpty) ...[
                    Text(
                      'Attributes',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    ...feature.attributes.entries.map(
                      (entry) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(entry.key),
                        subtitle: Text('${entry.value}'),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  if (feature.reviewNotes?.trim().isNotEmpty == true) ...[
                    Text(
                      'Review notes',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(feature.reviewNotes!),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  Text(
                    'Photos',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (feature.photos.isEmpty)
                    const AppEmptyState(
                      icon: Icons.photo_library_outlined,
                      title: 'No photos attached',
                      message: 'Photos will appear here after upload.',
                    )
                  else
                    ...feature.photos.map(
                      (photo) => AppCard(
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const CircleAvatar(
                            child: Icon(Icons.photo_outlined),
                          ),
                          title: Text(_photoLabel(photo.filePath)),
                          subtitle: Text(
                            photo.status?.isNotEmpty == true
                                ? 'Status: ${photo.status}'
                                : 'Captured photo',
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
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
    for (final candidate in <String?>[_selectedProjectId, requestedProjectId]) {
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

  List<Polygon> _polygonOverlays(List<MapFeatureSummary> features) {
    return features
        .where((feature) => feature.geometry['type'] == 'Polygon')
        .map((feature) {
          final coordinates = feature.geometry['coordinates'] as List?;
          final firstRing = coordinates?.isNotEmpty == true
              ? coordinates!.first as List?
              : null;
          final points = (firstRing ?? const <dynamic>[])
              .map((point) {
                final values = point as List;
                return LatLng(
                  (values[1] as num).toDouble(),
                  (values[0] as num).toDouble(),
                );
              })
              .toList(growable: false);
          final color = _statusColor(feature.status);
          return Polygon(
            points: points,
            color: color.withValues(alpha: 0.18),
            borderStrokeWidth: 2.5,
            borderColor: color,
          );
        })
        .toList(growable: false);
  }

  List<Polyline> _polylineOverlays(List<MapFeatureSummary> features) {
    return features
        .where((feature) => feature.geometry['type'] == 'LineString')
        .map((feature) {
          final coordinates =
              feature.geometry['coordinates'] as List? ?? const [];
          final points = coordinates
              .map((point) {
                final values = point as List;
                return LatLng(
                  (values[1] as num).toDouble(),
                  (values[0] as num).toDouble(),
                );
              })
              .toList(growable: false);
          return Polyline(
            points: points,
            color: _statusColor(feature.status),
            strokeWidth: 4,
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
          final color = _statusColor(feature.status);
          return Marker(
            point: point,
            width: 34,
            height: 34,
            child: GestureDetector(
              onTap: () => _openFeatureDetails(feature),
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: const Icon(
                  Icons.location_on,
                  color: Colors.white,
                  size: 18,
                ),
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

    if (type == 'LineString' && coordinates is List && coordinates.isNotEmpty) {
      final first = coordinates.first as List;
      return LatLng((first[1] as num).toDouble(), (first[0] as num).toDouble());
    }

    if (type == 'Polygon' &&
        coordinates is List &&
        coordinates.isNotEmpty &&
        coordinates.first is List &&
        (coordinates.first as List).isNotEmpty) {
      final first = (coordinates.first as List).first as List;
      return LatLng((first[1] as num).toDouble(), (first[0] as num).toDouble());
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

  String _photoLabel(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/');
    return segments.isEmpty ? path : segments.last;
  }
}
