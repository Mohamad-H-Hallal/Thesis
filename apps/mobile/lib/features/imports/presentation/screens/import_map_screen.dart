import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/pagination/paginated_list_controller.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/progressive_list_section.dart';
import '../../../auth/domain/auth_models.dart';
import '../../../map/domain/current_location_service.dart';
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
  static const List<String> _statusOrder = <String>[
    'pending_review',
    'approved',
    'rejected',
    'failed',
  ];

  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final Distance _distance = const Distance();
  final Set<String> _visibleStatuses = Set<String>.from(_statusOrder);
  late final MapOptions _mapOptions;

  bool _isMapReady = false;
  bool _hasPrimedWorkspace = false;
  bool _isLocating = false;
  bool _isPanelVisible = true;
  bool _isPanelExpanded = false;
  bool _isSearchOpen = false;
  bool _showApprovedProjectContext = true;
  bool _isFeatureBrowserOpen = false;
  LebanonBasemapStyle _basemapStyle = LebanonBasemapStyle.street;
  MapCamera? _latestMapCamera;
  String? _selectedFeatureTypeChip;
  String? _focusedFeatureId;
  String? _lastAutoFocusedFeatureId;
  LatLng? _currentLocation;
  VoidCallback? _pendingMapAction;
  Timer? _basemapTransitionTimer;
  Timer? _cameraRefreshTimer;
  bool _isBasemapTransitioning = false;

  LatLng get _defaultMapCenter => LebanonMapConfig.projectWorkspaceCenter;

  double get _defaultMapZoom => LebanonMapConfig.projectWorkspaceZoom;

  double get _mapMinZoom => LebanonMapConfig.projectWorkspaceZoom;

  double get _mapMaxZoom => LebanonMapConfig.fullscreenMaxZoom;

  @override
  void initState() {
    super.initState();
    _mapOptions = MapOptions(
      initialCenter: _defaultMapCenter,
      initialZoom: _defaultMapZoom,
      minZoom: _mapMinZoom,
      maxZoom: _mapMaxZoom,
      cameraConstraint: CameraConstraint.containCenter(
        bounds: LebanonMapConfig.bounds,
      ),
      onMapReady: _handleMapReady,
      onPositionChanged: (camera, hasGesture) {
        _latestMapCamera = camera;
        if (!_isMapReady && mounted) {
          setState(() {
            _isMapReady = true;
          });
        }
        if (hasGesture || _isBasemapTransitioning) {
          _scheduleCameraRefresh();
        }
        final pendingAction = _pendingMapAction;
        if (pendingAction != null) {
          _pendingMapAction = null;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) {
              return;
            }
            _runMapAction(pendingAction, queueUntilReady: true);
          });
        }
      },
      onTap: (_, point) {
        final details = ref
            .read(importDetailsProvider(widget.importId))
            .valueOrNull;
        final session = ref.read(authControllerProvider).session;
        final mapData =
            ref
                .read(
                  importMapDataProvider(
                    ImportMapQuery(
                      importId: widget.importId,
                      projectId: widget.projectId,
                    ),
                  ),
                )
                .valueOrNull ??
            const ImportMapData(
              stagedFeatures: <ImportedFeature>[],
              approvedProjectFeatures: <MapFeatureSummary>[],
            );
        _handleMapTap(
          point,
          stagedFeatures: _filteredStagedFeatures(mapData.stagedFeatures),
          approvedFeatures: _showApprovedProjectContext
              ? mapData.approvedProjectFeatures
              : const <MapFeatureSummary>[],
          canModerateImport: session != null
              ? _canModerateImport(session.user, details)
              : false,
        );
      },
    );
  }

  @override
  void dispose() {
    _basemapTransitionTimer?.cancel();
    _cameraRefreshTimer?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authControllerProvider).session;
    if (session == null) {
      return const SizedBox.shrink();
    }
    final importDetailsAsync = ref.watch(
      importDetailsProvider(widget.importId),
    );
    final projectAsync = ref.watch(projectByIdProvider(widget.projectId));
    final mapDataAsync = ref.watch(
      importMapDataProvider(
        ImportMapQuery(importId: widget.importId, projectId: widget.projectId),
      ),
    );

    if (mapDataAsync.isLoading && mapDataAsync.valueOrNull == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (mapDataAsync.hasError && mapDataAsync.valueOrNull == null) {
      return AppEmptyState(
        icon: Icons.map_outlined,
        title: 'Import map unavailable',
        message: userFacingErrorMessage(
          mapDataAsync.asError!.error,
          fallback: 'Unable to load imported features right now.',
        ),
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(
          importMapDataProvider(
            ImportMapQuery(
              importId: widget.importId,
              projectId: widget.projectId,
            ),
          ),
        ),
      );
    }

    final details = importDetailsAsync.valueOrNull;
    final project = projectAsync.valueOrNull;
    final mapData =
        mapDataAsync.valueOrNull ??
        const ImportMapData(
          stagedFeatures: <ImportedFeature>[],
          approvedProjectFeatures: <MapFeatureSummary>[],
        );
    final canModerateImport = _canModerateImport(session.user, details);
    final visibleStagedFeatures = _filteredStagedFeatures(
      mapData.stagedFeatures,
    );
    final cameraBounds =
        _latestMapCamera?.visibleBounds ?? LebanonMapConfig.bounds;
    final currentZoom = _latestMapCamera?.zoom ?? _defaultMapZoom;
    final useLightweightRender =
        visibleStagedFeatures.length + mapData.approvedProjectFeatures.length >
            1800 ||
        currentZoom < 9.75;
    final renderDetailedShapes = !useLightweightRender && currentZoom >= 10.5;
    final viewportStagedFeatures = _featuresInBounds(
      visibleStagedFeatures,
      cameraBounds,
    );
    final viewportApprovedFeatures = _projectFeaturesInBounds(
      mapData.approvedProjectFeatures,
      cameraBounds,
    );
    final markerPlacements = _buildMarkerPlacements(
      visibleStagedFeatures,
      _showApprovedProjectContext ? mapData.approvedProjectFeatures : const [],
    );
    final selectedFeature = _findImportedFeature(
      mapData.stagedFeatures,
      _focusedFeatureId ?? widget.initialFeatureId,
    );
    _scheduleInitialFeatureFocus(visibleStagedFeatures, selectedFeature);

    final projectLabel = project?.name ?? details?.job.projectName ?? 'Project';
    final categoryLabel = project?.category ?? 'Project';

    return Stack(
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: AppRadii.lg,
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerLowest,
              child: FlutterMap(
                key: ValueKey<String>('import_map_${widget.importId}'),
                options: _mapOptions,
                mapController: _mapController,
                children: [
                  if (LebanonMapConfig.shouldRenderTileLayers)
                    TileLayer(
                      urlTemplate: LebanonMapConfig.basemapUrlTemplate(
                        _basemapStyle,
                      ),
                      tileProvider: NetworkTileProvider(
                        silenceExceptions: true,
                      ),
                      userAgentPackageName: 'lb.gov.gis_collector',
                    ),
                  if (LebanonMapConfig.shouldRenderTileLayers &&
                      LebanonMapConfig.referenceLabelUrlTemplate(
                            _basemapStyle,
                          ) !=
                          null)
                    TileLayer(
                      urlTemplate: LebanonMapConfig.referenceLabelUrlTemplate(
                        _basemapStyle,
                      )!,
                      tileProvider: NetworkTileProvider(
                        silenceExceptions: true,
                      ),
                      userAgentPackageName: 'lb.gov.gis_collector',
                    ),
                  if (_showApprovedProjectContext) ...[
                    if (renderDetailedShapes)
                      PolygonLayer(
                        polygons: _projectContextPolygons(
                          viewportApprovedFeatures,
                        ),
                      ),
                    if (renderDetailedShapes)
                      PolylineLayer(
                        polylines: _projectContextPolylines(
                          viewportApprovedFeatures,
                        ),
                      ),
                    if (useLightweightRender)
                      CircleLayer(
                        circles: _projectContextCircles(
                          mapData.approvedProjectFeatures,
                          markerPlacements.projectPoints,
                        ),
                      )
                    else
                      MarkerLayer(
                        markers: _projectContextMarkers(
                          mapData.approvedProjectFeatures,
                          markerPlacements.projectPoints,
                        ),
                      ),
                  ],
                  if (renderDetailedShapes)
                    PolygonLayer(
                      polygons: _stagedPolygons(viewportStagedFeatures),
                    ),
                  if (renderDetailedShapes)
                    PolylineLayer(
                      polylines: _stagedPolylines(viewportStagedFeatures),
                    ),
                  if (_currentLocation != null)
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: _currentLocation!,
                          width: 48,
                          height: 48,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0x291565C0),
                              border: Border.all(
                                color: const Color(0xFF1565C0),
                                width: 2,
                              ),
                            ),
                            child: const Center(
                              child: Icon(
                                Icons.my_location,
                                color: Color(0xFF1565C0),
                                size: 24,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  if (useLightweightRender)
                    CircleLayer(
                      circles: _stagedCircles(
                        visibleStagedFeatures,
                        markerPlacements.stagedPoints,
                      ),
                    )
                  else
                    MarkerLayer(
                      markers: _stagedMarkers(
                        visibleStagedFeatures,
                        canModerateImport,
                        markerPlacements.stagedPoints,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (_isBasemapTransitioning)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Theme.of(
                        context,
                      ).colorScheme.surface.withValues(alpha: 0.78),
                      Theme.of(
                        context,
                      ).colorScheme.surface.withValues(alpha: 0.48),
                    ],
                  ),
                ),
                child: Center(
                  child: _MapWorkspaceCompactNotice(
                    icon: _basemapStyleIcon(_basemapStyle),
                    message:
                        'Loading ${LebanonMapConfig.basemapLabel(_basemapStyle)} view...',
                    toneColor: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          top: 12,
          left: 12,
          right: 12,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Padding(
                padding: EdgeInsets.only(right: _isPanelVisible ? 0 : 64),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SizeTransition(
                        sizeFactor: animation,
                        axisAlignment: -1,
                        child: child,
                      ),
                    ),
                    child: _isPanelVisible
                        ? SizedBox(
                            key: const ValueKey<String>(
                              'import_map_panel_visible',
                            ),
                            width: double.infinity,
                            child: _ImportMapFloatingPanel(
                              projectName: projectLabel,
                              categoryLabel: categoryLabel,
                              visibleFeatureCount: visibleStagedFeatures.length,
                              approvedContextCount:
                                  mapData.approvedProjectFeatures.length,
                              searchController: _searchController,
                              searchFocusNode: _searchFocusNode,
                              visibleStatuses: _visibleStatuses,
                              visibleFeatureTypes: _availableFeatureTypeChips(
                                mapData.stagedFeatures,
                              ),
                              selectedFeatureType: _selectedFeatureTypeChip,
                              basemapStyle: _basemapStyle,
                              isExpanded: _isPanelExpanded,
                              isSearchOpen: _isSearchOpen,
                              searchSummaryLabel: _searchSummaryLabel(
                                visibleStagedFeatures.length,
                              ),
                              visibleStatusSummaryLabel:
                                  _visibleStatusSummaryLabel(),
                              visibleFeatureTypeSummaryLabel:
                                  _visibleFeatureTypeSummaryLabel(),
                              showApprovedProjectContext:
                                  _showApprovedProjectContext,
                              onSearchPressed: _toggleSearch,
                              onSearchChanged: () => setState(() {}),
                              onClearSearch: () =>
                                  setState(_searchController.clear),
                              onResetVisibleStatuses: () => setState(() {
                                _visibleStatuses
                                  ..clear()
                                  ..addAll(_statusOrder);
                              }),
                              onToggleVisibleStatus: (status) => setState(() {
                                if (_visibleStatuses.contains(status)) {
                                  _visibleStatuses.remove(status);
                                } else {
                                  _visibleStatuses.add(status);
                                }
                              }),
                              onSelectFeatureType: (featureType) =>
                                  setState(() {
                                    _selectedFeatureTypeChip = featureType;
                                  }),
                              onBasemapStyleChanged: _setBasemapStyle,
                              onToggleExpanded: () => setState(() {
                                _isPanelExpanded = !_isPanelExpanded;
                              }),
                              onHidePanel: () {
                                setState(() {
                                  _isPanelVisible = false;
                                  _isPanelExpanded = false;
                                  _isSearchOpen = false;
                                });
                                _searchFocusNode.unfocus();
                              },
                              onToggleProjectContext: (value) => setState(() {
                                _showApprovedProjectContext = value;
                              }),
                            ),
                          )
                        : const SizedBox.shrink(
                            key: ValueKey<String>('import_map_panel_hidden'),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (!_isPanelVisible)
          Positioned(
            top: 12,
            right: 12,
            child: FloatingActionButton.small(
              heroTag: 'show_import_map_tools',
              onPressed: () => setState(() {
                _isPanelVisible = true;
              }),
              child: const Icon(Icons.tune_rounded),
            ),
          ),
        Positioned(
          right: AppSpacing.md,
          bottom: AppSpacing.lg,
          child: _ImportMapControlRail(
            featureCount: visibleStagedFeatures.length,
            approvedContextCount: mapData.approvedProjectFeatures.length,
            onOpenApprovedFeatures: () => _openApprovedFeatureBrowser(
              context,
              projectId: widget.projectId,
              projectName: projectLabel,
            ),
            onOpenFeatures: () => _openFeatureBrowser(
              context,
              projectName: projectLabel,
              canModerateImport: canModerateImport,
            ),
            onCenterCurrentLocation: _centerOnCurrentLocation,
            onFitWorkspace: _focusLebanonWorkspace,
            onZoomIn: () => _zoomBy(1),
            onZoomOut: () => _zoomBy(-1),
            isLocating: _isLocating,
          ),
        ),
      ],
    );
  }

  bool _canModerateImport(AppUser user, GisImportDetails? details) {
    if (user.role != UserRole.admin) {
      return false;
    }
    final reviewScope = details?.job.reviewScope ?? 'admin';
    if (reviewScope != 'protected_super_admin') {
      return true;
    }
    return user.isSuperAdmin;
  }

  List<ImportedFeature> _filteredStagedFeatures(
    List<ImportedFeature> features,
  ) {
    final query = _searchController.text.trim().toLowerCase();
    return features
        .where((feature) {
          if (!_visibleStatuses.contains(feature.status)) {
            return false;
          }
          if (!_matchesFeatureTypeFilter(feature)) {
            return false;
          }
          if (query.isEmpty) {
            return true;
          }
          return _featureSearchBlob(feature).contains(query);
        })
        .toList(growable: false);
  }

  bool _matchesFeatureTypeFilter(ImportedFeature feature) {
    final selected = _selectedFeatureTypeChip;
    if (selected == null) {
      return true;
    }
    final geometryType =
        feature.geometryType ?? feature.geometry?['type']?.toString() ?? '';
    switch (selected) {
      case 'point':
        return geometryType == 'Point' || geometryType == 'MultiPoint';
      case 'line':
        return geometryType == 'LineString' ||
            geometryType == 'MultiLineString';
      case 'polygon':
        return geometryType == 'Polygon' || geometryType == 'MultiPolygon';
      default:
        return true;
    }
  }

  String _featureSearchBlob(ImportedFeature feature) {
    final buffer = StringBuffer()
      ..write(_importFeatureTitle(feature).toLowerCase())
      ..write(' ')
      ..write(
        '${feature.geometryType ?? feature.geometry?['type'] ?? ''}'
            .toLowerCase(),
      )
      ..write(' ')
      ..write(_statusLabel(feature.status).toLowerCase());
    if (feature.sourceFeatureName?.trim().isNotEmpty ?? false) {
      buffer
        ..write(' ')
        ..write(feature.sourceFeatureName!.toLowerCase());
    }
    for (final entry in feature.attributes.entries) {
      buffer
        ..write(' ')
        ..write(entry.key.toLowerCase())
        ..write(' ')
        ..write('${entry.value}'.toLowerCase());
    }
    return buffer.toString();
  }

  String? _searchSummaryLabel(int visibleCount) {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      return null;
    }
    return visibleCount == 1
        ? '1 staged feature matches "$query"'
        : '$visibleCount staged features match "$query"';
  }

  String _visibleStatusSummaryLabel() {
    if (_visibleStatuses.length == _statusOrder.length) {
      return 'All statuses';
    }
    if (_visibleStatuses.isEmpty) {
      return 'No statuses';
    }
    return _visibleStatuses.map(_statusLabel).join(', ');
  }

  String? _visibleFeatureTypeSummaryLabel() {
    final selected = _selectedFeatureTypeChip;
    if (selected == null) {
      return null;
    }
    return '${_featureTypeFilterLabel(selected)} only';
  }

  List<String> _availableFeatureTypeChips(List<ImportedFeature> features) {
    return _importGeometryQuickFilters
        .map((filter) => filter.id)
        .toList(growable: false);
  }

  void _toggleSearch() {
    setState(() {
      _isSearchOpen = !_isSearchOpen;
      if (!_isSearchOpen) {
        _searchController.clear();
      }
    });
    if (_isSearchOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _searchFocusNode.requestFocus();
      });
    } else {
      _searchFocusNode.unfocus();
    }
  }

  void _setBasemapStyle(LebanonBasemapStyle style) {
    if (_basemapStyle == style) {
      return;
    }
    _basemapTransitionTimer?.cancel();
    setState(() {
      _basemapStyle = style;
      _isBasemapTransitioning = true;
    });
    _basemapTransitionTimer = Timer(const Duration(milliseconds: 480), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _isBasemapTransitioning = false;
      });
    });
  }

  void _scheduleCameraRefresh() {
    if (_cameraRefreshTimer?.isActive ?? false) {
      return;
    }
    _cameraRefreshTimer = Timer(const Duration(milliseconds: 90), () {
      if (!mounted) {
        return;
      }
      setState(() {});
    });
  }

  void _handleMapReady() {
    if (!mounted) {
      return;
    }
    final pendingAction = _pendingMapAction;
    _pendingMapAction = null;
    setState(() {
      _isMapReady = true;
    });
    if (!_hasPrimedWorkspace) {
      _hasPrimedWorkspace = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _focusLebanonWorkspace();
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

  void _runMapAction(VoidCallback action, {bool queueUntilReady = false}) {
    if (!_isMapReady && !queueUntilReady) {
      AppSnackbar.showError(
        context,
        'Map is still preparing. Please try again in a moment.',
      );
      return;
    }
    try {
      action();
      _scheduleCameraRefresh();
      if (!_isMapReady && mounted) {
        setState(() {
          _isMapReady = true;
        });
      }
    } catch (error) {
      if (error.toString().contains(
        'You need to have FlutterMap widget rendered at least once before using MapController',
      )) {
        if (!queueUntilReady) {
          AppSnackbar.showError(
            context,
            'Map is still preparing. Please try again in a moment.',
          );
          return;
        }
        _pendingMapAction = action;
        if (mounted) {
          setState(() {
            _isMapReady = false;
          });
        }
        return;
      }
      rethrow;
    }
  }

  void _focusLebanonWorkspace() {
    _runMapAction(
      () => _mapController.fitCamera(LebanonMapConfig.lebanonFit()),
      queueUntilReady: true,
    );
  }

  void _zoomBy(double delta) {
    final center = _latestMapCamera?.center ?? _defaultMapCenter;
    final zoom = (_latestMapCamera?.zoom ?? _defaultMapZoom) + delta;
    _runMapAction(
      () => _mapController.move(
        center,
        zoom.clamp(_mapMinZoom, _mapMaxZoom).toDouble(),
      ),
      queueUntilReady: true,
    );
  }

  Future<void> _centerOnCurrentLocation() async {
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
        if (!mounted) {
          return;
        }
        AppSnackbar.showError(
          context,
          'Current location is outside Lebanon. Staying on the Lebanon workspace.',
        );
        _focusLebanonWorkspace();
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _currentLocation = location.position;
      });
      _runMapAction(
        () => _mapController.move(location.position, 16),
        queueUntilReady: true,
      );
    } on CurrentLocationFailure catch (error) {
      if (!mounted) {
        return;
      }
      AppSnackbar.showError(context, error.message);
    } finally {
      if (mounted) {
        setState(() {
          _isLocating = false;
        });
      }
    }
  }

  ImportedFeature? _findImportedFeature(
    List<ImportedFeature> features,
    String? id,
  ) {
    if (id == null) {
      return null;
    }
    for (final feature in features) {
      if (feature.id == id) {
        return feature;
      }
    }
    return null;
  }

  void _scheduleInitialFeatureFocus(
    List<ImportedFeature> visibleStagedFeatures,
    ImportedFeature? selectedFeature,
  ) {
    final featureId = widget.initialFeatureId;
    if (featureId == null || _lastAutoFocusedFeatureId == featureId) {
      return;
    }
    if (selectedFeature == null ||
        !visibleStagedFeatures.any((item) => item.id == featureId)) {
      return;
    }
    _lastAutoFocusedFeatureId = featureId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _focusImportedFeature(selectedFeature);
      _openImportedFeatureDetails(
        selectedFeature,
        canModerateImport: _canModerateImport(
          ref.read(authControllerProvider).session!.user,
          ref.read(importDetailsProvider(widget.importId)).valueOrNull,
        ),
      );
    });
  }

  void _handleMapTap(
    LatLng point, {
    required List<ImportedFeature> stagedFeatures,
    required List<MapFeatureSummary> approvedFeatures,
    required bool canModerateImport,
  }) {
    if (_isSearchOpen || _isPanelExpanded) {
      setState(() {
        _isSearchOpen = false;
        _isPanelExpanded = false;
      });
      _searchFocusNode.unfocus();
      return;
    }

    final stagedMatch = _nearestImportedFeature(point, stagedFeatures);
    if (stagedMatch != null) {
      _focusImportedFeature(stagedMatch);
      _openImportedFeatureDetails(
        stagedMatch,
        canModerateImport: canModerateImport,
      );
      return;
    }

    if (_showApprovedProjectContext) {
      final approvedMatch = _nearestApprovedProjectFeature(
        point,
        approvedFeatures,
      );
      if (approvedMatch != null) {
        _focusProjectContextFeature(approvedMatch);
        _openApprovedProjectFeatureDetails(approvedMatch);
      }
    }
  }

  ImportedFeature? _nearestImportedFeature(
    LatLng point,
    List<ImportedFeature> features,
  ) {
    ImportedFeature? best;
    var bestDistance = double.infinity;
    final thresholdMeters = _selectionThresholdMeters();
    for (final feature in features) {
      final geometry = feature.geometry;
      if (geometry == null) {
        continue;
      }
      final focusPoint = _featureFocusPoint(geometry);
      if (focusPoint == null) {
        continue;
      }
      final distanceMeters = _distance.as(LengthUnit.Meter, point, focusPoint);
      if (distanceMeters < bestDistance) {
        bestDistance = distanceMeters;
        best = feature;
      }
    }
    if (bestDistance > thresholdMeters) {
      return null;
    }
    return best;
  }

  MapFeatureSummary? _nearestApprovedProjectFeature(
    LatLng point,
    List<MapFeatureSummary> features,
  ) {
    MapFeatureSummary? best;
    var bestDistance = double.infinity;
    final thresholdMeters = _selectionThresholdMeters();
    for (final feature in features) {
      final focusPoint = _featureFocusPoint(feature.geometry);
      if (focusPoint == null) {
        continue;
      }
      final distanceMeters = _distance.as(LengthUnit.Meter, point, focusPoint);
      if (distanceMeters < bestDistance) {
        bestDistance = distanceMeters;
        best = feature;
      }
    }
    if (bestDistance > thresholdMeters) {
      return null;
    }
    return best;
  }

  double _selectionThresholdMeters() {
    final zoom =
        _latestMapCamera?.zoom ?? LebanonMapConfig.fullscreenInitialZoom;
    if (zoom >= 15) {
      return 120;
    }
    if (zoom >= 13) {
      return 220;
    }
    if (zoom >= 11) {
      return 420;
    }
    return 700;
  }

  LatLng? _featureFocusPoint(Map<String, dynamic> geometry) {
    final type = geometry['type'];
    if (type == 'Point') {
      return geometryFocusPoint(geometry);
    }
    final points = geometryPoints(geometry);
    if (points.isEmpty) {
      return null;
    }
    final latitude =
        points.fold<double>(0, (sum, item) => sum + item.latitude) /
        points.length;
    final longitude =
        points.fold<double>(0, (sum, item) => sum + item.longitude) /
        points.length;
    return LatLng(latitude, longitude);
  }

  void _focusImportedFeature(ImportedFeature feature) {
    setState(() {
      _focusedFeatureId = feature.id;
    });
    final geometry = feature.geometry;
    if (geometry == null) {
      return;
    }
    final points = geometryPoints(geometry);
    if (points.isEmpty) {
      return;
    }
    _runMapAction(() {
      if (points.length == 1) {
        _mapController.move(
          points.first,
          math.max(_latestMapCamera?.zoom ?? 14, 14),
        );
        return;
      }
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(points),
          padding: const EdgeInsets.all(48),
        ),
      );
    }, queueUntilReady: true);
  }

  void _focusProjectContextFeature(MapFeatureSummary feature) {
    final points = geometryPoints(feature.geometry);
    if (points.isEmpty) {
      return;
    }
    _runMapAction(() {
      if (points.length == 1) {
        _mapController.move(
          points.first,
          math.max(_latestMapCamera?.zoom ?? 14, 14),
        );
        return;
      }
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(points),
          padding: const EdgeInsets.all(48),
        ),
      );
    }, queueUntilReady: true);
  }

  Future<void> _openFeatureBrowser(
    BuildContext context, {
    required String projectName,
    required bool canModerateImport,
  }) async {
    if (_isFeatureBrowserOpen) {
      return;
    }
    setState(() {
      _isFeatureBrowserOpen = true;
    });
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) => _ImportFeatureBrowserSheet(
          importId: widget.importId,
          projectName: projectName,
          initialSearch: _searchController.text.trim(),
          initialStatus: _visibleStatuses.length == 1
              ? _visibleStatuses.first
              : null,
          initialGeometryType: _selectedGeometryTypeForSheet(),
          onSelectFeature: (feature) {
            Navigator.of(sheetContext).pop();
            _focusImportedFeature(feature);
            _openImportedFeatureDetails(
              feature,
              canModerateImport: canModerateImport,
            );
          },
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isFeatureBrowserOpen = false;
        });
      }
    }
  }

  Future<void> _openApprovedFeatureBrowser(
    BuildContext context, {
    required String projectId,
    required String projectName,
  }) async {
    if (_isFeatureBrowserOpen) {
      return;
    }
    setState(() {
      _isFeatureBrowserOpen = true;
    });
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) => _ApprovedProjectFeatureBrowserSheet(
          projectId: projectId,
          projectName: projectName,
          onSelectFeature: (feature) {
            Navigator.of(sheetContext).pop();
            _focusProjectContextFeature(feature);
            _openApprovedProjectFeatureDetails(feature);
          },
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isFeatureBrowserOpen = false;
        });
      }
    }
  }

  String? _selectedGeometryTypeForSheet() {
    return _selectedFeatureTypeChip;
  }

  Future<void> _openImportedFeatureDetails(
    ImportedFeature feature, {
    required bool canModerateImport,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => feature.isSummary
          ? _ImportFeatureDetailsLoaderSheet(
              importId: widget.importId,
              featureId: feature.id,
              fallbackTitle: _importFeatureTitle(feature),
              canModerateImport: canModerateImport,
              onAddComment: _addFeatureComment,
              onApprove: _reviewFeatureFromMap,
              onReject: _reviewFeatureFromMap,
            )
          : _ImportFeatureDetailsSheet(
              feature: feature,
              canComment: canModerateImport,
              canReview: canModerateImport,
              onAddComment: canModerateImport
                  ? () => _addFeatureComment(context, feature)
                  : null,
              onApprove: feature.canBeApproved
                  ? () => _reviewFeatureFromMap(
                      sheetContext,
                      feature,
                      status: 'approved',
                    )
                  : null,
              onReject: feature.canBeRejected
                  ? () => _reviewFeatureFromMap(
                      sheetContext,
                      feature,
                      status: 'rejected',
                    )
                  : null,
            ),
    );
  }

  Future<void> _openApprovedProjectFeatureDetails(
    MapFeatureSummary feature,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) =>
          _ApprovedProjectFeatureDetailsSheet(feature: feature),
    );
  }

  Future<void> _addFeatureComment(
    BuildContext dialogContext,
    ImportedFeature feature,
  ) async {
    final note = await showDialog<String>(
      context: dialogContext,
      builder: (dialogContext) => _ImportFeatureCommentDialog(feature: feature),
    );
    if (!mounted || note == null || note.trim().isEmpty) {
      return;
    }
    try {
      await ref
          .read(importsRepositoryProvider)
          .addImportComment(
            importId: widget.importId,
            comment: note.trim(),
            featureId: feature.id,
          );
      ref.invalidate(importDetailsProvider(widget.importId));
      ref.read(workflowRefreshTickProvider.notifier).state++;
      if (!mounted) {
        return;
      }
      AppSnackbar.showSuccess(context, 'Feature comment saved successfully.');
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnackbar.showError(
        context,
        userFacingErrorMessage(
          error,
          fallback: 'Unable to save this feature comment right now.',
        ),
      );
    }
  }

  Future<void> _reviewFeatureFromMap(
    BuildContext sheetContext,
    ImportedFeature feature, {
    required String status,
  }) async {
    String? reason;
    if (status == 'rejected') {
      reason = await showDialog<String>(
        context: sheetContext,
        builder: (dialogContext) => const _ImportFeatureReviewReasonDialog(),
      );
      if (reason == null) {
        return;
      }
    }
    try {
      await ref
          .read(importsRepositoryProvider)
          .reviewImport(
            importId: widget.importId,
            status: status,
            reason: reason?.trim(),
            featureIds: <String>[feature.id],
          );
      ref.read(workflowRefreshTickProvider.notifier).state++;
      if (!mounted || !sheetContext.mounted) {
        return;
      }
      Navigator.of(sheetContext).pop();
      AppSnackbar.showSuccess(
        context,
        status == 'approved'
            ? 'Imported feature approved.'
            : 'Imported feature rejected.',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnackbar.showError(
        context,
        userFacingErrorMessage(
          error,
          fallback: status == 'approved'
              ? 'Unable to approve this imported feature right now.'
              : 'Unable to reject this imported feature right now.',
        ),
      );
    }
  }

  List<Polygon> _stagedPolygons(List<ImportedFeature> features) {
    final polygons = <Polygon>[];
    for (final feature in features) {
      final geometry = feature.geometry;
      if (geometry == null) {
        continue;
      }
      final type = geometry['type'];
      if (type != 'Polygon' && type != 'MultiPolygon') {
        continue;
      }
      final color = _statusColor(feature.status);
      for (final points in _polygonSegments(geometry)) {
        if (points.isEmpty) {
          continue;
        }
        polygons.add(
          Polygon(
            points: points,
            borderStrokeWidth: _focusedFeatureId == feature.id ? 3 : 2,
            borderColor: color,
            color: color.withValues(alpha: 0.18),
          ),
        );
      }
    }
    return polygons;
  }

  List<Polyline> _stagedPolylines(List<ImportedFeature> features) {
    final lines = <Polyline>[];
    for (final feature in features) {
      final geometry = feature.geometry;
      if (geometry == null) {
        continue;
      }
      final type = geometry['type'];
      if (type != 'LineString' && type != 'MultiLineString') {
        continue;
      }
      final color = _statusColor(feature.status);
      for (final points in _polylineSegments(geometry)) {
        if (points.isEmpty) {
          continue;
        }
        lines.add(
          Polyline(
            points: points,
            strokeWidth: _focusedFeatureId == feature.id ? 4 : 3,
            color: color,
          ),
        );
      }
    }
    return lines;
  }

  List<Marker> _stagedMarkers(
    List<ImportedFeature> features,
    bool canModerateImport,
    Map<String, LatLng> markerPoints,
  ) {
    final grouped = <String, List<(ImportedFeature, LatLng)>>{};
    for (final feature in features) {
      final geometry = feature.geometry;
      final point =
          markerPoints[feature.id] ??
          (geometry == null ? null : _featureFocusPoint(geometry));
      if (point == null) {
        continue;
      }
      final key =
          '${point.latitude.toStringAsFixed(7)}:${point.longitude.toStringAsFixed(7)}';
      grouped.putIfAbsent(key, () => <(ImportedFeature, LatLng)>[]).add((
        feature,
        point,
      ));
    }

    final markers = <Marker>[];
    for (final entries in grouped.values) {
      for (var index = 0; index < entries.length; index++) {
        final entry = entries[index];
        final feature = entry.$1;
        final markerPoint = entry.$2;
        final color = _statusColor(feature.status);
        markers.add(
          Marker(
            point: markerPoint,
            width: 34,
            height: 34,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                _focusImportedFeature(feature);
                _openImportedFeatureDetails(
                  feature,
                  canModerateImport: canModerateImport,
                );
              },
              child: Center(
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _focusedFeatureId == feature.id
                          ? Colors.black87
                          : Colors.white,
                      width: _focusedFeatureId == feature.id ? 2.2 : 1.8,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(
                    _statusIcon(feature.status),
                    color: Colors.white,
                    size: 11,
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }
    return markers;
  }

  List<Polygon> _projectContextPolygons(List<MapFeatureSummary> features) {
    return features
        .where((feature) {
          final type = feature.geometry['type'];
          return type == 'Polygon' || type == 'MultiPolygon';
        })
        .expand((feature) sync* {
          for (final points in _polygonSegments(feature.geometry)) {
            if (points.isEmpty) {
              continue;
            }
            yield Polygon(
              points: points,
              borderStrokeWidth: 1.6,
              borderColor: _projectContextColor,
              color: _projectContextColor.withValues(alpha: 0.08),
            );
          }
        })
        .toList(growable: false);
  }

  List<Polyline> _projectContextPolylines(List<MapFeatureSummary> features) {
    return features
        .where((feature) {
          final type = feature.geometry['type'];
          return type == 'LineString' || type == 'MultiLineString';
        })
        .expand((feature) sync* {
          for (final points in _polylineSegments(feature.geometry)) {
            if (points.isEmpty) {
              continue;
            }
            yield Polyline(
              points: points,
              strokeWidth: 2,
              color: _projectContextColor,
            );
          }
        })
        .toList(growable: false);
  }

  List<Marker> _projectContextMarkers(
    List<MapFeatureSummary> features,
    Map<String, LatLng> markerPoints,
  ) {
    final markers = <Marker>[];
    for (final feature in features) {
      final markerPoint =
          markerPoints[feature.id] ?? _featureFocusPoint(feature.geometry);
      if (markerPoint == null) {
        continue;
      }
      markers.add(
        Marker(
          point: markerPoint,
          width: 34,
          height: 34,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              _focusProjectContextFeature(feature);
              _openApprovedProjectFeatureDetails(feature);
            },
            child: Center(
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: _projectContextColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.6),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x26000000),
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: const Icon(Icons.check, color: Colors.white, size: 13),
              ),
            ),
          ),
        ),
      );
    }
    return markers;
  }

  List<CircleMarker> _stagedCircles(
    List<ImportedFeature> features,
    Map<String, LatLng> markerPoints,
  ) {
    return features
        .map((feature) {
          final geometry = feature.geometry;
          final point =
              markerPoints[feature.id] ??
              (geometry == null ? null : _featureFocusPoint(geometry));
          if (point == null) {
            return null;
          }
          return CircleMarker(
            point: point,
            radius: _focusedFeatureId == feature.id ? 8.5 : 7,
            color: _statusColor(feature.status),
            borderColor: _focusedFeatureId == feature.id
                ? Colors.black87
                : Colors.white,
            borderStrokeWidth: _focusedFeatureId == feature.id ? 2.2 : 1.6,
          );
        })
        .whereType<CircleMarker>()
        .toList(growable: false);
  }

  List<CircleMarker> _projectContextCircles(
    List<MapFeatureSummary> features,
    Map<String, LatLng> markerPoints,
  ) {
    return features
        .map((feature) {
          final point =
              markerPoints[feature.id] ?? _featureFocusPoint(feature.geometry);
          if (point == null) {
            return null;
          }
          return CircleMarker(
            point: point,
            radius: 7,
            color: _projectContextColor,
            borderColor: Colors.white,
            borderStrokeWidth: 1.6,
          );
        })
        .whereType<CircleMarker>()
        .toList(growable: false);
  }

  List<ImportedFeature> _featuresInBounds(
    List<ImportedFeature> features,
    LatLngBounds bounds,
  ) {
    return features
        .where((feature) => _geometryIntersectsBounds(feature.geometry, bounds))
        .toList(growable: false);
  }

  List<MapFeatureSummary> _projectFeaturesInBounds(
    List<MapFeatureSummary> features,
    LatLngBounds bounds,
  ) {
    return features
        .where((feature) => _geometryIntersectsBounds(feature.geometry, bounds))
        .toList(growable: false);
  }

  bool _geometryIntersectsBounds(
    Map<String, dynamic>? geometry,
    LatLngBounds bounds,
  ) {
    if (geometry == null) {
      return false;
    }
    final focusPoint = _featureFocusPoint(geometry);
    if (focusPoint != null && bounds.contains(focusPoint)) {
      return true;
    }
    final points = geometryPoints(geometry);
    for (final point in points) {
      if (bounds.contains(point)) {
        return true;
      }
    }
    return false;
  }

  _ImportMarkerPlacements _buildMarkerPlacements(
    List<ImportedFeature> stagedFeatures,
    List<MapFeatureSummary> approvedFeatures,
  ) {
    final grouped = <String, List<_MarkerPlacementSeed>>{};

    for (final feature in stagedFeatures) {
      final geometry = feature.geometry;
      final point = geometry == null ? null : _featureFocusPoint(geometry);
      if (point == null) {
        continue;
      }
      final key =
          '${point.latitude.toStringAsFixed(7)}:${point.longitude.toStringAsFixed(7)}';
      grouped
          .putIfAbsent(key, () => <_MarkerPlacementSeed>[])
          .add(_MarkerPlacementSeed.staged(id: feature.id, point: point));
    }

    for (final feature in approvedFeatures) {
      final point = _featureFocusPoint(feature.geometry);
      if (point == null) {
        continue;
      }
      final key =
          '${point.latitude.toStringAsFixed(7)}:${point.longitude.toStringAsFixed(7)}';
      grouped
          .putIfAbsent(key, () => <_MarkerPlacementSeed>[])
          .add(_MarkerPlacementSeed.project(id: feature.id, point: point));
    }

    final stagedPoints = <String, LatLng>{};
    final projectPoints = <String, LatLng>{};

    for (final entries in grouped.values) {
      for (var index = 0; index < entries.length; index++) {
        final seed = entries[index];
        final markerPoint = entries.length == 1
            ? seed.point
            : _spreadDuplicateMarkerPoint(
                seed.point,
                duplicateIndex: index,
                duplicateCount: entries.length,
              );
        if (seed.kind == _MarkerSeedKind.staged) {
          stagedPoints[seed.id] = markerPoint;
        } else {
          projectPoints[seed.id] = markerPoint;
        }
      }
    }

    return _ImportMarkerPlacements(
      stagedPoints: stagedPoints,
      projectPoints: projectPoints,
    );
  }

  LatLng _spreadDuplicateMarkerPoint(
    LatLng origin, {
    required int duplicateIndex,
    required int duplicateCount,
  }) {
    final ringCapacity = duplicateCount <= 6 ? duplicateCount : 6;
    final ring = duplicateIndex ~/ 6;
    final ringIndex = duplicateIndex % 6;
    final pointsInRing = math.min(duplicateCount - (ring * 6), ringCapacity);
    final angle = (-math.pi / 2) + ((2 * math.pi * ringIndex) / pointsInRing);
    final radiusDegrees = 0.0012 + (ring * 0.00055);
    return LatLng(
      origin.latitude + (math.sin(angle) * radiusDegrees),
      origin.longitude + (math.cos(angle) * radiusDegrees),
    );
  }

  List<List<LatLng>> _polylineSegments(Map<String, dynamic> geometry) {
    final type = geometry['type'];
    if (type == 'LineString') {
      final points = lineGeometryPoints(geometry);
      return points.isEmpty ? const <List<LatLng>>[] : <List<LatLng>>[points];
    }
    if (type != 'MultiLineString') {
      return const <List<LatLng>>[];
    }
    final coordinates = geometry['coordinates'];
    if (coordinates is! List) {
      return const <List<LatLng>>[];
    }
    return coordinates
        .whereType<List>()
        .map(
          (segment) => segment
              .map(_decodeCoordinatePair)
              .whereType<LatLng>()
              .toList(growable: false),
        )
        .where((points) => points.isNotEmpty)
        .toList(growable: false);
  }

  List<List<LatLng>> _polygonSegments(Map<String, dynamic> geometry) {
    final type = geometry['type'];
    if (type == 'Polygon') {
      final points = polygonGeometryPoints(geometry);
      return points.isEmpty ? const <List<LatLng>>[] : <List<LatLng>>[points];
    }
    if (type != 'MultiPolygon') {
      return const <List<LatLng>>[];
    }
    final coordinates = geometry['coordinates'];
    if (coordinates is! List) {
      return const <List<LatLng>>[];
    }
    return coordinates
        .whereType<List>()
        .map((polygon) {
          if (polygon.isEmpty) {
            return const <LatLng>[];
          }
          final firstRing = polygon.first;
          if (firstRing is! List) {
            return const <LatLng>[];
          }
          return firstRing
              .map(_decodeCoordinatePair)
              .whereType<LatLng>()
              .toList(growable: false);
        })
        .where((points) => points.isNotEmpty)
        .toList(growable: false);
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
}

