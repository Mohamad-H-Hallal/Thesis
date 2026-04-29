import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/offline/local_models.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../projects/domain/project.dart';
import '../../domain/current_location_service.dart';
import '../../domain/field_collection_validation.dart';
import '../../domain/lebanon_map.dart';
import '../../domain/map_feature.dart';
import '../widgets/feature_photo_gallery.dart';

class AddFeatureCaptureSeed {
  const AddFeatureCaptureSeed({
    required this.projectId,
    required this.geometryType,
    required this.vertices,
    this.gpsAccuracyMeters,
  });

  final String projectId;
  final String geometryType;
  final List<LatLng> vertices;
  final double? gpsAccuracyMeters;
}

bool shouldPersistFeatureDraftLocally(Object error) {
  if (error is DioException) {
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.connectionError) {
      return true;
    }
  }

  final message = userFacingErrorMessage(error, fallback: '').toLowerCase();
  return message.contains('network') ||
      message.contains('offline') ||
      message.contains('connection') ||
      message.contains('unable to reach the server') ||
      message.contains('socket') ||
      message.contains('timed out') ||
      message.contains('host lookup') ||
      message.contains('temporarily unavailable');
}

class AddFeatureFlowResult {
  const AddFeatureFlowResult.resumeCapture()
    : featureId = null,
      successMessage = null;

  const AddFeatureFlowResult.completed({
    required this.featureId,
    required this.successMessage,
  });

  final String? featureId;
  final String? successMessage;

  bool get shouldResumeCapture => successMessage == null;
}

class AddFeatureScreen extends ConsumerStatefulWidget {
  const AddFeatureScreen({
    super.key,
    this.initialProjectId,
    this.draftFeatureId,
    this.captureSeed,
  });

  final String? initialProjectId;
  final String? draftFeatureId;
  final AddFeatureCaptureSeed? captureSeed;

  @override
  ConsumerState<AddFeatureScreen> createState() => _AddFeatureScreenState();
}

class _AddFeatureScreenState extends ConsumerState<AddFeatureScreen> {
  final Uuid _uuid = const Uuid();
  final ImagePicker _imagePicker = ImagePicker();
  final MapController _geometryMapController = MapController();

  int _currentStep = 0;
  bool _isSaving = false;
  bool _isGeometryMapReady = false;

  String? _selectedProjectId;
  String? _selectedGeometryType;
  String? _currentDraftFeatureId;
  String? _hydratedDraftId;
  VoidCallback? _pendingGeometryMapAction;
  bool _captureSeedApplied = false;

  final Map<String, TextEditingController> _attributeControllers =
      <String, TextEditingController>{};
  final Map<String, dynamic> _attributeValues = <String, dynamic>{};
  final Map<String, String> _fieldErrors = <String, String>{};
  final List<_PendingPhoto> _pendingPhotos = <_PendingPhoto>[];
  final List<LatLng> _geometryVertices = <LatLng>[];

  double? _gpsAccuracyMeters;
  LatLng? _currentLocation;
  bool _isLocating = false;
  LebanonBasemapStyle _drawingBasemapStyle = LebanonBasemapStyle.satellite;
  List<MapFeaturePhoto> _uploadedPhotos = const <MapFeaturePhoto>[];
  late final MapOptions _geometryMapOptions = MapOptions(
    initialCenter: LebanonMapConfig.center,
    initialZoom: LebanonMapConfig.drawingInitialZoom,
    initialCameraFit: LebanonMapConfig.drawingFit,
    minZoom: LebanonMapConfig.drawingMinZoom,
    maxZoom: LebanonMapConfig.drawingMaxZoom,
    cameraConstraint: LebanonMapConfig.cameraConstraint,
    onMapReady: _handleGeometryMapReady,
    onTap: _handleGeometryMapTap,
  );

  bool get _isEditingDraft =>
      (widget.draftFeatureId?.isNotEmpty ?? false) ||
      (_currentDraftFeatureId?.isNotEmpty ?? false);

  void _returnToProjectMap(String projectId, {AddFeatureFlowResult? result}) {
    if (context.canPop()) {
      context.pop(result);
      return;
    }
    context.go(
      AppRoutes.mapForProject(projectId, featureId: result?.featureId),
    );
  }

  void _handleBack(ProjectSummary project) {
    if (widget.captureSeed != null && _currentStep == 1) {
      _returnToProjectMap(
        project.id,
        result: const AddFeatureFlowResult.resumeCapture(),
      );
      return;
    }
    setState(() {
      _currentStep -= 1;
    });
  }

