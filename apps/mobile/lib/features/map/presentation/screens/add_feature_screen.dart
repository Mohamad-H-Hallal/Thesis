import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../projects/domain/project.dart';
import '../../domain/field_collection_validation.dart';
import '../../domain/map_feature.dart';

class AddFeatureScreen extends ConsumerStatefulWidget {
  const AddFeatureScreen({
    super.key,
    this.initialProjectId,
    this.draftFeatureId,
  });

  final String? initialProjectId;
  final String? draftFeatureId;

  @override
  ConsumerState<AddFeatureScreen> createState() => _AddFeatureScreenState();
}

class _AddFeatureScreenState extends ConsumerState<AddFeatureScreen> {
  final Uuid _uuid = const Uuid();
  final Random _random = Random();
  final ImagePicker _imagePicker = ImagePicker();

  int _currentStep = 0;
  bool _isSaving = false;

  String? _selectedProjectId;
  String? _selectedGeometryType;
  String? _currentDraftFeatureId;
  String? _hydratedDraftId;

  final TextEditingController _latitudeController = TextEditingController();
  final TextEditingController _longitudeController = TextEditingController();

  final Map<String, TextEditingController> _attributeControllers =
      <String, TextEditingController>{};
  final Map<String, dynamic> _attributeValues = <String, dynamic>{};
  final Map<String, String> _fieldErrors = <String, String>{};
  final List<_PendingPhoto> _pendingPhotos = <_PendingPhoto>[];

  double? _gpsAccuracyMeters;
  List<MapFeaturePhoto> _uploadedPhotos = const <MapFeaturePhoto>[];

  bool get _isEditingDraft =>
      (widget.draftFeatureId?.isNotEmpty ?? false) ||
      (_currentDraftFeatureId?.isNotEmpty ?? false);

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

    final existingSelection = projects.any((item) => item.id == _selectedProjectId);
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
    final draftGeometryType = draftFeature?.geometry['type'] as String?;
    final geometryType = draftFeature == null
        ? (supportedGeometryTypes.contains(_selectedGeometryType)
              ? _selectedGeometryType
              : (supportedGeometryTypes.isEmpty
                    ? null
                    : supportedGeometryTypes.first))
        : (supportedGeometryTypes.contains(draftGeometryType)
              ? draftGeometryType
              : (supportedGeometryTypes.isEmpty
                    ? null
                    : supportedGeometryTypes.first));

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

    final point = _pointFromGeometry(draftFeature?.geometry);

