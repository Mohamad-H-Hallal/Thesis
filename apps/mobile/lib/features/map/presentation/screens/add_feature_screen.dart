import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/offline/local_models.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../projects/domain/project.dart';
import '../../domain/field_collection_validation.dart';

class AddFeatureScreen extends ConsumerStatefulWidget {
  const AddFeatureScreen({super.key, this.initialProjectId});

  final String? initialProjectId;

  @override
  ConsumerState<AddFeatureScreen> createState() => _AddFeatureScreenState();
}

class _AddFeatureScreenState extends ConsumerState<AddFeatureScreen> {
  final Uuid _uuid = const Uuid();
  final Random _random = Random();

  int _currentStep = 0;

  String? _selectedProjectId;
  String _selectedGeometryType = 'Point';

  final TextEditingController _latitudeController = TextEditingController();
  final TextEditingController _longitudeController = TextEditingController();

  final Map<String, TextEditingController> _attributeControllers =
      <String, TextEditingController>{};
  final Map<String, dynamic> _attributeValues = <String, dynamic>{};
  final Map<String, String> _fieldErrors = <String, String>{};

  final List<_PhotoCaptureDraft> _photos = <_PhotoCaptureDraft>[];

  double? _gpsAccuracyMeters;
  DateTime? _lastGpsSampleAt;

