import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

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
  final ImagePicker _imagePicker = ImagePicker();

  int _currentStep = 0;
  bool _isSubmitting = false;

  String? _selectedProjectId;
  String? _selectedGeometryType;

  final TextEditingController _latitudeController = TextEditingController();
  final TextEditingController _longitudeController = TextEditingController();

  final Map<String, TextEditingController> _attributeControllers =
      <String, TextEditingController>{};
  final Map<String, dynamic> _attributeValues = <String, dynamic>{};
  final Map<String, String> _fieldErrors = <String, String>{};

  final List<_SelectedPhoto> _photos = <_SelectedPhoto>[];

  double? _gpsAccuracyMeters;

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

    var fallback = projects.first;
    final preferredId = widget.initialProjectId;
    if (preferredId != null && preferredId.isNotEmpty) {
      final matching = projects.where((project) => project.id == preferredId);
      if (matching.isNotEmpty) {
        fallback = matching.first;
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
    final supportedGeometryTypes = _supportedGeometryTypes(project);
    final geometryType = supportedGeometryTypes.contains(_selectedGeometryType)
        ? _selectedGeometryType
        : (supportedGeometryTypes.isEmpty
              ? null
              : supportedGeometryTypes.first);

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
      _latitudeController.clear();
      _longitudeController.clear();
      _currentStep = 0;
    });
  }

  List<String> _supportedGeometryTypes(ProjectSummary project) {
    return project.allowedGeometryTypes
        .where((type) => type == 'Point')
        .toList(growable: false);
  }

  void _captureGpsSample(ProjectSummary project) {
    final latitude = 33.1 + (_random.nextDouble() * 1.45);
    final longitude = 35.1 + (_random.nextDouble() * 1.25);
    final accuracy = 3 + (_random.nextDouble() * 18);

    setState(() {
      _latitudeController.text = latitude.toStringAsFixed(6);
      _longitudeController.text = longitude.toStringAsFixed(6);
      _gpsAccuracyMeters = accuracy;
    });

    final quality = Phase6Validation.gpsQualityLabel(_gpsAccuracyMeters);
    AppSnackbar.showSuccess(
      context,
      'GPS sample captured: ${accuracy.toStringAsFixed(1)}m ($quality).',
    );
  }

  Future<void> _pickPhotos(ProjectSummary project) async {
    final remaining = project.maxPhotos - _photos.length;
    if (remaining <= 0) {
      AppSnackbar.showError(
        context,
        'Maximum photo limit reached (${project.maxPhotos}).',
      );
      return;
    }

    try {
      final picked = await _imagePicker.pickMultiImage(imageQuality: 82);
      if (picked.isEmpty) {
        return;
      }

      final filesToAdd = picked.take(remaining).toList(growable: false);
      final selected = await Future.wait(
        filesToAdd.map((file) async {
          final size = await file.length();
          return _SelectedPhoto(
            id: _uuid.v4(),
            filePath: file.path,
            fileName: file.name,
            sizeBytes: size,
            createdAt: DateTime.now(),
          );
        }),
      );

      setState(() {
        _photos.addAll(selected);
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
      AppSnackbar.showError(context, 'Photo selection failed: $error');
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
    if (_supportedGeometryTypes(project).isEmpty) {
      return 'This project does not allow point capture yet. Update the project geometry policy before collecting from mobile.';
    }

    if (stepIndex == 0) {
      if (_selectedProjectId == null || _selectedProjectId!.isEmpty) {
        return 'Select an assigned project.';
      }

      final lat = double.tryParse(_latitudeController.text.trim());
      final lon = double.tryParse(_longitudeController.text.trim());
      return Phase6Validation.validateGeometry(
        geometryType: _selectedGeometryType ?? 'Point',
        allowedGeometryTypes: _supportedGeometryTypes(project),
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
    }
  }

  Future<void> _saveToServer(
    ProjectSummary project, {
    required bool submit,
  }) async {
    final geometry = <String, dynamic>{
      'type': _selectedGeometryType ?? 'Point',
      'coordinates': <double>[
        double.parse(_longitudeController.text.trim()),
        double.parse(_latitudeController.text.trim()),
      ],
    };

    final attributes = _collectAttributeValues(project);
    setState(() {
      _isSubmitting = true;
    });

    try {
      final repository = ref.read(featureWorkflowRepositoryProvider);
      final feature = await repository.createDraft(
        projectId: project.id,
        geometry: geometry,
        attributes: attributes,
        accuracyMeters: _gpsAccuracyMeters,
        collectedOffline: false,
      );

      await repository.uploadPhotos(
        featureId: feature.id,
        filePaths: _photos
            .map((photo) => photo.filePath)
            .toList(growable: false),
      );

      if (submit) {
        await repository.submitForReview(feature.id);
      }

      ref.invalidate(projectMapFeaturesProvider(project.id));
      ref.invalidate(projectByIdProvider(project.id));
      ref.invalidate(reviewQueueProvider);

      if (!mounted) {
        return;
      }

      AppSnackbar.showSuccess(
        context,
        submit
            ? 'Feature submitted for review successfully.'
            : 'Feature draft saved to the project successfully.',
      );
      context.go(AppRoutes.mapForProject(project.id));
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnackbar.showError(context, error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
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
            message: '$error',
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
            final selectedProject =
                projects.where((p) => p.id == _selectedProjectId).isEmpty
                ? projects.first
                : projects.firstWhere((p) => p.id == _selectedProjectId);
            final supportedGeometryTypes = _supportedGeometryTypes(
              selectedProject,
            );

            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'New Feature',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Project-specific collection flow for geometry, attributes, photos, and review submission.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: List<Widget>.generate(4, (index) {
                          final labels = const [
                            'Geometry',
                            'Attributes',
                            'Photos',
                            'Review',
                          ];
                          final stateLabel = index < _currentStep
                              ? '${index + 1}. ${labels[index]}'
                              : '${index + 1}. ${labels[index]}';
                          return Chip(
                            label: Text(stateLabel),
                            avatar: Icon(
                              index < _currentStep
                                  ? Icons.check_circle_outline
                                  : Icons.radio_button_unchecked,
                              size: 18,
                            ),
                            backgroundColor: index == _currentStep
                                ? Theme.of(context).colorScheme.primaryContainer
                                : null,
                          );
                        }),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _buildCurrentStepCard(
                  context,
                  projects: projects,
                  selectedProject: selectedProject,
                  supportedGeometryTypes: supportedGeometryTypes,
                ),
                const SizedBox(height: 12),
                AppCard(
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      if (_currentStep > 0)
                        OutlinedButton(
                          onPressed: _isSubmitting
                              ? null
                              : () => setState(() => _currentStep -= 1),
                          child: const Text('Back'),
                        ),
                      if (_currentStep < 3)
                        AppButton(
                          label: 'Next',
                          icon: Icons.arrow_forward,
                          expand: false,
                          onPressed: _isSubmitting
                              ? null
                              : () => _handleContinue(projects),
                        ),
                      if (_currentStep == 3)
                        OutlinedButton.icon(
                          onPressed: _isSubmitting
                              ? null
                              : () => _saveToServer(
                                  selectedProject,
                                  submit: false,
                                ),
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('Save Draft'),
                        ),
                      if (_currentStep == 3)
                        FilledButton.icon(
                          onPressed: _isSubmitting
                              ? null
                              : () => _saveToServer(
                                  selectedProject,
                                  submit: true,
                                ),
                          icon: const Icon(Icons.send_outlined),
                          label: const Text('Submit for Review'),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
        if (_isSubmitting)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.18),
              child: const Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }

  Widget _buildCurrentStepCard(
    BuildContext context, {
    required List<ProjectSummary> projects,
    required ProjectSummary selectedProject,
    required List<String> supportedGeometryTypes,
  }) {
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
              if (supportedGeometryTypes.isEmpty)
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text('Point capture required'),
                      SizedBox(height: 8),
                      Text(
                        'This mobile build supports point capture. Update the project geometry policy to include Point before collecting from this screen.',
                      ),
                    ],
                  ),
                )
              else
                DropdownButtonFormField<String>(
                  initialValue: _selectedGeometryType,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Geometry Type'),
                  items: supportedGeometryTypes
                      .map(
                        (type) =>
                            DropdownMenuItem(value: type, child: Text(type)),
                      )
                      .toList(growable: false),
                  onChanged: (value) {
                    setState(() {
                      _selectedGeometryType = value;
                    });
                  },
                ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 520) {
                    return Column(
                      children: [
                        TextFormField(
                          controller: _latitudeController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Latitude',
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _longitudeController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Longitude',
                          ),
                        ),
                      ],
                    );
                  }

                  return Row(
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
                  );
                },
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
                          ? 'GPS not captured yet'
                          : 'Accuracy ${_gpsAccuracyMeters!.toStringAsFixed(1)}m (${Phase6Validation.gpsQualityLabel(_gpsAccuracyMeters)})',
                    ),
                  ),
                  Chip(
                    avatar: const Icon(Icons.rule, size: 18),
                    label: Text(
                      'Target <= ${selectedProject.maxGpsAccuracyMeters.toStringAsFixed(1)}m',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: supportedGeometryTypes.isEmpty
                    ? null
                    : () => _captureGpsSample(selectedProject),
                icon: const Icon(Icons.my_location),
                label: const Text('Capture GPS Sample'),
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
                'Form schema ${selectedProject.collectionFormSchema.version} with ${selectedProject.collectionFormSchema.fields.length} field(s).',
              ),
              const SizedBox(height: 12),
              if (selectedProject.collectionFormSchema.fields.isEmpty)
                const Text('No dynamic fields are configured for this project.')
              else
                ...selectedProject.collectionFormSchema.fields.map(
                  (field) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _buildSchemaField(field),
                  ),
                ),
            ],
          ),
        );
      case 2:
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Photo policy: ${selectedProject.requiresPhotos ? 'Required' : 'Optional'}',
              ),
              Text(
                'Minimum ${selectedProject.minPhotos} • Maximum ${selectedProject.maxPhotos}',
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => _pickPhotos(selectedProject),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Select Photos'),
              ),
              const SizedBox(height: 8),
              if (_photos.isEmpty)
                const Text('No photos selected yet.')
              else
                ..._photos.map(
                  (photo) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const CircleAvatar(
                                child: Icon(Icons.photo_camera_back),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(photo.fileName, softWrap: true),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${_formatBytes(photo.sizeBytes)} • ${photo.createdAt.toLocal()}',
                                      softWrap: true,
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () {
                                  setState(() {
                                    _photos.remove(photo);
                                  });
                                },
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
        );
      default:
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                selectedProject.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text('Geometry: ${_selectedGeometryType ?? 'Point'}'),
              Text(
                'GPS quality: ${Phase6Validation.gpsQualityLabel(_gpsAccuracyMeters)}',
              ),
              Text(
                'Attributes captured: ${_collectAttributeValues(selectedProject).length}',
              ),
              Text('Photos attached: ${_photos.length}'),
            ],
          ),
        );
    }
  }
}

class _SelectedPhoto {
  const _SelectedPhoto({
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
