import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/offline/local_models.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/sync/sync_controller.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../auth/domain/auth_models.dart';
import '../../../projects/domain/project.dart';
import '../../domain/current_location_service.dart';
import '../../domain/lebanon_map.dart';
import '../../domain/map_feature.dart';
import '../../domain/map_geometry.dart';
import '../widgets/feature_photo_gallery.dart';

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({
    this.initialProjectId,
    this.initialFeatureId,
    this.lockProjectSelection = false,
    super.key,
  });

  final String? initialProjectId;
  final String? initialFeatureId;
  final bool lockProjectSelection;

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _visibleStatuses = <String>{
    'approved',
    'pending_review',
    'rejected',
    'draft',
  };

  String? _selectedProjectId;
  String? _selectedFeatureChip;
  String? _tileFailureMessage;
  String? _autoOpenedFeatureId;
  String? _offlineDownloadProgressLabel;
  String? _offlineDownloadResultLabel;
  LatLng? _currentLocation;
  double? _currentLocationAccuracyMeters;
  bool _isDownloadingOffline = false;
  bool _isMainMapReady = false;
  bool _isLocating = false;
  LebanonBasemapStyle _basemapStyle = LebanonBasemapStyle.satellite;
  MapCamera? _latestMapCamera;
  VoidCallback? _pendingMainMapAction;
  late final MapOptions _mainMapOptions = MapOptions(
    initialCenter: LebanonMapConfig.center,
    initialZoom: LebanonMapConfig.fullscreenInitialZoom,
    initialCameraFit: LebanonMapConfig.fullscreenFit,
    minZoom: LebanonMapConfig.fullscreenMinZoom,
    maxZoom: LebanonMapConfig.fullscreenMaxZoom,
    cameraConstraint: LebanonMapConfig.cameraConstraint,
    onMapReady: _handleMainMapReady,
    onPositionChanged: _handleMainMapPositionChanged,
  );

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _handleMainMapReady() {
    if (!mounted) {
      return;
    }
    final pendingAction = _pendingMainMapAction;
    _pendingMainMapAction = null;
    if (!_isMainMapReady) {
      setState(() {
        _isMainMapReady = true;
      });
    }
    if (pendingAction != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        pendingAction();
      });
    }
  }

  void _handleMainMapPositionChanged(MapCamera camera, bool hasGesture) {
    _latestMapCamera = camera;
  }

  bool _isMapControllerLifecycleError(Object error) {
    return error.toString().contains(
      'You need to have FlutterMap widget rendered at least once before using MapController',
    );
  }

  void _runMainMapAction(VoidCallback action, {bool queueUntilReady = false}) {
    if (!_isMainMapReady) {
      if (queueUntilReady) {
        _pendingMainMapAction = action;
        return;
      }
      AppSnackbar.showError(
        context,
        'Map is still preparing. Please try again in a moment.',
      );
      return;
    }

    try {
      action();
    } catch (error) {
      if (_isMapControllerLifecycleError(error)) {
        _pendingMainMapAction = action;
        if (mounted) {
          setState(() {
            _isMainMapReady = false;
          });
        }
        return;
      }
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authControllerProvider).session;
    final role = session?.user.role ?? UserRole.viewer;
    final syncState = ref.watch(syncControllerProvider);
    final projectsAsync = ref.watch(mapProjectsProvider);

    return projectsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Map data unavailable',
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to load map data right now. Please try again.',
        ),
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
        final offlineMapPackageAsync = ref.watch(offlineMapPackageProvider);
        final hasContributorAssignment =
            role == UserRole.contributor &&
            project.hasApprovedCurrentUserAssignment;
        final canCollectOnMap =
            hasContributorAssignment && project.status == 'active';
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
                      setState(() {
                        _selectedProjectId = value;
                        _selectedFeatureChip = null;
                        _searchController.clear();
                        _tileFailureMessage = null;
                      });
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
                      avatar: const Icon(
                        Icons.satellite_alt_outlined,
                        size: 18,
                      ),
                      label: const Text('Hybrid imagery'),
                    ),
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
                    if (hasContributorAssignment)
                      FilledButton.icon(
                        onPressed: () {
                          if (canCollectOnMap) {
                            context.push(
                              AppRoutes.addFeatureForProject(project.id),
                            );
                            return;
                          }
                          _showCollectionUnavailableMessage(project.status);
                        },
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
                const SizedBox(height: AppSpacing.sm),
                offlineMapPackageAsync.when(
                  loading: () =>
                      const Text('Checking offline Lebanon map package...'),
                  error: (error, _) => Text(
                    userFacingErrorMessage(
                      error,
                      fallback:
                          'Offline map metadata is unavailable right now.',
                    ),
                  ),
                  data: (offlinePackage) => _OfflineMapStatusCard(
                    package: offlinePackage,
                    isDownloading: _isDownloadingOffline,
                    progressLabel: _offlineDownloadProgressLabel,
                    statusLabel: _offlineDownloadResultLabel,
                    onDownloadOverview: offlinePackage == null
                        ? null
                        : () => _downloadLebanonOverview(offlinePackage),
                    onDownloadVisible:
                        offlinePackage == null || !_isMainMapReady
                        ? null
                        : () => _downloadVisibleRegion(offlinePackage),
                  ),
                ),
                if (role == UserRole.contributor) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _SyncStatusLine(state: syncState),
                ],
              ],
            ),
          );
        }

        Widget buildWorkspace({Widget? embeddedControls}) {
          return featuresAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => AppEmptyState(
              icon: Icons.error_outline,
              title: 'Project map unavailable',
              message: userFacingErrorMessage(
                error,
                fallback:
                    'Unable to load project features right now. Please try again.',
              ),
              actionLabel: 'Retry',
              onAction: () =>
                  ref.invalidate(projectMapFeaturesProvider(project.id)),
            ),
            data: (features) {
              final quickFeatureChips = _deriveFeatureChips(project, features);
              final filteredFeatures = features
                  .where((feature) => _visibleStatuses.contains(feature.status))
                  .where(
                    (feature) => _matchesSearchAndChip(
                      feature,
                      query: _searchController.text,
                      selectedChip: _selectedFeatureChip,
                    ),
                  )
                  .toList(growable: false);
              _maybeOpenInitialFeatureDetails(
                project: project,
                features: filteredFeatures,
                canCollectOnMap: canCollectOnMap,
                canReview: canReview,
              );

              return _buildMapWorkspace(
                context,
                project: project,
                features: filteredFeatures,
                quickFeatureChips: quickFeatureChips,
                offlinePackageAsync: offlineMapPackageAsync,
                hasCollectionAccess: hasContributorAssignment,
                canCollectOnMap: canCollectOnMap,
                canReview: canReview,
                embeddedControls: embeddedControls,
              );
            },
          );
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxHeight < 860 || constraints.maxWidth < 640) {
              return Column(
                children: [
                  SectionHeader(
                    title: widget.lockProjectSelection
                        ? project.name
                        : 'Project Map',
                    subtitle: widget.lockProjectSelection
                        ? 'Field workspace for collection, review, and map validation.'
                        : 'Lebanon field map with project-specific features and review context.',
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Expanded(
                    child: buildWorkspace(embeddedControls: buildControls()),
                  ),
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
                      ? 'Field workspace for collection, review, and map validation.'
                      : 'Lebanon field map with project-specific features and review context.',
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
    required List<String> quickFeatureChips,
    required AsyncValue<OfflineMapPackage?> offlinePackageAsync,
    required bool hasCollectionAccess,
    required bool canCollectOnMap,
    required bool canReview,
    Widget? embeddedControls,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mapCard = _buildConstrainedMapCard(
          context,
          project: project,
          features: features,
          quickFeatureChips: quickFeatureChips,
          offlinePackage: offlinePackageAsync.valueOrNull,
          canCollectOnMap: canCollectOnMap,
          canReview: canReview,
        );
        final featureListContent = features.isEmpty
            ? AppEmptyState(
                icon: Icons.layers_clear_outlined,
                title: 'No map features match the current filters',
                message: hasCollectionAccess
                    ? 'Use Add Feature to collect orchard, field, or tree records for this project.'
                    : 'Approved or submitted features will appear here when they exist.',
                actionLabel: hasCollectionAccess ? 'Add Feature' : null,
                onAction: hasCollectionAccess
                    ? () {
                        if (canCollectOnMap) {
                          context.push(
                            AppRoutes.addFeatureForProject(project.id),
                          );
                          return;
                        }
                        _showCollectionUnavailableMessage(project.status);
                      }
                    : null,
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Project Features (${features.length})',
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
                                        'Feature ${_featureShortId(feature.id)}',
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
        final useMobileWorkspace =
            constraints.maxWidth < 900 ||
            constraints.maxHeight < 820 ||
            embeddedControls != null;

        if (useMobileWorkspace) {
          return Stack(
            children: [
              Positioned.fill(child: mapCard),
              DraggableScrollableSheet(
                initialChildSize: features.isEmpty ? 0.24 : 0.31,
                minChildSize: 0.17,
                maxChildSize: 0.78,
                snap: true,
                snapSizes: const <double>[0.24, 0.45, 0.78],
                builder: (context, scrollController) {
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(24),
                      ),
                      boxShadow: const [
                        BoxShadow(
                          blurRadius: 18,
                          offset: Offset(0, -6),
                          color: Color(0x1F000000),
                        ),
                      ],
                    ),
                    child: ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.md,
                        AppSpacing.sm,
                        AppSpacing.md,
                        AppSpacing.xl,
                      ),
                      children: [
                        Center(
                          child: Container(
                            width: 44,
                            height: 5,
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.outlineVariant,
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          project.name,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          '${project.category} • ${LebanonMapConfig.basemapLabel(_basemapStyle)} view',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        ...?switch (embeddedControls) {
                          final controls? => <Widget>[
                            controls,
                            const SizedBox(height: AppSpacing.sm),
                          ],
                          null => null,
                        },
                        legendCard,
                        const SizedBox(height: AppSpacing.sm),
                        featureListContent,
                      ],
                    ),
                  );
                },
              ),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 6, child: mapCard),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              flex: 4,
              child: Column(
                children: [
                  legendCard,
                  const SizedBox(height: AppSpacing.sm),
                  Expanded(
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: featureListContent,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildConstrainedMapCard(
    BuildContext context, {
    required ProjectSummary project,
    required List<MapFeatureSummary> features,
    required List<String> quickFeatureChips,
    required OfflineMapPackage? offlinePackage,
    required bool canCollectOnMap,
    required bool canReview,
  }) {
    final currentCenter = _latestMapCamera?.center ?? LebanonMapConfig.center;
    final currentZoom =
        _latestMapCamera?.zoom ?? LebanonMapConfig.fullscreenInitialZoom;

    return AppCard(
      padding: EdgeInsets.zero,
      child: Stack(
        children: [
          FutureBuilder<_OfflineTileAssets?>(
            future: offlinePackage == null
                ? Future<_OfflineTileAssets?>.value(null)
                : _loadOfflineTileAssets(offlinePackage),
            builder: (context, snapshot) {
              final labelOverlayUrl =
                  LebanonMapConfig.referenceLabelUrlTemplate(_basemapStyle);
              return ClipRRect(
                borderRadius: AppRadii.lg,
                child: FlutterMap(
                  mapController: _mapController,
                  options: _mainMapOptions,
                  children: [
                    if (_basemapStyle == LebanonBasemapStyle.satellite &&
                        snapshot.data != null)
                      TileLayer(
                        urlTemplate: snapshot.data!.templatePath,
                        tileProvider: FileTileProvider(),
                        fallbackUrl: snapshot.data!.fallbackPath,
                        userAgentPackageName: 'lb.gov.gis_collector',
                      ),
                    TileLayer(
                      urlTemplate: LebanonMapConfig.basemapUrlTemplate(
                        _basemapStyle,
                      ),
                      userAgentPackageName: 'lb.gov.gis_collector',
                      errorTileCallback: (tile, error, stackTrace) {
                        Object.hash(tile, stackTrace);
                        if (_tileFailureMessage != null ||
                            _basemapStyle != LebanonBasemapStyle.satellite) {
                          return;
                        }
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted || _tileFailureMessage != null) {
                            return;
                          }
                          setState(() {
                            _tileFailureMessage = snapshot.data == null
                                ? 'Live satellite imagery is temporarily unavailable.'
                                : 'Using saved offline imagery. Live labels may be limited until the connection returns.';
                          });
                        });
                      },
                    ),
                    if (labelOverlayUrl != null)
                      TileLayer(
                        urlTemplate: labelOverlayUrl,
                        userAgentPackageName: 'lb.gov.gis_collector',
                      ),
                    PolygonLayer(polygons: _polygonOverlays(features)),
                    PolylineLayer(polylines: _polylineOverlays(features)),
                    if (_currentLocation != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _currentLocation!,
                            width: 46,
                            height: 46,
                            child: const Icon(
                              Icons.my_location,
                              color: Color(0xFF1565C0),
                              size: 28,
                            ),
                          ),
                        ],
                      ),
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
              );
            },
          ),
          Positioned(
            left: 12,
            right: 72,
            top: 12,
            child: Material(
              color: Colors.transparent,
              child: AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                project.name,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${project.category} • ${features.length} visible feature(s)',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        SegmentedButton<LebanonBasemapStyle>(
                          segments: const [
                            ButtonSegment(
                              value: LebanonBasemapStyle.satellite,
                              icon: Icon(Icons.satellite_alt_outlined),
                              label: Text('Hybrid'),
                            ),
                            ButtonSegment(
                              value: LebanonBasemapStyle.street,
                              icon: Icon(Icons.map_outlined),
                              label: Text('Street'),
                            ),
                          ],
                          selected: <LebanonBasemapStyle>{_basemapStyle},
                          showSelectedIcon: false,
                          onSelectionChanged: (selection) {
                            setState(() {
                              _basemapStyle = selection.first;
                              _tileFailureMessage = null;
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextField(
                      controller: _searchController,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Search this project map',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _searchController.text.trim().isEmpty
                            ? null
                            : IconButton(
                                onPressed: () {
                                  setState(() {
                                    _searchController.clear();
                                  });
                                },
                                icon: const Icon(Icons.clear),
                              ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        const Chip(
                          avatar: Icon(Icons.flag_outlined, size: 18),
                          label: Text('Lebanon only'),
                        ),
                        Chip(
                          avatar: Icon(
                            _basemapStyle == LebanonBasemapStyle.satellite
                                ? Icons.satellite_alt_outlined
                                : Icons.map_outlined,
                            size: 18,
                          ),
                          label: Text(
                            _basemapStyle == LebanonBasemapStyle.satellite
                                ? 'Hybrid imagery'
                                : 'Street context',
                          ),
                        ),
                        if (_currentLocationAccuracyMeters != null)
                          Chip(
                            avatar: const Icon(Icons.my_location, size: 18),
                            label: Text(
                              'GPS ${_currentLocationAccuracyMeters!.toStringAsFixed(0)}m',
                            ),
                          ),
                      ],
                    ),
                    if (quickFeatureChips.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.sm),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: quickFeatureChips
                              .map(
                                (chip) => Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                    label: Text(chip),
                                    selected: _selectedFeatureChip == chip,
                                    onSelected: (selected) {
                                      setState(() {
                                        _selectedFeatureChip = selected
                                            ? chip
                                            : null;
                                      });
                                    },
                                  ),
                                ),
                              )
                              .toList(growable: false),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            right: 12,
            bottom: 12,
            child: Column(
              children: [
                FloatingActionButton.small(
                  heroTag: 'map_current_location',
                  onPressed: _isLocating
                      ? null
                      : _centerMainMapOnCurrentLocation,
                  child: _isLocating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.my_location_outlined),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'map_fit_lebanon',
                  onPressed: _isMainMapReady
                      ? () => _runMainMapAction(
                          () => _mapController.fitCamera(
                            LebanonMapConfig.lebanonFit(),
                          ),
                          queueUntilReady: true,
                        )
                      : null,
                  child: const Icon(Icons.zoom_out_map_outlined),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'map_zoom_in',
                  onPressed: _isMainMapReady
                      ? () => _runMainMapAction(
                          () => _mapController.move(
                            currentCenter,
                            (currentZoom + 1)
                                .clamp(
                                  LebanonMapConfig.fullscreenMinZoom,
                                  LebanonMapConfig.fullscreenMaxZoom,
                                )
                                .toDouble(),
                          ),
                          queueUntilReady: true,
                        )
                      : null,
                  child: const Icon(Icons.add),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'map_zoom_out',
                  onPressed: _isMainMapReady
                      ? () => _runMainMapAction(
                          () => _mapController.move(
                            currentCenter,
                            (currentZoom - 1)
                                .clamp(
                                  LebanonMapConfig.fullscreenMinZoom,
                                  LebanonMapConfig.fullscreenMaxZoom,
                                )
                                .toDouble(),
                          ),
                          queueUntilReady: true,
                        )
                      : null,
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
                      const Icon(Icons.cloud_off_outlined),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(_tileFailureMessage!, softWrap: true),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<String> _deriveFeatureChips(
    ProjectSummary project,
    List<MapFeatureSummary> features,
  ) {
    final chips = <String>{};
    for (final field in project.collectionFormSchema.fields) {
      if (field.type == CollectionFieldType.select &&
          _looksLikeFeatureTypeField(field.key, field.label)) {
        chips.addAll(
          field.options
              .map((option) => option.trim())
              .where((option) => option.isNotEmpty),
        );
      }
    }

    if (chips.isEmpty) {
      final counts = <String, int>{};
      for (final feature in features) {
        for (final entry in feature.attributes.entries) {
          if (!_looksLikeFeatureTypeField(entry.key, entry.key)) {
            continue;
          }
          final value = '${entry.value}'.trim();
          if (value.isEmpty || value.length > 24) {
            continue;
          }
          counts[value] = (counts[value] ?? 0) + 1;
        }
      }
      final ranked = counts.entries.toList(growable: false)
        ..sort((left, right) => right.value.compareTo(left.value));
      chips.addAll(
        ranked
            .take(6)
            .map((entry) => entry.key)
            .where((value) => value.isNotEmpty),
      );
    }

    return chips.take(6).toList(growable: false);
  }

  bool _looksLikeFeatureTypeField(String key, String label) {
    final normalized = '${key.toLowerCase()} ${label.toLowerCase()}';
    return normalized.contains('type') ||
        normalized.contains('species') ||
        normalized.contains('crop') ||
        normalized.contains('tree') ||
        normalized.contains('orchard');
  }

  bool _matchesSearchAndChip(
    MapFeatureSummary feature, {
    required String query,
    required String? selectedChip,
  }) {
    final haystack = _featureSearchBlob(feature);
    if (selectedChip != null && selectedChip.trim().isNotEmpty) {
      final chip = selectedChip.toLowerCase();
      final hasChip = feature.attributes.values.any(
        (value) => '$value'.toLowerCase().contains(chip),
      );
      if (!hasChip) {
        return false;
      }
    }

    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) {
      return true;
    }
    return haystack.contains(normalizedQuery);
  }

  String _featureSearchBlob(MapFeatureSummary feature) {
    final buffer = StringBuffer()
      ..write(feature.id.toLowerCase())
      ..write(' ')
      ..write('${feature.geometry['type'] ?? ''}'.toLowerCase());
    for (final entry in feature.attributes.entries) {
      buffer
        ..write(' ')
        ..write(entry.key.toLowerCase())
        ..write(' ')
        ..write('${entry.value}'.toLowerCase());
    }
    return buffer.toString();
  }

  Future<_OfflineTileAssets> _loadOfflineTileAssets(
    OfflineMapPackage package,
  ) async {
    final manager = ref.read(offlineTileCacheManagerProvider);
    final values = await Future.wait<String>([
      manager.localTileTemplate(
        package: package,
        basemapStyle: LebanonBasemapStyle.satellite,
      ),
      manager.transparentFallbackPath(),
    ]);
    return _OfflineTileAssets(templatePath: values[0], fallbackPath: values[1]);
  }

  Future<void> _downloadLebanonOverview(OfflineMapPackage package) async {
    if (_isDownloadingOffline) {
      return;
    }
    setState(() {
      _isDownloadingOffline = true;
      _offlineDownloadProgressLabel = 'Preparing Lebanon offline imagery...';
      _offlineDownloadResultLabel = null;
    });
    try {
      final manager = ref.read(offlineTileCacheManagerProvider);
      final summary = await ref
          .read(offlineTileCacheManagerProvider)
          .cacheLebanonOverview(
            package: package,
            onProgress: (progress) {
              if (!mounted) {
                return;
              }
              setState(() {
                _offlineDownloadProgressLabel =
                    'Saving Lebanon imagery ${progress.completedTiles}/${progress.requestedTiles} • ${progress.downloadedTiles} new • ${progress.skippedTiles} cached${progress.failedTiles > 0 ? ' • ${progress.failedTiles} failed' : ''}';
              });
            },
          );
      await manager.refreshStats(package);
      ref.invalidate(offlineMapPackageProvider);
      if (mounted) {
        final hasUsableTiles =
            summary.downloadedTiles > 0 || summary.skippedTiles > 0;
        final message =
            'Lebanon offline imagery updated. ${summary.downloadedTiles} new tile(s), ${summary.skippedTiles} cached${summary.failedTiles > 0 ? ', ${summary.failedTiles} failed' : ''}.';
        setState(() {
          _offlineDownloadResultLabel = message;
        });
        if (hasUsableTiles) {
          AppSnackbar.showSuccess(context, message);
        } else {
          AppSnackbar.showError(
            context,
            'Unable to save Lebanon offline imagery right now. Please try again later.',
          );
        }
      }
    } catch (error) {
      if (mounted) {
        final message = userFacingErrorMessage(
          error,
          fallback: 'Unable to save Lebanon offline imagery right now.',
        );
        setState(() {
          _offlineDownloadResultLabel = message;
        });
        AppSnackbar.showError(context, message);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDownloadingOffline = false;
          _offlineDownloadProgressLabel = null;
        });
      }
    }
  }

  Future<void> _downloadVisibleRegion(OfflineMapPackage package) async {
    if (_isDownloadingOffline) {
      return;
    }
    if (!_isMainMapReady) {
      AppSnackbar.showError(
        context,
        'Map is still preparing. Wait for the map to finish loading before downloading the visible area.',
      );
      return;
    }
    final camera = _latestMapCamera;
    if (camera == null) {
      AppSnackbar.showError(
        context,
        'Map extent is not ready yet. Try again in a moment.',
      );
      return;
    }
    setState(() {
      _isDownloadingOffline = true;
      _offlineDownloadProgressLabel =
          'Preparing current view for offline use...';
      _offlineDownloadResultLabel = null;
    });
    try {
      final manager = ref.read(offlineTileCacheManagerProvider);
      final summary = await manager.cacheVisibleRegion(
        package: package,
        basemapStyle: LebanonBasemapStyle.satellite,
        bounds: camera.visibleBounds,
        currentZoom: camera.zoom,
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          setState(() {
            _offlineDownloadProgressLabel =
                'Saving current view ${progress.completedTiles}/${progress.requestedTiles} • ${progress.downloadedTiles} new • ${progress.skippedTiles} cached${progress.failedTiles > 0 ? ' • ${progress.failedTiles} failed' : ''}';
          });
        },
      );
      await manager.refreshStats(package);
      ref.invalidate(offlineMapPackageProvider);
      if (mounted) {
        final hasUsableTiles =
            summary.downloadedTiles > 0 || summary.skippedTiles > 0;
        final message =
            'Current view saved for offline use. ${summary.downloadedTiles} new tile(s), ${summary.skippedTiles} cached${summary.failedTiles > 0 ? ', ${summary.failedTiles} failed' : ''}.';
        setState(() {
          _offlineDownloadResultLabel = message;
        });
        if (hasUsableTiles) {
          AppSnackbar.showSuccess(context, message);
        } else {
          AppSnackbar.showError(
            context,
            'Unable to save the current view for offline use right now. Please try again later.',
          );
        }
      }
    } catch (error) {
      if (mounted) {
        final message = userFacingErrorMessage(
          error,
          fallback:
              'Unable to save the current map view for offline use right now.',
        );
        setState(() {
          _offlineDownloadResultLabel = message;
        });
        AppSnackbar.showError(context, message);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDownloadingOffline = false;
          _offlineDownloadProgressLabel = null;
        });
      }
    }
  }

  Future<void> _centerMainMapOnCurrentLocation() async {
    if (_isLocating) {
      return;
    }
    setState(() {
      _isLocating = true;
    });

    try {
      final location = await ref
          .read(currentLocationServiceProvider)
          .fetchCurrentLocation();
      if (!LebanonMapConfig.contains(location.position)) {
        if (mounted) {
          AppSnackbar.showError(
            context,
            'Current location is outside the Lebanon map workspace.',
          );
        }
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _currentLocation = location.position;
        _currentLocationAccuracyMeters = location.accuracyMeters;
      });
      _runMainMapAction(
        () => _mapController.move(location.position, 16),
        queueUntilReady: true,
      );
    } on CurrentLocationFailure catch (error) {
      if (mounted) {
        AppSnackbar.showError(context, error.message);
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to get the current location right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLocating = false;
        });
      }
    }
  }

  void _showCollectionUnavailableMessage(String status) {
    final normalized = status.trim().toLowerCase();
    final message = switch (normalized) {
      'paused' =>
        'This project is paused. Feature collection is unavailable until the project returns to active status.',
      'completed' =>
        'This project is completed. New features cannot be added unless an admin reopens the project.',
      'archived' =>
        'This project is archived. Feature collection is unavailable.',
      'draft' =>
        'This project is still in draft status. Feature collection is unavailable until the project becomes active.',
      _ => 'Feature collection is unavailable for this project right now.',
    };
    AppSnackbar.showError(context, message);
  }

  Future<void> _reviewFeature({
    required MapFeatureSummary feature,
    required String status,
    VoidCallback? onSuccess,
  }) async {
    final note = await _promptNote(
      title: status == 'approved' ? 'Approval note' : 'Rejection note',
      hint: status == 'approved'
          ? 'Optional context for the contributor.'
          : 'Optional context for the contributor.',
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
            reviewNotes: note.trim().isEmpty ? null : note.trim(),
          );
      bumpWorkflowRefresh(ref);
      if (mounted) {
        onSuccess?.call();
        AppSnackbar.showSuccess(
          context,
          status == 'approved'
              ? 'Feature approved successfully.'
              : 'Feature rejected successfully.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to update this feature review right now.',
          ),
        );
      }
    }
  }

  Future<void> _submitDraft({
    required MapFeatureSummary feature,
    VoidCallback? onSuccess,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Submit draft'),
        content: const Text('Submit this draft for admin review now?'),
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
      bumpWorkflowRefresh(ref);
      if (mounted) {
        onSuccess?.call();
        AppSnackbar.showSuccess(
          context,
          'Draft submitted for review successfully.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to submit this draft right now.',
          ),
        );
      }
    }
  }

  Future<String?> _promptNote({
    required String title,
    required String hint,
  }) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _MapReviewNoteDialog(title: title, hint: hint),
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
      builder: (sheetContext) {
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
                          'Feature ${_featureShortId(feature.id)}',
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
                        : FeaturePhotoGallery(
                            items: feature.photos
                                .map(
                                  (photo) => FeaturePhotoGalleryItem(
                                    id: photo.id,
                                    imagePath:
                                        photo.thumbnailPath ?? photo.filePath,
                                    label: _photoLabel(photo.filePath),
                                    subtitle: photo.takenAt == null
                                        ? 'Captured photo'
                                        : 'Captured ${_formatDateTime(photo.takenAt!)}',
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
                              Navigator.of(sheetContext).pop();
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
                              feature: feature,
                              onSuccess: () => Navigator.of(sheetContext).pop(),
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
                          if (feature.status == 'pending_review' ||
                              feature.status == 'rejected')
                            FilledButton.icon(
                              onPressed: () => _reviewFeature(
                                feature: feature,
                                status: 'approved',
                                onSuccess: () =>
                                    Navigator.of(sheetContext).pop(),
                              ),
                              icon: const Icon(Icons.check_circle_outline),
                              label: Text(
                                feature.status == 'rejected'
                                    ? 'Re-approve'
                                    : 'Approve',
                              ),
                            ),
                          if (feature.status == 'pending_review' ||
                              feature.status == 'approved')
                            FilledButton.tonalIcon(
                              onPressed: () => _reviewFeature(
                                feature: feature,
                                status: 'rejected',
                                onSuccess: () =>
                                    Navigator.of(sheetContext).pop(),
                              ),
                              icon: const Icon(Icons.cancel_outlined),
                              label: const Text('Reject'),
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

  void _maybeOpenInitialFeatureDetails({
    required ProjectSummary project,
    required List<MapFeatureSummary> features,
    required bool canCollectOnMap,
    required bool canReview,
  }) {
    final targetFeatureId = widget.initialFeatureId;
    if (targetFeatureId == null ||
        targetFeatureId.isEmpty ||
        _autoOpenedFeatureId == targetFeatureId) {
      return;
    }

    MapFeatureSummary? feature;
    for (final item in features) {
      if (item.id == targetFeatureId) {
        feature = item;
        break;
      }
    }
    if (feature == null) {
      return;
    }

    _autoOpenedFeatureId = targetFeatureId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _openFeatureDetails(
        project: project,
        feature: feature!,
        canCollectOnMap: canCollectOnMap,
        canReview: canReview,
      );
    });
  }

  void _focusFeature(MapFeatureSummary feature) {
    final point = _pointFromGeometry(feature.geometry);
    if (point == null) {
      return;
    }
    _runMainMapAction(
      () => _mapController.move(point, 15),
      queueUntilReady: true,
    );
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
          final points = polygonGeometryPoints(feature.geometry);
          if (points.isEmpty) {
            return null;
          }
          final color = _statusColor(feature.status);
          return Polygon(
            points: points,
            color: color.withValues(alpha: 0.18),
            borderStrokeWidth: 2.5,
            borderColor: color,
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
            strokeWidth: 4,
          );
        })
        .whereType<Polyline>()
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
    final focusPoint = geometryFocusPoint(geometry);
    if (type == 'Point' && focusPoint != null) {
      return 'Point at ${focusPoint.latitude.toStringAsFixed(5)}, ${focusPoint.longitude.toStringAsFixed(5)}';
    }
    if (type == 'LineString') {
      return 'LineString with ${lineGeometryPoints(geometry).length} vertices';
    }
    if (type == 'Polygon') {
      return 'Polygon with ${polygonGeometryPoints(geometry).length} boundary points';
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

  String _featureShortId(String value) {
    if (value.length <= 8) {
      return value;
    }
    return value.substring(0, 8);
  }
}

class _SyncStatusLine extends StatelessWidget {
  const _SyncStatusLine({required this.state});

  final SyncState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    late final IconData icon;
    late final Color color;
    late final String text;

    if (state.isInitializing) {
      icon = Icons.sync;
      color = scheme.primary;
      text = 'Preparing offline sync';
    } else if (!state.isReady) {
      icon = Icons.cloud_off_outlined;
      color = scheme.error;
      text = 'Sync unavailable';
    } else if (state.isSyncing) {
      icon = Icons.sync;
      color = scheme.primary;
      text = 'Sync in progress';
    } else if (state.conflictCount > 0 || state.deadLetterCount > 0) {
      icon = Icons.error_outline;
      color = scheme.error;
      text =
          'Sync needs attention (${state.conflictCount + state.deadLetterCount} issue${state.conflictCount + state.deadLetterCount == 1 ? '' : 's'})';
    } else if (state.pendingCount > 0) {
      icon = Icons.cloud_upload_outlined;
      color = scheme.tertiary;
      text =
          '${state.pendingCount} update${state.pendingCount == 1 ? '' : 's'} queued for sync';
    } else if (state.lastSyncAt != null) {
      icon = Icons.cloud_done_outlined;
      color = scheme.primary;
      final local = state.lastSyncAt!.toLocal();
      final hour = local.hour.toString().padLeft(2, '0');
      final minute = local.minute.toString().padLeft(2, '0');
      text = 'Last refreshed at $hour:$minute';
    } else {
      icon = Icons.cloud_done_outlined;
      color = scheme.primary;
      text = 'Sync ready';
    }

    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall,
            softWrap: true,
          ),
        ),
      ],
    );
  }
}

