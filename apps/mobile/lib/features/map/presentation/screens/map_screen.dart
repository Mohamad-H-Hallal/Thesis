import 'dart:async';

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
import 'add_feature_screen.dart';
import '../widgets/feature_photo_gallery.dart';

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({
    this.initialProjectId,
    this.initialFeatureId,
    this.startCaptureOnOpen = false,
    this.lockProjectSelection = false,
    super.key,
  });

  final String? initialProjectId;
  final String? initialFeatureId;
  final bool startCaptureOnOpen;
  final bool lockProjectSelection;

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  static const List<String> _projectMapStatusOrder = <String>[
    'approved',
    'pending_review',
    'rejected',
    'draft',
  ];

  MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _projectMapSearchFocusNode = FocusNode();
  final Set<String> _visibleStatuses = Set<String>.from(_projectMapStatusOrder);
  final List<LatLng> _captureVertices = <LatLng>[];
  final Map<String, Future<_OfflineTileAssets?>> _offlineTileAssetsFutureCache =
      <String, Future<_OfflineTileAssets?>>{};

  String? _selectedProjectId;
  String? _selectedFeatureChip;
  String? _tileFailureMessage;
  String? _locationNoticeMessage;
  String? _autoOpenedFeatureId;
  String? _offlineDownloadProgressLabel;
  String? _offlineDownloadResultLabel;
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
  bool _hasHandledStartCaptureOnOpen = false;
  int _projectMapViewportVersion = 0;
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
  late final MapOptions _mainMapOptions;

  LatLng get _defaultMapCenter => widget.lockProjectSelection
      ? LebanonMapConfig.projectWorkspaceCenter
      : LebanonMapConfig.center;

  double get _defaultMapZoom => widget.lockProjectSelection
      ? LebanonMapConfig.projectWorkspaceZoom
      : LebanonMapConfig.fullscreenInitialZoom;

  @override
  void initState() {
    super.initState();
    _mainMapOptions = MapOptions(
      initialCenter: _defaultMapCenter,
      initialZoom: _defaultMapZoom,
      minZoom: LebanonMapConfig.fullscreenMinZoom,
      maxZoom: LebanonMapConfig.fullscreenMaxZoom,
      cameraConstraint: LebanonMapConfig.cameraConstraint,
      onMapReady: _handleMainMapReady,
      onPositionChanged: _handleMainMapPositionChanged,
      onTap: _handleMainMapTap,
    );
  }

  bool get _isProjectMapSecondaryOverlayOpen =>
      _isProjectMapGeometryChooserOpen || _isProjectMapModalSheetOpen;

  void _resetProjectMapViewport() {
    if (!mounted) {
      return;
    }
    setState(() {
      _isMainMapReady = false;
      _latestMapCamera = null;
      _lastProjectMapSurfaceWarmupKey = null;
      _lastVisibleTileRecoveryKey = null;
      _projectMapTileFailureCount = 0;
      _projectMapTileFailureBurstKey = null;
      _mapController = MapController();
      _projectMapViewportVersion++;
    });
  }

  bool _hasSavedOfflineImagery(OfflineMapPackage? package) =>
      (package?.tileCount ?? 0) > 0;

  Color _projectMapSurfaceFallbackColor() {
    switch (_basemapStyle) {
      case LebanonBasemapStyle.satellite:
        return const Color(0xFFB3C2C7);
      case LebanonBasemapStyle.street:
        return const Color(0xFFECE3D3);
    }
  }

  String _savedImageryFallbackNotice() {
    return 'Using saved map imagery for this area while live tiles reconnect.';
  }

  String _liveTilesUnavailableNotice() {
    return 'Live map tiles are temporarily unavailable. Project features remain available.';
  }

  void _notifyProjectMapTileFailure({
    required OfflineMapPackage? offlinePackage,
    required bool hasSavedOfflineImagery,
  }) {
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
      _showTileNotice(
        hasSavedOfflineImagery
            ? _savedImageryFallbackNotice()
            : _liveTilesUnavailableNotice(),
        usesSavedImagery: hasSavedOfflineImagery,
      );
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

  @override
  void dispose() {
    _locationNoticeTimer?.cancel();
    _tileNoticeTimer?.cancel();
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
          _showTileNotice(
            hasSavedOfflineImagery
                ? _savedImageryFallbackNotice()
                : _liveTilesUnavailableNotice(),
            usesSavedImagery: hasSavedOfflineImagery,
          );
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
          _showTileNotice(
            _savedImageryFallbackNotice(),
            usesSavedImagery: true,
          );
        }
      } catch (_) {
        if (mounted) {
          final hasSavedOfflineImagery = _hasSavedOfflineImagery(
            offlinePackage,
          );
          _showTileNotice(
            hasSavedOfflineImagery
                ? _savedImageryFallbackNotice()
                : _liveTilesUnavailableNotice(),
            usesSavedImagery: hasSavedOfflineImagery,
          );
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

  void _focusLebanonWorkspace({bool queueUntilReady = false}) {
    void focusWorkspace() {
      if (!mounted) {
        return;
      }
      _resetProjectMapViewport();
    }

    if (!_isMainMapReady) {
      if (queueUntilReady) {
        _pendingMainMapAction = focusWorkspace;
        return;
      }
      AppSnackbar.showError(
        context,
        'Map is still preparing. Please try again in a moment.',
      );
      return;
    }
    focusWorkspace();
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
                    basemapStyle: _basemapStyle,
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
          if (widget.lockProjectSelection) {
            return _buildProjectMapMobileWorkspace(
              context,
              project: project,
              features: features,
              quickFeatureChips: quickFeatureChips,
              offlinePackage: offlinePackageAsync.valueOrNull,
              hasCollectionAccess: hasCollectionAccess,
              canCollectOnMap: canCollectOnMap,
              canReview: canReview,
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

  Widget _buildProjectMapMobileWorkspace(
    BuildContext context, {
    required ProjectSummary project,
    required List<MapFeatureSummary> features,
    required List<String> quickFeatureChips,
    required OfflineMapPackage? offlinePackage,
    required bool hasCollectionAccess,
    required bool canCollectOnMap,
    required bool canReview,
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
    final suppressFloatingToolsForSearch = _projectMapSearchOpen || keyboardVisible;
    final addFeatureBottom = _isProjectMapCaptureMode ? 102.0 : 18.0;
    final rightRailBottom = _isProjectMapCaptureMode
        ? 116.0
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
                offlinePackage: offlinePackage,
                canCollectOnMap: canCollectOnMap,
                canReview: canReview,
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
                  onChangeGeometryType: () =>
                      _startProjectMapFeatureCapture(project),
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
                                child: SizeTransition(
                                  sizeFactor: animation,
                                  axisAlignment: -1,
                                  child: child,
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
                                    featureCount: features.length,
                                    searchController: _searchController,
                                    searchFocusNode: _projectMapSearchFocusNode,
                                    quickFeatureChips: quickFeatureChips,
                                    selectedFeatureChip: _selectedFeatureChip,
                                    visibleStatuses: _visibleStatuses,
                                    basemapStyle: _basemapStyle,
                                    gpsAccuracyMeters:
                                        _currentLocationAccuracyMeters,
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
                                      });
                                    },
                                    onResetVisibleStatuses:
                                        _resetVisibleStatuses,
                                    onToggleVisibleStatus: _toggleVisibleStatus,
                                    visibleStatusSummaryLabel:
                                        _visibleStatusSummaryLabel(),
                                    onBasemapStyleChanged: (style) {
                                      setState(() {
                                        _basemapStyle = style;
                                      });
                                      _clearTileNotice();
                                    },
                                    onOpenOfflineTools: () =>
                                        _openOfflineToolsSheet(
                                          offlinePackage: offlinePackage,
                                          hasCollectionAccess:
                                              hasCollectionAccess,
                                        ),
                                    onToggleExpanded: () =>
                                        _setProjectMapPanelState(
                                          visible: true,
                                          expanded: !_projectMapPanelExpanded,
                                        ),
                                    onHidePanel: () =>
                                        _setProjectMapPanelVisible(false),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                    if (!_isProjectMapPanelVisible)
                      Align(
                        alignment: Alignment.topRight,
                        child: _MapPanelIconButton(
                          tooltip: 'Show map tools',
                          icon: Icons.layers_outlined,
                          onPressed: () => _setProjectMapPanelVisible(true),
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
            left: 12,
            right: 12,
            bottom: 12,
            child: SafeArea(
              top: false,
              child: _InlineProjectMapGeometryTypeSheet(
                geometryTypes: _projectMapGeometryTypeOptions,
                onSelected: _enterProjectMapCapture,
                onClose: _dismissProjectMapGeometryChooser,
              ),
            ),
          ),
        if (!_isProjectMapSecondaryOverlayOpen && !suppressFloatingToolsForSearch)
          Positioned(
            right: 14,
            bottom: rightRailBottom,
            child: _MapControlRail(
              featureCount: features.length,
              onOpenFeatures: _isProjectMapCaptureMode
                  ? null
                  : () => _openFeatureBrowser(
                      project: project,
                      features: features,
                      canCollectOnMap: canCollectOnMap,
                      canReview: canReview,
                    ),
              onCenterCurrentLocation: _isLocating
                  ? null
                  : _centerMainMapOnCurrentLocation,
              onFitProject: _isMainMapReady
                  ? () => _focusLebanonWorkspace(queueUntilReady: true)
                  : null,
              onZoomIn: _isMainMapReady
                  ? () => _runMainMapAction(
                      () => _mapController.move(
                        _latestMapCamera?.center ?? _defaultMapCenter,
                        ((_latestMapCamera?.zoom ?? _defaultMapZoom) +
                                1)
                            .clamp(
                              LebanonMapConfig.fullscreenMinZoom,
                              LebanonMapConfig.fullscreenMaxZoom,
                            )
                            .toDouble(),
                      ),
                      queueUntilReady: true,
                    )
                  : null,
              onZoomOut: _isMainMapReady
                  ? () => _runMainMapAction(
                      () => _mapController.move(
                        _latestMapCamera?.center ?? _defaultMapCenter,
                        ((_latestMapCamera?.zoom ?? _defaultMapZoom) -
                                1)
                            .clamp(
                              LebanonMapConfig.fullscreenMinZoom,
                              LebanonMapConfig.fullscreenMaxZoom,
                            )
                            .toDouble(),
                      ),
                      queueUntilReady: true,
                    )
                  : null,
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
            right: 72,
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
    required OfflineMapPackage? offlinePackage,
    required bool canCollectOnMap,
    required bool canReview,
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
        final hasSavedOfflineImagery = _hasSavedOfflineImagery(offlinePackage);
        final canUseSavedOfflineImagery =
            snapshot.data != null && hasSavedOfflineImagery;
        final preferSavedImagery =
            _tileFailureUsesSavedImagery && canUseSavedOfflineImagery;
        final theme = Theme.of(context);
        return FlutterMap(
          key: ValueKey<String>(
            'project_map_${project.id}_$_projectMapViewportVersion',
          ),
          mapController: _mapController,
          options: _mainMapOptions,
          children: [
            if (preferSavedImagery && canUseSavedOfflineImagery)
              TileLayer(
                key: ValueKey<String>(
                  'project_map_offline_tiles_${_basemapStyle.name}_${snapshot.data!.templatePath}',
                ),
                urlTemplate: snapshot.data!.templatePath,
                tileProvider: FileTileProvider(),
                fallbackUrl: snapshot.data!.fallbackPath,
                userAgentPackageName: 'lb.gov.gis_collector',
              ),
            if (!preferSavedImagery)
              TileLayer(
                key: ValueKey<String>(
                  'project_map_live_basemap_${_basemapStyle.name}',
                ),
                urlTemplate: liveBasemapUrl,
                tileProvider: NetworkTileProvider(silenceExceptions: true),
                userAgentPackageName: 'lb.gov.gis_collector',
                errorTileCallback: (tile, error, stackTrace) {
                  Object.hash(tile, stackTrace);
                  _notifyProjectMapTileFailure(
                    offlinePackage: offlinePackage,
                    hasSavedOfflineImagery: hasSavedOfflineImagery,
                  );
                },
              ),
            if (labelOverlayUrl != null)
              TileLayer(
                key: ValueKey<String>(
                  'project_map_label_overlay_${_basemapStyle.name}',
                ),
                urlTemplate: labelOverlayUrl,
                tileProvider: NetworkTileProvider(silenceExceptions: true),
                userAgentPackageName: 'lb.gov.gis_collector',
              ),
            PolygonLayer(polygons: _polygonOverlays(features)),
            PolylineLayer(polylines: _polylineOverlays(features)),
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
                _captureVertices.length >= 3)
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
            future: _offlineTileAssetsFuture(offlinePackage),
            builder: (context, snapshot) {
              final labelOverlayUrl =
                  LebanonMapConfig.referenceLabelUrlTemplate(_basemapStyle);
              final hasSavedOfflineImagery = _hasSavedOfflineImagery(
                offlinePackage,
              );
              final canUseSavedOfflineImagery =
                  snapshot.data != null && hasSavedOfflineImagery;
              final preferSavedImagery =
                  _tileFailureUsesSavedImagery && canUseSavedOfflineImagery;
              return ClipRRect(
                borderRadius: AppRadii.lg,
                child: FlutterMap(
                  mapController: _mapController,
                  options: _mainMapOptions,
                  children: [
                    if (canUseSavedOfflineImagery)
                      TileLayer(
                        key: ValueKey<String>(
                          'preview_offline_tiles_${_basemapStyle.name}_${snapshot.data!.templatePath}',
                        ),
                        urlTemplate: snapshot.data!.templatePath,
                        tileProvider: FileTileProvider(),
                        fallbackUrl: snapshot.data!.fallbackPath,
                        userAgentPackageName: 'lb.gov.gis_collector',
                      ),
                    if (!preferSavedImagery)
                      TileLayer(
                        key: ValueKey<String>(
                          'preview_live_basemap_${_basemapStyle.name}',
                        ),
                        urlTemplate: LebanonMapConfig.basemapUrlTemplate(
                          _basemapStyle,
                        ),
                        tileProvider: NetworkTileProvider(
                          silenceExceptions: true,
                        ),
                        userAgentPackageName: 'lb.gov.gis_collector',
                        errorTileCallback: (tile, error, stackTrace) {
                          Object.hash(tile, stackTrace);
                          _notifyProjectMapTileFailure(
                            offlinePackage: offlinePackage,
                            hasSavedOfflineImagery: canUseSavedOfflineImagery,
                          );
                        },
                      ),
                    if (labelOverlayUrl != null)
                      TileLayer(
                        key: ValueKey<String>(
                          'preview_label_overlay_${_basemapStyle.name}',
                        ),
                        urlTemplate: labelOverlayUrl,
                        tileProvider: NetworkTileProvider(
                          silenceExceptions: true,
                        ),
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
                            });
                            _clearTileNotice();
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
    if (widget.lockProjectSelection) {
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
    required bool canCollectOnMap,
    required bool canReview,
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
          canCollectOnMap: canCollectOnMap,
          featureTitleBuilder: _featureBrowserTitle,
          featureSubtitleBuilder: _featureBrowserSubtitle,
          searchBlobBuilder: _featureSearchBlob,
          statusLabelBuilder: _statusLabel,
          statusColorBuilder: _statusColor,
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
            _focusFeature(feature);
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
    final syncState = ref.read(syncControllerProvider);
    if (mounted) {
      setState(() {
        _isProjectMapModalSheetOpen = true;
      });
    }
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => _OfflineMapSheet(
          basemapStyle: _basemapStyle,
          offlinePackage: offlinePackage,
          hasCollectionAccess: hasCollectionAccess,
          isDownloadingOffline: _isDownloadingOffline,
          offlineDownloadProgressLabel: _offlineDownloadProgressLabel,
          offlineDownloadResultLabel: _offlineDownloadResultLabel,
          syncState: syncState,
          canDownloadVisible: offlinePackage != null && _isMainMapReady,
          onClose: () => Navigator.of(context).pop(),
          onDownloadOverview: offlinePackage == null
              ? null
              : () => _downloadLebanonOverview(offlinePackage),
          onDownloadVisible: offlinePackage == null || !_isMainMapReady
              ? null
              : () => _downloadVisibleRegion(offlinePackage),
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
    for (final entry in feature.attributes.entries) {
      final value = '${entry.value}'.trim();
      if (_looksLikeFeatureTypeField(entry.key, entry.key) &&
          value.isNotEmpty &&
          value.length <= 40) {
        return value;
      }
    }
    return 'Feature ${_featureShortId(feature.id)}';
  }

  String _featureBrowserSubtitle(MapFeatureSummary feature) {
    final details = <String>[
      '${feature.geometry['type'] ?? 'Geometry'}',
      '${feature.photoCount} photo(s)',
    ];
    if (feature.collectedBy != null && feature.collectedBy!.trim().isNotEmpty) {
      details.add('Collector ${feature.collectedBy}');
    }
    return details.join(' • ');
  }

  Future<_OfflineTileAssets> _loadOfflineTileAssets(
    OfflineMapPackage package,
    LebanonBasemapStyle basemapStyle,
  ) async {
    final manager = ref.read(offlineTileCacheManagerProvider);
    final values = await Future.wait<String>([
      manager.localTileTemplate(package: package, basemapStyle: basemapStyle),
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
      _offlineDownloadProgressLabel =
          'Preparing the Lebanon overview for offline browsing...';
      _offlineDownloadResultLabel = null;
    });
    try {
      final manager = ref.read(offlineTileCacheManagerProvider);
      final summary = await ref
          .read(offlineTileCacheManagerProvider)
          .cacheLebanonOverview(
            package: package,
            basemapStyle: _basemapStyle,
            onProgress: (progress) {
              if (!mounted) {
                return;
              }
              setState(() {
                _offlineDownloadProgressLabel =
                    'Saving the Lebanon overview ${progress.completedTiles}/${progress.requestedTiles} • ${progress.downloadedTiles} new • ${progress.skippedTiles} already on this device${progress.failedTiles > 0 ? ' • ${progress.failedTiles} failed' : ''}';
              });
            },
          );
      await manager.refreshStats(package, basemapStyle: _basemapStyle);
      ref.invalidate(offlineMapPackageProvider);
      if (mounted) {
        final hasUsableTiles =
            summary.downloadedTiles > 0 || summary.skippedTiles > 0;
        final message =
            'Lebanon overview saved on this device. ${summary.downloadedTiles} new map image(s), ${summary.skippedTiles} already available${summary.failedTiles > 0 ? ', ${summary.failedTiles} failed' : ''}.';
        setState(() {
          _offlineDownloadResultLabel = message;
        });
        if (!hasUsableTiles) {
          AppSnackbar.showError(
            context,
            'Unable to save the Lebanon overview right now. Please try again later.',
          );
        }
      }
    } catch (error) {
      if (mounted) {
        final message = userFacingErrorMessage(
          error,
          fallback: 'Unable to save the Lebanon overview right now.',
        );
        setState(() {
          _offlineDownloadResultLabel = message;
        });
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
          'Preparing the visible map area for offline browsing...';
      _offlineDownloadResultLabel = null;
    });
    try {
      final manager = ref.read(offlineTileCacheManagerProvider);
      final summary = await manager.cacheVisibleRegion(
        package: package,
        basemapStyle: _basemapStyle,
        bounds: camera.visibleBounds,
        currentZoom: camera.zoom,
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          setState(() {
            _offlineDownloadProgressLabel =
                'Saving this visible area ${progress.completedTiles}/${progress.requestedTiles} • ${progress.downloadedTiles} new • ${progress.skippedTiles} already on this device${progress.failedTiles > 0 ? ' • ${progress.failedTiles} failed' : ''}';
          });
        },
      );
      await manager.refreshStats(package, basemapStyle: _basemapStyle);
      ref.invalidate(offlineMapPackageProvider);
      if (mounted) {
        final hasUsableTiles =
            summary.downloadedTiles > 0 || summary.skippedTiles > 0;
        final message =
            'This visible area is saved on this device. ${summary.downloadedTiles} new map image(s), ${summary.skippedTiles} already available${summary.failedTiles > 0 ? ', ${summary.failedTiles} failed' : ''}.';
        setState(() {
          _offlineDownloadResultLabel = message;
        });
        if (!hasUsableTiles) {
          AppSnackbar.showError(
            context,
            'Unable to save this visible area right now. Please try again later.',
          );
        }
      }
    } catch (error) {
      if (mounted) {
        final message = userFacingErrorMessage(
          error,
          fallback: 'Unable to save this visible map area right now.',
        );
        setState(() {
          _offlineDownloadResultLabel = message;
        });
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
    bool canReview, {
    bool interactive = true,
  }) {
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
              behavior: HitTestBehavior.translucent,
              onTap: !interactive
                  ? null
                  : () {
                      _focusFeature(feature);
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
                    border: Border.all(color: Colors.white, width: 1.8),
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
    required this.gpsAccuracyMeters,
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
    required this.onOpenOfflineTools,
    required this.onToggleExpanded,
    required this.onHidePanel,
  });

  final ProjectSummary project;
  final int featureCount;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final List<String> quickFeatureChips;
  final String? selectedFeatureChip;
  final Set<String> visibleStatuses;
  final LebanonBasemapStyle basemapStyle;
  final double? gpsAccuracyMeters;
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
  final VoidCallback onOpenOfflineTools;
  final VoidCallback onToggleExpanded;
  final VoidCallback onHidePanel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final activeFilterLabel = selectedFeatureChip ?? 'All features';
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
        elevation: 8,
        color: scheme.surface.withValues(alpha: 0.93),
        borderRadius: BorderRadius.circular(24),
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
                                    icon: Icons.place_outlined,
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
                              _MapPanelIconButton(
                                tooltip: 'Offline map',
                                icon: Icons.download_for_offline_outlined,
                                onPressed: onOpenOfflineTools,
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
                        gpsAccuracyMeters != null) ...[
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
                          if (!_isDefaultStatusSummary(
                            visibleStatusSummaryLabel,
                          ))
                            _MapInfoPill(
                              icon: Icons.visibility_outlined,
                              label: visibleStatusSummaryLabel,
                            ),
                          if (selectedFeatureChip != null)
                            _MapInfoPill(
                              icon: Icons.layers_outlined,
                              label: activeFilterLabel,
                            ),
                          if (gpsAccuracyMeters != null)
                            _MapInfoPill(
                              icon: Icons.my_location,
                              label:
                                  'GPS ${gpsAccuracyMeters!.toStringAsFixed(0)}m',
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
                              onSelected: (_) => onToggleVisibleStatus(status),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          ChoiceChip(
                            label: const Text('All'),
                            selected: selectedFeatureChip == null,
                            onSelected: (_) => onChipSelected(null),
                          ),
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
                          icon: basemapStyle == LebanonBasemapStyle.satellite
                              ? Icons.satellite_alt_outlined
                              : Icons.map_outlined,
                          label:
                              '${LebanonMapConfig.basemapLabel(basemapStyle)} view',
                        ),
                        if (gpsAccuracyMeters != null)
                          _MapInfoPill(
                            icon: Icons.my_location,
                            label:
                                'GPS ${gpsAccuracyMeters!.toStringAsFixed(0)}m',
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

class _ProjectMapGeometryCapturePanel extends StatelessWidget {
  const _ProjectMapGeometryCapturePanel({
    required this.geometryType,
    required this.summaryLabel,
    required this.instruction,
    required this.onCancel,
    required this.onChangeGeometryType,
  });

  final String geometryType;
  final String summaryLabel;
  final String instruction;
  final VoidCallback onCancel;
  final VoidCallback onChangeGeometryType;

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
                  tooltip: 'Change geometry type',
                  icon: Icons.swap_horiz_rounded,
                  onPressed: onChangeGeometryType,
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
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
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
              label: Text(
                geometryType == 'Point' ? 'Continue' : 'Continue to details',
              ),
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
    return Material(
      elevation: 10,
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ),
                Tooltip(
                  message: 'Close geometry chooser',
                  child: IconButton(
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
              ],
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
              if (geometryType != geometryTypes.last) const Divider(height: 1),
            ],
          ],
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
            child: Row(
              children: [
                Icon(
                  style == LebanonBasemapStyle.satellite
                      ? Icons.satellite_alt_outlined
                      : Icons.map_outlined,
                  size: 18,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(LebanonMapConfig.basemapLabel(style)),
                const Spacer(),
                if (style == basemapStyle)
                  Icon(Icons.check_rounded, size: 18, color: scheme.primary),
              ],
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
          child: Icon(
            basemapStyle == LebanonBasemapStyle.satellite
                ? Icons.satellite_alt_outlined
                : Icons.map_outlined,
            size: 16,
          ),
        ),
      ),
    );
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
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
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

class _ProjectFeatureBrowserSheet extends StatefulWidget {
  const _ProjectFeatureBrowserSheet({
    required this.project,
    required this.features,
    required this.canCollectOnMap,
    required this.featureTitleBuilder,
    required this.featureSubtitleBuilder,
    required this.searchBlobBuilder,
    required this.statusLabelBuilder,
    required this.statusColorBuilder,
    required this.onSelectFeature,
    this.onAddFeature,
  });

  final ProjectSummary project;
  final List<MapFeatureSummary> features;
  final bool canCollectOnMap;
  final String Function(MapFeatureSummary feature) featureTitleBuilder;
  final String Function(MapFeatureSummary feature) featureSubtitleBuilder;
  final String Function(MapFeatureSummary feature) searchBlobBuilder;
  final String Function(String status) statusLabelBuilder;
  final Color Function(String status) statusColorBuilder;
  final VoidCallback? onAddFeature;
  final ValueChanged<MapFeatureSummary> onSelectFeature;

  @override
  State<_ProjectFeatureBrowserSheet> createState() =>
      _ProjectFeatureBrowserSheetState();
}

class _ProjectFeatureBrowserSheetState
    extends State<_ProjectFeatureBrowserSheet> {
  final TextEditingController _searchController = TextEditingController();
  String? _statusFilter;
  String? _geometryTypeFilter;

  static const List<String> _statusOrder = <String>[
    'approved',
    'pending_review',
    'rejected',
    'draft',
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<MapFeatureSummary> get _filteredFeatures {
    final query = _searchController.text.trim().toLowerCase();
    return widget.features
        .where((feature) {
          if (_statusFilter != null && feature.status != _statusFilter) {
            return false;
          }
          if (_geometryTypeFilter != null &&
              '${feature.geometry['type'] ?? ''}' != _geometryTypeFilter) {
            return false;
          }
          if (query.isEmpty) {
            return true;
          }
          return widget.searchBlobBuilder(feature).contains(query);
        })
        .toList(growable: false);
  }

  List<String> get _geometryTypes {
    final values =
        widget.features
            .map((feature) => '${feature.geometry['type'] ?? 'Unknown'}')
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
    final filteredFeatures = _filteredFeatures;
    final geometryTypes = _geometryTypes;

    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.62,
        minChildSize: 0.34,
        maxChildSize: 0.92,
        builder: (context, controller) {
          return ListView(
            controller: controller,
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
                '${filteredFeatures.length} of ${widget.features.length} item(s) in ${widget.project.name}',
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
              if (geometryTypes.length > 1) ...[
                const SizedBox(height: AppSpacing.sm),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: const Text('Any geometry'),
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
              if (filteredFeatures.isEmpty)
                AppEmptyState(
                  icon: Icons.layers_clear_outlined,
                  title: 'No features match these filters',
                  message:
                      'Try a different search, status, or geometry filter for this project.',
                  actionLabel: widget.canCollectOnMap ? 'Add Feature' : null,
                  onAction: widget.onAddFeature,
                )
              else
                ...filteredFeatures.map(
                  (feature) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: AppCard(
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
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
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
                          const SizedBox(width: AppSpacing.sm),
                          StatusChip(status: feature.status),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _OfflineMapSheet extends StatelessWidget {
  const _OfflineMapSheet({
    required this.basemapStyle,
    required this.offlinePackage,
    required this.hasCollectionAccess,
    required this.isDownloadingOffline,
    required this.offlineDownloadProgressLabel,
    required this.offlineDownloadResultLabel,
    required this.syncState,
    required this.canDownloadVisible,
    required this.onClose,
    required this.onDownloadOverview,
    required this.onDownloadVisible,
  });

  final LebanonBasemapStyle basemapStyle;
  final OfflineMapPackage? offlinePackage;
  final bool hasCollectionAccess;
  final bool isDownloadingOffline;
  final String? offlineDownloadProgressLabel;
  final String? offlineDownloadResultLabel;
  final SyncState syncState;
  final bool canDownloadVisible;
  final VoidCallback onClose;
  final VoidCallback? onDownloadOverview;
  final VoidCallback? onDownloadVisible;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.44,
        minChildSize: 0.28,
        maxChildSize: 0.88,
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
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md,
                      AppSpacing.md,
                      AppSpacing.md,
                      AppSpacing.xl,
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
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: AppSpacing.xs),
                                Text(
                                  'Save map imagery on this device so this project area stays readable without signal.',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          IconButton(
                            tooltip: 'Close offline map',
                            onPressed: onClose,
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      _OfflineMapStatusCard(
                        package: offlinePackage,
                        basemapStyle: basemapStyle,
                        isDownloading: isDownloadingOffline,
                        progressLabel: offlineDownloadProgressLabel,
                        statusLabel: offlineDownloadResultLabel,
                        onDownloadOverview: onDownloadOverview,
                        onDownloadVisible: canDownloadVisible
                            ? onDownloadVisible
                            : null,
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
      ),
    );
  }
}

class _OfflineMapStatusCard extends StatelessWidget {
  const _OfflineMapStatusCard({
    required this.package,
    required this.basemapStyle,
    required this.isDownloading,
    required this.progressLabel,
    required this.statusLabel,
    required this.onDownloadOverview,
    required this.onDownloadVisible,
  });

  final OfflineMapPackage? package;
  final LebanonBasemapStyle basemapStyle;
  final bool isDownloading;
  final String? progressLabel;
  final String? statusLabel;
  final VoidCallback? onDownloadOverview;
  final VoidCallback? onDownloadVisible;

  @override
  Widget build(BuildContext context) {
    if (package == null) {
      return const Text('Offline map information is not available yet.');
    }

    final downloadedAt = package!.downloadedAt;
    final downloadedSummary = downloadedAt == null
        ? 'No saved offline areas on this device yet'
        : 'Saved on ${downloadedAt.toLocal().year}-${downloadedAt.toLocal().month.toString().padLeft(2, '0')}-${downloadedAt.toLocal().day.toString().padLeft(2, '0')}';
    final savedImageCount = package!.tileCount ?? 0;

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
            'Saved areas remain visible later on this device.',
            softWrap: true,
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MapInfoPill(
                icon: basemapStyle == LebanonBasemapStyle.satellite
                    ? Icons.satellite_alt_outlined
                    : Icons.map_outlined,
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
                    'Saves a lightweight Lebanon-wide reference map in the current style.',
                actionLabel: isDownloading ? 'Saving...' : 'Save overview',
                onPressed: isDownloading ? null : onDownloadOverview,
                filled: true,
              ),
              const SizedBox(height: AppSpacing.sm),
              _OfflineActionCard(
                icon: Icons.crop_free_outlined,
                title: 'Save this view',
                description:
                    'Saves only the map area currently visible on screen in the current style.',
                actionLabel: 'Save visible area',
                onPressed: isDownloading ? null : onDownloadVisible,
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
            Align(
              alignment: Alignment.centerLeft,
              child: filled
                  ? FilledButton.tonalIcon(
                      onPressed: onPressed,
                      icon: const Icon(Icons.download_outlined),
                      label: Text(actionLabel),
                    )
                  : OutlinedButton.icon(
                      onPressed: onPressed,
                      icon: const Icon(Icons.download_outlined),
                      label: Text(actionLabel),
                    ),
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