  @override
  void dispose() {
    _latitudeController.dispose();
    _longitudeController.dispose();
    for (final controller in _attributeControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _ensureProjectSelection(List<ProjectSummary> projects) {
    if (projects.isEmpty) {
      return;
    }

    final currentlySelected = projects.any((p) => p.id == _selectedProjectId);
    if (currentlySelected) {
      return;
    }

    ProjectSummary fallback = projects.first;
    final preferredId = widget.initialProjectId;
    if (preferredId != null) {
      final fromParam = projects.where((p) => p.id == preferredId);
      if (fromParam.isNotEmpty) {
        fallback = fromParam.first;
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _applyProjectSelection(fallback);
    });
  }

  void _applyProjectSelection(ProjectSummary project) {
    final allowedGeometry = project.allowedGeometryTypes.isNotEmpty
        ? project.allowedGeometryTypes
        : const <String>['Point'];
    final geometryType = allowedGeometry.contains(_selectedGeometryType)
        ? _selectedGeometryType
        : allowedGeometry.first;

    for (final controller in _attributeControllers.values) {
      controller.dispose();
    }
    _attributeControllers.clear();
    _attributeValues.clear();
    _fieldErrors.clear();

    for (final field in project.collectionFormSchema.fields) {
      if (field.type == CollectionFieldType.boolean) {
        _attributeValues[field.key] = false;
      } else if (field.type == CollectionFieldType.select) {
        _attributeValues[field.key] = field.options.isEmpty
            ? null
            : field.options.first;
      } else {
        _attributeControllers[field.key] = TextEditingController();
      }
    }

    setState(() {
      _selectedProjectId = project.id;
      _selectedGeometryType = geometryType;
      _photos.clear();
      _gpsAccuracyMeters = null;
      _lastGpsSampleAt = null;
    });
  }

  void _captureGpsSample(ProjectSummary project) {
    final latitude = 33.1 + (_random.nextDouble() * 1.45);
    final longitude = 35.1 + (_random.nextDouble() * 1.25);
    final accuracy = 3 + (_random.nextDouble() * 18);

    setState(() {
      _latitudeController.text = latitude.toStringAsFixed(6);
      _longitudeController.text = longitude.toStringAsFixed(6);
      _gpsAccuracyMeters = accuracy;
      _lastGpsSampleAt = DateTime.now();
    });

    final quality = Phase6Validation.gpsQualityLabel(_gpsAccuracyMeters);
    AppSnackbar.showSuccess(
      context,
      'GPS sample captured: ${accuracy.toStringAsFixed(1)}m ($quality). Max allowed: ${project.maxGpsAccuracyMeters.toStringAsFixed(1)}m.',
    );
  }

  void _addPhoto(ProjectSummary project) {
    if (_photos.length >= project.maxPhotos) {
      AppSnackbar.showError(
        context,
        'Maximum photo limit reached (${project.maxPhotos}).',
      );
      return;
    }

    final originalBytes = 900000 + _random.nextInt(2200000);
    final compressedBytes = max(220000, (originalBytes * 0.42).round());
    final ratio = 1 - (compressedBytes / originalBytes);

    setState(() {
      _photos.add(
        _PhotoCaptureDraft(
          id: _uuid.v4(),
          filePath: 'captured_${_photos.length + 1}.jpg',
          createdAt: DateTime.now(),
          originalBytes: originalBytes,
          compressedBytes: compressedBytes,
          compressionRatio: ratio,
          gpsAccuracyMeters:
              _gpsAccuracyMeters ?? (5 + _random.nextDouble() * 15),
        ),
      );
    });
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
          payload[field.key] = num.tryParse(raw);
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
    if (stepIndex == 0) {
      if (_selectedProjectId == null || _selectedProjectId!.isEmpty) {
        return 'Select an assigned project.';
      }

      final lat = double.tryParse(_latitudeController.text.trim());
      final lon = double.tryParse(_longitudeController.text.trim());
      return Phase6Validation.validateGeometry(
        geometryType: _selectedGeometryType,
        allowedGeometryTypes: project.allowedGeometryTypes,
        latitude: lat,
        longitude: lon,
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
        actualPhotos: _photos.length,
      );
    }

    return null;
  }

  Future<void> _handleContinue(List<ProjectSummary> projects) async {
    final project = projects.where((p) => p.id == _selectedProjectId).isEmpty
        ? null
        : projects.firstWhere((p) => p.id == _selectedProjectId);
    if (project == null) {
      AppSnackbar.showError(context, 'Select an assigned project.');
      return;
    }

    final validationError = _validateStep(project, _currentStep);
    if (validationError != null) {
      AppSnackbar.showError(context, validationError);
      return;
    }

    if (_currentStep < 3) {
      setState(() {
        _currentStep += 1;
      });
      return;
    }

    await _saveDraft(project);
  }

  Future<void> _saveDraft(ProjectSummary project) async {
    final now = DateTime.now();
    final draftId = _uuid.v4();
    final lat = double.tryParse(_latitudeController.text.trim());
    final lon = double.tryParse(_longitudeController.text.trim());

    final attributes = <String, dynamic>{
      'schema_version': project.collectionFormSchema.version,
      'attributes': _collectAttributeValues(project),
      'geometry': <String, dynamic>{
        'type': _selectedGeometryType,
        'latitude': lat,
        'longitude': lon,
      },
      'gps': <String, dynamic>{
        'accuracy_meters': _gpsAccuracyMeters,
        'captured_at': _lastGpsSampleAt?.toIso8601String(),
        'quality': Phase6Validation.gpsQualityLabel(_gpsAccuracyMeters),
      },
      'photos_metadata': _photos.map((photo) => photo.toMap()).toList(),
    };

    final draft = LocalDraftFeature(
      id: draftId,
      projectId: project.id,
      projectName: project.name,
      geometryType: _selectedGeometryType,
      attributesJson: jsonEncode(attributes),
      photos: _photos
          .map(
            (photo) => DraftPhoto(
              id: photo.id,
              filePath: photo.filePath,
              createdAt: photo.createdAt,
            ),
          )
          .toList(growable: false),
      status: 'draft',
      localVersion: now.millisecondsSinceEpoch,
      updatedAt: now,
    );

    await ref.read(localStoreProvider).upsertDraft(draft, enqueueSync: true);
    ref.invalidate(draftsProvider);
    await ref.read(syncControllerProvider.notifier).syncNow();

    if (!mounted) {
      return;
    }

    AppSnackbar.showSuccess(
      context,
      'Draft saved with schema ${project.collectionFormSchema.version} and queued for sync.',
    );
    context.go(AppRoutes.drafts);
  }

  Widget _buildSchemaField(CollectionFormFieldSchema field) {
    final errorText = _fieldErrors[field.key];
    switch (field.type) {
      case CollectionFieldType.text:
      case CollectionFieldType.multiline:
        return TextFormField(
          controller: _attributeControllers[field.key],
          minLines: field.type == CollectionFieldType.multiline ? 2 : 1,
          maxLines: field.type == CollectionFieldType.multiline ? 5 : 1,
          decoration: InputDecoration(
            labelText: field.required ? '${field.label} *' : field.label,
            hintText: field.hint,
            errorText: errorText,
          ),
        );
      case CollectionFieldType.number:
        return TextFormField(
          controller: _attributeControllers[field.key],
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: field.required ? '${field.label} *' : field.label,
            hintText: field.unit == null ? field.hint : 'Unit: ${field.unit}',
            errorText: errorText,
          ),
        );
      case CollectionFieldType.select:
        return DropdownButtonFormField<String>(
          initialValue: _attributeValues[field.key] as String?,
          items: field.options
              .map(
                (option) =>
                    DropdownMenuItem(value: option, child: Text(option)),
              )
              .toList(growable: false),
          onChanged: (value) {
            setState(() {
              _attributeValues[field.key] = value;
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
            });
          },
          subtitle: errorText == null ? null : Text(errorText),
          contentPadding: EdgeInsets.zero,
        );
      case CollectionFieldType.date:
        final rawDate = _attributeValues[field.key] as String?;
        return AppCard(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  rawDate == null || rawDate.isEmpty
                      ? '${field.label}${field.required ? ' *' : ''}: Not selected'
                      : '${field.label}: $rawDate',
                ),
              ),
              OutlinedButton.icon(
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
              ),
            ],
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final projectsAsync = ref.watch(projectsProvider);

    return projectsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Could not load assigned projects',
        message: '$error',
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(projectsProvider),
      ),
      data: (projects) {
        if (projects.isEmpty) {
          return const AppEmptyState(
            icon: Icons.assignment_late_outlined,
            title: 'No assignments available',
            message:
                'You are not assigned to any active field collection project yet.',
          );
        }

        _ensureProjectSelection(projects);
        final selectedProject =
            projects.where((p) => p.id == _selectedProjectId).isEmpty
            ? projects.first
            : projects.firstWhere((p) => p.id == _selectedProjectId);

        return Stepper(
          currentStep: _currentStep,
          onStepContinue: () => _handleContinue(projects),
          onStepCancel: () {
            if (_currentStep > 0) {
              setState(() => _currentStep -= 1);
            }
          },
          controlsBuilder: (context, details) {
            return Row(
              children: [
                AppButton(
                  label: _currentStep == 3 ? 'Save Draft Offline' : 'Next',
                  icon: _currentStep == 3
                      ? Icons.save_alt
                      : Icons.arrow_forward,
                  onPressed: details.onStepContinue,
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: details.onStepCancel,
                  child: const Text('Back'),
                ),
              ],
            );
          },
          steps: [
            Step(
              title: const Text('Geometry'),
              isActive: _currentStep >= 0,
              state: _currentStep > 0 ? StepState.complete : StepState.indexed,
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const AppCard(
                    child: Text(
                      'Geometry capture includes assignment-bound project selection, GPS quality checks, and geometry validation.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedProjectId,
                    decoration: const InputDecoration(
                      labelText: 'Assigned Project',
                    ),
                    items: projects
                        .map(
                          (project) => DropdownMenuItem(
                            value: project.id,
                            child: Text(project.name),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      final project = projects.firstWhere((p) => p.id == value);
                      _applyProjectSelection(project);
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedGeometryType,
                    decoration: const InputDecoration(
                      labelText: 'Geometry Type',
                    ),
                    items: selectedProject.allowedGeometryTypes
                        .map(
                          (type) =>
                              DropdownMenuItem(value: type, child: Text(type)),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        _selectedGeometryType = value;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _latitudeController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Latitude',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextFormField(
                          controller: _longitudeController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Longitude',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Chip(
                        avatar: const Icon(Icons.gps_fixed, size: 18),
                        label: Text(
                          _gpsAccuracyMeters == null
                              ? 'GPS: Not captured'
                              : 'GPS: ${_gpsAccuracyMeters!.toStringAsFixed(1)}m (${Phase6Validation.gpsQualityLabel(_gpsAccuracyMeters)})',
                        ),
                      ),
                      Chip(
                        avatar: const Icon(Icons.rule, size: 18),
                        label: Text(
                          'Max allowed: ${selectedProject.maxGpsAccuracyMeters.toStringAsFixed(1)}m',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => _captureGpsSample(selectedProject),
                    icon: const Icon(Icons.my_location),
                    label: const Text('Capture GPS Sample'),
                  ),
                  if (_lastGpsSampleAt != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Last sample: ${_lastGpsSampleAt!.toIso8601String()}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  if (_selectedGeometryType != 'Point')
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'LineString/Polygon drawing is planned for the next mapping increment; centroid validation is active now.',
                      ),
                    ),
                ],
              ),
            ),
            Step(
              title: const Text('Attributes'),
              isActive: _currentStep >= 1,
              state: _currentStep > 1 ? StepState.complete : StepState.indexed,
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppCard(
                    child: Text(
                      'Form schema: ${selectedProject.collectionFormSchema.version} (${selectedProject.collectionFormSchema.fields.length} field(s))',
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (selectedProject.collectionFormSchema.fields.isEmpty)
                    const Text(
                      'No dynamic form fields are configured for this project.',
                    )
                  else
                    ...selectedProject.collectionFormSchema.fields.map(
                      (field) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _buildSchemaField(field),
                      ),
                    ),
                ],
              ),
            ),
            Step(
              title: const Text('Photos'),
              isActive: _currentStep >= 2,
              state: _currentStep > 2 ? StepState.complete : StepState.indexed,
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Project photo policy: ${selectedProject.requiresPhotos ? 'Required' : 'Optional'}',
                        ),
                        Text(
                          'Min photos: ${selectedProject.minPhotos} • Max photos: ${selectedProject.maxPhotos}',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _photos.length >= selectedProject.maxPhotos
                        ? null
                        : () => _addPhoto(selectedProject),
                    icon: const Icon(Icons.photo_camera),
                    label: const Text('Capture Photo (Metadata Stub)'),
                  ),
                  const SizedBox(height: 8),
                  if (_photos.isEmpty)
                    const Text('No photos captured yet.')
                  else
                    ..._photos.map(
                      (photo) => AppCard(
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const CircleAvatar(
                            child: Icon(Icons.photo_camera_back),
                          ),
                          title: Text(photo.filePath),
                          subtitle: Text(
                            'Compressed: ${(photo.compressionRatio * 100).toStringAsFixed(0)}% • GPS ${photo.gpsAccuracyMeters.toStringAsFixed(1)}m',
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () {
                              setState(() {
                                _photos.remove(photo);
                              });
                            },
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Step(
              title: const Text('Review & Save Draft'),
              isActive: _currentStep >= 3,
              content: AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Ready to save this feature draft offline.'),
                    const SizedBox(height: 6),
                    Text('Project: ${selectedProject.name}'),
                    Text(
                      'Schema version: ${selectedProject.collectionFormSchema.version}',
                    ),
                    Text('Geometry: $_selectedGeometryType'),
                    Text(
                      'GPS quality: ${Phase6Validation.gpsQualityLabel(_gpsAccuracyMeters)}',
                    ),
                    Text(
                      'Attributes captured: ${_collectAttributeValues(selectedProject).length}',
                    ),
                    Text('Photos attached: ${_photos.length}'),
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

class _PhotoCaptureDraft {
  const _PhotoCaptureDraft({
    required this.id,
    required this.filePath,
    required this.createdAt,
    required this.originalBytes,
    required this.compressedBytes,
    required this.compressionRatio,
    required this.gpsAccuracyMeters,
  });

  final String id;
  final String filePath;
  final DateTime createdAt;
  final int originalBytes;
  final int compressedBytes;
  final double compressionRatio;
  final double gpsAccuracyMeters;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'file_path': filePath,
      'captured_at': createdAt.toIso8601String(),
      'original_bytes': originalBytes,
      'compressed_bytes': compressedBytes,
      'compression_ratio': compressionRatio,
      'gps_accuracy_meters': gpsAccuracyMeters,
    };
  }
}