class _OfflineMapStatusCard extends StatelessWidget {
  const _OfflineMapStatusCard({
    required this.package,
    required this.isDownloading,
    required this.progressLabel,
    required this.statusLabel,
    required this.onDownloadOverview,
    required this.onDownloadVisible,
  });

  final OfflineMapPackage? package;
  final bool isDownloading;
  final String? progressLabel;
  final String? statusLabel;
  final VoidCallback? onDownloadOverview;
  final VoidCallback? onDownloadVisible;

  @override
  Widget build(BuildContext context) {
    if (package == null) {
      return const Text('Offline imagery metadata is not available yet.');
    }

    final downloadedAt = package!.downloadedAt;
    final downloadedSummary = downloadedAt == null
        ? 'No offline imagery saved on this device yet'
        : 'Saved ${downloadedAt.toLocal().year}-${downloadedAt.toLocal().month.toString().padLeft(2, '0')}-${downloadedAt.toLocal().day.toString().padLeft(2, '0')}';

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Offline imagery cache',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Stores Lebanon satellite tiles on this device for offline browsing in saved areas.',
            softWrap: true,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Package ${package!.version} • Source ${package!.tileSource ?? 'imagery tiles'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            '${package!.tileCount ?? 0} cached tile(s) • ${_formatBytes(package!.sizeBytes ?? 0)} • $downloadedSummary',
            softWrap: true,
          ),
          if (progressLabel != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(progressLabel!, style: Theme.of(context).textTheme.bodySmall),
          ] else if (statusLabel != null && statusLabel!.trim().isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(statusLabel!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: isDownloading ? null : onDownloadOverview,
                icon: const Icon(Icons.download_outlined),
                label: Text(
                  isDownloading ? 'Saving...' : 'Save Lebanon overview',
                ),
              ),
              OutlinedButton.icon(
                onPressed: isDownloading ? null : onDownloadVisible,
                icon: const Icon(Icons.crop_free_outlined),
                label: const Text('Save current view'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    final kb = bytes / 1024;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(1)} KB';
    }
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(2)} MB';
  }
}

class _OfflineTileAssets {
  const _OfflineTileAssets({
    required this.templatePath,
    required this.fallbackPath,
  });

  final String templatePath;
  final String fallbackPath;
}

class _MapReviewNoteDialog extends StatefulWidget {
  const _MapReviewNoteDialog({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  State<_MapReviewNoteDialog> createState() => _MapReviewNoteDialogState();
}

class _MapReviewNoteDialogState extends State<_MapReviewNoteDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppTextField(
              label: 'Review note',
              controller: _controller,
              hint: widget.hint,
              minLines: 2,
              maxLines: 4,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
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
