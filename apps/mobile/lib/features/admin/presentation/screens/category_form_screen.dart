import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
                            hint: 'Fruit trees mapping',
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
                            hint: 'Used to group related field projects.',
                            controller: _descriptionController,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          AppTextField(
                            label: 'Icon URL',
                            hint: 'Optional icon reference',
                            controller: _iconUrlController,
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