class _ImportGeometryQuickFilter {
  const _ImportGeometryQuickFilter({required this.id, required this.label});

  final String id;
  final String label;
}

const List<_ImportGeometryQuickFilter> _importGeometryQuickFilters =
    <_ImportGeometryQuickFilter>[
      _ImportGeometryQuickFilter(id: 'point', label: 'Point'),
      _ImportGeometryQuickFilter(id: 'line', label: 'Line'),
      _ImportGeometryQuickFilter(id: 'polygon', label: 'Polygon'),
    ];

const List<_ImportGeometryQuickFilter> _projectGeometryQuickFilters =
    <_ImportGeometryQuickFilter>[
      _ImportGeometryQuickFilter(id: 'Point', label: 'Point'),
      _ImportGeometryQuickFilter(id: 'LineString', label: 'Line'),
      _ImportGeometryQuickFilter(id: 'Polygon', label: 'Polygon'),
    ];

const Color _projectContextColor = Color(0xFF546E7A);

class _ImportMapFloatingPanel extends StatelessWidget {
  const _ImportMapFloatingPanel({
    required this.projectName,
    required this.categoryLabel,
    required this.visibleFeatureCount,
    required this.approvedContextCount,
    required this.searchController,
    required this.searchFocusNode,
    required this.visibleStatuses,
    required this.visibleFeatureTypes,
    required this.selectedFeatureType,
    required this.basemapStyle,
    required this.isExpanded,
    required this.isSearchOpen,
    required this.searchSummaryLabel,
    required this.visibleStatusSummaryLabel,
    required this.visibleFeatureTypeSummaryLabel,
    required this.showApprovedProjectContext,
    required this.onSearchPressed,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.onResetVisibleStatuses,
    required this.onToggleVisibleStatus,
    required this.onSelectFeatureType,
    required this.onBasemapStyleChanged,
    required this.onToggleExpanded,
    required this.onHidePanel,
    required this.onToggleProjectContext,
  });

