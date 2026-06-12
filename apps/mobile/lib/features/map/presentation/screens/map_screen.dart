import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/offline/local_models.dart';
import '../../../../core/pagination/paginated_list_controller.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/utils/lebanon_time.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/sync/sync_controller.dart';
import '../../../../core/widgets/app_action_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_dialog_actions.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/progressive_list_section.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../auth/domain/auth_models.dart';
import '../../../ai/domain/ai_models.dart';
import '../../../ai/presentation/ai_providers.dart';
import '../../../ai/presentation/widgets/ai_uncertainty_task_widgets.dart';
import '../../../projects/domain/project.dart';
import '../../domain/app_tile_provider.dart';
import '../../domain/current_location_service.dart';
import '../../domain/lebanon_map.dart';
import '../../domain/map_feature.dart';
import '../../domain/map_geometry.dart';
import 'add_feature_screen.dart';
import '../widgets/feature_photo_gallery.dart';

const Color _aiValidationTaskColor = Color(0xFFC2185B);

enum _OfflineMapAction {
  saveOverview,
  saveVisibleArea,
  refreshSavedImagery,
  deleteSavedImagery,
}

class _OfflineSheetUiState {
  const _OfflineSheetUiState({
    this.isDownloading = false,
    this.activeAction,
    this.progressLabel,
    this.progressValue,
    this.statusLabel,
  });

