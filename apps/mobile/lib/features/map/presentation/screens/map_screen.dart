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
import '../../../../core/widgets/app_snackbar.dart';
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
  final Set<String> _visibleStatuses = <String>{
    'approved',
    'pending_review',
    'rejected',
    'draft',
  };

  String? _selectedProjectId;
  String? _tileFailureMessage;

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
            project.hasApprovedCurrentUserAssignment &&
            project.status == 'active';
        final canReview = role == UserRole.admin;

        Widget buildControls() {
          return AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!widget.lockProjectSelection) ...[
                  DropdownButtonFormField<String>(
                    initialValue: project.id,
                    isExpanded: true,
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
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final status in const [
                      'approved',
                      'pending_review',
                      'rejected',
                      'draft',
                    ])
                      FilterChip(
                        label: Text(_statusLabel(status)),
                        avatar: Icon(
                          Icons.circle,
                          size: 12,
                          color: _statusColor(status),
                        ),
                        selected: _visibleStatuses.contains(status),
                        onSelected: (selected) {
                          setState(() {
                            if (selected) {
                              _visibleStatuses.add(status);
                            } else if (_visibleStatuses.length > 1) {
                              _visibleStatuses.remove(status);
                            }
                          });
                        },
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
          );
        }

        Widget buildWorkspace() {
          return featuresAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => AppEmptyState(
              icon: Icons.error_outline,
              title: 'Project map unavailable',
              message: '$error',
              actionLabel: 'Retry',
              onAction: () =>
                  ref.invalidate(projectMapFeaturesProvider(project.id)),
            ),
            data: (features) {
              final filteredFeatures = features
                  .where((feature) => _visibleStatuses.contains(feature.status))
                  .toList(growable: false);

              return _buildMapWorkspace(
                context,
                project: project,
                features: filteredFeatures,
                canCollectOnMap: canCollectOnMap,
                canReview: canReview,
              );
            },
          );
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxHeight < 860 || constraints.maxWidth < 640) {
              final workspaceHeight = (constraints.maxHeight * 0.9).clamp(
                520.0,
                920.0,
              );
              return ListView(
                children: [
                  SectionHeader(
                    title: widget.lockProjectSelection
                        ? project.name
                        : 'Project Map',
                    subtitle: widget.lockProjectSelection
                        ? 'Project workspace for collection, review, and map validation.'
                        : 'Lebanon basemap with project-specific features and review context.',
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  buildControls(),
                  const SizedBox(height: AppSpacing.sm),
                  SizedBox(height: workspaceHeight, child: buildWorkspace()),
                ],
              );
            }

            return Column(
              children: [
                SectionHeader(
                  title: widget.lockProjectSelection
                      ? project.name
                      : 'Project Map',
                  subtitle: widget.lockProjectSelection
                      ? 'Project workspace for collection, review, and map validation.'
                      : 'Lebanon basemap with project-specific features and review context.',
                ),
                const SizedBox(height: AppSpacing.sm),
                buildControls(),
                const SizedBox(height: AppSpacing.sm),
                Expanded(child: buildWorkspace()),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildMapWorkspace(
    BuildContext context, {
    required ProjectSummary project,
    required List<MapFeatureSummary> features,
    required bool canCollectOnMap,
    required bool canReview,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mapCard = AppCard(
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
                      userAgentPackageName: 'lb.gov.gis_collector',
                      errorTileCallback: (tile, error, stackTrace) {
                        Object.hash(tile, stackTrace);
                        if (_tileFailureMessage != null) {
                          return;
                        }
                        final message = error.toString();
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted || _tileFailureMessage != null) {
                            return;
                          }
                          setState(() {
                            _tileFailureMessage =
                                'Basemap tiles are temporarily unavailable. Project features still remain usable.';
                          });
                          AppSnackbar.showError(
                            context,
                            message.contains('Failed host lookup')
                                ? 'Basemap tiles are unavailable on this connection. Feature overlays remain available.'
                                : 'Basemap tiles could not be loaded. Feature overlays remain available.',
                          );
                        });
                      },
                    ),
                    PolygonLayer(polygons: _polygonOverlays(features)),
                    PolylineLayer(polylines: _polylineOverlays(features)),
                    MarkerLayer(
                      markers: _markerOverlays(
                        features,
                        project,
                        canCollectOnMap,
                        canReview,
                      ),
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
              if (_tileFailureMessage != null)
                Positioned(
                  left: 12,
                  right: 72,
                  bottom: 12,
                  child: Material(
                    color: Colors.transparent,
                    child: AppCard(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.map_outlined),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(
                              _tileFailureMessage!,
                              softWrap: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );

        final featureList = features.isEmpty
            ? AppEmptyState(
                icon: Icons.layers_clear_outlined,
                title: 'No map features match the current filters',
                message: canCollectOnMap
                    ? 'Use Add Feature to collect orchard, field, or tree records for this project.'
                    : 'Approved or submitted features will appear here when they exist.',
                actionLabel: canCollectOnMap ? 'Add Feature' : null,
                onAction: canCollectOnMap
                    ? () => context.push(
                        AppRoutes.addFeatureForProject(project.id),
                      )
                    : null,
              )
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  Text(
                    'Project Features',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  ...features.map(
                    (feature) => Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: AppCard(
                        onTap: () => _openFeatureDetails(
                          project: project,
                          feature: feature,
                          canCollectOnMap: canCollectOnMap,
                          canReview: canReview,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
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
                                  Chip(
                                    label: Text(
                                      'Collector: ${feature.collectedBy}',
                                    ),
                                  ),
                                if (feature.accuracyMeters != null)
                                  Chip(
                                    label: Text(
                                      'GPS ${feature.accuracyMeters!.toStringAsFixed(1)}m',
                                    ),
                                  ),
                                TextButton.icon(
                                  onPressed: () {
                                    _focusFeature(feature);
                                    _openFeatureDetails(
                                      project: project,
                                      feature: feature,
                                      canCollectOnMap: canCollectOnMap,
                                      canReview: canReview,
                                    );
                                  },
                                  icon: const Icon(
                                    Icons.center_focus_strong,
                                    size: 18,
                                  ),
                                  label: const Text('View details'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );

        final legendCard = AppCard(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _LegendChip(label: 'Approved', color: _statusColor('approved')),
              _LegendChip(
                label: 'Pending review',
                color: _statusColor('pending_review'),
              ),
              _LegendChip(label: 'Rejected', color: _statusColor('rejected')),
              _LegendChip(label: 'Draft', color: _statusColor('draft')),
            ],
          ),
        );

        if (constraints.maxHeight < 720) {
          final mapHeight = constraints.maxHeight * 0.48;
          final listHeight = constraints.maxHeight * 0.42;
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              legendCard,
              const SizedBox(height: AppSpacing.sm),
              SizedBox(height: mapHeight, child: mapCard),
              const SizedBox(height: AppSpacing.sm),
              SizedBox(height: listHeight, child: featureList),
            ],
          );
        }

        return Column(
          children: [
            legendCard,
            const SizedBox(height: AppSpacing.sm),
            Expanded(flex: 4, child: mapCard),
            const SizedBox(height: AppSpacing.sm),
            Expanded(flex: 3, child: featureList),
          ],
        );
      },
    );
  }

  Future<void> _reviewFeature({
    required String projectId,
    required MapFeatureSummary feature,
    required String status,
  }) async {
    final note = await _promptNote(
      title: status == 'approved' ? 'Approval note' : 'Rejection note',
      hint: status == 'approved'
          ? 'Optional context for the contributor.'
          : 'Required reason for rejection.',
      requiredNote: status == 'rejected',
    );
    if (note == null) {
      return;
    }

    try {
      await ref
          .read(reviewRepositoryProvider)
          .reviewFeature(
            featureId: feature.id,
            status: status,
            reviewNotes: note,
          );
      ref.invalidate(projectMapFeaturesProvider(projectId));
      ref.invalidate(reviewQueueProvider);
      if (mounted) {
        Navigator.of(context).maybePop();
        AppSnackbar.showSuccess(
          context,
          status == 'approved'
              ? 'Feature approved successfully.'
              : 'Feature rejected successfully.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(context, error.toString());
      }
    }
  }

  Future<void> _submitDraft({
    required String projectId,
    required MapFeatureSummary feature,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Submit draft'),
        content: const Text(
          'Submit this draft for admin review now?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Submit'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    try {
      await ref
          .read(featureWorkflowRepositoryProvider)
          .submitForReview(feature.id);
      ref.invalidate(projectMapFeaturesProvider(projectId));
      ref.invalidate(projectByIdProvider(projectId));
      ref.invalidate(reviewQueueProvider);
      if (mounted) {
        Navigator.of(context).maybePop();
        AppSnackbar.showSuccess(
          context,
          'Draft submitted for review successfully.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(context, error.toString());
      }
    }
  }

  Future<String?> _promptNote({
    required String title,
    required String hint,
    required bool requiredNote,
  }) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(hintText: hint),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (requiredNote && value.isEmpty) {
                  return;
                }
                Navigator.of(context).pop(value);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  void _openFeatureDetails({
    required ProjectSummary project,
    required MapFeatureSummary feature,
    required bool canCollectOnMap,
    required bool canReview,
  }) {
    _focusFeature(feature);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.75,
            minChildSize: 0.45,
            maxChildSize: 0.94,
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
                      Chip(
                        label: Text(
                          'Geometry: ${feature.geometry['type'] ?? 'Unknown'}',
                        ),
                      ),
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
                  _DetailSection(
                    title: 'Geometry summary',
                    child: Text(_geometrySummary(feature.geometry)),
                  ),
                  _DetailSection(
                    title: 'Lifecycle',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (feature.collectedAt != null)
                          Text(
                            'Collected: ${_formatDateTime(feature.collectedAt!)}',
                          ),
                        if (feature.submittedAt != null)
                          Text(
                            'Submitted: ${_formatDateTime(feature.submittedAt!)}',
                          ),
                        if (feature.reviewedAt != null)
                          Text(
                            'Reviewed: ${_formatDateTime(feature.reviewedAt!)}',
                          ),
                      ],
                    ),
                  ),
                  if (feature.attributes.isNotEmpty)
                    _DetailSection(
                      title: 'Attributes',
                      child: Column(
                        children: feature.attributes.entries
                            .map(
                              (entry) => ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(entry.key),
                                subtitle: Text('${entry.value}'),
                              ),
                            )
                            .toList(growable: false),
                      ),
                    ),
                  if (feature.reviewNotes?.trim().isNotEmpty == true)
                    _DetailSection(
                      title: 'Review notes',
                      child: Text(feature.reviewNotes!),
                    ),
                  _DetailSection(
                    title: 'Photos',
                    child: feature.photos.isEmpty
                        ? const AppEmptyState(
                            icon: Icons.photo_library_outlined,
                            title: 'No photos attached',
                            message: 'Photos will appear here after upload.',
                          )
                        : Column(
                            children: feature.photos
                                .map(
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
                                )
                                .toList(growable: false),
                          ),
                  ),
                  if (canCollectOnMap && feature.status == 'draft')
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.md),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () {
                              Navigator.of(context).maybePop();
                              this.context.push(
                                AppRoutes.editDraftFeature(
                                  projectId: project.id,
                                  featureId: feature.id,
                                ),
                              );
                            },
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('Edit Draft'),
                          ),
                          FilledButton.icon(
                            onPressed: () => _submitDraft(
                              projectId: project.id,
                              feature: feature,
                            ),
                            icon: const Icon(Icons.send_outlined),
                            label: const Text('Submit Draft'),
                          ),
                        ],
                      ),
                    ),
                  if (canReview && feature.status != 'draft')
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.md),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: () => _reviewFeature(
                              projectId: project.id,
                              feature: feature,
                              status: 'approved',
                            ),
                            icon: const Icon(Icons.check_circle_outline),
                            label: Text(
                              feature.status == 'approved'
                                  ? 'Re-approve'
                                  : 'Approve',
                            ),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: () => _reviewFeature(
                              projectId: project.id,
                              feature: feature,
                              status: 'rejected',
                            ),
                            icon: const Icon(Icons.cancel_outlined),
                            label: Text(
                              feature.status == 'rejected'
                                  ? 'Re-reject'
                                  : 'Reject',
                            ),
                          ),
                        ],
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

  List<Marker> _markerOverlays(
    List<MapFeatureSummary> features,
    ProjectSummary project,
    bool canCollectOnMap,
    bool canReview,
  ) {
    return features
        .map((feature) {
          final point = _pointFromGeometry(feature.geometry);
          if (point == null) {
            return null;
          }
          final color = _statusColor(feature.status);
          return Marker(
            point: point,
            width: 38,
            height: 38,
            child: GestureDetector(
              onTap: () => _openFeatureDetails(
                project: project,
                feature: feature,
                canCollectOnMap: canCollectOnMap,
                canReview: canReview,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: Icon(
                  feature.status == 'approved'
                      ? Icons.check
                      : feature.status == 'rejected'
                      ? Icons.close
                      : Icons.schedule,
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

  String _statusLabel(String status) {
    switch (status) {
      case 'pending_review':
        return 'Pending';
      case 'approved':
        return 'Approved';
      case 'rejected':
        return 'Rejected';
      default:
        return 'Draft';
    }
  }

  String _geometrySummary(Map<String, dynamic> geometry) {
    final type = geometry['type'] as String? ?? 'Unknown';
    final coordinates = geometry['coordinates'];
    if (type == 'Point' && coordinates is List && coordinates.length >= 2) {
      return 'Point at lon ${coordinates[0]}, lat ${coordinates[1]}';
    }
    if (type == 'LineString' && coordinates is List) {
      return 'LineString with ${coordinates.length} vertices';
    }
    if (type == 'Polygon' && coordinates is List && coordinates.isNotEmpty) {
      final firstRing = coordinates.first;
      return 'Polygon with ${(firstRing as List).length} boundary points';
    }
    return type;
  }

  String _formatDateTime(DateTime value) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$month-$day $hour:$minute';
  }

  String _photoLabel(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/');
    return segments.isEmpty ? path : segments.last;
  }
}

class _LegendChip extends StatelessWidget {
  const _LegendChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(Icons.circle, color: color, size: 12),
      label: Text(label),
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          child,
        ],
      ),
    );
  }
}
