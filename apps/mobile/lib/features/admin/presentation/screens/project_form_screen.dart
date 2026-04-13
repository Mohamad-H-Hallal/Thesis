import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/loading_overlay.dart';
import '../../../auth/presentation/utils/auth_form_validators.dart';
import '../../../projects/domain/project.dart';
import '../../domain/admin_models.dart';

class ProjectFormScreen extends ConsumerStatefulWidget {
  const ProjectFormScreen({super.key, this.projectId});

  final String? projectId;

  bool get isEditing => projectId != null && projectId!.isNotEmpty;

  @override
  ConsumerState<ProjectFormScreen> createState() => _ProjectFormScreenState();
}

class _ProjectFormScreenState extends ConsumerState<ProjectFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _objectivesController = TextEditingController();
  final _minPhotosController = TextEditingController(text: '0');
  final _maxPhotosController = TextEditingController(text: '5');
  final _schemaVersionController = TextEditingController(text: 'v1.0');
  final _maxGpsAccuracyController = TextEditingController(text: '25');

  final List<_EditableFormField> _fields = <_EditableFormField>[];
  final Set<String> _allowedGeometryTypes = <String>{'Point'};

  bool _initialized = false;
  bool _isSaving = false;
  bool _requiresPhotos = false;
  bool _visibleToViewers = false;
  String? _categoryId;
  String _status = 'draft';
  DateTime? _startDate;
  DateTime? _endDate;

  void _returnToProjects() {
    if (context.canPop()) {
      context.pop();
      return;
    }
    context.go(AppRoutes.projects);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _objectivesController.dispose();
    _minPhotosController.dispose();
    _maxPhotosController.dispose();
    _schemaVersionController.dispose();
    _maxGpsAccuracyController.dispose();
    for (final field in _fields) {
      field.dispose();
    }
    super.dispose();
  }

  void _initializeForProject(ProjectSummary? project) {
    if (_initialized) {
      return;
    }

    if (widget.isEditing && project == null) {
      return;
    }

    if (project != null) {
      _nameController.text = project.name;
      _descriptionController.text = project.description;
      _objectivesController.text = project.objectives ?? '';
      _minPhotosController.text = '${project.minPhotos}';
      _maxPhotosController.text = '${project.maxPhotos}';
      _schemaVersionController.text = project.collectionFormSchema.version;
      _maxGpsAccuracyController.text = project.maxGpsAccuracyMeters
          .toStringAsFixed(0);
      _requiresPhotos = project.requiresPhotos;
      _visibleToViewers = project.visibleToViewers;
      _categoryId = project.categoryId;
      _status = project.status;
      _startDate = project.startDate;
      _endDate = project.endDate;
      _allowedGeometryTypes
        ..clear()
        ..addAll(project.allowedGeometryTypes);
      _fields
        ..clear()
        ..addAll(
          project.collectionFormSchema.fields
              .map(_EditableFormField.fromSchema)
              .toList(growable: false),
        );
    }

    _initialized = true;
  }

  List<String> _statusOptions() {
    if (!widget.isEditing) {
      return const <String>['draft', 'active'];
    }

    switch (_status) {
      case 'draft':
        return const <String>['draft', 'active'];
      case 'active':
        return const <String>['active', 'paused', 'completed'];
      case 'paused':
        return const <String>['paused', 'active', 'completed'];
      case 'completed':
        return const <String>['completed', 'active', 'paused', 'archived'];
      case 'archived':
        return const <String>['archived', 'completed'];
      default:
        return const <String>['draft'];
    }
  }

  Future<void> _pickDate({
    required bool isStart,
    required DateTime initialDate,
  }) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null) {
      return;
    }

    setState(() {
      if (isStart) {
        _startDate = picked;
      } else {
        _endDate = picked;
      }
    });
  }

  void _addField() {
    setState(() {
      _fields.add(_EditableFormField());
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    if (_categoryId == null || _categoryId!.isEmpty) {
      AppSnackbar.showError(context, 'Project category is required.');
      return;
    }
    if (_startDate != null &&
        _endDate != null &&
        _endDate!.isBefore(_startDate!)) {
      AppSnackbar.showError(
        context,
        'End date must be on or after the start date.',
      );
      return;
    }
    final scheduleError = _validateStatusSchedule();
    if (scheduleError != null) {
      AppSnackbar.showError(context, scheduleError);
      return;
    }
    if (_allowedGeometryTypes.isEmpty) {
      AppSnackbar.showError(
        context,
        'Select at least one allowed geometry type.',
      );
      return;
    }

    final minPhotos = int.tryParse(_minPhotosController.text.trim()) ?? 0;
    final maxPhotos = int.tryParse(_maxPhotosController.text.trim()) ?? 0;
    if (minPhotos < 0 || maxPhotos < 0 || minPhotos > maxPhotos) {
      AppSnackbar.showError(
        context,
        'Photo requirements must have valid minimum and maximum values.',
      );
      return;
    }

    final keys = <String>{};
    for (final field in _fields) {
      final error = field.validate();
      if (error != null) {
        AppSnackbar.showError(context, error);
        return;
      }
      final key = AuthFormValidators.normalize(field.keyController.text);
      if (!keys.add(key)) {
        AppSnackbar.showError(context, 'Collection field keys must be unique.');
        return;
      }
    }

    setState(() {
      _isSaving = true;
    });

    final input = ProjectProvisioningInput(
      name: AuthFormValidators.normalize(_nameController.text),
      description: AuthFormValidators.normalize(_descriptionController.text),
      objectives: AuthFormValidators.normalize(_objectivesController.text),
      categoryId: _categoryId!,
      status: _status,
      startDate: _startDate,
      endDate: _endDate,
      requiresPhotos: _requiresPhotos,
      minPhotos: minPhotos,
      maxPhotos: maxPhotos,
      visibleToViewers: _visibleToViewers,
      collectionFormSchema: <String, dynamic>{
        'version': AuthFormValidators.normalize(_schemaVersionController.text),
        'allowedGeometryTypes': _allowedGeometryTypes.toList(growable: false),
        'maxGpsAccuracyMeters':
            double.tryParse(_maxGpsAccuracyController.text.trim()) ?? 25,
        'fields': _fields
            .map((field) => field.toSchemaMap())
            .toList(growable: false),
      },
    );

    try {
      final repository = ref.read(adminRepositoryProvider);
      if (widget.isEditing) {
        await repository.updateProject(
          projectId: widget.projectId!,
          input: input,
        );
      } else {
        await repository.createProject(input);
      }

      bumpWorkflowRefresh(ref);

      if (!mounted) {
        return;
      }

      AppSnackbar.showSuccess(
        context,
        widget.isEditing
            ? 'Project updated successfully.'
            : 'Project created successfully.',
      );
      _returnToProjects();
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to save this project right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  String _formatDate(DateTime? value) {
    if (value == null) {
      return 'Not set';
    }
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '${value.year}-$month-$day';
  }

  String? _validateStatusSchedule() {
    final today = DateTime.now();
    final normalizedToday = DateTime(today.year, today.month, today.day);
    final start = _startDate == null
        ? null
        : DateTime(_startDate!.year, _startDate!.month, _startDate!.day);
    final end = _endDate == null
        ? null
        : DateTime(_endDate!.year, _endDate!.month, _endDate!.day);

    if (_status == 'draft' &&
        start != null &&
        start.isBefore(normalizedToday)) {
      return 'Draft projects must use a start date that is today or later.';
    }
    if (_status == 'active' &&
        start != null &&
        start.isAfter(normalizedToday)) {
      return 'Active projects cannot use a future start date.';
    }
    if (_status == 'completed' && end != null && end.isAfter(normalizedToday)) {
      return 'Completed projects cannot use a future end date.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(projectCategoriesProvider);
    final projectAsync = widget.isEditing
        ? ref.watch(projectByIdProvider(widget.projectId!))
        : const AsyncValue<ProjectSummary?>.data(null);

    return categoriesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Project form unavailable',
        message: '$error',
        actionLabel: 'Back',
        onAction: _returnToProjects,
      ),
      data: (categories) {
        if (categories.isEmpty) {
          return AppEmptyState(
            icon: Icons.category_outlined,
            title: 'Categories required',
            message:
                'Create at least one project category before creating projects.',
            actionLabel: 'Go to categories',
            onAction: () {
              if (context.canPop()) {
                context.pop();
              }
              context.go(AppRoutes.categories);
            },
          );
        }

        return projectAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => AppEmptyState(
            icon: Icons.error_outline,
            title: 'Project unavailable',
            message: '$error',
            actionLabel: 'Back',
            onAction: _returnToProjects,
          ),
          data: (project) {
            _initializeForProject(project);
            _categoryId ??= categories.first.id;
            final statusOptions = _statusOptions();

            return LoadingOverlay(
              isLoading: _isSaving,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 860),
                  child: Form(
                    key: _formKey,
                    child: ListView(
                      children: [
                        AppCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.isEditing
                                    ? 'Edit project'
                                    : 'Create project',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              AppTextField(
                                label: 'Project name',
                                hint: 'North Lebanon fruit tree census',
                                controller: _nameController,
                                validator: (value) =>
                                    AuthFormValidators.requiredField(
                                      value,
                                      fieldLabel: 'Project name',
                                      minLength: 3,
                                    ),
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              DropdownButtonFormField<String>(
                                initialValue: _categoryId,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Category',
                                ),
                                items: categories
                                    .map(
                                      (category) => DropdownMenuItem(
                                        value: category.id,
                                        child: Text(category.name),
                                      ),
                                    )
                                    .toList(growable: false),
                                onChanged: (value) {
                                  setState(() {
                                    _categoryId = value;
                                  });
                                },
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              AppTextField(
                                label: 'Description',
                                hint: 'Short operational summary',
                                controller: _descriptionController,
                                minLines: 3,
                                maxLines: 6,
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              AppTextField(
                                label: 'Objectives',
                                hint: 'Survey goals and collection scope',
                                controller: _objectivesController,
                                minLines: 3,
                                maxLines: 6,
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              DropdownButtonFormField<String>(
                                initialValue: _status,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Status',
                                ),
                                items: statusOptions
                                    .map(
                                      (status) => DropdownMenuItem(
                                        value: status,
                                        child: Text(status),
                                      ),
                                    )
                                    .toList(growable: false),
                                onChanged: (value) {
                                  if (value == null) {
                                    return;
                                  }
                                  setState(() {
                                    _status = value;
                                  });
                                },
                              ),
                              if (!widget.isEditing)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    top: AppSpacing.xs,
                                  ),
                                  child: Text(
                                    'New projects are created as draft first. Choosing active here promotes the project immediately after creation.',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ),
                              if (_status == 'paused')
                                Padding(
                                  padding: const EdgeInsets.only(
                                    top: AppSpacing.xs,
                                  ),
                                  child: Text(
                                    'Paused projects remain viewable, but feature collection and submission stay disabled until the project returns to active status.',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ),
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: AppSpacing.xs,
                                ),
                                child: Text(switch (_status) {
                                  'draft' =>
                                    'Draft projects should use a start date that is today or later.',
                                  'active' =>
                                    'Active projects should be underway now. Future start dates are not allowed.',
                                  'completed' =>
                                    'Completed projects should use an end date on or before today.',
                                  'archived' =>
                                    'Archived projects stay closed until they are restored to completed status.',
                                  _ =>
                                    'Paused projects keep their schedule but remain unavailable for collection until reactivated.',
                                }, style: Theme.of(context).textTheme.bodySmall),
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              Wrap(
                                spacing: AppSpacing.sm,
                                runSpacing: AppSpacing.sm,
                                children: [
                                  _DateCard(
                                    label: 'Start date',
                                    value: _formatDate(_startDate),
                                    onPressed: () => _pickDate(
                                      isStart: true,
                                      initialDate: _startDate ?? DateTime.now(),
                                    ),
                                  ),
                                  _DateCard(
                                    label: 'End date',
                                    value: _formatDate(_endDate),
                                    onPressed: () => _pickDate(
                                      isStart: false,
                                      initialDate:
                                          _endDate ??
                                          _startDate ??
                                          DateTime.now(),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                value: _visibleToViewers,
                                onChanged: (value) {
                                  setState(() {
                                    _visibleToViewers = value;
                                  });
                                },
                                title: const Text('Visible to users'),
                                subtitle: const Text(
                                  'When enabled and active/completed, this project is visible in the user and public project list.',
                                ),
                              ),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                value: _requiresPhotos,
                                onChanged: (value) {
                                  setState(() {
                                    _requiresPhotos = value;
                                  });
                                },
                                title: const Text('Require photos'),
                                subtitle: const Text(
                                  'Use the schema-backed project policy for required field photos.',
                                ),
                              ),
                              Wrap(
                                spacing: AppSpacing.sm,
                                runSpacing: AppSpacing.sm,
                                children: [
                                  SizedBox(
                                    width: 180,
                                    child: AppTextField(
                                      label: 'Minimum photos',
                                      controller: _minPhotosController,
                                      keyboardType: TextInputType.number,
                                      validator: (value) {
                                        final parsed = int.tryParse(
                                          value?.trim() ?? '',
                                        );
                                        if (parsed == null || parsed < 0) {
                                          return 'Enter a valid minimum';
                                        }
                                        return null;
                                      },
                                    ),
                                  ),
                                  SizedBox(
                                    width: 180,
                                    child: AppTextField(
                                      label: 'Maximum photos',
                                      controller: _maxPhotosController,
                                      keyboardType: TextInputType.number,
                                      validator: (value) {
                                        final parsed = int.tryParse(
                                          value?.trim() ?? '',
                                        );
                                        if (parsed == null || parsed < 0) {
                                          return 'Enter a valid maximum';
                                        }
                                        return null;
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        AppCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Collection schema',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              AppTextField(
                                label: 'Schema version',
                                controller: _schemaVersionController,
                                validator: (value) =>
                                    AuthFormValidators.requiredField(
                                      value,
                                      fieldLabel: 'Schema version',
                                      minLength: 2,
                                    ),
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              AppTextField(
                                label: 'Max GPS accuracy (meters)',
                                controller: _maxGpsAccuracyController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                validator: (value) {
                                  final parsed = double.tryParse(
                                    value?.trim() ?? '',
                                  );
                                  if (parsed == null || parsed <= 0) {
                                    return 'Enter a valid GPS accuracy target';
                                  }
                                  return null;
                                },
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              Text(
                                'Allowed geometry types',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: AppSpacing.xs),
                              Wrap(
                                spacing: AppSpacing.xs,
                                children: [
                                  for (final type in const [
                                    'Point',
                                    'LineString',
                                    'Polygon',
                                  ])
                                    FilterChip(
                                      label: Text(type),
                                      selected: _allowedGeometryTypes.contains(
                                        type,
                                      ),
                                      onSelected: (selected) {
                                        setState(() {
                                          if (selected) {
                                            _allowedGeometryTypes.add(type);
                                          } else {
                                            _allowedGeometryTypes.remove(type);
                                          }
                                        });
                                      },
                                    ),
                                ],
                              ),
                              const SizedBox(height: AppSpacing.md),
                              LayoutBuilder(
                                builder: (context, constraints) {
                                  final action = OutlinedButton.icon(
                                    onPressed: _addField,
                                    icon: const Icon(Icons.add),
                                    label: const Text('Add field'),
                                  );
                                  if (constraints.maxWidth < 480) {
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Dynamic collection fields',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleMedium,
                                        ),
                                        const SizedBox(height: AppSpacing.sm),
                                        action,
                                      ],
                                    );
                                  }
                                  return Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          'Dynamic collection fields',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleMedium,
                                        ),
                                      ),
                                      action,
                                    ],
                                  );
                                },
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              if (_fields.isEmpty)
                                const Text(
                                  'No dynamic fields configured. The project will collect geometry-only submissions until fields are added.',
                                )
                              else
                                ...List<Widget>.generate(_fields.length, (
                                  index,
                                ) {
                                  final field = _fields[index];
                                  return Padding(
                                    padding: const EdgeInsets.only(
                                      bottom: AppSpacing.sm,
                                    ),
                                    child: _FieldEditorCard(
                                      index: index,
                                      field: field,
                                      onRemove: () {
                                        setState(() {
                                          _fields.removeAt(index).dispose();
                                        });
                                      },
                                      onChanged: () => setState(() {}),
                                    ),
                                  );
                                }),
                            ],
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Wrap(
                          spacing: AppSpacing.sm,
                          runSpacing: AppSpacing.sm,
                          children: [
                            AppButton(
                              label: widget.isEditing
                                  ? 'Save changes'
                                  : 'Create project',
                              icon: Icons.save_outlined,
                              isLoading: _isSaving,
                              expand: false,
                              onPressed: _isSaving ? null : _save,
                            ),
                            OutlinedButton(
                              onPressed: _isSaving ? null : _returnToProjects,
                              child: const Text('Cancel'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _DateCard extends StatelessWidget {
  const _DateCard({
    required this.label,
    required this.value,
    required this.onPressed,
  });

  final String label;
  final String value;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 260,
      child: AppCard(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final summary = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodySmall),
                Text(value, style: Theme.of(context).textTheme.titleMedium),
              ],
            );
            final action = OutlinedButton.icon(
              onPressed: onPressed,
              icon: const Icon(Icons.event_outlined),
              label: const Text('Pick'),
            );

            if (constraints.maxWidth < 240) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  summary,
                  const SizedBox(height: AppSpacing.sm),
                  action,
                ],
              );
            }

            return Row(
              children: [
                Expanded(child: summary),
                const SizedBox(width: AppSpacing.sm),
                action,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _FieldEditorCard extends StatelessWidget {
  const _FieldEditorCard({
    required this.index,
    required this.field,
    required this.onRemove,
    required this.onChanged,
  });

  final int index;
  final _EditableFormField field;
  final VoidCallback onRemove;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Field ${index + 1}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Remove field',
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          AppTextField(
            label: 'Field key',
            hint: 'tree_species',
            controller: field.keyController,
            onChanged: (_) => onChanged(),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppTextField(
            label: 'Label',
            hint: 'Tree species',
            controller: field.labelController,
            onChanged: (_) => onChanged(),
          ),
          const SizedBox(height: AppSpacing.sm),
          DropdownButtonFormField<CollectionFieldType>(
            initialValue: field.type,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Field type'),
            items: CollectionFieldType.values
                .map(
                  (type) =>
                      DropdownMenuItem(value: type, child: Text(type.name)),
                )
                .toList(growable: false),
            onChanged: (value) {
              if (value == null) {
                return;
              }
              field.type = value;
              onChanged();
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          AppTextField(
            label: 'Hint',
            hint: 'Optional helper text',
            controller: field.hintController,
            minLines: 2,
            maxLines: 4,
            onChanged: (_) => onChanged(),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              SizedBox(
                width: 160,
                child: AppTextField(
                  label: 'Min',
                  controller: field.minController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) => onChanged(),
                ),
              ),
              SizedBox(
                width: 160,
                child: AppTextField(
                  label: 'Max',
                  controller: field.maxController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) => onChanged(),
                ),
              ),
              SizedBox(
                width: 160,
                child: AppTextField(
                  label: 'Unit',
                  controller: field.unitController,
                  onChanged: (_) => onChanged(),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          AppTextField(
            label: 'Options (comma-separated)',
            hint: 'Olive, Citrus, Apple',
            controller: field.optionsController,
            onChanged: (_) => onChanged(),
          ),
          const SizedBox(height: AppSpacing.xs),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: field.required,
            onChanged: (value) {
              field.required = value;
              onChanged();
            },
            title: const Text('Required field'),
          ),
        ],
      ),
    );
  }
}

class _EditableFormField {
  _EditableFormField({
    String key = '',
    String label = '',
    this.type = CollectionFieldType.text,
    String hint = '',
    String options = '',
    String unit = '',
    String min = '',
    String max = '',
    this.required = false,
  }) : keyController = TextEditingController(text: key),
       labelController = TextEditingController(text: label),
       hintController = TextEditingController(text: hint),
       optionsController = TextEditingController(text: options),
       unitController = TextEditingController(text: unit),
       minController = TextEditingController(text: min),
       maxController = TextEditingController(text: max);

  factory _EditableFormField.fromSchema(CollectionFormFieldSchema field) {
    return _EditableFormField(
      key: field.key,
      label: field.label,
      type: field.type,
      hint: field.hint ?? '',
      options: field.options.join(', '),
      unit: field.unit ?? '',
      min: field.min?.toString() ?? '',
      max: field.max?.toString() ?? '',
      required: field.required,
    );
  }

  final TextEditingController keyController;
  final TextEditingController labelController;
  final TextEditingController hintController;
  final TextEditingController optionsController;
  final TextEditingController unitController;
  final TextEditingController minController;
  final TextEditingController maxController;
  CollectionFieldType type;
  bool required;

  String? validate() {
    final key = AuthFormValidators.normalize(keyController.text);
    final label = AuthFormValidators.normalize(labelController.text);
    if (key.isEmpty) {
      return 'Every collection field needs a key.';
    }
    if (label.isEmpty) {
      return 'Every collection field needs a label.';
    }
    if (type == CollectionFieldType.select &&
        optionsController.text.trim().isEmpty) {
      return 'Select fields require at least one option.';
    }
    return null;
  }

  Map<String, dynamic> toSchemaMap() {
    final min = double.tryParse(minController.text.trim());
    final max = double.tryParse(maxController.text.trim());
    return <String, dynamic>{
      'key': AuthFormValidators.normalize(keyController.text),
      'label': AuthFormValidators.normalize(labelController.text),
      'type': type == CollectionFieldType.multiline ? 'textarea' : type.name,
      'required': required,
      'hint': AuthFormValidators.normalize(hintController.text),
      'options': optionsController.text
          .split(',')
          .map(AuthFormValidators.normalize)
          .where((value) => value.isNotEmpty)
          .toList(growable: false),
      'unit': AuthFormValidators.normalize(unitController.text),
      'min': min,
      'max': max,
    };
  }

  void dispose() {
    keyController.dispose();
    labelController.dispose();
    hintController.dispose();
    optionsController.dispose();
    unitController.dispose();
    minController.dispose();
    maxController.dispose();
  }
}