  final bool isDownloading;
  final _OfflineMapAction? activeAction;
  final String? progressLabel;
  final double? progressValue;
  final String? statusLabel;
}

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({
    this.initialProjectId,
    this.initialFeatureId,
    this.initialAiTaskId,
    this.initialFeatureSource,
    this.startCaptureOnOpen = false,
    this.lockProjectSelection = false,
    super.key,
  });

  final String? initialProjectId;
  final String? initialFeatureId;
  final String? initialAiTaskId;
  final String? initialFeatureSource;
  final bool startCaptureOnOpen;
  final bool lockProjectSelection;

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  static const String _noOfficialFeatureFilter = '__none_official_features__';
  static const List<String> _projectMapStatusOrder = <String>[
    'approved',
    'pending_review',
    'rejected',
    'draft',
  ];

  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _projectMapSearchFocusNode = FocusNode();
  final ValueNotifier<_OfflineSheetUiState> _offlineSheetUiState =
      ValueNotifier<_OfflineSheetUiState>(const _OfflineSheetUiState());
  final LayerHitNotifier<MapFeatureSummary> _projectPolygonHitNotifier =
      ValueNotifier(null);
  final LayerHitNotifier<MapFeatureSummary> _projectPolylineHitNotifier =
      ValueNotifier(null);
  final LayerHitNotifier<_PublishedAiMapFeature>
  _publishedAiPolygonHitNotifier = ValueNotifier(null);
  final LayerHitNotifier<_PublishedAiMapFeature>
  _publishedAiPolylineHitNotifier = ValueNotifier(null);
  final LayerHitNotifier<AiUncertaintyArea>
  _aiValidationTaskPolygonHitNotifier = ValueNotifier(null);
  final LayerHitNotifier<AiUncertaintyArea>
  _aiValidationTaskPolylineHitNotifier = ValueNotifier(null);
  final Set<String> _visibleStatuses = Set<String>.from(_projectMapStatusOrder);
  final List<LatLng> _captureVertices = <LatLng>[];
  final Map<String, Future<_OfflineTileAssets?>> _offlineTileAssetsFutureCache =
      <String, Future<_OfflineTileAssets?>>{};

  String? _selectedProjectId;
  String? _selectedFeatureChip;
  String? _tileFailureMessage;
  String? _locationNoticeMessage;
  String? _autoOpenedFeatureId;
  String? _autoOpenedAiValidationTaskId;
  String? _focusedFeatureId;
  String? _focusedAiValidationTaskId;
  String? _offlineDownloadProgressLabel;
  String? _offlineDownloadResultLabel;
  double? _offlineDownloadProgressValue;
  _OfflineMapAction? _activeOfflineMapAction;
  LatLng? _currentLocation;
  double? _currentLocationAccuracyMeters;
  bool _isDownloadingOffline = false;
  bool _isMainMapReady = false;
  bool _isLocating = false;
  bool _isPrimingProjectMapTiles = false;
  bool _isWarmingProjectMapSurface = false;
  bool _isRecoveringProjectMapVisibleTiles = false;
  bool _isProjectMapPanelVisible = true;
  bool _projectMapPanelExpanded = false;
  bool _projectMapSearchOpen = false;
  bool _isProjectMapCaptureMode = false;
  bool _isProjectMapGeometryChooserOpen = false;
  bool _isProjectMapModalSheetOpen = false;
  bool _showPublishedAiLayers = false;
  Set<String> _visiblePublishedAiLayerTypes = const <String>{
    'classification',
    'confidence',
    'uncertainty',
  };
  String? _selectedPublishedAiClass;
  List<String> _stablePublishedAiClassOptions = const <String>[];
  Map<String, int> _stablePublishedAiLayerCounts = const <String, int>{};
  Map<String, Map<String, int>> _stablePublishedAiLayerClassCounts =
      const <String, Map<String, int>>{};
  String? _focusedPublishedAiFeatureKey;
  _PublishedAiMapFeature? _focusedPublishedAiFeatureOverride;
  bool _hasHandledStartCaptureOnOpen = false;
  LebanonBasemapStyle _basemapStyle = LebanonBasemapStyle.street;
  MapCamera? _latestMapCamera;
  String? _lastAutoFrameKey;
  String? _lastPrimedProjectMapKey;
  String? _lastProjectMapSurfaceWarmupKey;
  String? _lastVisibleTileRecoveryKey;
  VoidCallback? _pendingMainMapAction;
  String? _captureGeometryType;
  double? _captureGpsAccuracyMeters;
  List<String> _projectMapGeometryTypeOptions = const <String>[];
  bool _tileFailureUsesSavedImagery = false;
  int _projectMapTileFailureCount = 0;
  String? _projectMapTileFailureBurstKey;
  Timer? _locationNoticeTimer;
  Timer? _tileNoticeTimer;
  Timer? _basemapTransitionTimer;
  late final MapOptions _mainMapOptions;
  bool _isBasemapTransitioning = false;
  Timer? _viewportRefreshTimer;
  ProjectMapViewportQuery? _projectViewportQuery;
  List<MapFeatureSummary>? _lastViewportFeatures;

  LatLng get _defaultMapCenter => LebanonMapConfig.center;

  double get _defaultMapZoom => LebanonMapConfig.fullscreenInitialZoom;

  double get _mapMinZoom => LebanonMapConfig.fullscreenMinZoom;

  double get _mapMaxZoom => LebanonMapConfig.fullscreenMaxZoom;

  @override
  void initState() {
    super.initState();
    _publishOfflineSheetState();
    _mainMapOptions = MapOptions(
      initialCenter: _defaultMapCenter,
      initialZoom: _defaultMapZoom,
      initialCameraFit: widget.lockProjectSelection
          ? LebanonMapConfig.fullscreenFit
          : null,
      minZoom: _mapMinZoom,
      maxZoom: _mapMaxZoom,
      cameraConstraint: widget.lockProjectSelection
          ? CameraConstraint.containCenter(bounds: LebanonMapConfig.bounds)
          : LebanonMapConfig.cameraConstraint,
      onMapReady: _handleMainMapReady,
      onPositionChanged: _handleMainMapPositionChanged,
      onTap: _handleMainMapTap,
    );
  }

  @override
  void didUpdateWidget(covariant MapScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousTarget = oldWidget.initialFeatureId?.trim();
    final nextTarget = widget.initialFeatureId?.trim();
    final previousAiTaskTarget = oldWidget.initialAiTaskId?.trim();
    final nextAiTaskTarget = widget.initialAiTaskId?.trim();
    if (previousTarget != nextTarget ||
        oldWidget.initialFeatureSource != widget.initialFeatureSource) {
      _autoOpenedFeatureId = null;
      _focusedFeatureId = (nextTarget?.isEmpty ?? true) ? null : nextTarget;
      _lastAutoFrameKey = null;
    }
    if (previousAiTaskTarget != nextAiTaskTarget ||
        oldWidget.initialFeatureSource != widget.initialFeatureSource) {
      _autoOpenedAiValidationTaskId = null;
      _focusedAiValidationTaskId = (nextAiTaskTarget?.isEmpty ?? true)
          ? null
          : nextAiTaskTarget;
      _lastAutoFrameKey = null;
    }
  }

  bool get _isProjectMapSecondaryOverlayOpen =>
      _isProjectMapGeometryChooserOpen || _isProjectMapModalSheetOpen;

  void _publishOfflineSheetState() {
    _offlineSheetUiState.value = _OfflineSheetUiState(
      isDownloading: _isDownloadingOffline,
      activeAction: _activeOfflineMapAction,
      progressLabel: _offlineDownloadProgressLabel,
      progressValue: _offlineDownloadProgressValue,
      statusLabel: _offlineDownloadResultLabel,
    );
  }

  void _moveToProjectWorkspace() {
    if (!mounted) {
      return;
    }
    _clearTileNotice();
    _lastProjectMapSurfaceWarmupKey = null;
    _lastVisibleTileRecoveryKey = null;
    _projectMapTileFailureCount = 0;
    _projectMapTileFailureBurstKey = null;
    _mapController.fitCamera(LebanonMapConfig.fullscreenFit);
  }

  bool _hasSavedOfflineImagery(OfflineMapPackage? package) =>
      (package?.tileCount ?? 0) > 0;

  Color _projectMapSurfaceFallbackColor() {
    switch (_basemapStyle) {
      case LebanonBasemapStyle.street:
        return const Color(0xFFECE3D3);
      case LebanonBasemapStyle.satellite:
        return const Color(0xFFB3C2C7);
    }
  }

  Duration _basemapTransitionDuration(LebanonBasemapStyle style) {
    switch (style) {
      case LebanonBasemapStyle.satellite:
        return const Duration(milliseconds: 1500);
      case LebanonBasemapStyle.street:
        return const Duration(milliseconds: 900);
    }
  }

  void _setProjectMapBasemapStyle(LebanonBasemapStyle style) {
    if (_basemapStyle == style && !_isBasemapTransitioning) {
      return;
    }
    _basemapTransitionTimer?.cancel();
    _projectMapSearchFocusNode.unfocus();
    if (!mounted) {
      return;
    }
    setState(() {
      _basemapStyle = style;
      _isBasemapTransitioning = true;
      _tileFailureMessage = null;
      _tileFailureUsesSavedImagery = false;
      _projectMapTileFailureCount = 0;
      _projectMapTileFailureBurstKey = null;
    });
    _basemapTransitionTimer = Timer(_basemapTransitionDuration(style), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _isBasemapTransitioning = false;
      });
    });
  }

  String _savedImageryFallbackNotice() {
    return 'Using saved map imagery for this area while live tiles reconnect.';
  }

  void _notifyProjectMapTileFailure({
    required OfflineMapPackage? offlinePackage,
    required bool hasSavedOfflineImagery,
  }) {
    if (_isBasemapTransitioning) {
      return;
    }
    if (!hasSavedOfflineImagery) {
      return;
    }
    final camera = _latestMapCamera;
    final burstKey = [
      _basemapStyle.name,
      camera?.zoom.floor() ?? -1,
      camera?.center.latitude.toStringAsFixed(2) ?? 'na',
      camera?.center.longitude.toStringAsFixed(2) ?? 'na',
    ].join(':');
    if (_projectMapTileFailureBurstKey != burstKey) {
      _projectMapTileFailureBurstKey = burstKey;
      _projectMapTileFailureCount = 0;
    }
    _projectMapTileFailureCount += 1;
    if (_projectMapTileFailureCount < 12) {
      return;
    }
    _scheduleProjectMapVisibleTileRecovery(offlinePackage);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _tileFailureMessage != null) {
        return;
      }
      _showTileNotice(_savedImageryFallbackNotice(), usesSavedImagery: true);
    });
  }

  void _clearLocationNotice() {
    _locationNoticeTimer?.cancel();
    _locationNoticeTimer = null;
    if (!mounted || _locationNoticeMessage == null) {
      return;
    }
    setState(() {
      _locationNoticeMessage = null;
    });
  }

  void _showLocationNotice(
    String message, {
    Duration duration = const Duration(seconds: 4),
  }) {
    _locationNoticeTimer?.cancel();
    if (!mounted) {
      return;
    }
    setState(() {
      _locationNoticeMessage = message;
    });
    _locationNoticeTimer = Timer(duration, () {
      if (!mounted) {
        return;
      }
      setState(() {
        if (_locationNoticeMessage == message) {
          _locationNoticeMessage = null;
        }
      });
    });
  }

  void _clearTileNotice() {
    _tileNoticeTimer?.cancel();
    _tileNoticeTimer = null;
    _projectMapTileFailureCount = 0;
    _projectMapTileFailureBurstKey = null;
    if (!mounted ||
        (_tileFailureMessage == null && !_tileFailureUsesSavedImagery)) {
      return;
    }
    setState(() {
      _tileFailureMessage = null;
      _tileFailureUsesSavedImagery = false;
    });
  }

  void _showTileNotice(
    String message, {
    required bool usesSavedImagery,
    Duration duration = const Duration(seconds: 5),
  }) {
    _tileNoticeTimer?.cancel();
    if (!mounted) {
      return;
    }
    setState(() {
      _tileFailureMessage = message;
      _tileFailureUsesSavedImagery = usesSavedImagery;
    });
    _tileNoticeTimer = Timer(duration, () {
      if (!mounted) {
        return;
      }
      setState(() {
        if (_tileFailureMessage == message) {
          _tileFailureMessage = null;
          _tileFailureUsesSavedImagery = false;
        }
      });
    });
  }

  Future<_OfflineTileAssets?> _offlineTileAssetsFuture(
    OfflineMapPackage? package,
  ) {
    if (package == null) {
      return Future<_OfflineTileAssets?>.value(null);
    }
    final key = '${package.version}:${_basemapStyle.name}';
    return _offlineTileAssetsFutureCache.putIfAbsent(
      key,
      () => _loadOfflineTileAssets(package, _basemapStyle),
    );
  }

  void _invalidateOfflineTileAssetsCache({
    OfflineMapPackage? package,
    LebanonBasemapStyle? basemapStyle,
  }) {
    if (package == null) {
      _offlineTileAssetsFutureCache.clear();
      return;
    }
    final style = basemapStyle ?? _basemapStyle;
    final key = '${package.version}:${style.name}';
    _offlineTileAssetsFutureCache.remove(key);
  }

  @override
  void dispose() {
    _locationNoticeTimer?.cancel();
    _tileNoticeTimer?.cancel();
    _basemapTransitionTimer?.cancel();
    _viewportRefreshTimer?.cancel();
    _offlineSheetUiState.dispose();
    _projectPolygonHitNotifier.dispose();
    _projectPolylineHitNotifier.dispose();
    _publishedAiPolygonHitNotifier.dispose();
    _publishedAiPolylineHitNotifier.dispose();
    _aiValidationTaskPolygonHitNotifier.dispose();
    _aiValidationTaskPolylineHitNotifier.dispose();
    _searchController.dispose();
    _projectMapSearchFocusNode.dispose();
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
    if (!_isMainMapReady && mounted) {
      setState(() {
        _isMainMapReady = true;
      });
    }
    final pendingAction = _pendingMainMapAction;
    if (pendingAction != null) {
      _pendingMainMapAction = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _runMainMapAction(pendingAction, queueUntilReady: true);
      });
    }
    _scheduleViewportRefresh();
  }

  void _scheduleViewportRefresh() {
    _viewportRefreshTimer?.cancel();
    _viewportRefreshTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) {
        return;
      }
      final projectId = _selectedProjectId ?? widget.initialProjectId;
      if (projectId == null || projectId.isEmpty) {
        return;
      }
      final nextQuery = _buildProjectViewportQuery(projectId);
      setState(() {
        if (_projectViewportQuery != nextQuery) {
          _projectViewportQuery = nextQuery;
        }
      });
    });
  }

  ProjectMapViewportQuery _buildProjectViewportQuery(String projectId) {
    final bounds = _latestMapCamera?.visibleBounds ?? LebanonMapConfig.bounds;
    final zoom = _latestMapCamera?.zoom ?? _defaultMapZoom;
    final precision = zoom >= 12 ? 4 : 3;
    double normalize(double value) =>
        double.parse(value.toStringAsFixed(precision));
    return ProjectMapViewportQuery(
      projectId: projectId,
      minLon: normalize(bounds.southWest.longitude),
      minLat: normalize(bounds.southWest.latitude),
      maxLon: normalize(bounds.northEast.longitude),
      maxLat: normalize(bounds.northEast.latitude),
      zoom: double.parse(zoom.toStringAsFixed(2)),
      featureType: _selectedFeatureChip == _noOfficialFeatureFilter
          ? null
          : _selectedFeatureChip,
    );
  }

  void _scheduleProjectMapTilePrime(OfflineMapPackage? offlinePackage) {
    if (!widget.lockProjectSelection || offlinePackage == null) {
      return;
    }

    final primeKey = '${offlinePackage.version}:${_basemapStyle.name}';
    if (_isPrimingProjectMapTiles || _lastPrimedProjectMapKey == primeKey) {
      return;
    }

    _isPrimingProjectMapTiles = true;
    _lastPrimedProjectMapKey = primeKey;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final manager = ref.read(offlineTileCacheManagerProvider);
        final summary = await manager.cacheLebanonOverview(
          package: offlinePackage,
          basemapStyle: _basemapStyle,
        );
        await manager.refreshStats(offlinePackage, basemapStyle: _basemapStyle);
        ref.invalidate(offlineMapPackageProvider);
        if (!mounted) {
          return;
        }
        if (summary.downloadedTiles > 0 || summary.skippedTiles > 0) {
          _clearTileNotice();
        }
      } catch (_) {
        if (mounted) {
          final hasSavedOfflineImagery = _hasSavedOfflineImagery(
            offlinePackage,
          );
          if (hasSavedOfflineImagery) {
            _showTileNotice(
              _savedImageryFallbackNotice(),
              usesSavedImagery: true,
            );
          }
        }
      } finally {
        _isPrimingProjectMapTiles = false;
      }
    });
  }

  void _scheduleProjectMapSurfaceWarmup(OfflineMapPackage? offlinePackage) {
    if (!widget.lockProjectSelection ||
        offlinePackage == null ||
        !_isMainMapReady ||
        _isWarmingProjectMapSurface ||
        _isProjectMapSecondaryOverlayOpen) {
      return;
    }

    final camera = _latestMapCamera;
    if (camera == null) {
      return;
    }

    final warmupKey =
        '${offlinePackage.version}:${_basemapStyle.name}:${camera.zoom.floor()}:${camera.center.latitude.toStringAsFixed(3)}:${camera.center.longitude.toStringAsFixed(3)}';
    if (_lastProjectMapSurfaceWarmupKey == warmupKey) {
      return;
    }

    _isWarmingProjectMapSurface = true;
    _lastProjectMapSurfaceWarmupKey = warmupKey;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final manager = ref.read(offlineTileCacheManagerProvider);
        await manager.cacheVisibleRegion(
          package: offlinePackage,
          basemapStyle: _basemapStyle,
          bounds: camera.visibleBounds,
          currentZoom: camera.zoom,
        );
        await manager.refreshStats(offlinePackage, basemapStyle: _basemapStyle);
        ref.invalidate(offlineMapPackageProvider);
      } catch (_) {
        // Keep the map usable even if the warmup request cannot complete.
      } finally {
        _isWarmingProjectMapSurface = false;
      }
    });
  }

  void _scheduleProjectMapVisibleTileRecovery(
    OfflineMapPackage? offlinePackage,
  ) {
    if (!widget.lockProjectSelection ||
        offlinePackage == null ||
        _isRecoveringProjectMapVisibleTiles) {
      return;
    }

    final camera = _latestMapCamera;
    if (camera == null) {
      return;
    }

    final recoveryKey =
        '${offlinePackage.version}:${_basemapStyle.name}:${camera.zoom.floor()}:${camera.center.latitude.toStringAsFixed(3)}:${camera.center.longitude.toStringAsFixed(3)}';
    if (_lastVisibleTileRecoveryKey == recoveryKey) {
      return;
    }

    _isRecoveringProjectMapVisibleTiles = true;
    _lastVisibleTileRecoveryKey = recoveryKey;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final manager = ref.read(offlineTileCacheManagerProvider);
        final summary = await manager.cacheVisibleRegion(
          package: offlinePackage,
          basemapStyle: _basemapStyle,
          bounds: camera.visibleBounds,
          currentZoom: camera.zoom,
        );
        await manager.refreshStats(offlinePackage, basemapStyle: _basemapStyle);
        ref.invalidate(offlineMapPackageProvider);
        if (!mounted) {
          return;
        }
        if (summary.downloadedTiles > 0 || summary.skippedTiles > 0) {
          _clearTileNotice();
        }
      } catch (_) {
        if (mounted) {
          final hasSavedOfflineImagery = _hasSavedOfflineImagery(
            offlinePackage,
          );
          if (hasSavedOfflineImagery) {
            _showTileNotice(
              _savedImageryFallbackNotice(),
              usesSavedImagery: true,
            );
          }
        }
      } finally {
        _isRecoveringProjectMapVisibleTiles = false;
      }
    });
  }

  void _handleMainMapTap(TapPosition tapPosition, LatLng point) {
    if (_isProjectMapCaptureMode && widget.lockProjectSelection) {
      _handleProjectMapCaptureTap(point);
      return;
    }
    if (!widget.lockProjectSelection) {
      _projectMapSearchFocusNode.unfocus();
      return;
    }
    if (_projectMapSearchOpen || _projectMapPanelExpanded) {
      _setProjectMapPanelState(searchOpen: false, expanded: false);
      return;
    }
    _projectMapSearchFocusNode.unfocus();
  }

  void _setProjectMapPanelVisible(bool visible) {
    if (!mounted) {
      return;
    }
    setState(() {
      _isProjectMapPanelVisible = visible;
      if (!visible) {
        _projectMapPanelExpanded = false;
        _projectMapSearchOpen = false;
      }
    });
    if (!visible) {
      _projectMapSearchFocusNode.unfocus();
    }
  }

  void _setProjectMapPanelState({
    bool? visible,
    bool? expanded,
    bool? searchOpen,
    bool focusSearch = false,
  }) {
    if (!mounted) {
      return;
    }
    setState(() {
      if (visible != null) {
        _isProjectMapPanelVisible = visible;
      }
      if (expanded != null) {
        _projectMapPanelExpanded = expanded;
      }
      if (searchOpen != null) {
        _projectMapSearchOpen = searchOpen;
      }
    });
    if (!_projectMapSearchOpen) {
      _projectMapSearchFocusNode.unfocus();
      return;
    }
    if (focusSearch) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _projectMapSearchFocusNode.requestFocus();
      });
    }
  }

  bool get _hasAllVisibleStatusesSelected =>
      _visibleStatuses.length == _projectMapStatusOrder.length;

  bool get _hasInitialFeatureTarget =>
      _initialFeatureId?.trim().isNotEmpty == true;

  String? get _initialFeatureId {
    final featureId = widget.initialFeatureId?.trim();
    if (featureId == null || featureId.isEmpty) {
      return null;
    }
    return featureId;
  }

  String? get _initialAiTaskId {
    final taskId = widget.initialAiTaskId?.trim();
    if (taskId == null || taskId.isEmpty) {
      return null;
    }
    return taskId;
  }

  void _focusLebanonWorkspace({bool queueUntilReady = false}) {
    if (!_isMainMapReady) {
      if (queueUntilReady) {
        _pendingMainMapAction = _moveToProjectWorkspace;
        return;
      }
      AppSnackbar.showError(
        context,
        'Map is still preparing. Please try again in a moment.',
      );
      return;
    }
    _runMainMapAction(
      _moveToProjectWorkspace,
      queueUntilReady: queueUntilReady,
    );
  }

  void _zoomProjectWorkspaceBy(double delta) {
    _runMainMapAction(
      () => _mapController.move(
        _latestMapCamera?.center ?? _defaultMapCenter,
        ((_latestMapCamera?.zoom ?? _defaultMapZoom) + delta)
            .clamp(_mapMinZoom, _mapMaxZoom)
            .toDouble(),
      ),
      queueUntilReady: true,
    );
  }

  String _visibleStatusSummaryLabel() {
    if (_hasAllVisibleStatusesSelected) {
      return 'All statuses';
    }
    final visibleLabels = _projectMapStatusOrder
        .where(_visibleStatuses.contains)
        .map(_statusFilterLabel)
        .toList(growable: false);
    if (visibleLabels.isEmpty) {
      return 'No status';
    }
    if (visibleLabels.length == 1) {
      return visibleLabels.first;
    }
    return '${visibleLabels.first} +${visibleLabels.length - 1}';
  }

  String? _searchSummaryLabel() {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      return null;
    }
    if (query.length <= 18) {
      return query;
    }
    return '${query.substring(0, 18)}…';
  }

  void _resetVisibleStatuses() {
    setState(() {
      _visibleStatuses
        ..clear()
        ..addAll(_projectMapStatusOrder);
    });
  }

  void _toggleVisibleStatus(String status) {
    setState(() {
      final isOnlySelected =
          _visibleStatuses.length == 1 && _visibleStatuses.contains(status);
      if (_hasAllVisibleStatusesSelected) {
        _visibleStatuses
          ..clear()
          ..add(status);
        return;
      }
      if (isOnlySelected) {
        _visibleStatuses
          ..clear()
          ..addAll(_projectMapStatusOrder);
        return;
      }
      _visibleStatuses
        ..clear()
        ..add(status);
    });
  }

  List<String> _supportedProjectGeometryTypes(ProjectSummary project) {
    return project.allowedGeometryTypes
        .where(
          (type) =>
              type == 'Point' || type == 'LineString' || type == 'Polygon',
        )
        .toList(growable: false);
  }

  Future<void> _startProjectMapFeatureCapture(ProjectSummary project) async {
    final supportedGeometryTypes = _supportedProjectGeometryTypes(project);
    if (supportedGeometryTypes.isEmpty) {
      AppSnackbar.showError(
        context,
        'This project does not support mobile geometry capture.',
      );
      return;
    }

    if (supportedGeometryTypes.length == 1) {
      _enterProjectMapCapture(supportedGeometryTypes.first);
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _isProjectMapGeometryChooserOpen = true;
      _projectMapGeometryTypeOptions = List<String>.from(
        supportedGeometryTypes,
      );
      _projectMapSearchOpen = false;
      _projectMapPanelExpanded = false;
    });
    _clearLocationNotice();
  }

  void _dismissProjectMapGeometryChooser() {
    if (!mounted || !_isProjectMapGeometryChooserOpen) {
      return;
    }
    setState(() {
      _isProjectMapGeometryChooserOpen = false;
      _projectMapGeometryTypeOptions = const <String>[];
    });
  }

  void _enterProjectMapCapture(String selectedGeometryType) {
    if (!mounted) {
      return;
    }
    setState(() {
      _isProjectMapGeometryChooserOpen = false;
      _projectMapGeometryTypeOptions = const <String>[];
      _isProjectMapCaptureMode = true;
      _captureGeometryType = selectedGeometryType;
      _captureVertices.clear();
      _captureGpsAccuracyMeters = _currentLocationAccuracyMeters;
      _projectMapSearchOpen = false;
      _projectMapPanelExpanded = false;
    });
    _clearLocationNotice();
  }

  void _cancelProjectMapFeatureCapture() {
    if (!mounted) {
      return;
    }
    setState(() {
      _isProjectMapGeometryChooserOpen = false;
      _projectMapGeometryTypeOptions = const <String>[];
      _isProjectMapCaptureMode = false;
      _captureGeometryType = null;
      _captureVertices.clear();
      _captureGpsAccuracyMeters = null;
    });
  }

  void _handleProjectMapCaptureTap(LatLng point) {
    if (!LebanonMapConfig.contains(point)) {
      AppSnackbar.showError(
        context,
        'Geometry capture is restricted to Lebanon.',
      );
      return;
    }

    setState(() {
      if ((_captureGeometryType ?? 'Point') == 'Point') {
        _captureVertices
          ..clear()
          ..add(point);
      } else {
        _captureVertices.add(point);
      }
      _captureGpsAccuracyMeters ??= _currentLocationAccuracyMeters;
    });
  }

  void _undoProjectMapCapture() {
    if (_captureVertices.isEmpty) {
      return;
    }
    setState(() {
      _captureVertices.removeLast();
    });
  }

  void _clearProjectMapCapture() {
    if (_captureVertices.isEmpty) {
      return;
    }
    setState(() {
      _captureVertices.clear();
    });
  }

  String? _validateProjectMapCapture() {
    final geometryType = _captureGeometryType ?? 'Point';
    switch (geometryType) {
      case 'LineString':
        return _captureVertices.length >= 2
            ? null
            : 'Add at least two vertices to continue.';
      case 'Polygon':
        return _captureVertices.length >= 3
            ? null
            : 'Add at least three points to continue.';
      case 'Point':
      default:
        return _captureVertices.isNotEmpty
            ? null
            : 'Place the feature on the map to continue.';
    }
  }

  Future<void> _continueProjectMapCapture(ProjectSummary project) async {
    final validationError = _validateProjectMapCapture();
    if (validationError != null) {
      AppSnackbar.showError(context, validationError);
      return;
    }

    final seed = AddFeatureCaptureSeed(
      projectId: project.id,
      geometryType: _captureGeometryType ?? 'Point',
      vertices: List<LatLng>.from(_captureVertices),
      gpsAccuracyMeters: _captureGpsAccuracyMeters,
    );

    final result = await context.push<AddFeatureFlowResult>(
      AppRoutes.addFeatureForProject(project.id),
      extra: seed,
    );
    if (!mounted) {
      return;
    }
    if (result == null || result.shouldResumeCapture) {
      return;
    }

    setState(() {
      _isProjectMapGeometryChooserOpen = false;
      _projectMapGeometryTypeOptions = const <String>[];
      _isProjectMapCaptureMode = false;
      _captureGeometryType = null;
      _captureVertices.clear();
      _captureGpsAccuracyMeters = null;
    });
    if (result.successMessage != null && result.successMessage!.isNotEmpty) {
      AppSnackbar.showSuccess(context, result.successMessage!);
    }
  }

  String _projectMapCaptureInstruction() {
    switch (_captureGeometryType ?? 'Point') {
      case 'LineString':
        return 'Tap the map to trace the line. Use GPS to center yourself first if needed.';
      case 'Polygon':
        return 'Tap the map to trace the boundary. Continue around the area, then move to details.';
      case 'Point':
      default:
        return 'Tap once to place the feature point, or use the location button.';
    }
  }

  String _projectMapCaptureSummary() {
    switch (_captureGeometryType ?? 'Point') {
      case 'LineString':
        return _captureVertices.isEmpty
            ? 'Line not started'
            : 'Line with ${_captureVertices.length} vertex${_captureVertices.length == 1 ? '' : 'es'}';
      case 'Polygon':
        return _captureVertices.isEmpty
            ? 'Boundary not started'
            : 'Polygon outline with ${_captureVertices.length} point${_captureVertices.length == 1 ? '' : 's'}';
      case 'Point':
      default:
        return _captureVertices.isEmpty ? 'Point not placed' : 'Point placed';
    }
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
      if (!_isMainMapReady && mounted) {
        setState(() {
          _isMainMapReady = true;
        });
      }
    } catch (error) {
      if (_isMapControllerLifecycleError(error)) {
        if (!queueUntilReady) {
          AppSnackbar.showError(
            context,
            'Map is still preparing. Please try again in a moment.',
          );
          return;
        }
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

  void _scheduleMainMapCameraAction(VoidCallback action) {
    if (!_isMainMapReady) {
      _pendingMainMapAction = action;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _runMainMapAction(action, queueUntilReady: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authControllerProvider).session;
    final role = session?.user.role ?? UserRole.viewer;
    final isUserRole = role == UserRole.viewer;
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
                'Projects appear here once they are user-visible or assigned to your account.',
          );
        }

        final project = _resolveSelectedProject(
          availableProjects,
          requestedProjectId: widget.initialProjectId,
        );
        final publishedAiLayersAsync = ref.watch(
          publishedAiLayersProvider(project.id),
        );
        final assignedAiValidationTasksAsync = role == UserRole.contributor
            ? ref.watch(
                myAiValidationTasksProvider(const AiUncertaintyTasksQuery()),
              )
            : null;
        final focusedAiValidationTaskId = _initialAiTaskId;
        final focusedAiValidationTaskAsync = focusedAiValidationTaskId == null
            ? null
            : ref.watch(aiUncertaintyAreaProvider(focusedAiValidationTaskId));
        _selectedProjectId ??= project.id;
        final viewportQuery =
            _projectViewportQuery ?? _buildProjectViewportQuery(project.id);
        final featuresAsync = ref.watch(
          projectMapViewportFeaturesProvider(viewportQuery),
        );
        if (featuresAsync.valueOrNull != null) {
          _lastViewportFeatures = featuresAsync.valueOrNull;
        }
        final offlineMapPackageAsync = ref.watch(offlineMapPackageProvider);
        final hasContributorAssignment =
            role == UserRole.contributor &&
            project.hasApprovedCurrentUserAssignment;
        final canCollectOnMap =
            hasContributorAssignment && project.status == 'active';
        final canUseOfflineMap = hasContributorAssignment;
        final canReview = role == UserRole.admin;
        _maybeStartProjectMapCaptureOnOpen(
          project: project,
          canCollectOnMap: canCollectOnMap,
        );

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
                        _lastAutoFrameKey = null;
                        _projectViewportQuery = _buildProjectViewportQuery(
                          value,
                        );
                        _lastViewportFeatures = null;
                      });
                      _clearTileNotice();
                      _clearLocationNotice();
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
                      avatar: Icon(_basemapStyleIcon(_basemapStyle), size: 18),
                      label: Text(LebanonMapConfig.basemapLabel(_basemapStyle)),
                    ),
                    if (!isUserRole)
                      Chip(label: Text(project.visibilitySummaryLabel)),
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
                if (!isUserRole) ...[
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
                ],
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
                      onPressed: () {
                        _lastViewportFeatures = null;
                        bumpWorkflowRefresh(ref);
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh'),
                    ),
                  ],
                ),
                if (canUseOfflineMap) ...[
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
                      basemapStyle: _basemapStyle,
                      isDownloading: _isDownloadingOffline,
                      activeAction: _activeOfflineMapAction,
                      progressLabel: _offlineDownloadProgressLabel,
                      progressValue: _offlineDownloadProgressValue,
                      statusLabel: _offlineDownloadResultLabel,
                      onDownloadOverview: offlinePackage == null
                          ? null
                          : () => _downloadLebanonOverview(offlinePackage),
                      onDownloadVisible:
                          offlinePackage == null || !_isMainMapReady
                          ? null
                          : () => _downloadVisibleRegion(offlinePackage),
                      onRefreshSavedImagery: offlinePackage == null
                          ? null
                          : () => _refreshSavedOfflineImagery(offlinePackage),
                      onDeleteSavedImagery: offlinePackage == null
                          ? null
                          : () => _confirmDeleteSavedOfflineImagery(
                              offlinePackage,
                            ),
                    ),
                  ),
                ],
                if (role == UserRole.contributor) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _SyncStatusLine(state: syncState),
                ],
              ],
            ),
          );
        }

        Widget buildWorkspace({Widget? embeddedControls}) {
          Widget buildLoadedWorkspace(List<MapFeatureSummary> features) {
            final aiValidationTasks = _aiValidationTasksForProject(
              projectId: project.id,
              assignedPage: assignedAiValidationTasksAsync?.valueOrNull,
              focusedTask: focusedAiValidationTaskAsync?.valueOrNull,
            );
            final publishedAiLayers = _publishedAiMapLayers(
              publishedAiLayersAsync.valueOrNull ?? const <AiOutputLayer>[],
            );
            final publishedAiLayerTypes = _publishedAiLayerTypes(
              publishedAiLayers,
            );
            final activePublishedAiLayers = publishedAiLayers
                .where(
                  (layer) =>
                      _visiblePublishedAiLayerTypes.contains(layer.layerType),
                )
                .toList(growable: false);
            final aiLayerCollections = <AiLayerFeatureCollection>[];
            if (_showPublishedAiLayers && activePublishedAiLayers.isNotEmpty) {
              for (final layer in activePublishedAiLayers) {
                final query = _publishedAiLayerViewportQuery(
                  layer,
                  viewportQuery,
                  classLabel: _selectedPublishedAiClass,
                );
                final collection = ref
                    .watch(aiLayerFeaturesProvider(query))
                    .valueOrNull;
                if (collection != null) {
                  aiLayerCollections.add(collection);
                }
              }
            }
            final loadedPublishedAiClassOptions = _publishedAiClassOptions(
              aiLayerCollections,
            );
            if (loadedPublishedAiClassOptions.isNotEmpty) {
              _stablePublishedAiClassOptions = loadedPublishedAiClassOptions;
            }
            final loadedPublishedAiLayerClassCounts =
                _publishedAiLayerClassCountsByType(aiLayerCollections);
            if (loadedPublishedAiLayerClassCounts.isNotEmpty) {
              _stablePublishedAiLayerClassCounts =
                  loadedPublishedAiLayerClassCounts;
            }
            final loadedPublishedAiLayerCounts = _publishedAiLayerCountsByType(
              aiLayerCollections,
            );
            if (loadedPublishedAiLayerCounts.isNotEmpty) {
              _stablePublishedAiLayerCounts = loadedPublishedAiLayerCounts;
            }
            final publishedAiClassOptions =
                publishedAiLayerTypes.contains('classification')
                ? _stablePublishedAiClassOptions
                : const <String>[];
            final publishedAiLayerCounts = Map<String, int>.from(
              _stablePublishedAiLayerCounts,
            );
            if (_selectedPublishedAiClass != null) {
              for (final layerType in publishedAiLayerTypes) {
                final selectedClassCount =
                    _stablePublishedAiLayerClassCounts[layerType]?[_selectedPublishedAiClass];
                publishedAiLayerCounts[layerType] = selectedClassCount ?? 0;
              }
            }
            final hasNoPublishedAiClassMatches =
                _showPublishedAiLayers &&
                _selectedPublishedAiClass != null &&
                activePublishedAiLayers.isNotEmpty &&
                publishedAiLayerCounts.entries
                    .where(
                      (entry) =>
                          _visiblePublishedAiLayerTypes.contains(entry.key),
                    )
                    .every((entry) => entry.value == 0);
            final hideOfficialFeatures =
                _showPublishedAiLayers &&
                _selectedFeatureChip == _noOfficialFeatureFilter;
            final scopedFeatures = hideOfficialFeatures
                ? const <MapFeatureSummary>[]
                : isUserRole
                ? features
                      .where((feature) => feature.status == 'approved')
                      .toList(growable: false)
                : features;
            final quickFeatureChips = _deriveFeatureChips(
              project,
              isUserRole
                  ? features
                        .where((feature) => feature.status == 'approved')
                        .toList(growable: false)
                  : features,
            );
            final filteredFeatures = scopedFeatures
                .where(
                  (feature) =>
                      isUserRole || _visibleStatuses.contains(feature.status),
                )
                .where(
                  (feature) => _matchesSearchAndChip(
                    feature,
                    query: _searchController.text,
                    selectedChip: null,
                  ),
                )
                .toList(growable: false);
            final countStatuses = isUserRole || _hasAllVisibleStatusesSelected
                ? null
                : _projectMapStatusOrder
                      .where(_visibleStatuses.contains)
                      .toList(growable: false);
            final countQuery = ProjectFeatureCountQuery(
              projectId: project.id,
              search: _searchController.text.trim().isEmpty
                  ? null
                  : _searchController.text.trim(),
              statuses: countStatuses,
              featureType: hideOfficialFeatures ? null : _selectedFeatureChip,
            );
            final featureCountAsync = hideOfficialFeatures
                ? null
                : ref.watch(projectFeatureCountProvider(countQuery));
            final fallbackFeatureCount = _projectMapFeatureTotal(
              project,
              filteredFeatures,
              canFilterStatuses: !isUserRole,
            );
            final totalFeatureCount = hideOfficialFeatures
                ? 0
                : featureCountAsync?.valueOrNull ?? fallbackFeatureCount;
            _maybeOpenInitialFeatureDetails(
              project: project,
              features: filteredFeatures,
              canCollectOnMap: canCollectOnMap,
              canReview: canReview,
            );
            _maybeOpenInitialAiValidationTaskDetails(
              project: project,
              tasks: aiValidationTasks,
            );

            return _buildMapWorkspace(
              context,
              project: project,
              features: filteredFeatures,
              aiValidationTasks: aiValidationTasks,
              totalFeatureCount: totalFeatureCount,
              quickFeatureChips: quickFeatureChips,
              offlinePackageAsync: offlineMapPackageAsync,
              hasCollectionAccess: hasContributorAssignment,
              canCollectOnMap: canCollectOnMap,
              canUseOfflineMap: canUseOfflineMap,
              canReview: canReview,
              canFilterStatuses: !isUserRole,
              publishedAiLayers: publishedAiLayers,
              publishedAiLayerCollections: aiLayerCollections,
              publishedAiLayerTypes: publishedAiLayerTypes,
              publishedAiClassOptions: publishedAiClassOptions,
              publishedAiLayerCounts: publishedAiLayerCounts,
              hasNoPublishedAiClassMatches: hasNoPublishedAiClassMatches,
              embeddedControls: embeddedControls,
            );
          }

          final cachedFeatures = _lastViewportFeatures;
          return featuresAsync.when(
            loading: () => cachedFeatures != null
                ? buildLoadedWorkspace(cachedFeatures)
                : const Center(child: CircularProgressIndicator()),
            error: (error, _) => cachedFeatures != null
                ? buildLoadedWorkspace(cachedFeatures)
                : AppEmptyState(
                    icon: Icons.error_outline,
                    title: 'Project map unavailable',
                    message: userFacingErrorMessage(
                      error,
                      fallback:
                          'Unable to load project features right now. Please try again.',
                    ),
                    actionLabel: 'Retry',
                    onAction: () => bumpWorkflowRefresh(ref),
                  ),
            data: buildLoadedWorkspace,
          );
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            if (widget.lockProjectSelection) {
              return buildWorkspace();
            }
            if (constraints.maxHeight < 860 || constraints.maxWidth < 640) {
              return Column(
                children: [
                  SectionHeader(
                    title: widget.lockProjectSelection
                        ? project.name
                        : 'Project Map',
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
    required List<AiUncertaintyArea> aiValidationTasks,
    required int totalFeatureCount,
    required List<String> quickFeatureChips,
    required AsyncValue<OfflineMapPackage?> offlinePackageAsync,
    required bool hasCollectionAccess,
    required bool canCollectOnMap,
    required bool canUseOfflineMap,
    required bool canReview,
    required bool canFilterStatuses,
    required List<AiOutputLayer> publishedAiLayers,
    required List<AiLayerFeatureCollection> publishedAiLayerCollections,
    required List<String> publishedAiLayerTypes,
    required List<String> publishedAiClassOptions,
    required Map<String, int> publishedAiLayerCounts,
    required bool hasNoPublishedAiClassMatches,
    Widget? embeddedControls,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mapCard = _buildConstrainedMapCard(
          context,
          project: project,
          features: features,
          aiValidationTasks: aiValidationTasks,
          totalFeatureCount: totalFeatureCount,
          quickFeatureChips: quickFeatureChips,
          offlinePackage: offlinePackageAsync.valueOrNull,
          canCollectOnMap: canCollectOnMap,
          canReview: canReview,
          publishedAiLayers: publishedAiLayers,
          publishedAiLayerCollections: publishedAiLayerCollections,
          publishedAiLayerTypes: publishedAiLayerTypes,
        );
        final featureListContent = features.isEmpty
            ? AppEmptyState(
                icon: Icons.layers_clear_outlined,
                title: 'No map features match the current filters',
                message: hasCollectionAccess
                    ? 'Use Add Feature to collect orchard, field, or tree records for this project.'
                    : canFilterStatuses
                    ? 'Approved or submitted features will appear here when they exist.'
                    : 'Approved features will appear here when they exist.',
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
                    'Project Features ($totalFeatureCount)',
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
                                        _featureDisplayTitle(feature),
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${_projectFeatureTypeLabel((feature.sourceGeometryType ?? feature.geometry['type'] ?? 'Geometry').toString())} • ${feature.photoCount} photo(s)',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                if (canFilterStatuses) ...[
                                  const SizedBox(width: AppSpacing.sm),
                                  StatusChip(status: feature.status),
                                ],
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
                                TextButton.icon(
                                  onPressed: () {
                                    _focusFeature(
                                      feature,
                                      detailsSheetAware: true,
                                    );
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

        final legendCard = canFilterStatuses
            ? AppCard(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _LegendChip(
                      label: 'Approved',
                      color: _statusColor('approved'),
                    ),
                    _LegendChip(
                      label: 'Pending review',
                      color: _statusColor('pending_review'),
                    ),
                    _LegendChip(
                      label: 'Rejected',
                      color: _statusColor('rejected'),
                    ),
                    _LegendChip(label: 'Draft', color: _statusColor('draft')),
                    if (aiValidationTasks.isNotEmpty)
                      _LegendChip(
                        label: 'AI validation task',
                        color: _aiValidationTaskColor,
                      ),
                  ],
                ),
              )
            : null;
        final useMobileWorkspace =
            constraints.maxWidth < 900 ||
            constraints.maxHeight < 820 ||
            embeddedControls != null;

        if (useMobileWorkspace) {
          if (widget.lockProjectSelection) {
            return _buildProjectMapMobileWorkspace(
              context,
              project: project,
              features: features,
              aiValidationTasks: aiValidationTasks,
              totalFeatureCount: totalFeatureCount,
              quickFeatureChips: quickFeatureChips,
              offlinePackage: offlinePackageAsync.valueOrNull,
              hasCollectionAccess: hasCollectionAccess,
              canCollectOnMap: canCollectOnMap,
              canUseOfflineMap: canUseOfflineMap,
              canReview: canReview,
              canFilterStatuses: canFilterStatuses,
              publishedAiLayers: publishedAiLayers,
              publishedAiLayerCollections: publishedAiLayerCollections,
              publishedAiLayerTypes: publishedAiLayerTypes,
              publishedAiClassOptions: publishedAiClassOptions,
              publishedAiLayerCounts: publishedAiLayerCounts,
              hasNoPublishedAiClassMatches: hasNoPublishedAiClassMatches,
            );
          }
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
                  final bottomInset =
                      MediaQuery.viewPaddingOf(context).bottom + AppSpacing.lg;
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
                        if (legendCard != null) ...[
                          legendCard,
                          const SizedBox(height: AppSpacing.sm),
                        ],
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
                  if (legendCard != null) ...[
                    legendCard,
                    const SizedBox(height: AppSpacing.sm),
                  ],
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

  Widget _buildProjectMapMobileWorkspace(
    BuildContext context, {
    required ProjectSummary project,
    required List<MapFeatureSummary> features,
    required List<AiUncertaintyArea> aiValidationTasks,
    required int totalFeatureCount,
    required List<String> quickFeatureChips,
    required OfflineMapPackage? offlinePackage,
    required bool hasCollectionAccess,
    required bool canCollectOnMap,
    required bool canUseOfflineMap,
    required bool canReview,
    required bool canFilterStatuses,
    required List<AiOutputLayer> publishedAiLayers,
    required List<AiLayerFeatureCollection> publishedAiLayerCollections,
    required List<String> publishedAiLayerTypes,
    required List<String> publishedAiClassOptions,
    required Map<String, int> publishedAiLayerCounts,
    required bool hasNoPublishedAiClassMatches,
  }) {
    _scheduleProjectAutoFrame(project: project);
    _scheduleProjectMapTilePrime(offlinePackage);
    _scheduleProjectMapSurfaceWarmup(offlinePackage);

    final theme = Theme.of(context);
    final locationNotice = _locationNoticeMessage?.trim().isNotEmpty == true
        ? _MapWorkspaceCompactNotice(
            icon: Icons.my_location_outlined,
            message: _locationNoticeMessage!,
            toneColor: theme.colorScheme.primary,
          )
        : null;
    final tileNotice = _tileFailureMessage?.trim().isNotEmpty == true
        ? _MapWorkspaceCompactNotice(
            icon: _tileFailureUsesSavedImagery
                ? Icons.map_outlined
                : Icons.cloud_off_outlined,
            message: _tileFailureMessage!,
            toneColor: _tileFailureUsesSavedImagery
                ? theme.colorScheme.primary
                : theme.colorScheme.secondary,
          )
        : null;
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final suppressFloatingToolsForSearch =
        _projectMapSearchOpen || keyboardVisible;
    final addFeatureBottom = _isProjectMapCaptureMode ? 102.0 : 18.0;
    final rightRailBottom = _isProjectMapCaptureMode
        ? 188.0
        : hasCollectionAccess
        ? addFeatureBottom + 68
        : 22.0;

    return Stack(
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: AppRadii.lg,
            child: ColoredBox(
              color: _projectMapSurfaceFallbackColor(),
              child: _buildMapCanvas(
                project: project,
                features: features,
                aiValidationTasks: aiValidationTasks,
                offlinePackage: offlinePackage,
                canCollectOnMap: canCollectOnMap,
                canReview: canReview,
                publishedAiLayerCollections: publishedAiLayerCollections,
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
                      theme.colorScheme.surface.withValues(alpha: 0.78),
                      theme.colorScheme.surface.withValues(alpha: 0.48),
                    ],
                  ),
                ),
                child: Center(
                  child: _MapWorkspaceCompactNotice(
                    icon: _basemapStyleIcon(_basemapStyle),
                    message:
                        'Loading ${LebanonMapConfig.basemapLabel(_basemapStyle)} view...',
                    toneColor: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          top: 12,
          left: 12,
          right: 12,
          child: _isProjectMapCaptureMode
              ? _ProjectMapGeometryCapturePanel(
                  geometryType: _captureGeometryType ?? 'Point',
                  summaryLabel: _projectMapCaptureSummary(),
                  instruction: _projectMapCaptureInstruction(),
                  onCancel: _cancelProjectMapFeatureCapture,
                )
              : Stack(
                  children: [
                    Padding(
                      padding: EdgeInsets.only(
                        right: _isProjectMapPanelVisible ? 0 : 64,
                      ),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: AnimatedBuilder(
                                  animation: animation,
                                  child: child,
                                  builder: (context, child) => ClipRect(
                                    child: Align(
                                      alignment: AlignmentDirectional.topStart,
                                      heightFactor: animation.value
                                          .clamp(0.0, 1.0)
                                          .toDouble(),
                                      child: child,
                                    ),
                                  ),
                                ),
                              ),
                          child: _isProjectMapPanelVisible
                              ? SizedBox(
                                  key: const ValueKey<String>(
                                    'project_map_panel_visible',
                                  ),
                                  width: double.infinity,
                                  child: _ProjectMapFloatingPanel(
                                    project: project,
                                    featureCount: totalFeatureCount,
                                    searchController: _searchController,
                                    searchFocusNode: _projectMapSearchFocusNode,
                                    quickFeatureChips: quickFeatureChips,
                                    selectedFeatureChip: _selectedFeatureChip,
                                    visibleStatuses: _visibleStatuses,
                                    basemapStyle: _basemapStyle,
                                    isExpanded: _projectMapPanelExpanded,
                                    isSearchOpen: _projectMapSearchOpen,
                                    searchSummaryLabel: _searchSummaryLabel(),
                                    onSearchChanged: () => setState(() {}),
                                    onClearSearch: () {
                                      setState(() {
                                        _searchController.clear();
                                      });
                                    },
                                    onSearchPressed: () =>
                                        _setProjectMapPanelState(
                                          visible: true,
                                          searchOpen: !_projectMapSearchOpen,
                                          expanded: _projectMapSearchOpen
                                              ? _projectMapPanelExpanded
                                              : false,
                                          focusSearch: !_projectMapSearchOpen,
                                        ),
                                    onChipSelected: (chip) {
                                      setState(() {
                                        _selectedFeatureChip = chip;
                                        _lastViewportFeatures = null;
                                        _projectViewportQuery =
                                            _buildProjectViewportQuery(
                                              project.id,
                                            );
                                      });
                                    },
                                    onResetVisibleStatuses:
                                        _resetVisibleStatuses,
                                    onToggleVisibleStatus: _toggleVisibleStatus,
                                    visibleStatusSummaryLabel:
                                        _visibleStatusSummaryLabel(),
                                    onBasemapStyleChanged:
                                        _setProjectMapBasemapStyle,
                                    publishedAiLayerTypes:
                                        publishedAiLayerTypes,
                                    publishedAiClassOptions:
                                        publishedAiClassOptions,
                                    publishedAiLayerCounts:
                                        publishedAiLayerCounts,
                                    selectedPublishedAiClass:
                                        _selectedPublishedAiClass,
                                    hasNoPublishedAiClassMatches:
                                        hasNoPublishedAiClassMatches,
                                    allowNoOfficialFeatureFilter:
                                        _showPublishedAiLayers,
                                    visiblePublishedAiLayerTypes:
                                        _visiblePublishedAiLayerTypes,
                                    onPublishedAiClassSelected: (className) {
                                      setState(() {
                                        _selectedPublishedAiClass = className;
                                        _focusedPublishedAiFeatureKey = null;
                                        _focusedPublishedAiFeatureOverride =
                                            null;
                                      });
                                    },
                                    onPublishedAiLayerTypeSelected:
                                        (layerType, selected) {
                                          setState(() {
                                            final next = Set<String>.from(
                                              _visiblePublishedAiLayerTypes,
                                            );
                                            if (selected) {
                                              next.add(layerType);
                                            } else {
                                              next.remove(layerType);
                                            }
                                            _visiblePublishedAiLayerTypes =
                                                next;
                                            if (!next.contains(
                                              'classification',
                                            )) {
                                              _selectedPublishedAiClass = null;
                                            }
                                            _focusedPublishedAiFeatureKey =
                                                null;
                                            _focusedPublishedAiFeatureOverride =
                                                null;
                                          });
                                        },
                                    showPublishedAiLayers:
                                        _showPublishedAiLayers,
                                    onTogglePublishedAiLayers:
                                        publishedAiLayers.isEmpty
                                        ? null
                                        : (selected) {
                                            setState(() {
                                              _showPublishedAiLayers = selected;
                                              if (selected &&
                                                  _visiblePublishedAiLayerTypes
                                                      .isEmpty) {
                                                _visiblePublishedAiLayerTypes =
                                                    publishedAiLayerTypes
                                                        .toSet();
                                              }
                                              if (!selected) {
                                                _selectedPublishedAiClass =
                                                    null;
                                                _focusedPublishedAiFeatureKey =
                                                    null;
                                                _focusedPublishedAiFeatureOverride =
                                                    null;
                                                if (_selectedFeatureChip ==
                                                    _noOfficialFeatureFilter) {
                                                  _selectedFeatureChip = null;
                                                  _lastViewportFeatures = null;
                                                  _projectViewportQuery =
                                                      _buildProjectViewportQuery(
                                                        project.id,
                                                      );
                                                }
                                              }
                                            });
                                          },
                                    onOpenOfflineTools: canUseOfflineMap
                                        ? () => _openOfflineToolsSheet(
                                            offlinePackage: offlinePackage,
                                            hasCollectionAccess:
                                                hasCollectionAccess,
                                          )
                                        : null,
                                    onToggleExpanded: () =>
                                        _setProjectMapPanelState(
                                          visible: true,
                                          expanded: !_projectMapPanelExpanded,
                                        ),
                                    onHidePanel: () =>
                                        _setProjectMapPanelVisible(false),
                                    canFilterStatuses: canFilterStatuses,
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                    if (!_isProjectMapPanelVisible)
                      Align(
                        alignment: Alignment.topRight,
                        child: FloatingActionButton.small(
                          heroTag: 'show_project_map_tools',
                          tooltip: 'Show map tools',
                          onPressed: () => _setProjectMapPanelVisible(true),
                          child: const Icon(Icons.tune_rounded),
                        ),
                      ),
                  ],
                ),
        ),
        if (_isProjectMapGeometryChooserOpen)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _dismissProjectMapGeometryChooser,
              child: ColoredBox(
                color: theme.colorScheme.scrim.withValues(alpha: 0.18),
              ),
            ),
          ),
        if (_isProjectMapGeometryChooserOpen)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _InlineProjectMapGeometryTypeSheet(
              geometryTypes: _projectMapGeometryTypeOptions,
              onSelected: _enterProjectMapCapture,
              onClose: _dismissProjectMapGeometryChooser,
            ),
          ),
        if (!_isProjectMapSecondaryOverlayOpen &&
            !suppressFloatingToolsForSearch)
          Positioned(
            right: 14,
            bottom: rightRailBottom,
            child: _MapControlRail(
              featureCount: totalFeatureCount,
              onOpenFeatures: _isProjectMapCaptureMode
                  ? null
                  : () => _openFeatureBrowser(
                      project: project,
                      features: features,
                      totalFeatureCount: totalFeatureCount,
                      canCollectOnMap: canCollectOnMap,
                      canReview: canReview,
                      canFilterStatuses: canFilterStatuses,
                      featureTypeOptions: quickFeatureChips,
                      initialFeatureType:
                          _selectedFeatureChip == _noOfficialFeatureFilter
                          ? _noOfficialFeatureFilter
                          : _selectedFeatureChip,
                    ),
              onCenterCurrentLocation: _isLocating
                  ? null
                  : _centerMainMapOnCurrentLocation,
              onFitProject: () => _focusLebanonWorkspace(queueUntilReady: true),
              onZoomIn: () => _zoomProjectWorkspaceBy(1),
              onZoomOut: () => _zoomProjectWorkspaceBy(-1),
              isLocating: _isLocating,
            ),
          ),
        if (locationNotice != null && !_isProjectMapSecondaryOverlayOpen)
          Positioned(
            left: 16,
            right: 16,
            bottom: addFeatureBottom + 54,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 296),
                child: locationNotice,
              ),
            ),
          ),
        if (tileNotice != null && !_isProjectMapSecondaryOverlayOpen)
          Positioned(
            left: 16,
            right: 16,
            bottom: addFeatureBottom + 10,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 296),
                child: tileNotice,
              ),
            ),
          ),
        if (hasCollectionAccess &&
            !_isProjectMapCaptureMode &&
            !_isProjectMapSecondaryOverlayOpen &&
            !suppressFloatingToolsForSearch)
          Positioned(
            right: 14,
            bottom: addFeatureBottom,
            child: Tooltip(
              message: 'Add Feature',
              child: FloatingActionButton.small(
                heroTag: 'project_map_add_feature',
                onPressed: () {
                  if (canCollectOnMap) {
                    _startProjectMapFeatureCapture(project);
                    return;
                  }
                  _showCollectionUnavailableMessage(project.status);
                },
                child: const Icon(Icons.add_location_alt_outlined),
              ),
            ),
          ),
        if (_isProjectMapCaptureMode)
          Positioned(
            left: 12,
            right: 12,
            bottom: 8,
            child: _ProjectMapCaptureActionBar(
              geometryType: _captureGeometryType ?? 'Point',
              canUndo: _captureVertices.isNotEmpty,
              canClear: _captureVertices.isNotEmpty,
              canContinue: _validateProjectMapCapture() == null,
              onBack: _cancelProjectMapFeatureCapture,
              onUndo: _captureVertices.isEmpty ? null : _undoProjectMapCapture,
              onClear: _captureVertices.isEmpty
                  ? null
                  : _clearProjectMapCapture,
              onContinue: () => _continueProjectMapCapture(project),
            ),
          ),
      ],
    );
  }

  Widget _buildMapCanvas({
    required ProjectSummary project,
    required List<MapFeatureSummary> features,
    required List<AiUncertaintyArea> aiValidationTasks,
    required OfflineMapPackage? offlinePackage,
    required bool canCollectOnMap,
    required bool canReview,
    required List<AiLayerFeatureCollection> publishedAiLayerCollections,
  }) {
    return FutureBuilder<_OfflineTileAssets?>(
      future: _offlineTileAssetsFuture(offlinePackage),
      builder: (context, snapshot) {
        final liveBasemapUrl = LebanonMapConfig.basemapUrlTemplate(
          _basemapStyle,
        );
        final labelOverlayUrl = LebanonMapConfig.referenceLabelUrlTemplate(
          _basemapStyle,
        );
        final shouldRenderTileLayers = LebanonMapConfig.shouldRenderTileLayers;
        final hasSavedOfflineImagery = snapshot.data?.hasCachedTiles ?? false;
        final canUseSavedOfflineImagery =
            snapshot.data != null && hasSavedOfflineImagery;
        final preferSavedImagery =
            _tileFailureUsesSavedImagery && canUseSavedOfflineImagery;
        final showReferenceLabels =
            labelOverlayUrl != null && !_isBasemapTransitioning;
        final theme = Theme.of(context);
        return FlutterMap(
          key: ValueKey<String>('project_map_${project.id}'),
          mapController: _mapController,
          options: _mainMapOptions,
          children: [
            if (shouldRenderTileLayers &&
                preferSavedImagery &&
                canUseSavedOfflineImagery)
              TileLayer(
                key: ValueKey<String>(
                  'project_map_offline_tiles_${_basemapStyle.name}_${snapshot.data!.templatePath}',
                ),
                urlTemplate: snapshot.data!.templatePath,
                tileProvider: FileTileProvider(),
                fallbackUrl: snapshot.data!.fallbackPath,
                userAgentPackageName: 'lb.gov.gis_collector',
              ),
            if (shouldRenderTileLayers && !preferSavedImagery)
              TileLayer(
                key: ValueKey<String>(
                  'project_map_live_basemap_${_basemapStyle.name}',
                ),
                urlTemplate: liveBasemapUrl,
                tileProvider: appNetworkTileProvider(),
                tileDisplay: const TileDisplay.fadeIn(
                  duration: Duration(milliseconds: 180),
                  startOpacity: 0,
                  reloadStartOpacity: 0,
                ),
                panBuffer: 2,
                keepBuffer: 3,
                userAgentPackageName: 'lb.gov.gis_collector',
                errorTileCallback: (tile, error, stackTrace) {
                  Object.hash(tile, stackTrace);
                  _notifyProjectMapTileFailure(
                    offlinePackage: offlinePackage,
                    hasSavedOfflineImagery: hasSavedOfflineImagery,
                  );
                },
              ),
            if (shouldRenderTileLayers && showReferenceLabels)
              TileLayer(
                key: ValueKey<String>(
                  'project_map_label_overlay_${_basemapStyle.name}',
                ),
                urlTemplate: labelOverlayUrl,
                tileProvider: appNetworkTileProvider(),
                tileDisplay: const TileDisplay.fadeIn(
                  duration: Duration(milliseconds: 220),
                  startOpacity: 0,
                  reloadStartOpacity: 0,
                ),
                panBuffer: 2,
                keepBuffer: 3,
                userAgentPackageName: 'lb.gov.gis_collector',
              ),
            _projectPolygonLayer(
              features: features,
              project: project,
              canCollectOnMap: canCollectOnMap,
              canReview: canReview,
              interactive: !_isProjectMapCaptureMode,
            ),
            _projectPolylineLayer(
              features: features,
              project: project,
              canCollectOnMap: canCollectOnMap,
              canReview: canReview,
              interactive: !_isProjectMapCaptureMode,
            ),
            if (aiValidationTasks.isNotEmpty) ...[
              _aiValidationTaskPolygonLayer(
                tasks: aiValidationTasks,
                project: project,
                interactive: !_isProjectMapCaptureMode,
              ),
              _aiValidationTaskPolylineLayer(
                tasks: aiValidationTasks,
                project: project,
                interactive: !_isProjectMapCaptureMode,
              ),
            ],
            if (_showPublishedAiLayers &&
                publishedAiLayerCollections.isNotEmpty) ...[
              _publishedAiPolygonLayer(publishedAiLayerCollections),
              _publishedAiPolylineLayer(publishedAiLayerCollections),
              MarkerLayer(
                markers: _publishedAiMarkerOverlays(
                  publishedAiLayerCollections,
                ),
              ),
            ],
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
            if (_isProjectMapCaptureMode &&
                (_captureGeometryType == 'Polygon') &&
                _captureVertices.length >= 3 &&
                isValidPolygonRing(<LatLng>[
                  ..._captureVertices,
                  _captureVertices.first,
                ]))
              PolygonLayer(
                polygons: [
                  Polygon(
                    points: <LatLng>[
                      ..._captureVertices,
                      _captureVertices.first,
                    ],
                    color: theme.colorScheme.primary.withValues(alpha: 0.18),
                    borderColor: theme.colorScheme.primary,
                    borderStrokeWidth: 2.2,
                  ),
                ],
              ),
            if (_isProjectMapCaptureMode &&
                ((_captureGeometryType == 'LineString' &&
                        _captureVertices.length >= 2) ||
                    (_captureGeometryType == 'Polygon' &&
                        _captureVertices.length >= 2)))
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: _captureVertices,
                    color: theme.colorScheme.primary,
                    strokeWidth: 3.6,
                  ),
                ],
              ),
            if (_isProjectMapCaptureMode && _captureVertices.isNotEmpty)
              MarkerLayer(
                markers: _captureVertices
                    .asMap()
                    .entries
                    .map(
                      (entry) => Marker(
                        point: entry.value,
                        width: (_captureGeometryType ?? 'Point') == 'Point'
                            ? 34
                            : 28,
                        height: (_captureGeometryType ?? 'Point') == 'Point'
                            ? 34
                            : 28,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x33000000),
                                blurRadius: 8,
                                offset: Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Center(
                            child: Text(
                              (_captureGeometryType ?? 'Point') == 'Point'
                                  ? ''
                                  : '${entry.key + 1}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(growable: false),
              ),
            MarkerLayer(
              markers: _markerOverlays(
                features,
                project,
                canCollectOnMap,
                canReview,
                interactive: !_isProjectMapCaptureMode,
              ),
            ),
            if (aiValidationTasks.isNotEmpty)
              MarkerLayer(
                markers: _aiValidationTaskMarkerOverlays(
                  tasks: aiValidationTasks,
                  project: project,
                  interactive: !_isProjectMapCaptureMode,
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
    required List<AiUncertaintyArea> aiValidationTasks,
    required int totalFeatureCount,
    required List<String> quickFeatureChips,
    required OfflineMapPackage? offlinePackage,
    required bool canCollectOnMap,
    required bool canReview,
    required List<AiOutputLayer> publishedAiLayers,
    required List<AiLayerFeatureCollection> publishedAiLayerCollections,
    required List<String> publishedAiLayerTypes,
  }) {
    final currentCenter = _latestMapCamera?.center ?? LebanonMapConfig.center;
    final currentZoom =
        _latestMapCamera?.zoom ?? LebanonMapConfig.fullscreenInitialZoom;

    return AppCard(
      padding: EdgeInsets.zero,
      child: Stack(
        children: [
          FutureBuilder<_OfflineTileAssets?>(
            future: _offlineTileAssetsFuture(offlinePackage),
            builder: (context, snapshot) {
              final labelOverlayUrl =
                  LebanonMapConfig.referenceLabelUrlTemplate(_basemapStyle);
              final shouldRenderTileLayers =
                  LebanonMapConfig.shouldRenderTileLayers;
              final hasSavedOfflineImagery =
                  snapshot.data?.hasCachedTiles ?? false;
              final canUseSavedOfflineImagery =
                  snapshot.data != null && hasSavedOfflineImagery;
              final preferSavedImagery =
                  _tileFailureUsesSavedImagery && canUseSavedOfflineImagery;
              final showReferenceLabels =
                  labelOverlayUrl != null && !_isBasemapTransitioning;
              return ClipRRect(
                borderRadius: AppRadii.lg,
                child: FlutterMap(
                  mapController: _mapController,
                  options: _mainMapOptions,
                  children: [
                    if (shouldRenderTileLayers &&
                        preferSavedImagery &&
                        canUseSavedOfflineImagery)
                      TileLayer(
                        key: ValueKey<String>(
                          'preview_offline_tiles_${_basemapStyle.name}_${snapshot.data!.templatePath}',
                        ),
                        urlTemplate: snapshot.data!.templatePath,
                        tileProvider: FileTileProvider(),
                        fallbackUrl: snapshot.data!.fallbackPath,
                        userAgentPackageName: 'lb.gov.gis_collector',
                      ),
                    if (shouldRenderTileLayers && !preferSavedImagery)
                      TileLayer(
                        key: ValueKey<String>(
                          'preview_live_basemap_${_basemapStyle.name}',
                        ),
                        urlTemplate: LebanonMapConfig.basemapUrlTemplate(
                          _basemapStyle,
                        ),
                        tileProvider: appNetworkTileProvider(),
                        tileDisplay: const TileDisplay.fadeIn(
                          duration: Duration(milliseconds: 180),
                          startOpacity: 0,
                          reloadStartOpacity: 0,
                        ),
                        panBuffer: 2,
                        keepBuffer: 3,
                        userAgentPackageName: 'lb.gov.gis_collector',
                        errorTileCallback: (tile, error, stackTrace) {
                          Object.hash(tile, stackTrace);
                          _notifyProjectMapTileFailure(
                            offlinePackage: offlinePackage,
                            hasSavedOfflineImagery: canUseSavedOfflineImagery,
                          );
                        },
                      ),
                    if (shouldRenderTileLayers && showReferenceLabels)
                      TileLayer(
                        key: ValueKey<String>(
                          'preview_label_overlay_${_basemapStyle.name}',
                        ),
                        urlTemplate: labelOverlayUrl,
                        tileProvider: appNetworkTileProvider(),
                        tileDisplay: const TileDisplay.fadeIn(
                          duration: Duration(milliseconds: 220),
                          startOpacity: 0,
                          reloadStartOpacity: 0,
                        ),
                        panBuffer: 2,
                        keepBuffer: 3,
                        userAgentPackageName: 'lb.gov.gis_collector',
                      ),
                    _projectPolygonLayer(
                      features: features,
                      project: project,
                      canCollectOnMap: canCollectOnMap,
                      canReview: canReview,
                    ),
                    _projectPolylineLayer(
                      features: features,
                      project: project,
                      canCollectOnMap: canCollectOnMap,
                      canReview: canReview,
                    ),
                    if (aiValidationTasks.isNotEmpty) ...[
                      _aiValidationTaskPolygonLayer(
                        tasks: aiValidationTasks,
                        project: project,
                      ),
                      _aiValidationTaskPolylineLayer(
                        tasks: aiValidationTasks,
                        project: project,
                      ),
                    ],
                    if (_showPublishedAiLayers &&
                        publishedAiLayerCollections.isNotEmpty) ...[
                      _publishedAiPolygonLayer(publishedAiLayerCollections),
                      _publishedAiPolylineLayer(publishedAiLayerCollections),
                      MarkerLayer(
                        markers: _publishedAiMarkerOverlays(
                          publishedAiLayerCollections,
                        ),
                      ),
                    ],
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
                    if (aiValidationTasks.isNotEmpty)
                      MarkerLayer(
                        markers: _aiValidationTaskMarkerOverlays(
                          tasks: aiValidationTasks,
                          project: project,
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
                                '${project.category} • ${_featureCountLabel(totalFeatureCount)}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        _MapStyleMenuButton(
                          basemapStyle: _basemapStyle,
                          onSelected: _setProjectMapBasemapStyle,
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
                            _basemapStyleIcon(_basemapStyle),
                            size: 18,
                          ),
                          label: Text(
                            LebanonMapConfig.basemapDescription(_basemapStyle),
                          ),
                        ),
                        if (publishedAiLayers.isNotEmpty)
                          FilterChip(
                            avatar: const Icon(
                              Icons.auto_awesome_outlined,
                              size: 18,
                            ),
                            label: Text(
                              _showPublishedAiLayers
                                  ? 'Hide AI layer'
                                  : 'Show AI layer',
                            ),
                            selected: _showPublishedAiLayers,
                            onSelected: (selected) {
                              setState(() {
                                _showPublishedAiLayers = selected;
                              });
                            },
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
                            LebanonMapConfig.fullscreenFit,
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
                                .clamp(_mapMinZoom, _mapMaxZoom)
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
                                .clamp(_mapMinZoom, _mapMaxZoom)
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
      ..write('${feature.geometry['type'] ?? ''}'.toLowerCase())
      ..write(' ')
      ..write(_featureBrowserTitle(feature).toLowerCase())
      ..write(' ')
      ..write(_statusLabel(feature.status).toLowerCase());
    if (feature.collectedBy != null && feature.collectedBy!.trim().isNotEmpty) {
      buffer
        ..write(' ')
        ..write(feature.collectedBy!.toLowerCase());
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

  void _scheduleProjectAutoFrame({required ProjectSummary project}) {
    if (widget.lockProjectSelection || _hasInitialFeatureTarget) {
      return;
    }
    final frameKey = project.id;
    if (_lastAutoFrameKey == frameKey) {
      return;
    }
    _lastAutoFrameKey = frameKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _focusLebanonWorkspace(queueUntilReady: true);
    });
  }

  Future<void> _openFeatureBrowser({
    required ProjectSummary project,
    required List<MapFeatureSummary> features,
    required int totalFeatureCount,
    required bool canCollectOnMap,
    required bool canReview,
    required bool canFilterStatuses,
    required List<String> featureTypeOptions,
    required String? initialFeatureType,
  }) async {
    if (mounted) {
      setState(() {
        _isProjectMapModalSheetOpen = true;
      });
    }
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) => _ProjectFeatureBrowserSheet(
          project: project,
          features: features,
          initialTotalCount: totalFeatureCount,
          canCollectOnMap: canCollectOnMap,
          featureTitleBuilder: _featureBrowserTitle,
          featureSubtitleBuilder: _featureBrowserSubtitle,
          searchBlobBuilder: _featureSearchBlob,
          statusLabelBuilder: _statusLabel,
          statusColorBuilder: _statusColor,
          canFilterStatuses: canFilterStatuses,
          featureTypeOptions: featureTypeOptions,
          initialFeatureType: initialFeatureType,
          onAddFeature: canCollectOnMap
              ? () {
                  Navigator.of(sheetContext).pop();
                  if (widget.lockProjectSelection) {
                    _startProjectMapFeatureCapture(project);
                    return;
                  }
                  context.push(AppRoutes.addFeatureForProject(project.id));
                }
              : null,
          onSelectFeature: (feature) {
            Navigator.of(sheetContext).pop();
            if (feature.isAggregate) {
              _focusFeatureAggregate(feature);
              return;
            }
            _focusFeature(feature, detailsSheetAware: true);
            _openFeatureDetails(
              project: project,
              feature: feature,
              canCollectOnMap: canCollectOnMap,
              canReview: canReview,
            );
          },
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isProjectMapModalSheetOpen = false;
        });
      }
    }
  }

  Future<void> _openOfflineToolsSheet({
    required OfflineMapPackage? offlinePackage,
    required bool hasCollectionAccess,
  }) async {
    setState(() {
      _isProjectMapModalSheetOpen = true;
    });
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        isDismissible: true,
        enableDrag: true,
        backgroundColor: Colors.transparent,
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width),
        builder: (context) => _OfflineMapSheet(
          basemapStyle: _basemapStyle,
          initialOfflinePackage: offlinePackage,
          hasCollectionAccess: hasCollectionAccess,
          uiStateListenable: _offlineSheetUiState,
          canDownloadVisible: offlinePackage != null && _isMainMapReady,
          onDownloadOverview: _downloadLebanonOverview,
          onDownloadVisible: _downloadVisibleRegion,
          onRefreshSavedImagery: _refreshSavedOfflineImagery,
          onDeleteSavedImagery: _confirmDeleteSavedOfflineImagery,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isProjectMapModalSheetOpen = false;
        });
      }
    }
  }

  String _featureBrowserTitle(MapFeatureSummary feature) {
    return _featureDisplayTitle(feature);
  }

  String _featureBrowserSubtitle(MapFeatureSummary feature) {
    final geometryType =
        (feature.sourceGeometryType ?? feature.geometry['type'] ?? 'Geometry')
            .toString();
    final details = <String>[
      _mapGeometryLabel(geometryType),
      '${feature.photoCount} photo(s)',
    ];
    if (feature.collectedBy != null && feature.collectedBy!.trim().isNotEmpty) {
      details.add('Collector ${feature.collectedBy}');
    }
    return details.join(' • ');
  }

  void _startOfflineAction(
    _OfflineMapAction action, {
    required String progressLabel,
  }) {
    setState(() {
      _isDownloadingOffline = true;
      _activeOfflineMapAction = action;
      _offlineDownloadProgressLabel = progressLabel;
      _offlineDownloadProgressValue = null;
      _offlineDownloadResultLabel = null;
    });
    _publishOfflineSheetState();
  }

  void _updateOfflineProgress({
    required String label,
    required int completedTiles,
    required int requestedTiles,
  }) {
    if (!mounted) {
      return;
    }
    final progressValue = requestedTiles <= 0
        ? null
        : (completedTiles / requestedTiles).clamp(0.0, 1.0);
    setState(() {
      _offlineDownloadProgressLabel = label;
      _offlineDownloadProgressValue = progressValue;
    });
    _publishOfflineSheetState();
  }

  void _completeOfflineAction({
    required String message,
    required bool success,
  }) {
    if (!mounted) {
      return;
    }
    setState(() {
      _offlineDownloadResultLabel = message;
      _offlineDownloadProgressValue = null;
    });
    _publishOfflineSheetState();
    if (success) {
      AppSnackbar.showSuccess(context, message);
    } else {
      AppSnackbar.showError(context, message);
    }
  }

  void _finishOfflineAction() {
    if (!mounted) {
      return;
    }
    setState(() {
      _isDownloadingOffline = false;
      _activeOfflineMapAction = null;
      _offlineDownloadProgressLabel = null;
      _offlineDownloadProgressValue = null;
    });
    _publishOfflineSheetState();
  }

  String? _featureAttributeValue(
    MapFeatureSummary feature,
    bool Function(String key, String label) matcher, {
    int maxLength = 60,
  }) {
    for (final entry in feature.attributes.entries) {
      final value = '${entry.value}'.trim();
      if (!matcher(entry.key, entry.key) ||
          value.isEmpty ||
          value.length > maxLength) {
        continue;
      }
      return value;
    }
    return null;
  }

  bool _looksLikeFeatureNameField(String key, String label) {
    final normalized = '${key.toLowerCase()} ${label.toLowerCase()}';
    return normalized.contains('name') ||
        normalized.contains('title') ||
        normalized.contains('label');
  }

  String _featureDisplayTitle(MapFeatureSummary feature) {
    if (feature.isAggregate) {
      final count = math.max(1, feature.clusterCount);
      return count == 1 ? 'Project feature' : '$count project features';
    }
    final nameValue = _featureAttributeValue(
      feature,
      _looksLikeFeatureNameField,
    );
    if (nameValue != null) {
      return nameValue;
    }
    final typeValue = _featureAttributeValue(
      feature,
      _looksLikeFeatureTypeField,
      maxLength: 40,
    );
    if (typeValue != null) {
      return typeValue;
    }
    return switch ((feature.sourceGeometryType ??
            feature.geometry['type'] ??
            '')
        .toString()
        .toLowerCase()) {
      'linestring' || 'multilinestring' => 'Line feature',
      'polygon' || 'multipolygon' => 'Polygon feature',
      _ => 'Point feature',
    };
  }

  String _projectFeatureSubtitle(MapFeatureSummary feature) {
    if (feature.isAggregate) {
      return 'Zoom in to review individual features';
    }
    final details = <String>[
      _projectFeatureTypeLabel(
        feature.sourceGeometryType ??
            feature.geometry['type']?.toString() ??
            'Unknown',
      ),
    ];
    if (feature.photoCount > 0) {
      details.add(
        '${feature.photoCount} photo${feature.photoCount == 1 ? '' : 's'}',
      );
    }
    return details.join(' • ');
  }

  int _representedProjectFeatureCount(List<MapFeatureSummary> features) {
    return features.fold<int>(
      0,
      (total, feature) => total + math.max(1, feature.clusterCount),
    );
  }

  int _projectMapFeatureTotal(
    ProjectSummary project,
    List<MapFeatureSummary> renderedFeatures, {
    required bool canFilterStatuses,
  }) {
    final hasLocalFeatureFilter =
        _searchController.text.trim().isNotEmpty ||
        _selectedFeatureChip != null;
    if (hasLocalFeatureFilter) {
      return _representedProjectFeatureCount(renderedFeatures);
    }
    if (!canFilterStatuses) {
      return math.max(
        project.approvedFeatures,
        _representedProjectFeatureCount(renderedFeatures),
      );
    }

    var total = 0;
    if (_visibleStatuses.contains('approved')) {
      total += project.approvedFeatures;
    }
    if (_visibleStatuses.contains('pending_review')) {
      total += project.pendingReviews;
    }
    if (_visibleStatuses.contains('rejected')) {
      total += project.rejectedFeatures;
    }
    if (_visibleStatuses.contains('draft')) {
      total += project.draftFeatures;
    }
    return total > 0
        ? total
        : _representedProjectFeatureCount(renderedFeatures);
  }

  String _featureCountLabel(int count) {
    return count == 1 ? '1 feature' : '$count features';
  }

  String _projectFeatureTypeLabel(String geometryType) {
    switch (geometryType.toLowerCase()) {
      case 'point':
      case 'multipoint':
        return 'Point feature';
      case 'linestring':
      case 'multilinestring':
        return 'Line feature';
      case 'polygon':
      case 'multipolygon':
        return 'Polygon feature';
      default:
        return geometryType;
    }
  }

  Future<_OfflineTileAssets> _loadOfflineTileAssets(
    OfflineMapPackage package,
    LebanonBasemapStyle basemapStyle,
  ) async {
    final manager = ref.read(offlineTileCacheManagerProvider);
    final values = await Future.wait<Object>([
      manager.localTileTemplate(package: package, basemapStyle: basemapStyle),
      manager.transparentFallbackPath(),
      manager.hasCachedTiles(package: package, basemapStyle: basemapStyle),
    ]);
    return _OfflineTileAssets(
      templatePath: values[0] as String,
      fallbackPath: values[1] as String,
      hasCachedTiles: values[2] as bool,
    );
  }

  Future<void> _downloadLebanonOverview(OfflineMapPackage package) async {
    if (_isDownloadingOffline) {
      return;
    }
    _startOfflineAction(
      _OfflineMapAction.saveOverview,
      progressLabel: 'Preparing the Lebanon overview for offline browsing...',
    );
    try {
      final manager = ref.read(offlineTileCacheManagerProvider);
      final summary = await ref
          .read(offlineTileCacheManagerProvider)
          .cacheLebanonOverview(
            package: package,
            basemapStyle: _basemapStyle,
            onProgress: (progress) {
              _updateOfflineProgress(
                label:
                    'Saving the Lebanon overview ${progress.completedTiles}/${progress.requestedTiles} • ${progress.downloadedTiles} new • ${progress.skippedTiles} already on this device${progress.failedTiles > 0 ? ' • ${progress.failedTiles} failed' : ''}',
                completedTiles: progress.completedTiles,
                requestedTiles: progress.requestedTiles,
              );
            },
          );
      _invalidateOfflineTileAssetsCache(
        package: package,
        basemapStyle: _basemapStyle,
      );
      await manager.refreshStats(package, basemapStyle: _basemapStyle);
      final _ = await ref.refresh(offlineMapPackageProvider.future);
      if (mounted) {
        final hasUsableTiles =
            summary.downloadedTiles > 0 || summary.skippedTiles > 0;
        final message =
            'Lebanon overview saved on this device. ${summary.downloadedTiles} new map image(s), ${summary.skippedTiles} already available${summary.failedTiles > 0 ? ', ${summary.failedTiles} failed' : ''}.';
        if (!hasUsableTiles) {
          _completeOfflineAction(
            message:
                'Unable to save the Lebanon overview right now. Please try again later.',
            success: false,
          );
          return;
        }
        _completeOfflineAction(message: message, success: true);
      }
    } catch (error) {
      if (mounted) {
        _completeOfflineAction(
          message: userFacingErrorMessage(
            error,
            fallback: 'Unable to save the Lebanon overview right now.',
          ),
          success: false,
        );
      }
    } finally {
      _finishOfflineAction();
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
    _startOfflineAction(
      _OfflineMapAction.saveVisibleArea,
      progressLabel: 'Preparing the visible map area for offline browsing...',
    );
    try {
      final manager = ref.read(offlineTileCacheManagerProvider);
      final summary = await manager.cacheVisibleRegion(
        package: package,
        basemapStyle: _basemapStyle,
        bounds: camera.visibleBounds,
        currentZoom: camera.zoom,
        onProgress: (progress) {
          _updateOfflineProgress(
            label:
                'Saving this visible area ${progress.completedTiles}/${progress.requestedTiles} • ${progress.downloadedTiles} new • ${progress.skippedTiles} already on this device${progress.failedTiles > 0 ? ' • ${progress.failedTiles} failed' : ''}',
            completedTiles: progress.completedTiles,
            requestedTiles: progress.requestedTiles,
          );
        },
      );
      _invalidateOfflineTileAssetsCache(
        package: package,
        basemapStyle: _basemapStyle,
      );
      await manager.refreshStats(package, basemapStyle: _basemapStyle);
      final _ = await ref.refresh(offlineMapPackageProvider.future);
      if (mounted) {
        final hasUsableTiles =
            summary.downloadedTiles > 0 || summary.skippedTiles > 0;
        final message =
            'This visible area is saved on this device. ${summary.downloadedTiles} new map image(s), ${summary.skippedTiles} already available${summary.failedTiles > 0 ? ', ${summary.failedTiles} failed' : ''}.';
        if (!hasUsableTiles) {
          _completeOfflineAction(
            message:
                'Unable to save this visible area right now. Please try again later.',
            success: false,
          );
          return;
        }
        _completeOfflineAction(message: message, success: true);
      }
    } catch (error) {
      if (mounted) {
        _completeOfflineAction(
          message: userFacingErrorMessage(
            error,
            fallback: 'Unable to save this visible map area right now.',
          ),
          success: false,
        );
      }
    } finally {
      _finishOfflineAction();
    }
  }

  Future<void> _refreshSavedOfflineImagery(OfflineMapPackage package) async {
    if (_isDownloadingOffline) {
      return;
    }
    _startOfflineAction(
      _OfflineMapAction.refreshSavedImagery,
      progressLabel:
          'Refreshing saved map imagery for the current view style...',
    );
    try {
      final manager = ref.read(offlineTileCacheManagerProvider);
      final summary = await manager.refreshCachedTiles(
        package: package,
        basemapStyle: _basemapStyle,
        onProgress: (progress) {
          _updateOfflineProgress(
            label:
                'Refreshing saved imagery ${progress.completedTiles}/${progress.requestedTiles}${progress.failedTiles > 0 ? ' • ${progress.failedTiles} failed' : ''}',
            completedTiles: progress.completedTiles,
            requestedTiles: progress.requestedTiles,
          );
        },
      );
      _invalidateOfflineTileAssetsCache(
        package: package,
        basemapStyle: _basemapStyle,
      );
      await manager.refreshStats(package, basemapStyle: _basemapStyle);
      final _ = await ref.refresh(offlineMapPackageProvider.future);
      if (!mounted) {
        return;
      }
      final message = summary.requestedTiles == 0
          ? 'No saved offline imagery is available yet for the ${LebanonMapConfig.basemapLabel(_basemapStyle).toLowerCase()} view.'
          : 'Saved imagery refreshed. ${summary.downloadedTiles} map image(s) updated${summary.failedTiles > 0 ? ', ${summary.failedTiles} failed' : ''}.';
      if (summary.downloadedTiles > 0) {
        _clearTileNotice();
      }
      _completeOfflineAction(message: message, success: true);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _completeOfflineAction(
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to refresh saved offline imagery right now.',
        ),
        success: false,
      );
    } finally {
      _finishOfflineAction();
    }
  }

  Future<void> _confirmDeleteSavedOfflineImagery(
    OfflineMapPackage package,
  ) async {
    if (_isDownloadingOffline || !mounted) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete saved imagery?'),
        content: Text(
          'This removes the saved ${LebanonMapConfig.basemapLabel(_basemapStyle).toLowerCase()} imagery from this device for the signed-in user.',
        ),
        actions: [
          AppDialogActions(
            cancel: TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            confirm: FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await _deleteSavedOfflineImagery(package);
  }

  Future<void> _deleteSavedOfflineImagery(OfflineMapPackage package) async {
    if (_isDownloadingOffline) {
      return;
    }
    _startOfflineAction(
      _OfflineMapAction.deleteSavedImagery,
      progressLabel: 'Removing saved offline imagery from this device...',
    );
    try {
      final manager = ref.read(offlineTileCacheManagerProvider);
      await manager.clearCachedTiles(
        package: package,
        basemapStyle: _basemapStyle,
      );
      _invalidateOfflineTileAssetsCache(
        package: package,
        basemapStyle: _basemapStyle,
      );
      await manager.refreshStats(package, basemapStyle: _basemapStyle);
      final _ = await ref.refresh(offlineMapPackageProvider.future);
      if (!mounted) {
        return;
      }
      _clearTileNotice();
      _completeOfflineAction(
        message:
            'Saved ${LebanonMapConfig.basemapLabel(_basemapStyle).toLowerCase()} imagery removed from this device.',
        success: true,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      _completeOfflineAction(
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to remove saved offline imagery right now.',
        ),
        success: false,
      );
    } finally {
      _finishOfflineAction();
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
          setState(() {
            _currentLocation = null;
            _currentLocationAccuracyMeters = null;
          });
          _showLocationNotice(
            'Current location is outside Lebanon. Staying on the project workspace.',
          );
          _focusLebanonWorkspace(queueUntilReady: true);
        }
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _currentLocation = location.position;
        _currentLocationAccuracyMeters = location.accuracyMeters;
        _captureGpsAccuracyMeters = _isProjectMapCaptureMode
            ? location.accuracyMeters
            : _captureGpsAccuracyMeters;
        if (_isProjectMapCaptureMode &&
            (_captureGeometryType ?? 'Point') == 'Point') {
          _captureVertices
            ..clear()
            ..add(location.position);
        } else if (_isProjectMapCaptureMode) {}
      });
      if (_isProjectMapCaptureMode &&
          (_captureGeometryType ?? 'Point') == 'Point') {
        _showLocationNotice('Current location set for the feature point.');
      } else if (_isProjectMapCaptureMode) {
        _showLocationNotice(
          'Map centered on the current location. Continue drawing on the map.',
        );
      } else {
        _clearLocationNotice();
      }
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

  void _maybeStartProjectMapCaptureOnOpen({
    required ProjectSummary project,
    required bool canCollectOnMap,
  }) {
    if (!widget.startCaptureOnOpen || _hasHandledStartCaptureOnOpen) {
      return;
    }

    _hasHandledStartCaptureOnOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (canCollectOnMap) {
        _startProjectMapFeatureCapture(project);
        return;
      }
      _showCollectionUnavailableMessage(project.status);
    });
  }

  Future<void> _reviewFeature({
    required MapFeatureSummary feature,
    required String status,
    VoidCallback? onSuccess,
  }) async {
    final note = await _promptNote(
      title: status == 'approved' ? 'Approve feature' : 'Reject feature',
      hint: 'Optional context for the contributor.',
      submitLabel: status == 'approved' ? 'Approve' : 'Reject',
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
          AppDialogActions(
            cancel: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            confirm: FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Submit'),
            ),
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

  Future<void> _deleteDraftFeature({
    required MapFeatureSummary feature,
    VoidCallback? onSuccess,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete draft'),
        content: const Text(
          'Delete this draft feature? This cannot be undone.',
        ),
        actions: [
          AppDialogActions(
            cancel: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            confirm: FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    try {
      await ref.read(featureWorkflowRepositoryProvider).deleteDraft(feature.id);
      bumpWorkflowRefresh(ref);
      if (mounted) {
        onSuccess?.call();
        AppSnackbar.showSuccess(context, 'Draft deleted successfully.');
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to delete this draft right now.',
          ),
        );
      }
    }
  }

  Future<String?> _promptNote({
    required String title,
    required String hint,
    required String submitLabel,
  }) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _MapReviewNoteDialog(
        title: title,
        hint: hint,
        submitLabel: submitLabel,
      ),
    );
  }

  void _openFeatureDetails({
    required ProjectSummary project,
    required MapFeatureSummary feature,
    required bool canCollectOnMap,
    required bool canReview,
  }) {
    _focusFeature(feature, detailsSheetAware: true);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => feature.isSummary
          ? Consumer(
              builder: (context, ref, _) {
                final detailAsync = ref.watch(
                  projectFeatureDetailsProvider(feature.id),
                );
                return detailAsync.when(
                  loading: () => _ProjectFeatureLoadingSheet(
                    title: _featureDisplayTitle(feature),
                  ),
                  error: (error, _) => _ProjectFeatureErrorSheet(
                    title: _featureDisplayTitle(feature),
                    message: userFacingErrorMessage(
                      error,
                      fallback:
                          'Unable to load this project feature right now.',
                    ),
                    onRetry: () => ref.invalidate(
                      projectFeatureDetailsProvider(feature.id),
                    ),
                  ),
                  data: (loadedFeature) => _buildProjectFeatureDetailsSheet(
                    sheetContext,
                    project: project,
                    feature: loadedFeature,
                    canCollectOnMap: canCollectOnMap,
                    canReview: canReview,
                  ),
                );
              },
            )
          : _buildProjectFeatureDetailsSheet(
              sheetContext,
              project: project,
              feature: feature,
              canCollectOnMap: canCollectOnMap,
              canReview: canReview,
            ),
    );
  }

  Widget _buildProjectFeatureDetailsSheet(
    BuildContext sheetContext, {
    required ProjectSummary project,
    required MapFeatureSummary feature,
    required bool canCollectOnMap,
    required bool canReview,
  }) {
    final bottomInset =
        MediaQuery.viewPaddingOf(sheetContext).bottom + AppSpacing.lg;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.45,
      maxChildSize: 0.94,
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
                        _featureDisplayTitle(feature),
                        style: Theme.of(context).textTheme.titleLarge,
                        softWrap: true,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _projectFeatureSubtitle(feature),
                        style: Theme.of(context).textTheme.bodySmall,
                        softWrap: true,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                StatusChip(status: feature.status),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _DetailSection(
              title: 'Feature details',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _MapInfoPill(
                        icon: Icons.category_outlined,
                        label: _projectFeatureTypeLabel(
                          feature.sourceGeometryType ??
                              feature.geometry['type']?.toString() ??
                              'Unknown',
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
                  const SizedBox(height: AppSpacing.sm),
                  Text(_geometrySummary(feature.geometry), softWrap: true),
                ],
              ),
            ),
            _DetailSection(
              title: 'Timeline',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (feature.collectedAt != null)
                    _TimelineRow(
                      label: 'Collected',
                      value: _formatDateTime(feature.collectedAt!),
                    ),
                  if (feature.submittedAt != null)
                    _TimelineRow(
                      label: 'Submitted',
                      value: _formatDateTime(feature.submittedAt!),
                    ),
                  if (feature.reviewedAt != null)
                    _TimelineRow(
                      label: 'Reviewed',
                      value: _formatDateTime(feature.reviewedAt!),
                    ),
                ],
              ),
            ),
            if (feature.attributes.isNotEmpty)
              _DetailSection(
                title: 'Attributes',
                child: _FeatureAttributesGrid(attributes: feature.attributes),
              ),
            if (feature.reviewNotes?.trim().isNotEmpty == true)
              _DetailSection(
                title: 'Review notes',
                child: Text(feature.reviewNotes!, softWrap: true),
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
                              imagePath: photo.thumbnailPath ?? photo.filePath,
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
                child: AppActionButtons(
                  maxColumns: 2,
                  compactBreakpoint: 360,
                  fillRows: true,
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
                    FilledButton.tonalIcon(
                      onPressed: () => _deleteDraftFeature(
                        feature: feature,
                        onSuccess: () => Navigator.of(sheetContext).pop(),
                      ),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Delete Draft'),
                    ),
                  ],
                ),
              ),
            if (canReview && feature.status != 'draft')
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.md),
                child: AppActionButtons(
                  maxColumns: 2,
                  compactBreakpoint: 360,
                  fillRows: true,
                  children: [
                    if (feature.status == 'pending_review' ||
                        feature.status == 'rejected')
                      FilledButton.icon(
                        onPressed: () => _reviewFeature(
                          feature: feature,
                          status: 'approved',
                          onSuccess: () => Navigator.of(sheetContext).pop(),
                        ),
                        icon: const Icon(Icons.check_circle_outline),
                        label: const Text('Approve'),
                      ),
                    if (feature.status == 'pending_review' ||
                        feature.status == 'approved')
                      FilledButton.tonalIcon(
                        onPressed: () => _reviewFeature(
                          feature: feature,
                          status: 'rejected',
                          onSuccess: () => Navigator.of(sheetContext).pop(),
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
    );
  }

  void _maybeOpenInitialFeatureDetails({
    required ProjectSummary project,
    required List<MapFeatureSummary> features,
    required bool canCollectOnMap,
    required bool canReview,
  }) {
    final targetFeatureId = _initialFeatureId;
    if (targetFeatureId == null ||
        targetFeatureId.isEmpty ||
        _autoOpenedFeatureId == targetFeatureId) {
      return;
    }

    MapFeatureSummary? fallbackFeature;
    for (final item in features) {
      if (item.id == targetFeatureId) {
        fallbackFeature = item;
        break;
      }
    }

    _autoOpenedFeatureId = targetFeatureId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(
        ref
            .read(projectFeatureDetailsProvider(targetFeatureId).future)
            .then((target) {
              if (!mounted) {
                return;
              }
              _openFeatureDetails(
                project: project,
                feature: target,
                canCollectOnMap: canCollectOnMap,
                canReview: canReview,
              );
            })
            .catchError((_) {
              if (!mounted) {
                return;
              }
              if (fallbackFeature != null) {
                _openFeatureDetails(
                  project: project,
                  feature: fallbackFeature,
                  canCollectOnMap: canCollectOnMap,
                  canReview: canReview,
                );
                return;
              }
              if (mounted) {
                _autoOpenedFeatureId = null;
              }
            }),
      );
    });
  }

  List<AiUncertaintyArea> _aiValidationTasksForProject({
    required String projectId,
    required AiUncertaintyAreasPage? assignedPage,
    required AiUncertaintyArea? focusedTask,
  }) {
    final tasksById = <String, AiUncertaintyArea>{};
    for (final task in assignedPage?.items ?? const <AiUncertaintyArea>[]) {
      if (task.projectId == projectId) {
        tasksById[task.id] = task;
      }
    }
    if (focusedTask != null && focusedTask.projectId == projectId) {
      tasksById[focusedTask.id] = focusedTask;
    }
    return tasksById.values.toList(growable: false);
  }

  void _maybeOpenInitialAiValidationTaskDetails({
    required ProjectSummary project,
    required List<AiUncertaintyArea> tasks,
  }) {
    final targetTaskId = _initialAiTaskId;
    if (targetTaskId == null ||
        targetTaskId.isEmpty ||
        _autoOpenedAiValidationTaskId == targetTaskId) {
      return;
    }

    AiUncertaintyArea? targetTask;
    for (final task in tasks) {
      if (task.id == targetTaskId) {
        targetTask = task;
        break;
      }
    }
    if (targetTask == null) {
      return;
    }

    _autoOpenedAiValidationTaskId = targetTaskId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _openAiValidationTaskDetails(project: project, task: targetTask!);
    });
  }

  void _focusFeature(
    MapFeatureSummary feature, {
    bool detailsSheetAware = false,
  }) {
    if (mounted && _focusedFeatureId != feature.id) {
      setState(() {
        _focusedFeatureId = feature.id;
      });
    }
    final points = geometryPoints(feature.geometry);
    if (points.isEmpty) {
      return;
    }
    _scheduleMainMapCameraAction(() {
      if (geometryPointsCollapseToSingleLocation(points)) {
        final target = geometryPointsCenter(points);
        if (target == null) {
          return;
        }
        final targetZoom = detailsSheetAware
            ? math.max(_latestMapCamera?.zoom ?? 17, 17)
            : 15.0;
        _mapController.move(
          target,
          targetZoom.clamp(_mapMinZoom, _mapMaxZoom).toDouble(),
        );
        return;
      }
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(points),
          padding: detailsSheetAware
              ? const EdgeInsets.fromLTRB(72, 72, 72, 300)
              : const EdgeInsets.all(48),
        ),
      );
    });
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

  Widget _projectPolygonLayer({
    required List<MapFeatureSummary> features,
    required ProjectSummary project,
    required bool canCollectOnMap,
    required bool canReview,
    bool interactive = true,
  }) {
    final layer = PolygonLayer<MapFeatureSummary>(
      polygons: _polygonOverlays(features),
      hitNotifier: interactive ? _projectPolygonHitNotifier : null,
    );
    if (!interactive) {
      return layer;
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      hitTestBehavior: HitTestBehavior.deferToChild,
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTap: () => _handleProjectGeometryLayerHit(
          _projectPolygonHitNotifier,
          project: project,
          canCollectOnMap: canCollectOnMap,
          canReview: canReview,
        ),
        child: layer,
      ),
    );
  }

  Widget _projectPolylineLayer({
    required List<MapFeatureSummary> features,
    required ProjectSummary project,
    required bool canCollectOnMap,
    required bool canReview,
    bool interactive = true,
  }) {
    final layer = PolylineLayer<MapFeatureSummary>(
      polylines: _polylineOverlays(features),
      hitNotifier: interactive ? _projectPolylineHitNotifier : null,
      minimumHitbox: 12,
    );
    if (!interactive) {
      return layer;
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      hitTestBehavior: HitTestBehavior.deferToChild,
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTap: () => _handleProjectGeometryLayerHit(
          _projectPolylineHitNotifier,
          project: project,
          canCollectOnMap: canCollectOnMap,
          canReview: canReview,
        ),
        child: layer,
      ),
    );
  }

  void _handleProjectGeometryLayerHit(
    LayerHitNotifier<MapFeatureSummary> notifier, {
    required ProjectSummary project,
    required bool canCollectOnMap,
    required bool canReview,
  }) {
    if (_isProjectMapCaptureMode) {
      return;
    }
    final hits = notifier.value?.hitValues;
    if (hits == null || hits.isEmpty) {
      return;
    }
    final feature = hits.first;
    if (feature.isAggregate) {
      _focusFeatureAggregate(feature);
      return;
    }
    _openFeatureDetails(
      project: project,
      feature: feature,
      canCollectOnMap: canCollectOnMap,
      canReview: canReview,
    );
  }

  Widget _aiValidationTaskPolygonLayer({
    required List<AiUncertaintyArea> tasks,
    required ProjectSummary project,
    bool interactive = true,
  }) {
    final layer = PolygonLayer<AiUncertaintyArea>(
      polygons: _aiValidationTaskPolygonOverlays(tasks),
      hitNotifier: interactive ? _aiValidationTaskPolygonHitNotifier : null,
    );
    return MouseRegion(
      cursor: interactive ? SystemMouseCursors.click : MouseCursor.defer,
      hitTestBehavior: HitTestBehavior.deferToChild,
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTap: interactive
            ? () => _handleAiValidationTaskLayerHit(
                _aiValidationTaskPolygonHitNotifier,
                project: project,
              )
            : null,
        child: layer,
      ),
    );
  }

  Widget _aiValidationTaskPolylineLayer({
    required List<AiUncertaintyArea> tasks,
    required ProjectSummary project,
    bool interactive = true,
  }) {
    final layer = PolylineLayer<AiUncertaintyArea>(
      polylines: _aiValidationTaskPolylineOverlays(tasks),
      hitNotifier: interactive ? _aiValidationTaskPolylineHitNotifier : null,
      minimumHitbox: 14,
    );
    return MouseRegion(
      cursor: interactive ? SystemMouseCursors.click : MouseCursor.defer,
      hitTestBehavior: HitTestBehavior.deferToChild,
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTap: interactive
            ? () => _handleAiValidationTaskLayerHit(
                _aiValidationTaskPolylineHitNotifier,
                project: project,
              )
            : null,
        child: layer,
      ),
    );
  }

  List<Polygon<AiUncertaintyArea>> _aiValidationTaskPolygonOverlays(
    List<AiUncertaintyArea> tasks,
  ) {
    final polygons = <Polygon<AiUncertaintyArea>>[];
    for (final task in tasks) {
      if (!isPolygonGeometry(task.geometry)) {
        continue;
      }
      final focused = _focusedAiValidationTaskId == task.id;
      for (final points in polygonGeometrySegments(task.geometry)) {
        if (!isValidPolygonRing(points)) {
          continue;
        }
        polygons.add(
          Polygon<AiUncertaintyArea>(
            points: points,
            color: _aiValidationTaskColor.withValues(
              alpha: focused ? 0.26 : 0.16,
            ),
            borderColor: focused ? Colors.black87 : _aiValidationTaskColor,
            borderStrokeWidth: focused ? 3.6 : 2.6,
            hitValue: task,
          ),
        );
      }
    }
    return polygons;
  }

  List<Polyline<AiUncertaintyArea>> _aiValidationTaskPolylineOverlays(
    List<AiUncertaintyArea> tasks,
  ) {
    final polylines = <Polyline<AiUncertaintyArea>>[];
    for (final task in tasks) {
      if (!isLineGeometry(task.geometry)) {
        continue;
      }
      final focused = _focusedAiValidationTaskId == task.id;
      for (final points in lineGeometrySegments(task.geometry)) {
        if (points.length < 2) {
          continue;
        }
        polylines.add(
          Polyline<AiUncertaintyArea>(
            points: points,
            color: focused ? Colors.black87 : _aiValidationTaskColor,
            strokeWidth: focused ? 5.2 : 4,
            hitValue: task,
          ),
        );
      }
    }
    return polylines;
  }

  List<Marker> _aiValidationTaskMarkerOverlays({
    required List<AiUncertaintyArea> tasks,
    required ProjectSummary project,
    bool interactive = true,
  }) {
    final markers = <Marker>[];
    for (final task in tasks) {
      final point = geometryFocusPoint(task.geometry);
      if (point == null) {
        continue;
      }
      final focused = _focusedAiValidationTaskId == task.id;
      markers.add(
        Marker(
          point: point,
          width: focused ? 48 : 40,
          height: focused ? 48 : 40,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: !interactive
                ? null
                : () => _openAiValidationTaskDetails(
                    project: project,
                    task: task,
                  ),
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _aiValidationTaskColor,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: focused ? Colors.black87 : Colors.white,
                    width: focused ? 2.4 : 1.8,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 7,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: const SizedBox.square(
                  dimension: 28,
                  child: Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.white,
                    size: 17,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return markers;
  }

  void _handleAiValidationTaskLayerHit(
    LayerHitNotifier<AiUncertaintyArea> notifier, {
    required ProjectSummary project,
  }) {
    if (_isProjectMapCaptureMode) {
      return;
    }
    final hits = notifier.value?.hitValues;
    if (hits == null || hits.isEmpty) {
      return;
    }
    _openAiValidationTaskDetails(project: project, task: hits.first);
  }

  void _openAiValidationTaskDetails({
    required ProjectSummary project,
    required AiUncertaintyArea task,
  }) {
    _focusAiValidationTask(task);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _AiValidationTaskDetailsSheet(
        project: project,
        task: task,
        canSubmit: _canSubmitAiValidationTask(task),
        onSubmit: () {
          Navigator.of(sheetContext).pop();
          showAiUncertaintySubmitDialog(
            context,
            task: task,
            onSubmitted: () => bumpWorkflowRefresh(ref),
          );
        },
      ),
    );
  }

  bool _canSubmitAiValidationTask(AiUncertaintyArea task) {
    final user = ref.read(authControllerProvider).session?.user;
    return user?.role == UserRole.contributor &&
        task.assignedTo == user?.id &&
        (task.status == 'assigned' || task.status == 'in_progress');
  }

  void _focusAiValidationTask(AiUncertaintyArea task) {
    final points = geometryPoints(task.geometry);
    setState(() => _focusedAiValidationTaskId = task.id);
    if (points.isEmpty) {
      return;
    }
    _runMainMapAction(() {
      if (points.length > 1 &&
          !geometryPointsCollapseToSingleLocation(points)) {
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(points),
            padding: const EdgeInsets.all(76),
            maxZoom: 16,
          ),
        );
        return;
      }
      final center = geometryPointsCenter(points);
      if (center != null) {
        _mapController.move(center, 16);
      }
    }, queueUntilReady: true);
  }

  Widget _publishedAiPolygonLayer(List<AiLayerFeatureCollection> collections) {
    final layer = PolygonLayer<_PublishedAiMapFeature>(
      polygons: _publishedAiPolygonOverlays(collections),
      hitNotifier: _publishedAiPolygonHitNotifier,
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      hitTestBehavior: HitTestBehavior.deferToChild,
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTap: () => _handlePublishedAiLayerHit(_publishedAiPolygonHitNotifier),
        child: layer,
      ),
    );
  }

  Widget _publishedAiPolylineLayer(List<AiLayerFeatureCollection> collections) {
    final layer = PolylineLayer<_PublishedAiMapFeature>(
      polylines: _publishedAiPolylineOverlays(collections),
      hitNotifier: _publishedAiPolylineHitNotifier,
      minimumHitbox: 12,
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      hitTestBehavior: HitTestBehavior.deferToChild,
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTap: () =>
            _handlePublishedAiLayerHit(_publishedAiPolylineHitNotifier),
        child: layer,
      ),
    );
  }

  void _handlePublishedAiLayerHit(
    LayerHitNotifier<_PublishedAiMapFeature> notifier,
  ) {
    if (_isProjectMapCaptureMode) {
      return;
    }
    final hits = notifier.value?.hitValues;
    if (hits == null || hits.isEmpty) {
      return;
    }
    final selected = hits.firstWhere(
      (item) => !_publishedAiIsAggregate(item.feature),
      orElse: () => hits.first,
    );
    if (_publishedAiIsAggregate(selected.feature)) {
      _focusPublishedAiAggregate(selected);
      return;
    }
    _openPublishedAiFeatureDetails(selected);
  }

  List<Polygon<_PublishedAiMapFeature>> _publishedAiPolygonOverlays(
    List<AiLayerFeatureCollection> collections,
  ) {
    final polygons = <Polygon<_PublishedAiMapFeature>>[];
    for (final item in _publishedAiFeatures(
      collections,
      focusedOverride: _focusedPublishedAiFeatureOverride,
    )) {
      if (!isPolygonGeometry(item.feature.geometry)) {
        continue;
      }
      final focused = _focusedPublishedAiFeatureKey == item.key;
      final style = _publishedAiFeatureStyle(item, focused: focused);
      for (final points in polygonGeometrySegments(item.feature.geometry)) {
        if (!isValidPolygonRing(points)) {
          continue;
        }
        polygons.add(
          Polygon<_PublishedAiMapFeature>(
            points: points,
            color: style.fillColor,
            borderStrokeWidth: style.borderWidth,
            borderColor: style.borderColor,
            hitValue: item,
          ),
        );
      }
    }
    return polygons;
  }

  List<Polyline<_PublishedAiMapFeature>> _publishedAiPolylineOverlays(
    List<AiLayerFeatureCollection> collections,
  ) {
    final polylines = <Polyline<_PublishedAiMapFeature>>[];
    for (final item in _publishedAiFeatures(
      collections,
      focusedOverride: _focusedPublishedAiFeatureOverride,
    )) {
      if (!isLineGeometry(item.feature.geometry)) {
        continue;
      }
      final focused = _focusedPublishedAiFeatureKey == item.key;
      final style = _publishedAiFeatureStyle(item, focused: focused);
      for (final points in lineGeometrySegments(item.feature.geometry)) {
        if (points.length < 2) {
          continue;
        }
        polylines.add(
          Polyline<_PublishedAiMapFeature>(
            points: points,
            color: style.borderColor,
            strokeWidth: math.max(2.8, style.borderWidth),
            hitValue: item,
          ),
        );
      }
    }
    return polylines;
  }

  List<Marker> _publishedAiMarkerOverlays(
    List<AiLayerFeatureCollection> collections,
  ) {
    final markers = <Marker>[];
    for (final item in _publishedAiFeatures(
      collections,
      focusedOverride: _focusedPublishedAiFeatureOverride,
    )) {
      if (!isPointGeometry(item.feature.geometry)) {
        continue;
      }
      final focused = _focusedPublishedAiFeatureKey == item.key;
      final style = _publishedAiFeatureStyle(item, focused: focused);
      final aggregate = _publishedAiIsAggregate(item.feature);
      for (final point in pointGeometryPoints(item.feature.geometry)) {
        markers.add(
          Marker(
            point: point,
            width: aggregate ? 28 : 24,
            height: aggregate ? 28 : 24,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                if (aggregate) {
                  _focusPublishedAiAggregate(item);
                  return;
                }
                _openPublishedAiFeatureDetails(item);
              },
              child: Center(
                child: Container(
                  width: aggregate ? 18 : 14,
                  height: aggregate ? 18 : 14,
                  decoration: BoxDecoration(
                    color: style.borderColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.8),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 5,
                        offset: Offset(0, 2),
                      ),
                    ],
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

  void _focusPublishedAiAggregate(_PublishedAiMapFeature item) {
    final point = geometryFocusPoint(item.feature.geometry);
    if (point == null) {
      return;
    }
    _runMainMapAction(() {
      _mapController.move(
        point,
        math.max((_latestMapCamera?.zoom ?? _defaultMapZoom) + 1.8, 12),
      );
    }, queueUntilReady: true);
  }

  void _openPublishedAiFeatureDetails(_PublishedAiMapFeature item) {
    _focusPublishedAiFeature(item);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _PublishedAiFeatureDetailsSheet(item: item),
    );
  }

  void _focusPublishedAiFeature(_PublishedAiMapFeature item) {
    final points = geometryPoints(item.feature.geometry);
    setState(() {
      _focusedPublishedAiFeatureKey = item.key;
      _focusedPublishedAiFeatureOverride = item;
    });
    if (points.isEmpty) {
      return;
    }
    _runMainMapAction(() {
      if (points.length > 1 &&
          !geometryPointsCollapseToSingleLocation(points)) {
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(points),
            padding: const EdgeInsets.all(72),
            maxZoom: 16,
          ),
        );
        return;
      }
      final center = geometryPointsCenter(points);
      if (center != null) {
        _mapController.move(center, 16);
      }
    }, queueUntilReady: true);
  }

  List<Polygon<MapFeatureSummary>> _polygonOverlays(
    List<MapFeatureSummary> features,
  ) {
    final polygons = <Polygon<MapFeatureSummary>>[];
    for (final feature in features) {
      if (!isPolygonGeometry(feature.geometry)) {
        continue;
      }
      final color = _statusColor(feature.status);
      final focused = _focusedFeatureId == feature.id;
      for (final points in polygonGeometrySegments(feature.geometry)) {
        if (!isValidPolygonRing(points)) {
          continue;
        }
        polygons.add(
          Polygon<MapFeatureSummary>(
            points: points,
            color: color.withValues(alpha: focused ? 0.24 : 0.12),
            borderStrokeWidth: focused ? 3.2 : 2,
            borderColor: focused
                ? Colors.black87
                : color.withValues(alpha: 0.95),
            hitValue: feature,
          ),
        );
      }
    }
    return polygons;
  }

  List<Polyline<MapFeatureSummary>> _polylineOverlays(
    List<MapFeatureSummary> features,
  ) {
    final polylines = <Polyline<MapFeatureSummary>>[];
    for (final feature in features) {
      if (!isLineGeometry(feature.geometry)) {
        continue;
      }
      final focused = _focusedFeatureId == feature.id;
      for (final points in lineGeometrySegments(feature.geometry)) {
        if (points.isEmpty) {
          continue;
        }
        polylines.add(
          Polyline<MapFeatureSummary>(
            points: points,
            color: _statusColor(feature.status).withValues(alpha: 0.9),
            strokeWidth: focused ? 5 : 3.2,
            hitValue: feature,
          ),
        );
      }
    }
    return polylines;
  }

  List<Marker> _markerOverlays(
    List<MapFeatureSummary> features,
    ProjectSummary project,
    bool canCollectOnMap,
    bool canReview, {
    bool interactive = true,
  }) {
    final grouped = <String, List<(MapFeatureSummary, LatLng)>>{};
    for (final feature in features) {
      final points = pointGeometryPoints(feature.geometry);
      if (points.isEmpty) {
        continue;
      }
      for (final point in points) {
        final key =
            '${point.latitude.toStringAsFixed(7)}:${point.longitude.toStringAsFixed(7)}';
        grouped.putIfAbsent(key, () => <(MapFeatureSummary, LatLng)>[]).add((
          feature,
          point,
        ));
      }
    }

    final markers = <Marker>[];
    for (final entries in grouped.values) {
      for (var index = 0; index < entries.length; index++) {
        final entry = entries[index];
        final feature = entry.$1;
        final basePoint = entry.$2;
        final markerPoint = entries.length == 1
            ? basePoint
            : _spreadDuplicateMarkerPoint(
                basePoint,
                duplicateIndex: index,
                duplicateCount: entries.length,
              );
        final color = _statusColor(feature.status);
        final isFocused = _focusedFeatureId == feature.id;
        markers.add(
          Marker(
            point: markerPoint,
            width: isFocused ? 42 : 34,
            height: isFocused ? 42 : 34,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: !interactive
                  ? null
                  : () {
                      if (feature.isAggregate) {
                        _focusFeatureAggregate(feature);
                        return;
                      }
                      _focusFeature(feature, detailsSheetAware: true);
                      _openFeatureDetails(
                        project: project,
                        feature: feature,
                        canCollectOnMap: canCollectOnMap,
                        canReview: canReview,
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
                      color: isFocused ? Colors.black87 : Colors.white,
                      width: isFocused ? 2.4 : 1.8,
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
                    feature.status == 'approved'
                        ? Icons.check
                        : feature.status == 'rejected'
                        ? Icons.close
                        : Icons.schedule,
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

  void _focusFeatureAggregate(MapFeatureSummary feature) {
    final point = _pointFromGeometry(feature.geometry);
    if (point == null) {
      return;
    }
    _runMainMapAction(() {
      _mapController.move(
        point,
        math.max((_latestMapCamera?.zoom ?? _defaultMapZoom) + 1.6, 11),
      );
    }, queueUntilReady: true);
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
    final radiusMeters = 16.0 + (ring * 12.0);
    final latOffset = (radiusMeters / 111320.0) * math.sin(angle);
    final longitudeScale = math.cos(origin.latitude * math.pi / 180).abs();
    final lngMetersDivisor =
        111320.0 * (longitudeScale < 0.1 ? 0.1 : longitudeScale);
    final lngOffset = (radiusMeters / lngMetersDivisor) * math.cos(angle);
    return LatLng(origin.latitude + latOffset, origin.longitude + lngOffset);
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

  String _statusFilterLabel(String status) {
    switch (status) {
      case 'pending_review':
        return 'Pending review';
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
    final normalizedType = type.toLowerCase();
    if (normalizedType == 'point' && focusPoint != null) {
      return 'Point feature at ${focusPoint.latitude.toStringAsFixed(5)}, ${focusPoint.longitude.toStringAsFixed(5)}';
    }
    if (normalizedType == 'multipoint') {
      return 'Point feature with ${geometryPoints(geometry).length} points';
    }
    if (normalizedType == 'linestring' || normalizedType == 'multilinestring') {
      return 'Line feature with ${lineGeometryPoints(geometry).length} vertices';
    }
    if (normalizedType == 'polygon' || normalizedType == 'multipolygon') {
      return 'Polygon feature with ${polygonGeometryPoints(geometry).length} boundary points';
    }
    return _projectFeatureTypeLabel(type);
  }

  String _formatDateTime(DateTime value) {
    return formatLebanonDateTime(value);
  }

  String _photoLabel(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/');
    return segments.isEmpty ? path : segments.last;
  }
}

List<AiOutputLayer> _publishedAiMapLayers(List<AiOutputLayer> layers) {
  const types = {'classification', 'confidence', 'uncertainty'};
  final latestByType = <String, AiOutputLayer>{};
  for (final layer in layers.where(
    (layer) => layer.status == 'published' && types.contains(layer.layerType),
  )) {
    final existing = latestByType[layer.layerType];
    if (existing == null || _isNewerPublishedLayer(layer, existing)) {
      latestByType[layer.layerType] = layer;
    }
  }
  return [
    for (final type in const ['classification', 'confidence', 'uncertainty'])
      if (latestByType[type] != null) latestByType[type]!,
  ];
}

bool _isNewerPublishedLayer(AiOutputLayer candidate, AiOutputLayer current) {
  final candidateDate =
      candidate.publishedAt ?? candidate.updatedAt ?? candidate.createdAt;
  final currentDate =
      current.publishedAt ?? current.updatedAt ?? current.createdAt;
  if (candidateDate == null) {
    return currentDate == null && candidate.id.compareTo(current.id) > 0;
  }
  if (currentDate == null) {
    return true;
  }
  return candidateDate.isAfter(currentDate);
}

List<String> _publishedAiLayerTypes(List<AiOutputLayer> layers) {
  return [
    for (final type in const ['classification', 'confidence', 'uncertainty'])
      if (layers.any((layer) => layer.layerType == type)) type,
  ];
}

AiLayerFeaturesQuery _publishedAiLayerViewportQuery(
  AiOutputLayer layer,
  ProjectMapViewportQuery viewport, {
  String? classLabel,
}) {
  final detail = viewport.zoom >= 13 ? 'full' : 'overview';
  final geometry = viewport.zoom < 11
      ? 'aggregate'
      : viewport.zoom < 13
      ? 'simplified'
      : 'full';
  return AiLayerFeaturesQuery(
    layerId: layer.id,
    detail: detail,
    geometry: geometry,
    bounds:
        '${viewport.minLon},${viewport.minLat},${viewport.maxLon},${viewport.maxLat}',
    zoom: viewport.zoom,
    limit: 900,
    classLabel: classLabel,
  );
}

List<String> _publishedAiClassOptions(
  List<AiLayerFeatureCollection> collections,
) {
  final values = <String>{};
  for (final collection in collections) {
    if (collection.layer.layerType != 'classification') {
      continue;
    }
    values.addAll(
      collection.classCounts.keys.where((value) => value.trim().isNotEmpty),
    );
    for (final feature in collection.features) {
      final className = _publishedAiFeatureClass(feature);
      if (className != null && className.trim().isNotEmpty) {
        values.add(className);
      }
    }
  }
  final sorted = values.toList(growable: false);
  sorted.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return sorted;
}

Map<String, int> _publishedAiLayerCountsByType(
  List<AiLayerFeatureCollection> collections,
) {
  final counts = <String, int>{};
  for (final collection in collections) {
    final type = collection.layer.layerType;
    counts[type] = math.max(counts[type] ?? 0, collection.featureCount);
  }
  return counts;
}

Map<String, Map<String, int>> _publishedAiLayerClassCountsByType(
  List<AiLayerFeatureCollection> collections,
) {
  final counts = <String, Map<String, int>>{};
  for (final collection in collections) {
    final layerCounts = <String, int>{};
    collection.classCounts.forEach((label, count) {
      if (label.trim().isEmpty || count < 0) {
        return;
      }
      layerCounts[label] = count;
    });
    if (layerCounts.isNotEmpty) {
      counts[collection.layer.layerType] = layerCounts;
    }
  }
  return counts;
}

String _publishedAiLayerChipLabel(String layerType, int? count) {
  final label = _publishedAiFriendlyLayerType(layerType);
  if (count == null) {
    return label;
  }
  return '$label $count';
}

String _assignedValidationTaskLabel(AiUncertaintyArea task) {
  if (task.assignedToName?.trim().isNotEmpty == true) {
    return 'Assigned to ${task.assignedToName!.trim()}';
  }
  if (task.assignedToEmail?.trim().isNotEmpty == true) {
    return 'Assigned to ${task.assignedToEmail!.trim()}';
  }
  if (task.assignedTo?.trim().isNotEmpty == true) {
    return 'Assigned';
  }
  return 'Unassigned';
}

String _geometrySummaryForTask(Map<String, dynamic> geometry) {
  final type = geometry['type']?.toString() ?? 'Unknown';
  final normalizedType = type.toLowerCase();
  final focusPoint = geometryFocusPoint(geometry);
  if (normalizedType == 'point' && focusPoint != null) {
    return 'Point at ${focusPoint.latitude.toStringAsFixed(5)}, ${focusPoint.longitude.toStringAsFixed(5)}';
  }
  if (normalizedType == 'multipoint') {
    return 'Point task with ${geometryPoints(geometry).length} points';
  }
  if (normalizedType == 'linestring' || normalizedType == 'multilinestring') {
    return 'Line task with ${lineGeometryPoints(geometry).length} vertices';
  }
  if (normalizedType == 'polygon' || normalizedType == 'multipolygon') {
    return 'Polygon task with ${polygonGeometryPoints(geometry).length} boundary points';
  }
  return type;
}

List<_PublishedAiMapFeature> _publishedAiFeatures(
  List<AiLayerFeatureCollection> collections, {
  _PublishedAiMapFeature? focusedOverride,
}) {
  final items = <_PublishedAiMapFeature>[
    for (final collection in collections)
      for (final feature in collection.features)
        _PublishedAiMapFeature(layer: collection.layer, feature: feature),
  ];
  if (focusedOverride == null ||
      items.any((item) => item.key == focusedOverride.key)) {
    return items;
  }
  return <_PublishedAiMapFeature>[...items, focusedOverride];
}

class _PublishedAiMapFeature {
  const _PublishedAiMapFeature({required this.layer, required this.feature});

  final AiOutputLayer layer;
  final AiLayerFeature feature;

  String get key => '${layer.id}:${feature.id}';
}

class _PublishedAiStyle {
  const _PublishedAiStyle({
    required this.fillColor,
    required this.borderColor,
    required this.borderWidth,
  });

  final Color fillColor;
  final Color borderColor;
  final double borderWidth;
}

_PublishedAiStyle _publishedAiFeatureStyle(
  _PublishedAiMapFeature item, {
  bool focused = false,
}) {
  switch (item.layer.layerType) {
    case 'confidence':
      final confidence = _publishedAiFeatureConfidence(item.feature);
      final alpha = confidence == null
          ? 0.20
          : (0.10 + confidence.clamp(0, 1).toDouble() * 0.28);
      return _PublishedAiStyle(
        fillColor: const Color(0xFF0288D1).withValues(alpha: alpha),
        borderColor: focused ? Colors.black87 : const Color(0xFF01579B),
        borderWidth: focused ? 3.2 : 2,
      );
    case 'uncertainty':
      return _PublishedAiStyle(
        fillColor: const Color(0xFFE65100).withValues(alpha: 0.22),
        borderColor: focused ? Colors.black87 : const Color(0xFFBF360C),
        borderWidth: focused ? 3.4 : 2.2,
      );
    case 'classification':
    default:
      final color = _publishedAiClassColor(
        _publishedAiFeatureClass(item.feature),
      );
      return _PublishedAiStyle(
        fillColor: color.withValues(alpha: 0.18),
        borderColor: focused ? Colors.black87 : color,
        borderWidth: focused ? 3.2 : 2,
      );
  }
}

Color _publishedAiClassColor(String? className) {
  final normalized = (className ?? '').toLowerCase();
  if (normalized.contains('citrus')) {
    return const Color(0xFFF9A825);
  }
  if (normalized.contains('fruit')) {
    return const Color(0xFF7B1FA2);
  }
  if (normalized.contains('olive')) {
    return const Color(0xFF2E7D32);
  }
  return const Color(0xFF00695C);
}

Color _publishedAiLayerTypeColor(String layerType) {
  switch (layerType) {
    case 'confidence':
      return const Color(0xFF0288D1);
    case 'uncertainty':
      return const Color(0xFFE65100);
    case 'classification':
    default:
      return const Color(0xFF2E7D32);
  }
}

String? _publishedAiFeatureClass(AiLayerFeature feature) {
  for (final key in const [
    'predicted_class',
    'dominant_class',
    'class_label',
    'label',
    'L4_descr',
  ]) {
    final value = feature.properties[key]?.toString().trim();
    if (value != null && value.isNotEmpty) {
      return value;
    }
  }
  return null;
}

double? _publishedAiFeatureConfidence(AiLayerFeature feature) {
  final raw = feature.properties['confidence'];
  if (raw is num) {
    return raw.toDouble();
  }
  if (raw is String) {
    return double.tryParse(raw);
  }
  return null;
}

bool _publishedAiIsAggregate(AiLayerFeature feature) {
  return feature.properties['aggregate'] == true ||
      feature.properties['preview_kind'] == 'aggregate';
}

String? _publishedAiFeatureText(AiLayerFeature feature, List<String> keys) {
  for (final key in keys) {
    final value = feature.properties[key]?.toString().trim();
    if (value != null && value.isNotEmpty) {
      return value;
    }
  }
  return null;
}

String _publishedAiFriendlyLayerType(String type) {
  switch (type) {
    case 'confidence':
      return 'Confidence';
    case 'uncertainty':
      return 'Uncertainty';
    case 'classification':
      return 'Classification';
    default:
      return 'AI layer';
  }
}

String _publishedAiFriendlyClass(String value) {
  return value
      .replaceAll('_', ' ')
      .split(' ')
      .where((part) => part.trim().isNotEmpty)
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');
}

String _publishedAiFormatConfidence(double value) =>
    '${(value * 100).clamp(0, 100).toStringAsFixed(1)}%';

class _PublishedAiFeatureDetailsSheet extends StatelessWidget {
  const _PublishedAiFeatureDetailsSheet({required this.item});

  final _PublishedAiMapFeature item;

  @override
  Widget build(BuildContext context) {
    final feature = item.feature;
    final className = _publishedAiFeatureClass(feature);
    final confidence = _publishedAiFeatureConfidence(feature);
    final bottomInset =
        MediaQuery.viewPaddingOf(context).bottom + AppSpacing.lg;
    final model = _publishedAiFeatureText(feature, const [
      'model_name',
      'model',
    ]);
    final source =
        _publishedAiFeatureText(feature, const ['source']) ?? 'AI prediction';
    final runId = _publishedAiFeatureText(feature, const ['run_id']);
    final area = _publishedAiFeatureText(feature, const ['area_ha', 'area']);
    final attributes = <String, dynamic>{
      'layer': _publishedAiFriendlyLayerType(item.layer.layerType),
      'source': source,
    };
    if (className != null) {
      attributes['predicted_class'] = _publishedAiFriendlyClass(className);
    }
    if (confidence != null) {
      attributes['confidence'] = _publishedAiFormatConfidence(confidence);
    }
    if (model != null) {
      attributes['model'] = model;
    }
    if (area != null) {
      attributes['area'] = area;
    }
    if (runId != null) {
      attributes['run_id'] = runId;
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.45,
      maxChildSize: 0.94,
      builder: (context, controller) => ListView(
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
                      className == null
                          ? 'AI prediction'
                          : _publishedAiFriendlyClass(className),
                      style: Theme.of(context).textTheme.titleLarge,
                      softWrap: true,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_publishedAiFriendlyLayerType(item.layer.layerType)} layer - read only',
                      style: Theme.of(context).textTheme.bodySmall,
                      softWrap: true,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              StatusChip(status: 'published'),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _DetailSection(
            title: 'Prediction details',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (className != null)
                      _MapInfoPill(
                        icon: Icons.category_outlined,
                        label: _publishedAiFriendlyClass(className),
                      ),
                    if (confidence != null)
                      _MapInfoPill(
                        icon: Icons.speed_outlined,
                        label:
                            'Confidence ${_publishedAiFormatConfidence(confidence)}',
                      ),
                    _MapInfoPill(
                      icon: Icons.layers_outlined,
                      label: _publishedAiFriendlyLayerType(
                        item.layer.layerType,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (attributes.isNotEmpty)
            _DetailSection(
              title: 'Attributes',
              child: _FeatureAttributesGrid(attributes: attributes),
            ),
          const _DetailSection(
            title: 'Data status',
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline, size: 20),
                SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Read-only AI prediction. Not approved field data and not editable.',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AiValidationTaskDetailsSheet extends StatelessWidget {
  const _AiValidationTaskDetailsSheet({
    required this.project,
    required this.task,
    required this.canSubmit,
    required this.onSubmit,
  });

  final ProjectSummary project;
  final AiUncertaintyArea task;
  final bool canSubmit;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final bottomInset =
        MediaQuery.viewPaddingOf(context).bottom + AppSpacing.lg;
    final linkedFeatureId = task.validatedFeatureId?.trim();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      minChildSize: 0.42,
      maxChildSize: 0.94,
      builder: (context, controller) => ListView(
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
                      aiUncertaintyClassLabel(task),
                      style: Theme.of(context).textTheme.titleLarge,
                      softWrap: true,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${project.name} - AI validation task ${aiUncertaintyCompactId(task.id)}',
                      style: Theme.of(context).textTheme.bodySmall,
                      softWrap: true,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              StatusChip(status: task.status),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          const AiUncertaintyTaskWarning(),
          const SizedBox(height: AppSpacing.md),
          _DetailSection(
            title: 'AI uncertainty',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AiUncertaintyMetricPills(task: task, includeStatus: false),
                const SizedBox(height: AppSpacing.sm),
                Text(_geometrySummaryForTask(task.geometry), softWrap: true),
              ],
            ),
          ),
          _DetailSection(
            title: 'Assignment',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MapInfoPill(
                  icon: Icons.person_outline,
                  label: _assignedValidationTaskLabel(task),
                ),
                if (task.aiRunId.trim().isNotEmpty)
                  _MapInfoPill(
                    icon: Icons.memory_outlined,
                    label: 'Run ${aiUncertaintyCompactId(task.aiRunId)}',
                  ),
              ],
            ),
          ),
          if (linkedFeatureId != null && linkedFeatureId.isNotEmpty)
            _DetailSection(
              title: 'Linked feature',
              child: Text(
                '$linkedFeatureId (${task.validatedFeatureStatus ?? 'review pending'})',
                softWrap: true,
              ),
            ),
          if (canSubmit)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: AppActionButtons(
                maxColumns: 1,
                fillRows: true,
                children: [
                  FilledButton.icon(
                    onPressed: onSubmit,
                    icon: const Icon(Icons.link_outlined),
                    label: const Text('Submit/link validation'),
                  ),
                ],
              ),
            ),
          const _DetailSection(
            title: 'Data status',
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline, size: 20),
                SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Validation target only. It is not official field data and cannot be edited or deleted as a project feature.',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProjectMapFloatingPanel extends StatelessWidget {
  const _ProjectMapFloatingPanel({
    required this.project,
    required this.featureCount,
    required this.searchController,
    required this.searchFocusNode,
    required this.quickFeatureChips,
    required this.selectedFeatureChip,
    required this.visibleStatuses,
    required this.basemapStyle,
    required this.isExpanded,
    required this.isSearchOpen,
    required this.searchSummaryLabel,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.onSearchPressed,
    required this.onChipSelected,
    required this.onResetVisibleStatuses,
    required this.onToggleVisibleStatus,
    required this.visibleStatusSummaryLabel,
    required this.onBasemapStyleChanged,
    required this.publishedAiLayerTypes,
    required this.publishedAiClassOptions,
    required this.publishedAiLayerCounts,
    required this.selectedPublishedAiClass,
    required this.hasNoPublishedAiClassMatches,
    required this.allowNoOfficialFeatureFilter,
    required this.visiblePublishedAiLayerTypes,
    required this.onPublishedAiClassSelected,
    required this.onPublishedAiLayerTypeSelected,
    required this.showPublishedAiLayers,
    required this.onTogglePublishedAiLayers,
    required this.onOpenOfflineTools,
    required this.onToggleExpanded,
    required this.onHidePanel,
    required this.canFilterStatuses,
  });

  final ProjectSummary project;
  final int featureCount;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final List<String> quickFeatureChips;
  final String? selectedFeatureChip;
  final Set<String> visibleStatuses;
  final LebanonBasemapStyle basemapStyle;
  final bool isExpanded;
  final bool isSearchOpen;
  final String? searchSummaryLabel;
  final VoidCallback onSearchChanged;
  final VoidCallback onClearSearch;
  final VoidCallback onSearchPressed;
  final ValueChanged<String?> onChipSelected;
  final VoidCallback onResetVisibleStatuses;
  final ValueChanged<String> onToggleVisibleStatus;
  final String visibleStatusSummaryLabel;
  final ValueChanged<LebanonBasemapStyle> onBasemapStyleChanged;
  final List<String> publishedAiLayerTypes;
  final List<String> publishedAiClassOptions;
  final Map<String, int> publishedAiLayerCounts;
  final String? selectedPublishedAiClass;
  final bool hasNoPublishedAiClassMatches;
  final bool allowNoOfficialFeatureFilter;
  final Set<String> visiblePublishedAiLayerTypes;
  final ValueChanged<String?> onPublishedAiClassSelected;
  final void Function(String layerType, bool selected)
  onPublishedAiLayerTypeSelected;
  final bool showPublishedAiLayers;
  final ValueChanged<bool>? onTogglePublishedAiLayers;
  final VoidCallback? onOpenOfflineTools;
  final VoidCallback onToggleExpanded;
  final VoidCallback onHidePanel;
  final bool canFilterStatuses;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final openOfflineTools = onOpenOfflineTools;
    final officialFeatureFilterLabel = selectedFeatureChip ?? 'All features';
    final hasVisibleOfficialFeatureChip =
        selectedFeatureChip != null &&
        selectedFeatureChip != _MapScreenState._noOfficialFeatureFilter;
    final visibleCountLabel = featureCount == 1
        ? '1 feature'
        : '$featureCount features';
    final categoryLabel = project.category.trim().isEmpty
        ? 'Project'
        : project.category.trim();

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
                ? 176.0
                : constraints.maxWidth >= 370
                ? 140.0
                : 104.0;
            final metaMaxWidth = constraints.maxWidth >= 420
                ? 152.0
                : constraints.maxWidth >= 360
                ? 126.0
                : 104.0;
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
                                project.name,
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
                                    label: categoryLabel,
                                    maxWidth: metaMaxWidth,
                                    textStyle: theme.textTheme.labelSmall
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                  _CompactMapMetaPill(
                                    icon: showPublishedAiLayers
                                        ? Icons.auto_awesome_outlined
                                        : Icons.place_outlined,
                                    label: visibleCountLabel,
                                    maxWidth: metaMaxWidth - 12,
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
                              if (openOfflineTools != null)
                                _MapPanelIconButton(
                                  tooltip: 'Offline map',
                                  icon: Icons.download_for_offline_outlined,
                                  onPressed: openOfflineTools,
                                ),
                              _MapPanelIconButton(
                                tooltip: isSearchOpen
                                    ? 'Close search'
                                    : 'Search map',
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
                        hintText: 'Search visible features',
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
                        !_isDefaultStatusSummary(visibleStatusSummaryLabel) ||
                        selectedFeatureChip != null ||
                        showPublishedAiLayers) ...[
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
                          if (canFilterStatuses &&
                              !_isDefaultStatusSummary(
                                visibleStatusSummaryLabel,
                              ))
                            _MapInfoPill(
                              icon: Icons.visibility_outlined,
                              label: visibleStatusSummaryLabel,
                            ),
                          if (hasVisibleOfficialFeatureChip)
                            _MapInfoPill(
                              icon: Icons.layers_outlined,
                              label: officialFeatureFilterLabel,
                            ),
                        ],
                      ),
                    ],
                  ],
                  if (isExpanded) ...[
                    const SizedBox(height: 10),
                    if (onTogglePublishedAiLayers != null) ...[
                      FilterChip(
                        avatar: const Icon(
                          Icons.auto_awesome_outlined,
                          size: 18,
                        ),
                        label: Text(
                          showPublishedAiLayers
                              ? 'Hide published AI layer'
                              : 'Show published AI layer',
                        ),
                        selected: showPublishedAiLayers,
                        onSelected: onTogglePublishedAiLayers,
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (showPublishedAiLayers) ...[
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (
                              var index = 0;
                              index < publishedAiLayerTypes.length;
                              index += 1
                            ) ...[
                              if (index > 0) const SizedBox(width: 8),
                              _LegendFilterChip(
                                label: _publishedAiLayerChipLabel(
                                  publishedAiLayerTypes[index],
                                  publishedAiLayerCounts[publishedAiLayerTypes[index]],
                                ),
                                color: _publishedAiLayerTypeColor(
                                  publishedAiLayerTypes[index],
                                ),
                                selected: visiblePublishedAiLayerTypes.contains(
                                  publishedAiLayerTypes[index],
                                ),
                                onSelected: (selected) =>
                                    onPublishedAiLayerTypeSelected(
                                      publishedAiLayerTypes[index],
                                      selected,
                                    ),
                              ),
                            ],
                            if (visiblePublishedAiLayerTypes.length !=
                                publishedAiLayerTypes.length) ...[
                              const SizedBox(width: 8),
                              ActionChip(
                                avatar: const Icon(Icons.clear, size: 18),
                                label: const Text('All layers'),
                                onPressed: () {
                                  for (final layerType
                                      in publishedAiLayerTypes) {
                                    onPublishedAiLayerTypeSelected(
                                      layerType,
                                      true,
                                    );
                                  }
                                },
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (visiblePublishedAiLayerTypes.contains(
                            'classification',
                          ) &&
                          publishedAiClassOptions.isNotEmpty) ...[
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              ChoiceChip(
                                label: const Text('All classes'),
                                selected: selectedPublishedAiClass == null,
                                onSelected: (_) =>
                                    onPublishedAiClassSelected(null),
                              ),
                              for (final className
                                  in publishedAiClassOptions) ...[
                                const SizedBox(width: 8),
                                _LegendFilterChip(
                                  label: _publishedAiFriendlyClass(className),
                                  color: _publishedAiClassColor(className),
                                  selected:
                                      selectedPublishedAiClass == className,
                                  onSelected: (selected) =>
                                      onPublishedAiClassSelected(
                                        selected ? className : null,
                                      ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        if (hasNoPublishedAiClassMatches) ...[
                          const Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.search_off_outlined, size: 18),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'No AI predictions match this class.',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                        ],
                      ],
                    ],
                    if (canFilterStatuses) ...[
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            FilterChip(
                              label: const Text('All pins'),
                              selected:
                                  visibleStatuses.length ==
                                  _MapScreenState._projectMapStatusOrder.length,
                              onSelected: (_) => onResetVisibleStatuses(),
                            ),
                            for (final status
                                in _MapScreenState._projectMapStatusOrder) ...[
                              const SizedBox(width: 8),
                              FilterChip(
                                label: Text(_statusFilterLabel(status)),
                                selected: visibleStatuses.contains(status),
                                onSelected: (_) =>
                                    onToggleVisibleStatus(status),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          ChoiceChip(
                            label: const Text('All'),
                            selected: selectedFeatureChip == null,
                            onSelected: (_) => onChipSelected(null),
                          ),
                          if (allowNoOfficialFeatureFilter) ...[
                            const SizedBox(width: 8),
                            ChoiceChip(
                              avatar: const Icon(
                                Icons.visibility_off_outlined,
                                size: 18,
                              ),
                              label: const Text('None'),
                              selected:
                                  selectedFeatureChip ==
                                  _MapScreenState._noOfficialFeatureFilter,
                              onSelected: (selected) => onChipSelected(
                                selected
                                    ? _MapScreenState._noOfficialFeatureFilter
                                    : null,
                              ),
                            ),
                          ],
                          for (final chip in quickFeatureChips) ...[
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: Text(chip),
                              selected: selectedFeatureChip == chip,
                              onSelected: (selected) =>
                                  onChipSelected(selected ? chip : null),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _MapInfoPill(
                          icon: _basemapStyleIcon(basemapStyle),
                          label:
                              '${LebanonMapConfig.basemapLabel(basemapStyle)} view',
                        ),
                      ],
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

  String _statusFilterLabel(String status) {
    switch (status) {
      case 'pending_review':
        return 'Pending review';
      case 'approved':
        return 'Approved';
      case 'rejected':
        return 'Rejected';
      default:
        return 'Draft';
    }
  }

  bool _isDefaultStatusSummary(String label) => label == 'All statuses';
}

class _MapControlRail extends StatelessWidget {
  const _MapControlRail({
    required this.featureCount,
    required this.onOpenFeatures,
    required this.onCenterCurrentLocation,
    required this.onFitProject,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.isLocating,
  });

  final int featureCount;
  final VoidCallback? onOpenFeatures;
  final VoidCallback? onCenterCurrentLocation;
  final VoidCallback? onFitProject;
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
        if (onOpenFeatures != null) ...[
          _MapFloatingActionButton(
            tooltip: 'Browse project features',
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
                onPressed: onFitProject,
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

class _LegendFilterChip extends StatelessWidget {
  const _LegendFilterChip({
    required this.label,
    required this.color,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final Color color;
  final bool selected;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      avatar: Icon(Icons.square_rounded, color: color, size: 16),
      label: Text(label),
      selected: selected,
      onSelected: onSelected,
    );
  }
}

class _ProjectMapGeometryCapturePanel extends StatelessWidget {
  const _ProjectMapGeometryCapturePanel({
    required this.geometryType,
    required this.summaryLabel,
    required this.instruction,
    required this.onCancel,
  });

  final String geometryType;
  final String summaryLabel;
  final String instruction;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      elevation: 8,
      color: scheme.surface.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Add feature on this map',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _CompactMapMetaPill(
                  icon: Icons.edit_location_alt_outlined,
                  label: _geometryTypeLabel(geometryType),
                  textStyle: theme.textTheme.labelSmall,
                ),
                const SizedBox(width: 6),
                _MapPanelIconButton(
                  tooltip: 'Cancel geometry capture',
                  icon: Icons.close_rounded,
                  onPressed: onCancel,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(instruction, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            _MapInfoPill(icon: Icons.route_outlined, label: summaryLabel),
          ],
        ),
      ),
    );
  }

  String _geometryTypeLabel(String geometryType) {
    switch (geometryType) {
      case 'LineString':
        return 'Line';
      case 'Polygon':
        return 'Polygon';
      case 'Point':
      default:
        return 'Point';
    }
  }
}

class _ProjectMapCaptureActionBar extends StatelessWidget {
  const _ProjectMapCaptureActionBar({
    required this.geometryType,
    required this.canUndo,
    required this.canClear,
    required this.canContinue,
    required this.onBack,
    required this.onUndo,
    required this.onClear,
    required this.onContinue,
  });

  final String geometryType;
  final bool canUndo;
  final bool canClear;
  final bool canContinue;
  final VoidCallback onBack;
  final VoidCallback? onUndo;
  final VoidCallback? onClear;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 8,
      color: scheme.surface.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: AppActionButtons(
          maxColumns: 2,
          compactBreakpoint: 340,
          fillRows: true,
          children: [
            OutlinedButton.icon(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_outlined),
              label: const Text('Back'),
            ),
            OutlinedButton.icon(
              onPressed: onUndo,
              icon: const Icon(Icons.undo_outlined),
              label: const Text('Undo'),
            ),
            OutlinedButton.icon(
              onPressed: onClear,
              icon: const Icon(Icons.clear_outlined),
              label: const Text('Clear'),
            ),
            FilledButton.icon(
              onPressed: canContinue ? onContinue : null,
              icon: const Icon(Icons.arrow_forward_outlined),
              label: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineProjectMapGeometryTypeSheet extends StatelessWidget {
  const _InlineProjectMapGeometryTypeSheet({
    required this.geometryTypes,
    required this.onSelected,
    required this.onClose,
  });

  final List<String> geometryTypes;
  final ValueChanged<String> onSelected;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset =
        MediaQuery.viewPaddingOf(context).bottom + AppSpacing.md;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity > 240) {
          onClose();
        }
      },
      child: Material(
        elevation: 10,
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, bottomInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Choose geometry',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Start the feature directly on this project map.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              for (final geometryType in geometryTypes) ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_geometryTypeIcon(geometryType)),
                  title: Text(_geometryTypeLabel(geometryType)),
                  subtitle: Text(_geometryTypeDescription(geometryType)),
                  onTap: () => onSelected(geometryType),
                ),
                if (geometryType != geometryTypes.last)
                  const Divider(height: 1),
              ],
            ],
          ),
        ),
      ),
    );
  }

  IconData _geometryTypeIcon(String geometryType) {
    switch (geometryType) {
      case 'LineString':
        return Icons.timeline_outlined;
      case 'Polygon':
        return Icons.crop_square_outlined;
      case 'Point':
      default:
        return Icons.place_outlined;
    }
  }

  String _geometryTypeLabel(String geometryType) {
    switch (geometryType) {
      case 'LineString':
        return 'Line';
      case 'Polygon':
        return 'Polygon';
      case 'Point':
      default:
        return 'Point';
    }
  }

  String _geometryTypeDescription(String geometryType) {
    switch (geometryType) {
      case 'LineString':
        return 'Trace a road, channel, or field edge.';
      case 'Polygon':
        return 'Outline an orchard, parcel, or area of interest.';
      case 'Point':
      default:
        return 'Place one precise location on the map.';
    }
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
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240),
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
      text = 'Preparing offline access';
    } else if (!state.isReady) {
      icon = Icons.cloud_off_outlined;
      color = scheme.error;
      text = 'Offline access unavailable';
    } else if (state.isSyncing) {
      icon = Icons.sync;
      color = scheme.primary;
      text = 'Syncing saved changes';
    } else if (state.conflictCount > 0 || state.deadLetterCount > 0) {
      icon = Icons.error_outline;
      color = scheme.error;
      text =
          '${state.conflictCount + state.deadLetterCount} change${state.conflictCount + state.deadLetterCount == 1 ? '' : 's'} need review';
    } else if (state.pendingCount > 0) {
      icon = Icons.cloud_upload_outlined;
      color = scheme.tertiary;
      text =
          '${state.pendingCount} change${state.pendingCount == 1 ? '' : 's'} waiting to sync';
    } else if (state.lastSyncAt != null) {
      icon = Icons.cloud_done_outlined;
      color = scheme.primary;
      text = 'Last sync ${formatLebanonTime(state.lastSyncAt!)}';
    } else {
      icon = Icons.cloud_done_outlined;
      color = scheme.primary;
      text = 'All changes synced';
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

class _ProjectFeatureBrowserSheet extends ConsumerStatefulWidget {
  const _ProjectFeatureBrowserSheet({
    required this.project,
    required this.features,
    required this.initialTotalCount,
    required this.canCollectOnMap,
    required this.canFilterStatuses,
    required this.featureTitleBuilder,
    required this.featureSubtitleBuilder,
    required this.searchBlobBuilder,
    required this.statusLabelBuilder,
    required this.statusColorBuilder,
    required this.onSelectFeature,
    required this.featureTypeOptions,
    this.initialFeatureType,
    this.onAddFeature,
  });

  final ProjectSummary project;
  final List<MapFeatureSummary> features;
  final int initialTotalCount;
  final bool canCollectOnMap;
  final bool canFilterStatuses;
  final String Function(MapFeatureSummary feature) featureTitleBuilder;
  final String Function(MapFeatureSummary feature) featureSubtitleBuilder;
  final String Function(MapFeatureSummary feature) searchBlobBuilder;
  final String Function(String status) statusLabelBuilder;
  final Color Function(String status) statusColorBuilder;
  final List<String> featureTypeOptions;
  final String? initialFeatureType;
  final VoidCallback? onAddFeature;
  final ValueChanged<MapFeatureSummary> onSelectFeature;

  @override
  ConsumerState<_ProjectFeatureBrowserSheet> createState() =>
      _ProjectFeatureBrowserSheetState();
}

class _ProjectFeatureBrowserSheetState
    extends ConsumerState<_ProjectFeatureBrowserSheet> {
  final TextEditingController _searchController = TextEditingController();
  String? _statusFilter;
  String? _geometryTypeFilter;
  String? _featureTypeFilter;

  static const List<String> _statusOrder = <String>[
    'approved',
    'pending_review',
    'rejected',
    'draft',
  ];

  @override
  void initState() {
    super.initState();
    final initialFeatureType = widget.initialFeatureType?.trim();
    _featureTypeFilter = initialFeatureType?.isEmpty == true
        ? null
        : initialFeatureType;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<String> get _geometryTypes {
    final values =
        widget.project.allowedGeometryTypes
            .where(
              (type) =>
                  type == 'Point' || type == 'LineString' || type == 'Polygon',
            )
            .toSet()
            .toList(growable: false)
          ..sort();
    return values;
  }

  String _geometryLabel(String geometryType) {
    switch (geometryType) {
      case 'Point':
        return 'Point';
      case 'LineString':
        return 'Line';
      case 'Polygon':
        return 'Polygon';
      default:
        return geometryType;
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = ProjectFeatureBrowserQuery(
      projectId: widget.project.id,
      search: _searchController.text.trim().isEmpty
          ? null
          : _searchController.text.trim(),
      status: widget.canFilterStatuses ? _statusFilter : null,
      geometryType: _geometryTypeFilter,
      featureType: _featureTypeFilter,
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
    final useSeedFeatures =
        featureState.items.isEmpty &&
        widget.features.isNotEmpty &&
        _searchController.text.trim().isEmpty &&
        _statusFilter == null &&
        _geometryTypeFilter == null &&
        _featureTypeFilter == widget.initialFeatureType;
    final displayedFeatures = useSeedFeatures
        ? widget.features
        : featureState.items;
    final displayedRepresentedCount = _representedCount(displayedFeatures);
    final displayedTotal = useSeedFeatures
        ? math.max(widget.initialTotalCount, displayedRepresentedCount)
        : featureState.total;
    final geometryTypes = _geometryTypes;
    final lockedFeatureType = widget.initialFeatureType?.trim();
    final hasNoOfficialFeatureType =
        lockedFeatureType == _MapScreenState._noOfficialFeatureFilter;
    final hasLockedFeatureType =
        lockedFeatureType != null && lockedFeatureType.isNotEmpty;
    final lockedFeatureTypeLabel = hasNoOfficialFeatureType
        ? 'None'
        : lockedFeatureType ?? '';

    final bottomInset =
        MediaQuery.viewPaddingOf(context).bottom + AppSpacing.lg;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.62,
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
              'Project features',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Showing $displayedRepresentedCount of $displayedTotal item(s) in ${widget.project.name}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search this project\'s features',
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
            if (widget.canFilterStatuses)
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
                        label: Text(widget.statusLabelBuilder(status)),
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
            if (widget.featureTypeOptions.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              if (hasLockedFeatureType) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ChoiceChip(
                      label: Text(lockedFeatureTypeLabel),
                      selected: true,
                      onSelected: (_) {},
                    ),
                    const _MapInfoPill(
                      icon: Icons.lock_outline,
                      label: 'Using map filter',
                    ),
                  ],
                ),
              ] else
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: const Text('All'),
                        selected: _featureTypeFilter == null,
                        onSelected: (_) {
                          setState(() {
                            _featureTypeFilter = null;
                          });
                        },
                      ),
                      for (final featureType in widget.featureTypeOptions) ...[
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: Text(featureType),
                          selected: _featureTypeFilter == featureType,
                          onSelected: (selected) {
                            setState(() {
                              _featureTypeFilter = selected
                                  ? featureType
                                  : null;
                            });
                          },
                        ),
                      ],
                    ],
                  ),
                ),
            ],
            if (geometryTypes.length > 1) ...[
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
                    for (final geometryType in geometryTypes) ...[
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: Text(_geometryLabel(geometryType)),
                        selected: _geometryTypeFilter == geometryType,
                        onSelected: (selected) {
                          setState(() {
                            _geometryTypeFilter = selected
                                ? geometryType
                                : null;
                          });
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            if (featuresAsync.isLoading && displayedFeatures.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (featuresAsync.hasError && displayedFeatures.isEmpty)
              AppEmptyState(
                icon: Icons.error_outline,
                title: 'Project features unavailable',
                message: userFacingErrorMessage(
                  featuresAsync.asError?.error ??
                      StateError(
                        'Project features failed without an error payload.',
                      ),
                  fallback:
                      'Unable to load project features right now. Please try again.',
                ),
                actionLabel: 'Retry',
                onAction: featuresController.refresh,
              )
            else if (displayedFeatures.isEmpty)
              AppEmptyState(
                icon: Icons.layers_clear_outlined,
                title: hasNoOfficialFeatureType
                    ? 'Official features are hidden'
                    : 'No features match these filters',
                message: hasNoOfficialFeatureType
                    ? 'The map is showing published AI layers only. Clear the None filter to browse official project features again.'
                    : widget.canFilterStatuses
                    ? 'Try a different search, status, or geometry filter for this project.'
                    : 'Try a different search or geometry filter for this project.',
                actionLabel: hasNoOfficialFeatureType
                    ? null
                    : widget.canCollectOnMap
                    ? 'Add Feature'
                    : null,
                onAction: hasNoOfficialFeatureType ? null : widget.onAddFeature,
              )
            else
              ProgressiveListSection<MapFeatureSummary>(
                items: displayedFeatures,
                resetKey: query,
                hasMore: useSeedFeatures ? false : featureState.hasMore,
                isLoadingMore: featureState.isLoadingMore,
                onLoadMore: useSeedFeatures
                    ? null
                    : featuresController.loadMore,
                gridMinItemWidth: 360,
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
                          color: widget.statusColorBuilder(feature.status),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.featureTitleBuilder(feature),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              widget.featureSubtitleBuilder(feature),
                              style: Theme.of(context).textTheme.bodySmall,
                              softWrap: true,
                            ),
                          ],
                        ),
                      ),
                      if (widget.canFilterStatuses) ...[
                        const SizedBox(width: AppSpacing.sm),
                        StatusChip(status: feature.status),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  int _representedCount(List<MapFeatureSummary> features) {
    return features.fold<int>(
      0,
      (total, feature) => total + math.max(1, feature.clusterCount),
    );
  }
}

class _OfflineMapSheet extends ConsumerWidget {
  const _OfflineMapSheet({
    required this.basemapStyle,
    required this.initialOfflinePackage,
    required this.hasCollectionAccess,
    required this.uiStateListenable,
    required this.canDownloadVisible,
    required this.onDownloadOverview,
    required this.onDownloadVisible,
    required this.onRefreshSavedImagery,
    required this.onDeleteSavedImagery,
  });

  final LebanonBasemapStyle basemapStyle;
  final OfflineMapPackage? initialOfflinePackage;
  final bool hasCollectionAccess;
  final ValueListenable<_OfflineSheetUiState> uiStateListenable;
  final bool canDownloadVisible;
  final Future<void> Function(OfflineMapPackage package)? onDownloadOverview;
  final Future<void> Function(OfflineMapPackage package)? onDownloadVisible;
  final Future<void> Function(OfflineMapPackage package)? onRefreshSavedImagery;
  final Future<void> Function(OfflineMapPackage package)? onDeleteSavedImagery;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(syncControllerProvider);
    final livePackage =
        ref.watch(offlineMapPackageProvider).valueOrNull ??
        initialOfflinePackage;
    final bottomInset =
        MediaQuery.viewPaddingOf(context).bottom + AppSpacing.lg;
    return ValueListenableBuilder<_OfflineSheetUiState>(
      valueListenable: uiStateListenable,
      builder: (context, uiState, _) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          minChildSize: 0.38,
          maxChildSize: 0.94,
          builder: (context, controller) {
            return DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                boxShadow: const [
                  BoxShadow(
                    blurRadius: 24,
                    color: Color(0x29000000),
                    offset: Offset(0, -6),
                  ),
                ],
              ),
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      controller: controller,
                      padding: EdgeInsets.fromLTRB(
                        AppSpacing.md,
                        AppSpacing.md,
                        AppSpacing.md,
                        bottomInset,
                      ),
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Offline map',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleLarge,
                                  ),
                                  const SizedBox(height: AppSpacing.xs),
                                  Text(
                                    'Save map imagery on this device so this project area stays readable without signal.',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.md),
                        _OfflineMapStatusCard(
                          package: livePackage,
                          basemapStyle: basemapStyle,
                          isDownloading: uiState.isDownloading,
                          activeAction: uiState.activeAction,
                          progressLabel: uiState.progressLabel,
                          progressValue: uiState.progressValue,
                          statusLabel: uiState.statusLabel,
                          onDownloadOverview:
                              livePackage == null || onDownloadOverview == null
                              ? null
                              : () => onDownloadOverview!(livePackage),
                          onDownloadVisible:
                              livePackage == null ||
                                  !canDownloadVisible ||
                                  onDownloadVisible == null
                              ? null
                              : () => onDownloadVisible!(livePackage),
                          onRefreshSavedImagery:
                              livePackage == null ||
                                  onRefreshSavedImagery == null
                              ? null
                              : () => onRefreshSavedImagery!(livePackage),
                          onDeleteSavedImagery:
                              livePackage == null ||
                                  onDeleteSavedImagery == null
                              ? null
                              : () => onDeleteSavedImagery!(livePackage),
                        ),
                        if (hasCollectionAccess) ...[
                          const SizedBox(height: AppSpacing.md),
                          AppCard(child: _SyncStatusLine(state: syncState)),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _OfflineMapStatusCard extends StatelessWidget {
  const _OfflineMapStatusCard({
    required this.package,
    required this.basemapStyle,
    required this.isDownloading,
    required this.activeAction,
    required this.progressLabel,
    required this.progressValue,
    required this.statusLabel,
    required this.onDownloadOverview,
    required this.onDownloadVisible,
    required this.onRefreshSavedImagery,
    required this.onDeleteSavedImagery,
  });

  final OfflineMapPackage? package;
  final LebanonBasemapStyle basemapStyle;
  final bool isDownloading;
  final _OfflineMapAction? activeAction;
  final String? progressLabel;
  final double? progressValue;
  final String? statusLabel;
  final VoidCallback? onDownloadOverview;
  final VoidCallback? onDownloadVisible;
  final VoidCallback? onRefreshSavedImagery;
  final VoidCallback? onDeleteSavedImagery;

  @override
  Widget build(BuildContext context) {
    if (package == null) {
      return const Text('Offline map information is not available yet.');
    }

    final downloadedAt = package!.downloadedAt;
    final downloadedSummary = downloadedAt == null
        ? 'No saved offline areas for this account on this device yet'
        : 'Last refreshed on ${formatLebanonDate(downloadedAt)}';
    final savedImageCount = package!.tileCount ?? 0;
    final hasSavedImagery = savedImageCount > 0;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Saved offline imagery',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Saved imagery is stored on this device for the signed-in user. It is used when live tiles are unavailable, and refreshing it online replaces older cached tiles.',
            softWrap: true,
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MapInfoPill(
                icon: _basemapStyleIcon(basemapStyle),
                label: '${LebanonMapConfig.basemapLabel(basemapStyle)} view',
              ),
              _MapInfoPill(
                icon: Icons.storage_rounded,
                label:
                    '$savedImageCount saved map image${savedImageCount == 1 ? '' : 's'}',
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${_formatBytes(package!.sizeBytes ?? 0)} • $downloadedSummary',
            softWrap: true,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Map source: ${package!.tileSource ?? 'Base map imagery'}',
            softWrap: true,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (progressLabel != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(progressLabel!, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: AppSpacing.xs),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: progressValue,
                minHeight: 8,
              ),
            ),
          ] else if (statusLabel != null && statusLabel!.trim().isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(statusLabel!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: AppSpacing.sm),
          Column(
            children: [
              _OfflineActionCard(
                icon: Icons.public_rounded,
                title: 'Save Lebanon overview',
                description:
                    'Saves a lightweight Lebanon-wide reference layer in the current style for offline orientation and country-level browsing.',
                actionLabel:
                    isDownloading &&
                        activeAction == _OfflineMapAction.saveOverview
                    ? 'Saving...'
                    : 'Save overview',
                onPressed: isDownloading ? null : onDownloadOverview,
                filled: true,
              ),
              const SizedBox(height: AppSpacing.sm),
              _OfflineActionCard(
                icon: Icons.crop_free_outlined,
                title: 'Save this view',
                description:
                    'Saves the detailed map area currently visible on screen in the current style for this signed-in user.',
                actionLabel:
                    isDownloading &&
                        activeAction == _OfflineMapAction.saveVisibleArea
                    ? 'Saving...'
                    : 'Save visible area',
                onPressed: isDownloading ? null : onDownloadVisible,
              ),
              if (hasSavedImagery) ...[
                const SizedBox(height: AppSpacing.sm),
                _OfflineActionCard(
                  icon: Icons.refresh_rounded,
                  title: 'Refresh saved imagery',
                  description:
                      'Re-downloads the saved map images for this style on this device so older cached tiles are replaced.',
                  actionLabel:
                      isDownloading &&
                          activeAction == _OfflineMapAction.refreshSavedImagery
                      ? 'Refreshing...'
                      : 'Refresh saved',
                  onPressed: isDownloading ? null : onRefreshSavedImagery,
                ),
                const SizedBox(height: AppSpacing.sm),
                _OfflineActionCard(
                  icon: Icons.delete_outline_rounded,
                  title: 'Delete saved imagery',
                  description:
                      'Removes the saved map images for this style from this device for the signed-in user.',
                  actionLabel:
                      isDownloading &&
                          activeAction == _OfflineMapAction.deleteSavedImagery
                      ? 'Deleting...'
                      : 'Delete saved',
                  onPressed: isDownloading ? null : onDeleteSavedImagery,
                ),
              ],
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

class _OfflineActionCard extends StatelessWidget {
  const _OfflineActionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.onPressed,
    this.filled = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final String actionLabel;
  final VoidCallback? onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 20, color: scheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        description,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            AppActionButtons(
              maxColumns: 1,
              fillRows: true,
              children: [
                if (filled)
                  FilledButton.tonalIcon(
                    onPressed: onPressed,
                    icon: const Icon(Icons.download_outlined),
                    label: Text(actionLabel),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: onPressed,
                    icon: const Icon(Icons.download_outlined),
                    label: Text(actionLabel),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OfflineTileAssets {
  const _OfflineTileAssets({
    required this.templatePath,
    required this.fallbackPath,
    required this.hasCachedTiles,
  });

  final String templatePath;
  final String fallbackPath;
  final bool hasCachedTiles;
}

class _MapReviewNoteDialog extends StatefulWidget {
  const _MapReviewNoteDialog({
    required this.title,
    required this.hint,
    required this.submitLabel,
  });

  final String title;
  final String hint;
  final String submitLabel;

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
        AppDialogActions(
          cancel: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          confirm: FilledButton(
            onPressed: _submit,
            child: Text(widget.submitLabel),
          ),
        ),
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

String _mapGeometryLabel(String geometryType) {
  switch (geometryType.toLowerCase()) {
    case 'point':
    case 'multipoint':
      return 'Point';
    case 'linestring':
    case 'multilinestring':
      return 'Line';
    case 'polygon':
    case 'multipolygon':
      return 'Polygon';
    default:
      return geometryType;
  }
}

class _ProjectFeatureLoadingSheet extends StatelessWidget {
  const _ProjectFeatureLoadingSheet({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final bottomInset =
        MediaQuery.viewPaddingOf(context).bottom + AppSpacing.lg;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.38,
      minChildSize: 0.28,
      maxChildSize: 0.5,
      builder: (context, controller) {
        return ListView(
          controller: controller,
          padding: EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            bottomInset,
          ),
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.lg),
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Loading feature details...',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        );
      },
    );
  }
}

class _ProjectFeatureErrorSheet extends StatelessWidget {
  const _ProjectFeatureErrorSheet({
    required this.title,
    required this.message,
    required this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final bottomInset =
        MediaQuery.viewPaddingOf(context).bottom + AppSpacing.lg;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.46,
      minChildSize: 0.32,
      maxChildSize: 0.64,
      builder: (context, controller) {
        return ListView(
          controller: controller,
          padding: EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            bottomInset,
          ),
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.lg),
            AppEmptyState(
              icon: Icons.error_outline,
              title: 'Feature details unavailable',
              message: message,
              actionLabel: 'Retry',
              onAction: onRetry,
            ),
          ],
        );
      },
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
      child: AppCard(
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
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium,
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureAttributesGrid extends StatelessWidget {
  const _FeatureAttributesGrid({required this.attributes});

  final Map<String, dynamic> attributes;

  @override
  Widget build(BuildContext context) {
    final entries = attributes.entries.toList(growable: false)
      ..sort((left, right) => left.key.compareTo(right.key));
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
                          _projectMapLabelizeAttributeKey(entry.key),
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                          softWrap: true,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _projectMapFormatAttributeValue(entry.value),
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

String _projectMapLabelizeAttributeKey(String key) {
  return key
      .replaceAll('_', ' ')
      .split(' ')
      .where((part) => part.isNotEmpty)
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');
}

String _projectMapFormatAttributeValue(Object? value) {
  if (value == null) {
    return 'Not provided';
  }
  if (value is List) {
    return value.map((item) => item.toString()).join(', ');
  }
  if (value is Map) {
    return value.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join(', ');
  }
  return value.toString();
}