  @override
  void dispose() {
    for (final controller in _attributeControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _handleGeometryMapReady() {
    if (!mounted) {
      return;
    }
    final pendingAction = _pendingGeometryMapAction;
    _pendingGeometryMapAction = null;
    if (!_isGeometryMapReady) {
      setState(() {
        _isGeometryMapReady = true;
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

  bool _isMapControllerLifecycleError(Object error) {
    return error.toString().contains(
      'You need to have FlutterMap widget rendered at least once before using MapController',
    );
  }

  void _runGeometryMapAction(
    VoidCallback action, {
    bool queueUntilReady = false,
  }) {
    if (!_isGeometryMapReady) {
      if (queueUntilReady) {
        _pendingGeometryMapAction = action;
        return;
      }
      AppSnackbar.showError(
        context,
        'Geometry map is still preparing. Please try again in a moment.',
      );
      return;
    }

    try {
      action();
    } catch (error) {
      if (_isMapControllerLifecycleError(error)) {
        _pendingGeometryMapAction = action;
        if (mounted) {
          setState(() {
            _isGeometryMapReady = false;
          });
        }
        return;
      }
      rethrow;
    }
  }

  void _ensureProjectSelection(List<ProjectSummary> projects) {
    if (projects.isEmpty) {
      return;
    }

    final existingSelection = projects.any(
      (item) => item.id == _selectedProjectId,
    );
    if (existingSelection) {
      return;
    }

    ProjectSummary fallback = projects.first;
    final preferredId = widget.initialProjectId;
    if (preferredId != null && preferredId.isNotEmpty) {
      fallback = projects.firstWhere(
        (project) => project.id == preferredId,
        orElse: () => projects.first,
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _applyProjectSelection(fallback);
    });
  }

  void _applyProjectSelection(
    ProjectSummary project, {
    MapFeatureSummary? draftFeature,
  }) {
    final supportedGeometryTypes = _supportedGeometryTypes(project);
    final captureSeed = draftFeature == null
        ? _captureSeedForProject(project)
        : null;
    final draftGeometryType = draftFeature?.geometry['type'] as String?;
    final geometryType = switch ((draftFeature, captureSeed)) {
      (MapFeatureSummary _, _) =>
        supportedGeometryTypes.contains(draftGeometryType)
            ? draftGeometryType
            : (supportedGeometryTypes.isEmpty
                  ? null
                  : supportedGeometryTypes.first),
      (_, AddFeatureCaptureSeed seed) =>
        supportedGeometryTypes.contains(seed.geometryType)
            ? seed.geometryType
            : (supportedGeometryTypes.isEmpty
                  ? null
                  : supportedGeometryTypes.first),
      _ =>
        supportedGeometryTypes.contains(_selectedGeometryType)
            ? _selectedGeometryType
            : (supportedGeometryTypes.isEmpty
                  ? null
                  : supportedGeometryTypes.first),
    };

    for (final controller in _attributeControllers.values) {
      controller.dispose();
    }
    _attributeControllers.clear();
    _attributeValues.clear();
    _fieldErrors.clear();

    for (final field in project.collectionFormSchema.fields) {
      final value = draftFeature?.attributes[field.key];
      switch (field.type) {
        case CollectionFieldType.boolean:
          _attributeValues[field.key] = value is bool ? value : false;
          break;
        case CollectionFieldType.select:
          _attributeValues[field.key] = value?.toString().isNotEmpty == true
              ? value.toString()
              : (field.options.isEmpty ? null : field.options.first);
          break;
        case CollectionFieldType.date:
          _attributeValues[field.key] = value?.toString();
          break;
        case CollectionFieldType.text:
        case CollectionFieldType.multiline:
        case CollectionFieldType.number:
          _attributeControllers[field.key] = TextEditingController(
            text: value?.toString() ?? '',
          );
          break;
      }
    }

    final geometryVertices = _geometryVerticesFromGeometry(
      draftFeature?.geometry ??
          (captureSeed == null ? null : _captureSeedGeometry(captureSeed)),
    );

    setState(() {
      _selectedProjectId = project.id;
      _selectedGeometryType = geometryType;
      _uploadedPhotos = draftFeature?.photos ?? const <MapFeaturePhoto>[];
      _pendingPhotos.clear();
      _gpsAccuracyMeters =
          draftFeature?.accuracyMeters ?? captureSeed?.gpsAccuracyMeters;
      _geometryVertices
        ..clear()
        ..addAll(geometryVertices);
      _currentStep = captureSeed == null ? 0 : 1;
      _currentDraftFeatureId = draftFeature?.id;
      _hydratedDraftId = draftFeature?.id;
    });
    if (captureSeed != null) {
      _captureSeedApplied = true;
    }

    _runGeometryMapAction(_fitGeometryOrLebanon, queueUntilReady: true);
  }

  AddFeatureCaptureSeed? _captureSeedForProject(ProjectSummary project) {
    final seed = widget.captureSeed;
    if (_captureSeedApplied || seed == null) {
      return null;
    }
    if (seed.projectId != project.id) {
      return null;
    }
    return seed;
  }

  Map<String, dynamic> _captureSeedGeometry(AddFeatureCaptureSeed seed) {
    switch (seed.geometryType) {
      case 'LineString':
        return <String, dynamic>{
          'type': 'LineString',
          'coordinates': seed.vertices
              .map((point) => <double>[point.longitude, point.latitude])
              .toList(growable: false),
        };
      case 'Polygon':
        final ring = seed.vertices
            .map((point) => <double>[point.longitude, point.latitude])
            .toList(growable: true);
        if (ring.isNotEmpty) {
          final first = ring.first;
          final last = ring.last;
          if (first[0] != last[0] || first[1] != last[1]) {
            ring.add(<double>[first[0], first[1]]);
          }
        }
        return <String, dynamic>{
          'type': 'Polygon',
          'coordinates': <List<List<double>>>[ring],
        };
      case 'Point':
      default:
        final point = seed.vertices.isEmpty ? null : seed.vertices.first;
        return <String, dynamic>{
          'type': 'Point',
          'coordinates': point == null
              ? const <double>[]
              : <double>[point.longitude, point.latitude],
        };
    }
  }

  void _ensureDraftHydrated(
    ProjectSummary project,
    MapFeatureSummary draftFeature,
  ) {
    if (_hydratedDraftId == draftFeature.id &&
        _selectedProjectId == project.id &&
        _currentDraftFeatureId == draftFeature.id) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _applyProjectSelection(project, draftFeature: draftFeature);
    });
  }

  List<String> _supportedGeometryTypes(ProjectSummary project) {
    return project.allowedGeometryTypes
        .where(
          (type) =>
              type == 'Point' || type == 'LineString' || type == 'Polygon',
        )
        .toList(growable: false);
  }

  void _fitGeometryOrLebanon() {
    if (_geometryVertices.isEmpty) {
      _geometryMapController.fitCamera(
        LebanonMapConfig.lebanonFit(padding: const EdgeInsets.all(18)),
      );
      return;
    }

    if (_geometryVertices.length == 1) {
      final point = _geometryVertices.first;
      _geometryMapController.move(point, 15);
      return;
    }

    _geometryMapController.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(_geometryVertices),
        padding: const EdgeInsets.all(28),
      ),
    );
  }

  void _handleGeometryMapTap(TapPosition _, LatLng point) {
    if (!LebanonMapConfig.contains(point)) {
      AppSnackbar.showError(
        context,
        'Geometry capture is restricted to Lebanon.',
      );
      return;
    }
    setState(() {
      if ((_selectedGeometryType ?? 'Point') == 'Point') {
        _geometryVertices
          ..clear()
          ..add(point);
      } else {
        _geometryVertices.add(point);
      }
    });
    _runGeometryMapAction(_fitGeometryOrLebanon, queueUntilReady: true);
  }

  Future<void> _useCurrentLocationForGeometry() async {
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
        _gpsAccuracyMeters = location.accuracyMeters;
        if ((_selectedGeometryType ?? 'Point') == 'Point') {
          _geometryVertices
            ..clear()
            ..add(location.position);
        }
      });
      _runGeometryMapAction(
        () => _geometryMapController.move(location.position, 16),
        queueUntilReady: true,
      );
      if (mounted && (_selectedGeometryType ?? 'Point') != 'Point') {
        AppSnackbar.showSuccess(
          context,
          'Map centered on the current location. Tap the map to place geometry vertices.',
        );
      }
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

  Future<void> _pickPhotos(ProjectSummary project) async {
    final remaining =
        project.maxPhotos - _uploadedPhotos.length - _pendingPhotos.length;
    if (remaining <= 0) {
      AppSnackbar.showError(
        context,
        'Maximum photo limit reached (${project.maxPhotos}).',
      );
      return;
    }

    try {
      final source = await showModalBottomSheet<_PhotoPickerSource>(
        context: context,
        builder: (context) => SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Take photo'),
                onTap: () =>
                    Navigator.of(context).pop(_PhotoPickerSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Choose from gallery'),
                onTap: () =>
                    Navigator.of(context).pop(_PhotoPickerSource.gallery),
              ),
            ],
          ),
        ),
      );
      if (source == null) {
        return;
      }