    setState(() {
      _selectedProjectId = project.id;
      _selectedGeometryType = geometryType;
      _uploadedPhotos = draftFeature?.photos ?? const <MapFeaturePhoto>[];
      _pendingPhotos.clear();
      _gpsAccuracyMeters = draftFeature?.accuracyMeters;
      _latitudeController.text = point?.latitude.toStringAsFixed(6) ?? '';
      _longitudeController.text = point?.longitude.toStringAsFixed(6) ?? '';
      _currentStep = 0;
      _currentDraftFeatureId = draftFeature?.id;
      _hydratedDraftId = draftFeature?.id;
    });
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
      final picked = await _imagePicker.pickMultiImage(imageQuality: 82);
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
    if (project.status != 'active') {
      AppSnackbar.showError(
        context,
        'Feature collection is only available while the project is active.',
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

    final geometry = <String, dynamic>{
      'type': _selectedGeometryType ?? 'Point',
      'coordinates': <double>[
        double.parse(_longitudeController.text.trim()),
        double.parse(_latitudeController.text.trim()),
      ],
    };

    final attributes = _collectAttributeValues(project);
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
          accuracyMeters: _gpsAccuracyMeters,
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

      AppSnackbar.showSuccess(
        context,
        submit
            ? 'Feature submitted for review successfully.'
            : 'Feature draft saved successfully.',
      );
      context.go(AppRoutes.mapForProject(project.id));
    } catch (error) {
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
    final projectsAsync = ref.watch(projectListProvider(ProjectViewScope.assigned));

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
                  project.id ==
                  (_selectedProjectId ?? widget.initialProjectId),
              orElse: () => projects.first,
            );

            if (widget.draftFeatureId != null && widget.draftFeatureId!.isNotEmpty) {
              final projectId = widget.initialProjectId ?? selectedProject.id;
              final draftAsync = ref.watch(projectMapFeaturesProvider(projectId));

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
                  onAction: () => context.go(AppRoutes.mapForProject(projectId)),
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
                      onAction: () => context.go(AppRoutes.mapForProject(projectId)),
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
        onAction: () => context.go(AppRoutes.mapForProject(selectedProject.id)),
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SectionHeader(
          title: _isEditingDraft ? 'Edit draft feature' : 'New feature',
          subtitle:
              'Capture geometry, fill project attributes, attach photos, and save or submit for review.',
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
                      : () => setState(() => _currentStep -= 1),
                  child: const Text('Back'),
                ),
              if (_currentStep < 3)
                FilledButton.icon(
                  onPressed: _isSaving ? null : () => _handleNext(selectedProject),
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
                decoration: const InputDecoration(labelText: 'Assigned project'),
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
                        final project = projects.firstWhere((p) => p.id == value);
                        _applyProjectSelection(project);
                      },
              ),
              const SizedBox(height: AppSpacing.sm),
              if (supportedGeometryTypes.isEmpty)
                const AppEmptyState(
                  icon: Icons.edit_location_alt_outlined,
                  title: 'Point capture unavailable',
                  message:
                      'This mobile build supports point geometry only. Update the project collection schema if you need a different geometry policy.',
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
              LayoutBuilder(
                builder: (context, constraints) {
                  final latitudeField = AppTextField(
                    label: 'Latitude',
                    controller: _latitudeController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                  );
                  final longitudeField = AppTextField(
                    label: 'Longitude',
                    controller: _longitudeController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                  );

                  if (constraints.maxWidth < 520) {
                    return Column(
                      children: [
                        latitudeField,
                        const SizedBox(height: AppSpacing.sm),
                        longitudeField,
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: latitudeField),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(child: longitudeField),
                    ],
                  );
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Chip(
                    avatar: const Icon(Icons.gps_fixed, size: 18),
                    label: Text(
                      _gpsAccuracyMeters == null
                          ? 'GPS not captured'
                          : 'Accuracy ${_gpsAccuracyMeters!.toStringAsFixed(1)}m (${Phase6Validation.gpsQualityLabel(_gpsAccuracyMeters)})',
                    ),
                  ),
                  Chip(
                    avatar: const Icon(Icons.rule_outlined, size: 18),
                    label: Text(
                      'Target <= ${selectedProject.maxGpsAccuracyMeters.toStringAsFixed(1)}m',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: supportedGeometryTypes.isEmpty
                    ? null
                    : () => _captureGpsSample(selectedProject),
                icon: const Icon(Icons.my_location_outlined),
                label: const Text('Capture GPS sample'),
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
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Photos',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Policy: ${selectedProject.requiresPhotos ? 'Required' : 'Optional'} • Minimum ${selectedProject.minPhotos} • Maximum ${selectedProject.maxPhotos}',
                softWrap: true,
              ),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: _isSaving ? null : () => _pickPhotos(selectedProject),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Add photos'),
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
                  ..._uploadedPhotos.map(
                    (photo) => Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                      child: AppCard(
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const CircleAvatar(
                            child: Icon(Icons.photo_outlined),
                          ),
                          title: Text(_photoLabel(photo.filePath), softWrap: true),
                          subtitle: Text(
                            photo.status?.trim().isNotEmpty == true
                                ? 'Uploaded • ${photo.status}'
                                : 'Uploaded to this draft',
                            softWrap: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                if (_pendingPhotos.isNotEmpty) ...[
                  if (_uploadedPhotos.isNotEmpty)
                    const SizedBox(height: AppSpacing.sm),
                  Text(
                    'New photos',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  ..._pendingPhotos.map(
                    (photo) => Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                      child: AppCard(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const CircleAvatar(
                              child: Icon(Icons.photo_camera_back_outlined),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(photo.fileName, softWrap: true),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${_formatBytes(photo.sizeBytes)} • Pending upload',
                                    softWrap: true,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: _isSaving
                                  ? null
                                  : () {
                                      setState(() {
                                        _pendingPhotos.remove(photo);
                                      });
                                    },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
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
                  Chip(label: Text('Geometry: ${_selectedGeometryType ?? 'Point'}')),
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

  _GeometryPoint? _pointFromGeometry(Map<String, dynamic>? geometry) {
    if (geometry == null) {
      return null;
    }
    final type = geometry['type'] as String?;
    final coordinates = geometry['coordinates'];
    if (type == 'Point' && coordinates is List && coordinates.length >= 2) {
      return _GeometryPoint(
        latitude: (coordinates[1] as num).toDouble(),
        longitude: (coordinates[0] as num).toDouble(),
      );
    }
    return null;
  }

  String _photoLabel(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/');
    return segments.isEmpty ? path : segments.last;
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

class _GeometryPoint {
  const _GeometryPoint({
    required this.latitude,
    required this.longitude,
  });

  final double latitude;
  final double longitude;
}