  final String projectName;
  final String categoryLabel;
  final int visibleFeatureCount;
  final int approvedContextCount;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final Set<String> visibleStatuses;
  final List<String> visibleFeatureTypes;
  final String? selectedFeatureType;
  final LebanonBasemapStyle basemapStyle;
  final bool isExpanded;
  final bool isSearchOpen;
  final String? searchSummaryLabel;
  final String visibleStatusSummaryLabel;
  final String? visibleFeatureTypeSummaryLabel;
  final bool showApprovedProjectContext;
  final VoidCallback onSearchPressed;
  final VoidCallback onSearchChanged;
  final VoidCallback onClearSearch;
  final VoidCallback onResetVisibleStatuses;
  final ValueChanged<String> onToggleVisibleStatus;
  final ValueChanged<String?> onSelectFeatureType;
  final ValueChanged<LebanonBasemapStyle> onBasemapStyleChanged;
  final VoidCallback onToggleExpanded;
  final VoidCallback onHidePanel;
  final ValueChanged<bool> onToggleProjectContext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final visibleCountLabel = visibleFeatureCount == 1
        ? '1 imported feature'
        : '$visibleFeatureCount imported features';
    final contextCountLabel = approvedContextCount == 1
        ? '1 project context feature'
        : '$approvedContextCount project context features';

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: Material(
        elevation: 0,
        color: scheme.surface.withValues(alpha: 0.93),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.38),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final actionRailWidth = constraints.maxWidth >= 430
                ? 146.0
                : constraints.maxWidth >= 370
                ? 118.0
                : 92.0;
            final metaMaxWidth = constraints.maxWidth >= 420
                ? 156.0
                : constraints.maxWidth >= 360
                ? 128.0
                : 106.0;
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 11, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                projectName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  height: 1.15,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  _CompactMapMetaPill(
                                    icon: Icons.category_outlined,
                                    label: categoryLabel.trim().isEmpty
                                        ? 'Project'
                                        : categoryLabel.trim(),
                                    maxWidth: metaMaxWidth,
                                    textStyle: theme.textTheme.labelSmall
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                  _CompactMapMetaPill(
                                    icon: Icons.place_outlined,
                                    label: visibleCountLabel,
                                    maxWidth: metaMaxWidth,
                                    textStyle: theme.textTheme.labelSmall
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: actionRailWidth),
                        child: Align(
                          alignment: Alignment.topRight,
                          child: Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              _MapStyleMenuButton(
                                basemapStyle: basemapStyle,
                                onSelected: onBasemapStyleChanged,
                              ),
                              _MapPanelIconButton(
                                tooltip: isSearchOpen
                                    ? 'Close search'
                                    : 'Search imported features',
                                icon: isSearchOpen
                                    ? Icons.search_off_rounded
                                    : Icons.search_rounded,
                                onPressed: onSearchPressed,
                              ),
                              _MapPanelIconButton(
                                tooltip: isExpanded
                                    ? 'Hide quick filters'
                                    : 'Show quick filters',
                                icon: isExpanded
                                    ? Icons.keyboard_arrow_up_rounded
                                    : Icons.tune_rounded,
                                onPressed: onToggleExpanded,
                              ),
                              _ProjectMapOverflowMenuButton(
                                onHidePanel: onHidePanel,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (isSearchOpen) ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: searchController,
                      focusNode: searchFocusNode,
                      textInputAction: TextInputAction.search,
                      onChanged: (_) => onSearchChanged(),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'Search imported features on this map',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        suffixIcon: searchController.text.trim().isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear search',
                                onPressed: onClearSearch,
                                icon: const Icon(Icons.clear),
                              ),
                      ),
                    ),
                  ],
                  if (!isExpanded) ...[
                    if (searchSummaryLabel != null ||
                        visibleStatusSummaryLabel != 'All statuses' ||
                        visibleFeatureTypeSummaryLabel != null ||
                        !showApprovedProjectContext) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (searchSummaryLabel != null)
                            _MapInfoPill(
                              icon: Icons.search,
                              label: searchSummaryLabel!,
                            ),
                          if (visibleStatusSummaryLabel != 'All statuses')
                            _MapInfoPill(
                              icon: Icons.visibility_outlined,
                              label: visibleStatusSummaryLabel,
                            ),
                          if (visibleFeatureTypeSummaryLabel != null)
                            _MapInfoPill(
                              icon: Icons.category_outlined,
                              label: visibleFeatureTypeSummaryLabel!,
                            ),
                          if (!showApprovedProjectContext)
                            const _MapInfoPill(
                              icon: Icons.visibility_off_outlined,
                              label: 'Project context hidden',
                            ),
                        ],
                      ),
                    ],
                  ],
                  if (isExpanded) ...[
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          ChoiceChip(
                            label: const Text('All'),
                            selected:
                                visibleStatuses.length ==
                                _ImportMapScreenState._statusOrder.length,
                            onSelected: (_) => onResetVisibleStatuses(),
                          ),
                          for (final status
                              in _ImportMapScreenState._statusOrder) ...[
                            const SizedBox(width: 8),
                            FilterChip(
                              avatar: Icon(
                                _statusIcon(status),
                                size: 16,
                                color: _statusColor(status),
                              ),
                              label: Text(_statusLabel(status)),
                              selected: visibleStatuses.contains(status),
                              onSelected: (_) => onToggleVisibleStatus(status),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (visibleFeatureTypes.isNotEmpty) ...[
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            ChoiceChip(
                              label: const Text('All'),
                              selected: selectedFeatureType == null,
                              onSelected: (_) => onSelectFeatureType(null),
                            ),
                            for (final featureType in visibleFeatureTypes) ...[
                              const SizedBox(width: 8),
                              ChoiceChip(
                                label: Text(
                                  _featureTypeFilterLabel(featureType),
                                ),
                                selected: selectedFeatureType == featureType,
                                onSelected: (selected) => onSelectFeatureType(
                                  selected ? featureType : null,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _MapInfoPill(
                          icon: _basemapStyleIcon(basemapStyle),
                          label:
                              '${LebanonMapConfig.basemapLabel(basemapStyle)} view',
                        ),
                        _MapInfoPill(
                          icon: Icons.map_outlined,
                          label: contextCountLabel,
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest.withValues(
                          alpha: 0.62,
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Show approved project context',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Keep approved project features visible as read-only reference.',
                                    style: theme.textTheme.bodySmall,
                                    softWrap: true,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Switch.adaptive(
                              value: showApprovedProjectContext,
                              onChanged: onToggleProjectContext,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ImportMapControlRail extends StatelessWidget {
  const _ImportMapControlRail({
    required this.featureCount,
    required this.approvedContextCount,
    required this.onOpenApprovedFeatures,
    required this.onOpenFeatures,
    required this.onCenterCurrentLocation,
    required this.onFitWorkspace,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.isLocating,
  });

  final int featureCount;
  final int approvedContextCount;
  final VoidCallback? onOpenApprovedFeatures;
  final VoidCallback? onOpenFeatures;
  final VoidCallback? onCenterCurrentLocation;
  final VoidCallback? onFitWorkspace;
  final VoidCallback? onZoomIn;
  final VoidCallback? onZoomOut;
  final bool isLocating;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (onOpenApprovedFeatures != null) ...[
          _MapFloatingActionButton(
            tooltip: 'Browse approved project features',
            onPressed: onOpenApprovedFeatures,
            badgeLabel: '$approvedContextCount',
            child: const Icon(Icons.verified_outlined, size: 20),
          ),
          const SizedBox(height: 12),
        ],
        if (onOpenFeatures != null) ...[
          _MapFloatingActionButton(
            tooltip: 'Browse imported features',
            onPressed: onOpenFeatures,
            badgeLabel: '$featureCount',
            child: const Icon(Icons.layers_outlined, size: 20),
          ),
          const SizedBox(height: 12),
        ],
        Material(
          elevation: 6,
          color: scheme.surface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _GroupedMapRailButton(
                tooltip: 'Current location',
                onPressed: onCenterCurrentLocation,
                icon: isLocating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.my_location_outlined),
                isTop: true,
              ),
              const _GroupedMapRailDivider(),
              _GroupedMapRailButton(
                tooltip: 'Fit Lebanon workspace',
                onPressed: onFitWorkspace,
                icon: const Icon(Icons.center_focus_strong_outlined),
              ),
              const _GroupedMapRailDivider(),
              _GroupedMapRailButton(
                tooltip: 'Zoom in',
                onPressed: onZoomIn,
                icon: const Icon(Icons.add),
              ),
              const _GroupedMapRailDivider(),
              _GroupedMapRailButton(
                tooltip: 'Zoom out',
                onPressed: onZoomOut,
                icon: const Icon(Icons.remove),
                isBottom: true,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ImportFeatureBrowserSheet extends ConsumerStatefulWidget {
  const _ImportFeatureBrowserSheet({
    required this.importId,
    required this.projectName,
    required this.onSelectFeature,
    this.initialSearch,
    this.initialStatus,
    this.initialGeometryType,
  });

  final String importId;
  final String projectName;
  final String? initialSearch;
  final String? initialStatus;
  final String? initialGeometryType;
  final ValueChanged<ImportedFeature> onSelectFeature;

  @override
  ConsumerState<_ImportFeatureBrowserSheet> createState() =>
      _ImportFeatureBrowserSheetState();
}

class _ImportFeatureBrowserSheetState
    extends ConsumerState<_ImportFeatureBrowserSheet> {
  static const List<String> _statusOrder = <String>[
    'pending_review',
    'approved',
    'rejected',
    'failed',
  ];

  late final TextEditingController _searchController;
  String? _statusFilter;
  String? _geometryTypeFilter;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.initialSearch ?? '');
    _statusFilter = widget.initialStatus;
    _geometryTypeFilter = widget.initialGeometryType;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = ImportedFeatureListQuery(
      importId: widget.importId,
      status: _statusFilter,
      search: _searchController.text.trim().isEmpty
          ? null
          : _searchController.text.trim(),
      geometryType: _geometryTypeFilter,
    );
    final featuresAsync = ref.watch(paginatedImportFeaturesProvider(query));
    final featuresController = ref.read(
      paginatedImportFeaturesProvider(query).notifier,
    );
    final featureState =
        featuresAsync.valueOrNull ??
        const PaginatedListState<ImportedFeature>.initial();
    final displayedFeatures = featureState.items;
    final bottomInset =
        MediaQuery.viewPaddingOf(context).bottom + AppSpacing.lg;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.64,
      minChildSize: 0.34,
      maxChildSize: 0.92,
      builder: (context, controller) {
        return ListView(
          controller: controller,
          padding: EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            bottomInset,
          ),
          children: [
            Center(
              child: Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Imported features',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Showing ${displayedFeatures.length} of ${featureState.total} item(s) in ${widget.projectName}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search imported features',
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
            const SizedBox(height: AppSpacing.sm),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('All'),
                    selected: _statusFilter == null,
                    onSelected: (_) {
                      setState(() {
                        _statusFilter = null;
                      });
                    },
                  ),
                  for (final status in _statusOrder) ...[
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text(_statusLabel(status)),
                      selected: _statusFilter == status,
                      onSelected: (selected) {
                        setState(() {
                          _statusFilter = selected ? status : null;
                        });
                      },
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('All'),
                    selected: _geometryTypeFilter == null,
                    onSelected: (_) {
                      setState(() {
                        _geometryTypeFilter = null;
                      });
                    },
                  ),
                  for (final filter in _importGeometryQuickFilters) ...[
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text(filter.label),
                      selected: _geometryTypeFilter == filter.id,
                      onSelected: (selected) {
                        setState(() {
                          _geometryTypeFilter = selected ? filter.id : null;
                        });
                      },
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (featuresAsync.isLoading && displayedFeatures.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (featuresAsync.hasError && displayedFeatures.isEmpty)
              AppEmptyState(
                icon: Icons.error_outline,
                title: 'Imported features unavailable',
                message: userFacingErrorMessage(
                  featuresAsync.asError!.error,
                  fallback:
                      'Unable to load imported features right now. Please try again.',
                ),
                actionLabel: 'Retry',
                onAction: featuresController.refresh,
              )
            else if (displayedFeatures.isEmpty)
              AppEmptyState(
                icon: Icons.layers_clear_outlined,
                title: 'No imported features match these filters',
                message:
                    'Try a different search, status, or feature type filter.',
                actionLabel: 'Clear filters',
                onAction: () {
                  setState(() {
                    _searchController.clear();
                    _statusFilter = null;
                    _geometryTypeFilter = null;
                  });
                },
              )
            else
              ProgressiveListSection<ImportedFeature>(
                items: displayedFeatures,
                resetKey: query,
                hasMore: featureState.hasMore,
                isLoadingMore: featureState.isLoadingMore,
                onLoadMore: featuresController.loadMore,
                itemBuilder: (context, feature, _) => AppCard(
                  onTap: () => widget.onSelectFeature(feature),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        margin: const EdgeInsets.only(top: 6),
                        decoration: BoxDecoration(
                          color: _statusColor(feature.status),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _importFeatureTitle(feature),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _importedFeatureSubtitle(feature),
                              style: Theme.of(context).textTheme.bodySmall,
                              softWrap: true,
                            ),
                            if (feature.validationWarnings.isNotEmpty ||
                                feature.validationErrors.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  if (feature.validationWarnings.isNotEmpty)
                                    _MapInfoPill(
                                      icon: Icons.warning_amber_rounded,
                                      label:
                                          '${feature.validationWarnings.length} warning${feature.validationWarnings.length == 1 ? '' : 's'}',
                                    ),
                                  if (feature.validationErrors.isNotEmpty)
                                    _MapInfoPill(
                                      icon: Icons.error_outline,
                                      label:
                                          '${feature.validationErrors.length} error${feature.validationErrors.length == 1 ? '' : 's'}',
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      _ImportFeatureStatusChip(status: feature.status),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ApprovedProjectFeatureBrowserSheet extends ConsumerStatefulWidget {
  const _ApprovedProjectFeatureBrowserSheet({
    required this.projectId,
    required this.projectName,
    required this.onSelectFeature,
  });

  final String projectId;
  final String projectName;
  final ValueChanged<MapFeatureSummary> onSelectFeature;

  @override
  ConsumerState<_ApprovedProjectFeatureBrowserSheet> createState() =>
      _ApprovedProjectFeatureBrowserSheetState();
}

class _ApprovedProjectFeatureBrowserSheetState
    extends ConsumerState<_ApprovedProjectFeatureBrowserSheet> {
  late final TextEditingController _searchController;
  String? _geometryTypeFilter;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = ProjectFeatureBrowserQuery(
      projectId: widget.projectId,
      search: _searchController.text.trim().isEmpty
          ? null
          : _searchController.text.trim(),
      status: 'approved',
      geometryType: _geometryTypeFilter,
    );
    final featuresAsync = ref.watch(
      paginatedProjectFeatureBrowserProvider(query),
    );
    final featuresController = ref.read(
      paginatedProjectFeatureBrowserProvider(query).notifier,
    );
    final featureState =
        featuresAsync.valueOrNull ??
        const PaginatedListState<MapFeatureSummary>.initial();
    final displayedFeatures = featureState.items;
    final bottomInset =
        MediaQuery.viewPaddingOf(context).bottom + AppSpacing.lg;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.64,
      minChildSize: 0.34,
      maxChildSize: 0.92,
      builder: (context, controller) {
        return ListView(
          controller: controller,
          padding: EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            bottomInset,
          ),
          children: [
            Center(
              child: Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Approved project features',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Showing ${displayedFeatures.length} of ${featureState.total} approved feature(s) in ${widget.projectName}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search approved project features',
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
            const SizedBox(height: AppSpacing.sm),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('All'),
                    selected: _geometryTypeFilter == null,
                    onSelected: (_) {
                      setState(() {
                        _geometryTypeFilter = null;
                      });
                    },
                  ),
                  for (final filter in _projectGeometryQuickFilters) ...[
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text(filter.label),
                      selected: _geometryTypeFilter == filter.id,
                      onSelected: (selected) {
                        setState(() {
                          _geometryTypeFilter = selected ? filter.id : null;
                        });
                      },
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (featuresAsync.isLoading && displayedFeatures.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (featuresAsync.hasError && displayedFeatures.isEmpty)
              AppEmptyState(
                icon: Icons.error_outline,
                title: 'Approved features unavailable',
                message: userFacingErrorMessage(
                  featuresAsync.asError!.error,
                  fallback:
                      'Unable to load approved project features right now. Please try again.',
                ),
                actionLabel: 'Retry',
                onAction: featuresController.refresh,
              )
            else if (displayedFeatures.isEmpty)
              AppEmptyState(
                icon: Icons.layers_clear_outlined,
                title: 'No approved project features match these filters',
                message: 'Try a different search or feature type filter.',
                actionLabel: 'Clear filters',
                onAction: () {
                  setState(() {
                    _searchController.clear();
                    _geometryTypeFilter = null;
                  });
                },
              )
            else
              ProgressiveListSection<MapFeatureSummary>(
                items: displayedFeatures,
                resetKey: query,
                hasMore: featureState.hasMore,
                isLoadingMore: featureState.isLoadingMore,
                onLoadMore: featuresController.loadMore,
                itemBuilder: (context, feature, _) => AppCard(
                  onTap: () => widget.onSelectFeature(feature),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 24,
                        height: 24,
                        margin: const EdgeInsets.only(top: 2),
                        decoration: BoxDecoration(
                          color: _projectContextColor,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.6),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x26000000),
                              blurRadius: 6,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.check,
                          color: Colors.white,
                          size: 12,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _projectFeatureTitle(feature),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _approvedProjectFeatureSubtitle(feature),
                              style: Theme.of(context).textTheme.bodySmall,
                              softWrap: true,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      const _MapInfoPill(
                        icon: Icons.check_circle_outline,
                        label: 'Approved',
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
}

class _ImportFeatureDetailsLoaderSheet extends ConsumerWidget {
  const _ImportFeatureDetailsLoaderSheet({
    required this.importId,
    required this.featureId,
    required this.fallbackTitle,
    required this.canModerateImport,
    required this.onAddComment,
    required this.onApprove,
    required this.onReject,
  });

  final String importId;
  final String featureId;
  final String fallbackTitle;
  final bool canModerateImport;
  final Future<void> Function(BuildContext, ImportedFeature) onAddComment;
  final Future<void> Function(
    BuildContext,
    ImportedFeature, {
    required String status,
  })
  onApprove;
  final Future<void> Function(
    BuildContext,
    ImportedFeature, {
    required String status,
  })
  onReject;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final featureAsync = ref.watch(
      importFeatureProvider(
        ImportFeatureQuery(importId: importId, featureId: featureId),
      ),
    );

    return featureAsync.when(
      data: (feature) => _ImportFeatureDetailsSheet(
        feature: feature,
        canComment: canModerateImport,
        canReview: canModerateImport,
        onAddComment: canModerateImport
            ? () => onAddComment(context, feature)
            : null,
        onApprove: feature.canBeApproved
            ? () => onApprove(context, feature, status: 'approved')
            : null,
        onReject: feature.canBeRejected
            ? () => onReject(context, feature, status: 'rejected')
            : null,
      ),
      loading: () => _ImportFeatureDetailsLoadingSheet(
        title: fallbackTitle,
        message: 'Loading feature details...',
      ),
      error: (error, _) => _ImportFeatureDetailsLoadingSheet(
        title: fallbackTitle,
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to load this imported feature right now.',
        ),
        isError: true,
      ),
    );
  }
}

class _ImportFeatureDetailsLoadingSheet extends StatelessWidget {
  const _ImportFeatureDetailsLoadingSheet({
    required this.title,
    required this.message,
    this.isError = false,
  });

  final String title;
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final bottomInset =
        MediaQuery.viewPaddingOf(context).bottom + AppSpacing.lg;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.34,
      minChildSize: 0.24,
      maxChildSize: 0.52,
      builder: (context, controller) {
        return ListView(
          controller: controller,
          padding: EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            bottomInset,
          ),
          children: [
            Center(
              child: Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.md),
            if (!isError)
              const Center(child: CircularProgressIndicator())
            else
              Icon(
                Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
                size: 36,
              ),
            const SizedBox(height: AppSpacing.md),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
              softWrap: true,
            ),
          ],
        );
      },
    );
  }
}

class _ImportFeatureDetailsSheet extends StatelessWidget {
  const _ImportFeatureDetailsSheet({
    required this.feature,
    required this.canComment,
    required this.canReview,
    this.onAddComment,
    this.onApprove,
    this.onReject,
  });

  final ImportedFeature feature;
  final bool canComment;
  final bool canReview;
  final VoidCallback? onAddComment;
  final Future<void> Function()? onApprove;
  final Future<void> Function()? onReject;

  @override
  Widget build(BuildContext context) {
    final bottomInset =
        MediaQuery.viewPaddingOf(context).bottom + AppSpacing.lg;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.64,
      minChildSize: 0.34,
      maxChildSize: 0.92,
      builder: (context, controller) {
        return ListView(
          controller: controller,
          padding: EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            bottomInset,
          ),
          children: [
            Center(
              child: Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _importFeatureTitle(feature),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _importedFeatureSubtitle(feature),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                _ImportFeatureStatusChip(status: feature.status),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (feature.reviewReason?.trim().isNotEmpty ?? false) ...[
              _DetailSection(
                title: 'Review reason',
                child: Text(feature.reviewReason!.trim(), softWrap: true),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            if (feature.validationErrors.isNotEmpty) ...[
              _ValidationIssueGroup(
                title: 'Validation errors',
                icon: Icons.error_outline,
                toneColor: Theme.of(context).colorScheme.error,
                messages: feature.validationErrors,
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            if (feature.validationWarnings.isNotEmpty) ...[
              _ValidationIssueGroup(
                title: 'Validation warnings',
                icon: Icons.warning_amber_rounded,
                toneColor: const Color(0xFFE67E22),
                messages: feature.validationWarnings,
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            _DetailSection(
              title: 'Feature details',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MapInfoPill(
                    icon: Icons.category_outlined,
                    label: _featureTypeDisplayLabel(
                      feature.geometryType ??
                          feature.geometry?['type']?.toString() ??
                          'Unknown',
                    ),
                  ),
                  if (feature.sourceFeatureName?.trim().isNotEmpty ?? false)
                    _MapInfoPill(
                      icon: Icons.badge_outlined,
                      label: feature.sourceFeatureName!.trim(),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            _DetailSection(
              title: 'Attributes',
              child: feature.attributes.isEmpty
                  ? const Text('No attributes were imported for this feature.')
                  : _AttributesGrid(attributes: feature.attributes),
            ),
            if (canReview || (canComment && onAddComment != null)) ...[
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (canReview && onApprove != null)
                    FilledButton.icon(
                      onPressed: onApprove,
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('Approve feature'),
                    ),
                  if (canReview && onReject != null)
                    OutlinedButton.icon(
                      onPressed: onReject,
                      icon: const Icon(Icons.cancel_outlined),
                      label: const Text('Reject feature'),
                    ),
                  if (canComment && onAddComment != null)
                    FilledButton.tonalIcon(
                      onPressed: onAddComment,
                      icon: const Icon(Icons.comment_outlined),
                      label: const Text('Comment on feature'),
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _ApprovedProjectFeatureDetailsSheet extends StatelessWidget {
  const _ApprovedProjectFeatureDetailsSheet({required this.feature});

  final MapFeatureSummary feature;

  @override
  Widget build(BuildContext context) {
    final bottomInset =
        MediaQuery.viewPaddingOf(context).bottom + AppSpacing.lg;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.58,
      minChildSize: 0.32,
      maxChildSize: 0.9,
      builder: (context, controller) {
        return ListView(
          controller: controller,
          padding: EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            bottomInset,
          ),
          children: [
            Center(
              child: Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _projectFeatureTitle(feature),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Approved project feature shown only as map context.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                const _MapInfoPill(
                  icon: Icons.check_circle_outline,
                  label: 'Project context',
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _DetailSection(
              title: 'Feature details',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MapInfoPill(
                    icon: Icons.category_outlined,
                    label: _featureTypeDisplayLabel(
                      feature.geometry['type']?.toString() ?? 'Unknown',
                    ),
                  ),
                  if (feature.collectedBy?.trim().isNotEmpty ?? false)
                    _MapInfoPill(
                      icon: Icons.person_outline,
                      label: 'Collected by ${feature.collectedBy!.trim()}',
                    ),
                  if (feature.reviewedBy?.trim().isNotEmpty ?? false)
                    _MapInfoPill(
                      icon: Icons.verified_outlined,
                      label: 'Reviewed by ${feature.reviewedBy!.trim()}',
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            _DetailSection(
              title: 'Attributes',
              child: feature.attributes.isEmpty
                  ? const Text(
                      'No attributes are available for this approved project feature.',
                    )
                  : _AttributesGrid(attributes: feature.attributes),
            ),
            if (feature.reviewNotes?.trim().isNotEmpty ?? false) ...[
              const SizedBox(height: AppSpacing.md),
              _DetailSection(
                title: 'Review notes',
                child: Text(feature.reviewNotes!.trim(), softWrap: true),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _AttributesGrid extends StatelessWidget {
  const _AttributesGrid({required this.attributes});

  final Map<String, dynamic> attributes;

  @override
  Widget build(BuildContext context) {
    final entries = _filteredImportAttributes(attributes).entries.toList(
      growable: false,
    )..sort((left, right) => left.key.compareTo(right.key));
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 520 ? 2 : 1;
        final itemWidth = columns == 1
            ? constraints.maxWidth
            : (constraints.maxWidth - 12) / 2;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final entry in entries)
              SizedBox(
                width: itemWidth,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).colorScheme.outlineVariant.withValues(alpha: 0.36),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _labelize(entry.key),
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                          softWrap: true,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatAttributeValue(entry.value),
                          style: Theme.of(context).textTheme.bodyMedium,
                          softWrap: true,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ImportFeatureCommentDialog extends StatefulWidget {
  const _ImportFeatureCommentDialog({required this.feature});

  final ImportedFeature feature;

  @override
  State<_ImportFeatureCommentDialog> createState() =>
      _ImportFeatureCommentDialogState();
}

class _ImportFeatureCommentDialogState
    extends State<_ImportFeatureCommentDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add feature comment'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _importFeatureTitle(widget.feature),
            style: Theme.of(context).textTheme.titleSmall,
            softWrap: true,
          ),
          const SizedBox(height: AppSpacing.sm),
          AppTextField(
            label: 'Comment',
            controller: _controller,
            hint: 'Add a review note for this imported feature.',
            minLines: 3,
            maxLines: 6,
            onChanged: (_) => setState(() {}),
            textCapitalization: TextCapitalization.sentences,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _controller.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Save comment'),
        ),
      ],
    );
  }
}

class _ImportFeatureReviewReasonDialog extends StatefulWidget {
  const _ImportFeatureReviewReasonDialog();

  @override
  State<_ImportFeatureReviewReasonDialog> createState() =>
      _ImportFeatureReviewReasonDialogState();
}

class _ImportFeatureReviewReasonDialogState
    extends State<_ImportFeatureReviewReasonDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reject feature'),
      content: AppTextField(
        label: 'Reason (optional)',
        controller: _controller,
        hint: 'Explain why this imported feature is being rejected.',
        minLines: 3,
        maxLines: 5,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.sm),
          child,
        ],
      ),
    );
  }
}

class _ValidationIssueGroup extends StatelessWidget {
  const _ValidationIssueGroup({
    required this.title,
    required this.icon,
    required this.toneColor,
    required this.messages,
  });

  final String title;
  final IconData icon;
  final Color toneColor;
  final List<String> messages;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: toneColor, size: 18),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final message in messages) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Icon(Icons.circle, size: 7, color: toneColor),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    message,
                    softWrap: true,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            if (message != messages.last) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _ImportFeatureStatusChip extends StatelessWidget {
  const _ImportFeatureStatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _statusLabel(status),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MapWorkspaceCompactNotice extends StatelessWidget {
  const _MapWorkspaceCompactNotice({
    required this.icon,
    required this.message,
    required this.toneColor,
  });

  final IconData icon;
  final String message;
  final Color toneColor;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 3,
      color: toneColor.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: toneColor, size: 15),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MapPanelIconButton extends StatelessWidget {
  const _MapPanelIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: scheme.secondaryContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onPressed,
          child: SizedBox(width: 30, height: 30, child: Icon(icon, size: 16)),
        ),
      ),
    );
  }
}

class _MapStyleMenuButton extends StatelessWidget {
  const _MapStyleMenuButton({
    required this.basemapStyle,
    required this.onSelected,
  });

  final LebanonBasemapStyle basemapStyle;
  final ValueChanged<LebanonBasemapStyle> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<LebanonBasemapStyle>(
      tooltip: 'Map style',
      onSelected: onSelected,
      itemBuilder: (context) => <PopupMenuEntry<LebanonBasemapStyle>>[
        for (final style in LebanonBasemapStyle.values)
          PopupMenuItem<LebanonBasemapStyle>(
            value: style,
            child: SizedBox(
              width: 210,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(_basemapStyleIcon(style), size: 18),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(LebanonMapConfig.basemapLabel(style)),
                        const SizedBox(height: 2),
                        Text(
                          LebanonMapConfig.basemapDescription(style),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (style == basemapStyle) ...[
                    const SizedBox(width: AppSpacing.sm),
                    Icon(Icons.check_rounded, size: 18, color: scheme.primary),
                  ],
                ],
              ),
            ),
          ),
      ],
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.secondaryContainer.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(12),
        ),
        child: SizedBox(
          width: 30,
          height: 30,
          child: Icon(_basemapStyleIcon(basemapStyle), size: 16),
        ),
      ),
    );
  }
}

IconData _basemapStyleIcon(LebanonBasemapStyle style) {
  switch (style) {
    case LebanonBasemapStyle.street:
      return Icons.map_outlined;
    case LebanonBasemapStyle.satellite:
      return Icons.satellite_alt_outlined;
  }
}

enum _ProjectMapOverflowAction { hideTools }

class _ProjectMapOverflowMenuButton extends StatelessWidget {
  const _ProjectMapOverflowMenuButton({required this.onHidePanel});

  final VoidCallback onHidePanel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<_ProjectMapOverflowAction>(
      tooltip: 'More map tools',
      onSelected: (action) {
        switch (action) {
          case _ProjectMapOverflowAction.hideTools:
            onHidePanel();
            break;
        }
      },
      itemBuilder: (context) =>
          const <PopupMenuEntry<_ProjectMapOverflowAction>>[
            PopupMenuItem<_ProjectMapOverflowAction>(
              value: _ProjectMapOverflowAction.hideTools,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.visibility_off_outlined, size: 18),
                title: Text('Hide map tools'),
              ),
            ),
          ],
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.secondaryContainer.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(13),
        ),
        child: const SizedBox(
          width: 32,
          height: 32,
          child: Icon(Icons.more_horiz_rounded, size: 16),
        ),
      ),
    );
  }
}

class _CompactMapMetaPill extends StatelessWidget {
  const _CompactMapMetaPill({
    required this.icon,
    required this.label,
    this.textStyle,
    this.maxWidth = 110,
  });

  final IconData icon;
  final String label;
  final TextStyle? textStyle;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(999),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth + 40),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: scheme.primary),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MapInfoPill extends StatelessWidget {
  const _MapInfoPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodySmall,
                softWrap: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportMarkerPlacements {
  const _ImportMarkerPlacements({
    required this.stagedPoints,
    required this.projectPoints,
  });

  final Map<String, LatLng> stagedPoints;
  final Map<String, LatLng> projectPoints;
}

enum _MarkerSeedKind { staged, project }

class _MarkerPlacementSeed {
  const _MarkerPlacementSeed.staged({required this.id, required this.point})
    : kind = _MarkerSeedKind.staged;

  const _MarkerPlacementSeed.project({required this.id, required this.point})
    : kind = _MarkerSeedKind.project;

  final _MarkerSeedKind kind;
  final String id;
  final LatLng point;
}

class _GroupedMapRailDivider extends StatelessWidget {
  const _GroupedMapRailDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 0.8,
      indent: 8,
      endIndent: 8,
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}

class _GroupedMapRailButton extends StatelessWidget {
  const _GroupedMapRailButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.isTop = false,
    this.isBottom = false,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Widget icon;
  final bool isTop;
  final bool isBottom;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.vertical(
      top: isTop ? const Radius.circular(22) : Radius.zero,
      bottom: isBottom ? const Radius.circular(22) : Radius.zero,
    );
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          onTap: onPressed,
          child: SizedBox(width: 44, height: 42, child: Center(child: icon)),
        ),
      ),
    );
  }
}

class _MapFloatingActionButton extends StatelessWidget {
  const _MapFloatingActionButton({
    required this.tooltip,
    required this.onPressed,
    required this.child,
    this.badgeLabel,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Widget child;
  final String? badgeLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        elevation: 6,
        color: scheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onPressed,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Center(child: child),
                if (badgeLabel != null)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1.5,
                        ),
                        child: Text(
                          badgeLabel!,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: scheme.onPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
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
    case 'failed':
      return 'Failed';
    default:
      return _labelize(status);
  }
}

String _featureTypeFilterLabel(String geometryType) {
  switch (geometryType) {
    case 'point':
    case 'Point':
    case 'MultiPoint':
      return 'Point';
    case 'line':
    case 'LineString':
    case 'MultiLineString':
      return 'Line';
    case 'polygon':
    case 'Polygon':
    case 'MultiPolygon':
      return 'Polygon';
    default:
      return geometryType;
  }
}

String _featureTypeDisplayLabel(String geometryType) {
  switch (geometryType) {
    case 'point':
    case 'Point':
    case 'MultiPoint':
      return 'Point feature';
    case 'line':
    case 'LineString':
    case 'MultiLineString':
      return 'Line feature';
    case 'polygon':
    case 'Polygon':
    case 'MultiPolygon':
      return 'Polygon feature';
    default:
      return _featureTypeFilterLabel(geometryType);
  }
}

Color _statusColor(String status) {
  switch (status) {
    case 'pending_review':
      return const Color(0xFFE67E22);
    case 'approved':
      return const Color(0xFF2E7D32);
    case 'rejected':
      return const Color(0xFFC62828);
    case 'failed':
      return const Color(0xFF7B1FA2);
    default:
      return const Color(0xFF546E7A);
  }
}

IconData _statusIcon(String status) {
  switch (status) {
    case 'approved':
      return Icons.check;
    case 'rejected':
      return Icons.close;
    case 'failed':
      return Icons.priority_high_rounded;
    case 'pending_review':
      return Icons.schedule;
    default:
      return Icons.circle;
  }
}

String _importedFeatureSubtitle(ImportedFeature feature) {
  final type = _featureTypeDisplayLabel(
    feature.geometryType ?? feature.geometry?['type']?.toString() ?? 'Unknown',
  );
  final sourceName = feature.sourceFeatureName?.trim();
  if (sourceName != null && sourceName.isNotEmpty) {
    return '$type • $sourceName';
  }
  return type;
}

String _importFeatureTitle(ImportedFeature feature) {
  final title = feature.displayTitle.trim();
  final lower = title.toLowerCase();
  final typeLabel = _featureTypeDisplayLabel(
    feature.geometryType ?? feature.geometry?['type']?.toString() ?? 'Feature',
  );
  if (lower == 'point' ||
      lower == 'multipoint' ||
      lower == 'linestring' ||
      lower == 'multilinestring' ||
      lower == 'polygon' ||
      lower == 'multipolygon') {
    return typeLabel;
  }
  final replacements = <String, String>{
    'imported point ': 'Point feature ',
    'imported points ': 'Point feature ',
    'imported line ': 'Line feature ',
    'imported lines ': 'Line feature ',
    'imported area ': 'Polygon feature ',
    'imported areas ': 'Polygon feature ',
  };
  for (final entry in replacements.entries) {
    if (lower.startsWith(entry.key)) {
      return '${entry.value}${title.substring(entry.key.length)}'.trim();
    }
  }
  return title;
}

String _projectFeatureTitle(MapFeatureSummary feature) {
  const preferredKeys = <String>['name', 'title', 'label', 'feature_type'];
  for (final key in preferredKeys) {
    final raw = feature.attributes[key];
    if (raw == null) {
      continue;
    }
    final text = '$raw'.trim();
    if (text.isNotEmpty) {
      return text;
    }
  }
  final type = _featureTypeDisplayLabel(
    feature.geometry['type']?.toString() ?? 'Feature',
  );
  final suffix = feature.id.length > 8
      ? feature.id.substring(0, 8)
      : feature.id;
  return '$type $suffix';
}

String _approvedProjectFeatureSubtitle(MapFeatureSummary feature) {
  final details = <String>[
    _featureTypeDisplayLabel(
      feature.geometry['type']?.toString() ?? 'Geometry',
    ),
    '${feature.photoCount} photo(s)',
  ];
  if (feature.collectedBy?.trim().isNotEmpty ?? false) {
    details.add('Collector ${feature.collectedBy!.trim()}');
  }
  return details.join(' • ');
}

Map<String, dynamic> _filteredImportAttributes(
  Map<String, dynamic> attributes,
) {
  final filtered = <String, dynamic>{};
  for (final entry in attributes.entries) {
    if (_shouldHideImportAttributeKey(entry.key)) {
      continue;
    }
    filtered[entry.key] = entry.value;
  }
  return filtered;
}

bool _shouldHideImportAttributeKey(String key) {
  final normalized = key.trim().toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]'),
    '',
  );
  return normalized == 'accuracy' ||
      normalized == 'accuracymeter' ||
      normalized == 'accuracymeters';
}

String _labelize(String value) {
  final normalized = value
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match.group(1)} ${match.group(2)}',
      )
      .replaceAll('_', ' ')
      .replaceAll('-', ' ')
      .trim();
  if (normalized.isEmpty) {
    return value;
  }
  return normalized
      .split(RegExp(r'\s+'))
      .map(
        (part) => part.isEmpty
            ? part
            : '${part[0].toUpperCase()}${part.substring(1)}',
      )
      .join(' ');
}

String _formatAttributeValue(Object? value) {
  if (value == null) {
    return '—';
  }
  if (value is bool) {
    return value ? 'Yes' : 'No';
  }
  if (value is List) {
    if (value.isEmpty) {
      return '—';
    }
    return value.map(_formatAttributeValue).join(', ');
  }
  if (value is Map) {
    if (value.isEmpty) {
      return '—';
    }
    return value.entries
        .map(
          (entry) =>
              '${_labelize('${entry.key}')} : ${_formatAttributeValue(entry.value)}',
        )
        .join(', ');
  }
  final text = '$value'.trim();
  return text.isEmpty ? '—' : text;
}