      final picked = await (source == _PhotoPickerSource.camera
          ? () async {
              final captured = await _imagePicker.pickImage(
                source: ImageSource.camera,
                imageQuality: 82,
              );
              if (captured == null) {
                return <XFile>[];
              }
              return <XFile>[captured];
            }()
          : _imagePicker.pickMultiImage(imageQuality: 82));
      if (picked.isEmpty) {
        return;
      }

      final filesToAdd = picked.take(remaining).toList(growable: false);
      final selected = await Future.wait(
        filesToAdd.map((file) async {
          final size = await file.length();
          return _PendingPhoto(
            id: _uuid.v4(),
            filePath: file.path,
            fileName: file.name,
            sizeBytes: size,
            createdAt: DateTime.now(),
          );
        }),
      );

      setState(() {
        _pendingPhotos.addAll(selected);
      });

      if (picked.length > remaining && mounted) {
        AppSnackbar.showError(
          context,
          'Only $remaining photo(s) were added because of the project limit.',
        );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnackbar.showError(
        context,
        userFacingErrorMessage(
          error,
          fallback: 'Unable to add photos right now. Please try again.',
        ),
      );
    }
  }

  Map<String, dynamic> _collectAttributeValues(ProjectSummary project) {
    final payload = <String, dynamic>{};
    for (final field in project.collectionFormSchema.fields) {
      switch (field.type) {
        case CollectionFieldType.text:
        case CollectionFieldType.multiline:
          payload[field.key] = _attributeControllers[field.key]?.text.trim();
          break;
        case CollectionFieldType.number:
          final raw = _attributeControllers[field.key]?.text.trim() ?? '';
          payload[field.key] = raw.isEmpty ? null : num.tryParse(raw);
          break;
        case CollectionFieldType.select:
        case CollectionFieldType.boolean:
        case CollectionFieldType.date:
          payload[field.key] = _attributeValues[field.key];
          break;
      }
    }
    return payload;
  }

  String? _validateStep(ProjectSummary project, int stepIndex) {
    if (_supportedGeometryTypes(project).isEmpty) {
      return 'This project does not allow supported mobile geometry capture yet.';
    }

    if (stepIndex == 0) {
      if (_selectedProjectId == null || _selectedProjectId!.isEmpty) {
        return 'Select an assigned project.';
      }
      return Phase6Validation.validateGeometry(
        geometryType: _selectedGeometryType ?? 'Point',
        allowedGeometryTypes: _supportedGeometryTypes(project),
        vertices: List<LatLng>.from(_geometryVertices),
        gpsAccuracyMeters: _gpsAccuracyMeters,
        maxGpsAccuracyMeters: project.maxGpsAccuracyMeters,
      );
    }

    if (stepIndex == 1) {
      final errors = Phase6Validation.validateAttributes(
        schema: project.collectionFormSchema,
        values: _collectAttributeValues(project),
      );
      setState(() {
        _fieldErrors
          ..clear()
          ..addAll(errors);
      });
      if (errors.isNotEmpty) {
        return errors.values.first;
      }
      return null;
    }

    if (stepIndex == 2) {
      return Phase6Validation.validatePhotoCount(
        requiresPhotos: project.requiresPhotos,
        minPhotos: project.minPhotos,
        maxPhotos: project.maxPhotos,
        actualPhotos: _uploadedPhotos.length + _pendingPhotos.length,
      );
    }

    return null;
  }

  Future<void> _handleNext(ProjectSummary project) async {
    final validationError = _validateStep(project, _currentStep);
    if (validationError != null) {
      AppSnackbar.showError(context, validationError);
      return;
    }

    if (_currentStep < 3) {
      setState(() {
        _currentStep += 1;
      });
    }
  }

  Future<void> _saveFeature(
    ProjectSummary project, {
    required bool submit,
  }) async {
    if (submit && project.status != 'active') {
      AppSnackbar.showError(
        context,
        'Feature submission is only available while the project is active.',
      );
      return;
    }

    for (var step = 0; step <= 2; step += 1) {
      final validationError = _validateStep(project, step);
      if (validationError != null) {
        setState(() {
          _currentStep = step;
        });
        AppSnackbar.showError(context, validationError);
        return;
      }
    }

    final geometry = _buildGeometryPayload();

    final attributes = _collectAttributeValues(project);
    final draftId = _currentDraftFeatureId ?? _uuid.v4();
    setState(() {
      _isSaving = true;
    });

    try {
      final repository = ref.read(featureWorkflowRepositoryProvider);
      String featureId = _currentDraftFeatureId ?? '';
      if (featureId.isEmpty) {
        final feature = await repository.createDraft(
          projectId: project.id,
          geometry: geometry,
          attributes: attributes,
          collectedOffline: false,
        );
        featureId = feature.id;
      } else {
        await repository.updateDraft(
          featureId: featureId,
          geometry: geometry,
          attributes: attributes,
        );
      }

      if (_pendingPhotos.isNotEmpty) {
        await repository.uploadPhotos(
          featureId: featureId,
          filePaths: _pendingPhotos
              .map((photo) => photo.filePath)
              .toList(growable: false),
        );
      }

      if (submit) {
        await repository.submitForReview(featureId);
      }

      bumpWorkflowRefresh(ref);

      if (!mounted) {
        return;
      }

      _returnToProjectMap(
        project.id,
        result: AddFeatureFlowResult.completed(
          featureId: featureId,
          successMessage: submit
              ? 'Feature submitted for review successfully.'
              : 'Feature draft saved successfully.',
        ),
      );
    } catch (error) {
      if (await _saveLocallyIfNeeded(
        error,
        project: project,
        draftId: draftId,
        geometry: geometry,
        attributes: attributes,
        submit: submit,
      )) {
        return;
      }

      if (!mounted) {
        return;
      }
      AppSnackbar.showError(
        context,
        userFacingErrorMessage(
          error,
          fallback: submit
              ? 'Unable to submit this feature right now.'
              : 'Unable to save this draft right now.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<bool> _saveLocallyIfNeeded(
    Object error, {
    required ProjectSummary project,
    required String draftId,
    required Map<String, dynamic> geometry,
    required Map<String, dynamic> attributes,
    required bool submit,
  }) async {
    if (!_shouldPersistLocally(error)) {
      return false;
    }

    final localStore = ref.read(localStoreProvider);
    final session = ref.read(authControllerProvider).session;
    final now = DateTime.now();
    final existingDraft = await localStore.getDraftById(draftId);
    final offlineDraft = LocalDraftFeature(
      id: draftId,
      ownerUserId: session?.user.id ?? '',
      projectId: project.id,
      projectName: project.name,
      geometryType: _selectedGeometryType ?? 'Point',
      geometryJson: jsonEncode(geometry),
      attributesJson: jsonEncode(attributes),
      photos: <DraftPhoto>[
        if (existingDraft != null) ...existingDraft.photos,
        ..._pendingPhotos.map(
          (photo) => DraftPhoto(
            id: photo.id,
            filePath: photo.filePath,
            createdAt: photo.createdAt,
          ),
        ),
      ],
      status: submit ? 'submitted' : 'draft',
      localVersion: (existingDraft?.localVersion ?? 0) + 1,
      remoteVersion: existingDraft?.remoteVersion,
      updatedAt: now,
    );

    await localStore.upsertDraft(offlineDraft);
    await ref.read(syncControllerProvider.notifier).refreshStatus();
    bumpWorkflowRefresh(ref);

    if (mounted) {
      _returnToProjectMap(
        project.id,
        result: AddFeatureFlowResult.completed(
          featureId: draftId,
          successMessage: submit
              ? 'Saved offline. It will be submitted for review when you are back online.'
              : 'Draft saved offline. It will sync when you are back online.',
        ),
      );
    }
    return true;
  }

  bool _shouldPersistLocally(Object error) {
    return shouldPersistFeatureDraftLocally(error);
  }

  Map<String, dynamic> _buildGeometryPayload() {
    final type = _selectedGeometryType ?? 'Point';
    switch (type) {
      case 'LineString':
        return <String, dynamic>{
          'type': 'LineString',
          'coordinates': _geometryVertices
              .map((point) => <double>[point.longitude, point.latitude])
              .toList(growable: false),
        };
      case 'Polygon':
        final ring = _geometryVertices
            .map((point) => <double>[point.longitude, point.latitude])
            .toList(growable: true);
        if (ring.isNotEmpty) {
          final first = ring.first;
          final last = ring.last;
          if (first[0] != last[0] || first[1] != last[1]) {
            ring.add(<double>[first[0], first[1]]);
          }
        }
        return <String, dynamic>{
          'type': 'Polygon',
          'coordinates': <List<List<double>>>[ring],
        };
      case 'Point':
      default:
        final point = _geometryVertices.first;
        return <String, dynamic>{
          'type': 'Point',
          'coordinates': <double>[point.longitude, point.latitude],
        };
    }
  }

  List<LatLng> _geometryVerticesFromGeometry(Map<String, dynamic>? geometry) {
    if (geometry == null) {
      return const <LatLng>[];
    }

    final type = geometry['type'] as String?;
    final coordinates = geometry['coordinates'];
    if (type == 'Point' && coordinates is List && coordinates.length >= 2) {
      return <LatLng>[
        LatLng(
          (coordinates[1] as num).toDouble(),
          (coordinates[0] as num).toDouble(),
        ),
      ];
    }
    if (type == 'LineString' && coordinates is List) {
      return coordinates
          .whereType<List>()
          .where((point) => point.length >= 2)
          .map(
            (point) => LatLng(
              (point[1] as num).toDouble(),
              (point[0] as num).toDouble(),
            ),
          )
          .toList(growable: false);
    }
    if (type == 'Polygon' &&
        coordinates is List &&
        coordinates.isNotEmpty &&
        coordinates.first is List) {
      final ring = coordinates.first as List;
      final points = ring
          .whereType<List>()
          .where((point) => point.length >= 2)
          .map(
            (point) => LatLng(
              (point[1] as num).toDouble(),
              (point[0] as num).toDouble(),
            ),
          )
          .toList(growable: false);
      if (points.length >= 2 && points.first == points.last) {
        return points.sublist(0, points.length - 1);
      }
      return points;
    }
    return const <LatLng>[];
  }

  Widget _buildSchemaField(CollectionFormFieldSchema field) {
    final errorText = _fieldErrors[field.key];
    switch (field.type) {
      case CollectionFieldType.text:
      case CollectionFieldType.multiline:
        return AppTextField(
          label: field.required ? '${field.label} *' : field.label,
          controller: _attributeControllers[field.key]!,
          hint: field.hint,
          minLines: field.type == CollectionFieldType.multiline ? 3 : null,
          maxLines: field.type == CollectionFieldType.multiline ? 6 : 1,
          validator: (_) => errorText,
          onChanged: (_) {
            if (_fieldErrors.remove(field.key) != null) {
              setState(() {});
            }
          },
        );
      case CollectionFieldType.number:
        return AppTextField(
          label: field.required ? '${field.label} *' : field.label,
          controller: _attributeControllers[field.key]!,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          hint: field.unit == null ? field.hint : 'Unit: ${field.unit}',
          validator: (_) => errorText,
          onChanged: (_) {
            if (_fieldErrors.remove(field.key) != null) {
              setState(() {});
            }
          },
        );
      case CollectionFieldType.select:
        return DropdownButtonFormField<String>(
          initialValue: _attributeValues[field.key] as String?,
          isExpanded: true,
          items: field.options
              .map(
                (option) =>
                    DropdownMenuItem(value: option, child: Text(option)),
              )
              .toList(growable: false),
          onChanged: (value) {
            setState(() {
              _attributeValues[field.key] = value;
              _fieldErrors.remove(field.key);
            });
          },
          decoration: InputDecoration(
            labelText: field.required ? '${field.label} *' : field.label,
            errorText: errorText,
          ),
        );
      case CollectionFieldType.boolean:
        final value = (_attributeValues[field.key] as bool?) ?? false;
        return SwitchListTile(
          title: Text(field.label),
          value: value,
          onChanged: (nextValue) {
            setState(() {
              _attributeValues[field.key] = nextValue;
              _fieldErrors.remove(field.key);
            });
          },
          subtitle: errorText == null ? null : Text(errorText),
          contentPadding: EdgeInsets.zero,
        );
      case CollectionFieldType.date:
        final rawDate = _attributeValues[field.key] as String?;
        return AppCard(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final dateSummary = Text(
                rawDate == null || rawDate.isEmpty
                    ? '${field.label}${field.required ? ' *' : ''}: Not selected'
                    : '${field.label}: $rawDate',
              );
              final pickButton = OutlinedButton.icon(
                onPressed: () async {
                  final now = DateTime.now();
                  final picked = await showDatePicker(
                    context: context,
                    firstDate: DateTime(now.year - 10),
                    lastDate: DateTime(now.year + 10),
                    initialDate: now,
                  );
                  if (picked == null) {
                    return;
                  }
                  setState(() {
                    _attributeValues[field.key] =
                        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                  });
                },
                icon: const Icon(Icons.event),
                label: const Text('Pick'),
              );

              if (constraints.maxWidth < 420) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    dateSummary,
                    const SizedBox(height: 12),
                    pickButton,
                  ],
                );
              }

              return Row(
                children: [
                  Expanded(child: dateSummary),
                  const SizedBox(width: 12),
                  pickButton,
                ],
              );
            },
          ),
        );
    }
  }

  String _formatBytes(int bytes) {
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

  @override
  Widget build(BuildContext context) {
    final projectsAsync = ref.watch(
      projectListProvider(ProjectViewScope.assigned),
    );

    return Stack(
      children: [
        projectsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => AppEmptyState(
            icon: Icons.error_outline,
            title: 'Could not load assigned projects',
            message: userFacingErrorMessage(
              error,
              fallback:
                  'Unable to load assigned projects right now. Please try again.',
            ),
            actionLabel: 'Retry',
            onAction: () =>
                ref.invalidate(projectListProvider(ProjectViewScope.assigned)),
          ),
          data: (projects) {
            if (projects.isEmpty) {
              return const AppEmptyState(
                icon: Icons.assignment_late_outlined,
                title: 'No approved assignments available',
                message:
                    'You need an approved contributor assignment before you can collect features.',
              );
            }

            _ensureProjectSelection(projects);
            final selectedProject = projects.firstWhere(
              (project) =>
                  project.id == (_selectedProjectId ?? widget.initialProjectId),
              orElse: () => projects.first,
            );

            if (widget.draftFeatureId != null &&
                widget.draftFeatureId!.isNotEmpty) {
              final projectId = widget.initialProjectId ?? selectedProject.id;
              final draftAsync = ref.watch(
                projectMapFeaturesProvider(projectId),
              );

              return draftAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => AppEmptyState(
                  icon: Icons.error_outline,
                  title: 'Draft unavailable',
                  message: userFacingErrorMessage(
                    error,
                    fallback:
                        'Unable to load this draft right now. Please try again.',
                  ),
                  actionLabel: 'Back to map',
                  onAction: () => _returnToProjectMap(projectId),
                ),
                data: (features) {
                  final draftProject = projects.firstWhere(
                    (project) => project.id == projectId,
                    orElse: () => selectedProject,
                  );
                  MapFeatureSummary? feature;
                  for (final item in features) {
                    if (item.id == widget.draftFeatureId) {
                      feature = item;
                      break;
                    }
                  }

                  if (feature == null) {
                    return AppEmptyState(
                      icon: Icons.edit_off_outlined,
                      title: 'Draft not found',
                      message:
                          'The selected draft could not be loaded from this project.',
                      actionLabel: 'Back to map',
                      onAction: () => _returnToProjectMap(projectId),
                    );
                  }

                  _ensureDraftHydrated(draftProject, feature);
                  if (_hydratedDraftId != feature.id) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  return _buildContent(context, projects, draftProject);
                },
              );
            }

            return _buildContent(context, projects, selectedProject);
          },
        ),
        if (_isSaving)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.18),
              child: const Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }

  Widget _buildContent(
    BuildContext context,
    List<ProjectSummary> projects,
    ProjectSummary selectedProject,
  ) {
    if (selectedProject.status != 'active') {
      return AppEmptyState(
        icon: Icons.pause_circle_outline,
        title: 'Collection unavailable',
        message:
            'This project is ${selectedProject.status}. Feature collection and submission are disabled until it returns to active status.',
        actionLabel: 'Back to map',
        onAction: () => _returnToProjectMap(selectedProject.id),
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SectionHeader(
          title: _isEditingDraft ? 'Edit draft feature' : 'New feature',
        ),
        const SizedBox(height: AppSpacing.sm),
        AppCard(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List<Widget>.generate(4, (index) {
              const labels = <String>[
                'Geometry',
                'Attributes',
                'Photos',
                'Review',
              ];
              return Chip(
                avatar: Icon(
                  index < _currentStep
                      ? Icons.check_circle_outline
                      : Icons.radio_button_unchecked,
                  size: 18,
                ),
                backgroundColor: index == _currentStep
                    ? Theme.of(context).colorScheme.primaryContainer
                    : null,
                label: Text('${index + 1}. ${labels[index]}'),
              );
            }),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        _buildCurrentStepCard(
          context,
          projects: projects,
          selectedProject: selectedProject,
        ),
        const SizedBox(height: AppSpacing.sm),
        AppCard(
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (_currentStep > 0)
                OutlinedButton(
                  onPressed: _isSaving
                      ? null
                      : () => _handleBack(selectedProject),
                  child: const Text('Back'),
                ),
              if (_currentStep < 3)
                FilledButton.icon(
                  onPressed: _isSaving
                      ? null
                      : () => _handleNext(selectedProject),
                  icon: const Icon(Icons.arrow_forward_outlined),
                  label: const Text('Next'),
                ),
              if (_currentStep == 3)
                OutlinedButton.icon(
                  onPressed: _isSaving
                      ? null
                      : () => _saveFeature(selectedProject, submit: false),
                  icon: const Icon(Icons.save_outlined),
                  label: Text(_isEditingDraft ? 'Update Draft' : 'Save Draft'),
                ),
              if (_currentStep == 3)
                FilledButton.icon(
                  onPressed: _isSaving
                      ? null
                      : () => _saveFeature(selectedProject, submit: true),
                  icon: const Icon(Icons.send_outlined),
                  label: const Text('Submit for Review'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCurrentStepCard(
    BuildContext context, {
    required List<ProjectSummary> projects,
    required ProjectSummary selectedProject,
  }) {
    final supportedGeometryTypes = _supportedGeometryTypes(selectedProject);
    switch (_currentStep) {
      case 0:
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _selectedProjectId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Assigned project',
                ),
                items: projects
                    .map(
                      (project) => DropdownMenuItem<String>(
                        value: project.id,
                        child: Text(
                          project.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: widget.draftFeatureId != null
                    ? null
                    : (value) {
                        if (value == null) {
                          return;
                        }
                        final project = projects.firstWhere(
                          (p) => p.id == value,
                        );
                        _applyProjectSelection(project);
                      },
              ),
              const SizedBox(height: AppSpacing.sm),
              if (supportedGeometryTypes.isEmpty)
                const AppEmptyState(
                  icon: Icons.edit_location_alt_outlined,
                  title: 'Geometry capture unavailable',
                  message:
                      'This project does not expose a supported geometry type for mobile capture.',
                )
              else
                DropdownButtonFormField<String>(
                  initialValue: _selectedGeometryType,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Geometry type'),
                  items: supportedGeometryTypes
                      .map(
                        (type) => DropdownMenuItem<String>(
                          value: type,
                          child: Text(type),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (value) {
                    setState(() {
                      _selectedGeometryType = value;
                    });
                  },
                ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Use the field map to capture geometry directly in Lebanon. Hybrid imagery, labels, and current location are available for field collection.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.sm),
              _GeometryCaptureMapCard(
                mapController: _geometryMapController,
                mapOptions: _geometryMapOptions,
                basemapStyle: _drawingBasemapStyle,
                geometryType: _selectedGeometryType ?? 'Point',
                vertices: _geometryVertices,
                isMapReady: _isGeometryMapReady,
                currentLocation: _currentLocation,
                isLocating: _isLocating,
                onUndo: _isSaving || _geometryVertices.isEmpty
                    ? null
                    : () {
                        setState(() {
                          _geometryVertices.removeLast();
                        });
                        _runGeometryMapAction(
                          _fitGeometryOrLebanon,
                          queueUntilReady: true,
                        );
                      },
                onClear: _isSaving || _geometryVertices.isEmpty
                    ? null
                    : () {
                        setState(() {
                          _geometryVertices.clear();
                        });
                        _runGeometryMapAction(
                          _fitGeometryOrLebanon,
                          queueUntilReady: true,
                        );
                      },
                onUseCurrentLocation: _isSaving
                    ? null
                    : _useCurrentLocationForGeometry,
                onToggleBasemap: (style) {
                  setState(() {
                    _drawingBasemapStyle = style;
                  });
                },
                onFitLebanon: () =>
                    _runGeometryMapAction(_fitGeometryOrLebanon),
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Chip(
                    avatar: const Icon(
                      Icons.edit_location_alt_outlined,
                      size: 18,
                    ),
                    label: Text(
                      _geometryVertices.isEmpty
                          ? 'No geometry captured yet'
                          : _geometrySummary(),
                    ),
                  ),
                  Chip(
                    avatar: const Icon(Icons.rule_outlined, size: 18),
                    label: Text('Lebanon-only capture'),
                  ),
                ],
              ),
            ],
          ),
        );
      case 1:
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Collection form',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Form schema ${selectedProject.collectionFormSchema.version} with ${selectedProject.collectionFormSchema.fields.length} field(s).',
              ),
              const SizedBox(height: AppSpacing.sm),
              if (selectedProject.collectionFormSchema.fields.isEmpty)
                const Text('No dynamic fields are configured for this project.')
              else
                ...selectedProject.collectionFormSchema.fields.map(
                  (field) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: _buildSchemaField(field),
                  ),
                ),
            ],
          ),
        );
      case 2:
        final uploadedPhotoItems = _uploadedPhotos
            .map(
              (photo) => FeaturePhotoGalleryItem(
                id: photo.id,
                imagePath: photo.thumbnailPath ?? photo.filePath,
                label: _photoLabel(photo.filePath),
                subtitle: photo.takenAt == null
                    ? 'Uploaded to this draft'
                    : 'Captured ${_formatDateTime(photo.takenAt!)}',
              ),
            )
            .toList(growable: false);
        final pendingPhotoItems = _pendingPhotos
            .map(
              (photo) => FeaturePhotoGalleryItem(
                id: photo.id,
                imagePath: photo.filePath,
                label: photo.fileName,
                subtitle: '${_formatBytes(photo.sizeBytes)} • Pending upload',
                isLocalFile: true,
                onRemove: _isSaving
                    ? null
                    : () {
                        setState(() {
                          _pendingPhotos.remove(photo);
                        });
                      },
              ),
            )
            .toList(growable: false);
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Photos', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Policy: ${selectedProject.requiresPhotos ? 'Required' : 'Optional'} • Minimum ${selectedProject.minPhotos} • Maximum ${selectedProject.maxPhotos}',
                softWrap: true,
              ),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: _isSaving
                    ? null
                    : () => _pickPhotos(selectedProject),
                icon: const Icon(Icons.add_a_photo_outlined),
                label: const Text('Add Photos'),
              ),
              const SizedBox(height: AppSpacing.sm),
              if (_uploadedPhotos.isEmpty && _pendingPhotos.isEmpty)
                const Text('No photos attached yet.')
              else ...[
                if (_uploadedPhotos.isNotEmpty) ...[
                  Text(
                    'Uploaded photos',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  FeaturePhotoGallery(items: uploadedPhotoItems),
                ],
                if (_pendingPhotos.isNotEmpty) ...[
                  if (_uploadedPhotos.isNotEmpty)
                    const SizedBox(height: AppSpacing.sm),
                  Text(
                    'New photos',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  FeaturePhotoGallery(items: pendingPhotoItems),
                ],
              ],
            ],
          ),
        );
      default:
        final attributes = _collectAttributeValues(selectedProject);
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _isEditingDraft ? 'Draft review' : 'Submission review',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Chip(label: Text(selectedProject.name)),
                  Chip(
                    label: Text(
                      'Geometry: ${_selectedGeometryType ?? 'Point'}',
                    ),
                  ),
                  if (_geometryVertices.isNotEmpty)
                    Chip(label: Text(_geometrySummary())),
                  Chip(
                    label: Text(
                      'Photos: ${_uploadedPhotos.length + _pendingPhotos.length}',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Drafts can be saved and reopened from the project map. Submitting sends the draft into the admin review queue.',
                softWrap: true,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Captured attributes',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: AppSpacing.xs),
              if (attributes.isEmpty)
                const Text('No attribute values captured.')
              else
                ...attributes.entries.map(
                  (entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('${entry.key}: ${entry.value ?? '—'}'),
                  ),
                ),
            ],
          ),
        );
    }
  }

  String _geometrySummary() {
    final geometryType = _selectedGeometryType ?? 'Point';
    switch (geometryType) {
      case 'LineString':
        return 'Line with ${_geometryVertices.length} vertex${_geometryVertices.length == 1 ? '' : 'es'}';
      case 'Polygon':
        return 'Polygon outline with ${_geometryVertices.length} point${_geometryVertices.length == 1 ? '' : 's'}';
      case 'Point':
      default:
        if (_geometryVertices.isEmpty) {
          return 'Point not placed yet';
        }
        final point = _geometryVertices.first;
        return 'Point ${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}';
    }
  }

  String _photoLabel(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/');
    return segments.isEmpty ? path : segments.last;
  }

  String _formatDateTime(DateTime value) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$month-$day $hour:$minute';
  }
}

