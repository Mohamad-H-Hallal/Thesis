import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/config/app_env.dart';
import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/loading_overlay.dart';
import '../../../auth/presentation/utils/auth_form_validators.dart';

class CategoryFormScreen extends ConsumerStatefulWidget {
  const CategoryFormScreen({super.key, this.categoryId});

  final String? categoryId;

  bool get isEditing => categoryId != null && categoryId!.isNotEmpty;

  @override
  ConsumerState<CategoryFormScreen> createState() => _CategoryFormScreenState();
}

class _CategoryFormScreenState extends ConsumerState<CategoryFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _iconUrlController = TextEditingController();
  bool _initialized = false;
  bool _isSaving = false;
  bool _isUploadingIcon = false;
  final ImagePicker _imagePicker = ImagePicker();

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _iconUrlController.dispose();
    super.dispose();
  }

  void _initializeIfNeeded() {
    if (_initialized || !widget.isEditing) {
      return;
    }
    final categories = ref.read(projectCategoriesProvider).valueOrNull;
    if (categories == null) {
      return;
    }
    final match = categories.where((item) => item.id == widget.categoryId);
    if (match.isEmpty) {
      return;
    }
    final category = match.first;
    _nameController.text = category.name;
    _descriptionController.text = category.description ?? '';
    _iconUrlController.text = category.iconUrl ?? '';
    _initialized = true;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final repository = ref.read(adminRepositoryProvider);
      if (widget.isEditing) {
        await repository.updateCategory(
          categoryId: widget.categoryId!,
          name: AuthFormValidators.normalize(_nameController.text),
          description: AuthFormValidators.normalize(_descriptionController.text),
          iconUrl: AuthFormValidators.normalize(_iconUrlController.text),
        );
      } else {
        await repository.createCategory(
          name: AuthFormValidators.normalize(_nameController.text),
          description: AuthFormValidators.normalize(_descriptionController.text),
          iconUrl: AuthFormValidators.normalize(_iconUrlController.text),
        );
      }

      ref.invalidate(projectCategoriesProvider);
      if (!mounted) {
        return;
      }
      AppSnackbar.showSuccess(
        context,
        widget.isEditing
            ? 'Category updated successfully.'
            : 'Category created successfully.',
      );
      context.go(AppRoutes.categories);
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(context, error.toString());
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  String? _iconPreviewUrl() {
    final raw = AuthFormValidators.normalize(_iconUrlController.text);
    if (raw.isEmpty) {
      return null;
    }
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return raw;
    }
    return '${AppEnv.apiBaseUrl}$raw';
  }

  Future<void> _pickAndUploadIcon(ImageSource source) async {
    final pickedFile = await _imagePicker.pickImage(source: source, imageQuality: 88);
    if (pickedFile == null) {
      return;
    }

    setState(() => _isUploadingIcon = true);
    try {
      final iconUrl = await ref.read(adminRepositoryProvider).uploadCategoryIcon(
            filePath: pickedFile.path,
            fileName: pickedFile.name,
          );
      if (!mounted) {
        return;
      }
      setState(() {
        _iconUrlController.text = iconUrl;
      });
      AppSnackbar.showSuccess(context, 'Category icon uploaded successfully.');
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(context, error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _isUploadingIcon = false);
      }
    }
  }

  Future<void> _manageIcon() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take photo'),
              onTap: () => Navigator.of(context).pop('camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.of(context).pop('gallery'),
            ),
            if (_iconUrlController.text.trim().isNotEmpty)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Remove current icon'),
                onTap: () => Navigator.of(context).pop('remove'),
              ),
          ],
        ),
      ),
    );

    switch (action) {
      case 'camera':
        await _pickAndUploadIcon(ImageSource.camera);
        break;
      case 'gallery':
        await _pickAndUploadIcon(ImageSource.gallery);
        break;
      case 'remove':
        setState(() {
          _iconUrlController.clear();
        });
        break;
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(projectCategoriesProvider);

    return categoriesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Category form unavailable',
        message: '$error',
        actionLabel: 'Back',
        onAction: () => context.go(AppRoutes.categories),
      ),
      data: (_) {
        _initializeIfNeeded();
        return LoadingOverlay(
          isLoading: _isSaving,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
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
                                ? 'Edit category'
                                : 'Create category',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          AppTextField(
                            label: 'Category name',
                            hint: 'Category name',
                            controller: _nameController,
                            validator: (value) =>
                                AuthFormValidators.requiredField(
                                  value,
                                  fieldLabel: 'Category name',
                                  minLength: 3,
                                ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          AppTextField(
                            label: 'Description',
                            hint: 'Optional description',
                            controller: _descriptionController,
                            minLines: 3,
                            maxLines: 6,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            'Category icon',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          AppCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (_iconPreviewUrl() != null)
                                  ClipRRect(
                                    borderRadius: AppRadii.md,
                                    child: Image.network(
                                      _iconPreviewUrl()!,
                                      height: 160,
                                      width: double.infinity,
                                      fit: BoxFit.cover,
                                      errorBuilder: (context, error, stackTrace) => Container(
                                        height: 120,
                                        alignment: Alignment.center,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .surfaceContainerHighest,
                                        child: const Text('Icon preview unavailable'),
                                      ),
                                    ),
                                  )
                                else
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(AppSpacing.md),
                                    decoration: BoxDecoration(
                                      borderRadius: AppRadii.md,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .surfaceContainerHighest,
                                    ),
                                    child: const Text(
                                      'Optional. Add an icon using camera or gallery to help users recognize this category quickly.',
                                    ),
                                  ),
                                const SizedBox(height: AppSpacing.sm),
                                Wrap(
                                  spacing: AppSpacing.sm,
                                  runSpacing: AppSpacing.sm,
                                  children: [
                                    AppButton(
                                      label: _iconUrlController.text.trim().isEmpty
                                          ? 'Add icon'
                                          : 'Change icon',
                                      icon: Icons.image_outlined,
                                      isLoading: _isUploadingIcon,
                                      expand: false,
                                      onPressed: _isUploadingIcon ? null : _manageIcon,
                                    ),
                                    if (_iconUrlController.text.trim().isNotEmpty)
                                      OutlinedButton.icon(
                                        onPressed: _isUploadingIcon
                                            ? null
                                            : () => setState(() {
                                                  _iconUrlController.clear();
                                                }),
                                        icon: const Icon(Icons.delete_outline),
                                        label: const Text('Remove'),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Wrap(
                            spacing: AppSpacing.sm,
                            runSpacing: AppSpacing.sm,
                            children: [
                              AppButton(
                                label:
                                    widget.isEditing ? 'Save Changes' : 'Create',
                                icon: Icons.save_outlined,
                                isLoading: _isSaving,
                                expand: false,
                                onPressed: _isSaving ? null : _save,
                              ),
                              OutlinedButton(
                                onPressed: _isSaving
                                    ? null
                                    : () => context.go(AppRoutes.categories),
                                child: const Text('Cancel'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