class _PendingPhoto {
  const _PendingPhoto({
    required this.id,
    required this.filePath,
    required this.fileName,
    required this.sizeBytes,
    required this.createdAt,
  });

  final String id;
  final String filePath;
  final String fileName;
  final int sizeBytes;
  final DateTime createdAt;
}

enum _PhotoPickerSource { camera, gallery }

class _GeometryCaptureMapCard extends StatelessWidget {
  const _GeometryCaptureMapCard({
    required this.mapController,
    required this.mapOptions,
    required this.basemapStyle,
    required this.geometryType,
    required this.vertices,
    required this.isMapReady,
    required this.currentLocation,
    required this.isLocating,
    required this.onUndo,
    required this.onClear,
    required this.onUseCurrentLocation,
    required this.onToggleBasemap,
    required this.onFitLebanon,
  });

  final MapController mapController;
  final MapOptions mapOptions;
  final LebanonBasemapStyle basemapStyle;
  final String geometryType;
  final List<LatLng> vertices;
  final bool isMapReady;
  final LatLng? currentLocation;
  final bool isLocating;
  final VoidCallback? onUndo;
  final VoidCallback? onClear;
  final VoidCallback? onUseCurrentLocation;
  final ValueChanged<LebanonBasemapStyle> onToggleBasemap;
  final VoidCallback onFitLebanon;

  @override
  Widget build(BuildContext context) {
    final polygonPoints = geometryType == 'Polygon' && vertices.length >= 3
        ? <LatLng>[...vertices, vertices.first]
        : const <LatLng>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 360,
          child: ClipRRect(
            borderRadius: AppRadii.lg,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: mapController,
                  options: mapOptions,
                  children: [
                    if (LebanonMapConfig.shouldRenderTileLayers)
                      TileLayer(
                        urlTemplate: LebanonMapConfig.basemapUrlTemplate(
                          basemapStyle,
                        ),
                        userAgentPackageName: 'lb.gov.gis_collector',
                      ),
                    if (LebanonMapConfig.shouldRenderTileLayers &&
                        LebanonMapConfig.referenceLabelUrlTemplate(
                              basemapStyle,
                            ) !=
                            null)
                      TileLayer(
                        urlTemplate: LebanonMapConfig.referenceLabelUrlTemplate(
                          basemapStyle,
                        )!,
                        userAgentPackageName: 'lb.gov.gis_collector',
                      ),
                    if (polygonPoints.isNotEmpty)
                      PolygonLayer(
                        polygons: [
                          Polygon(
                            points: polygonPoints,
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.20),
                            borderColor: Theme.of(context).colorScheme.primary,
                            borderStrokeWidth: 2.5,
                          ),
                        ],
                      ),
                    if (geometryType == 'LineString' && vertices.length >= 2)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: vertices,
                            color: Theme.of(context).colorScheme.primary,
                            strokeWidth: 4,
                          ),
                        ],
                      ),
                    if (currentLocation != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: currentLocation!,
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
                      markers: vertices
                          .asMap()
                          .entries
                          .map(
                            (entry) => Marker(
                              width: 34,
                              height: 34,
                              point: entry.value,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Theme.of(context).colorScheme.primary,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 2,
                                  ),
                                ),
                                child: Center(
                                  child: Text(
                                    '${entry.key + 1}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(color: Colors.white),
                                  ),
                                ),
                              ),
                            ),
                          )
                          .toList(growable: false),
                    ),
                  ],
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  top: 12,
                  child: AppCard(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final basemapToggle =
                            SegmentedButton<LebanonBasemapStyle>(
                              segments: const [
                                ButtonSegment(
                                  value: LebanonBasemapStyle.satellite,
                                  label: Text('Hybrid'),
                                ),
                                ButtonSegment(
                                  value: LebanonBasemapStyle.street,
                                  label: Text('Street'),
                                ),
                              ],
                              selected: <LebanonBasemapStyle>{basemapStyle},
                              showSelectedIcon: false,
                              onSelectionChanged: (selection) =>
                                  onToggleBasemap(selection.first),
                            );
                        final instruction = Text(
                          geometryType == 'Point'
                              ? 'Tap once to place the feature.'
                              : geometryType == 'LineString'
                              ? 'Tap to add line vertices in order.'
                              : 'Tap to trace the polygon boundary.',
                          style: Theme.of(context).textTheme.bodySmall,
                        );

                        if (constraints.maxWidth < 420) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              instruction,
                              const SizedBox(height: AppSpacing.sm),
                              basemapToggle,
                            ],
                          );
                        }

                        return Row(
                          children: [
                            Expanded(child: instruction),
                            const SizedBox(width: AppSpacing.sm),
                            basemapToggle,
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: isLocating ? null : onUseCurrentLocation,
              icon: isLocating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.my_location_outlined),
              label: Text(
                geometryType == 'Point'
                    ? 'Use current location'
                    : 'Center on current location',
              ),
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
            OutlinedButton.icon(
              onPressed: isMapReady ? onFitLebanon : null,
              icon: const Icon(Icons.zoom_out_map_outlined),
              label: const Text('Fit Lebanon'),
            ),
          ],
        ),
      ],
    );
  }
}
