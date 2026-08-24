import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/loading_overlay.dart';
import '../../../auth/presentation/utils/auth_form_validators.dart';
import '../../../auth/presentation/widgets/lebanese_mobile_field.dart';

class AdminCreationScreen extends ConsumerStatefulWidget {
  const AdminCreationScreen({super.key});

  @override
  ConsumerState<AdminCreationScreen> createState() =>
      _AdminCreationScreenState();
}

class _AdminCreationScreenState extends ConsumerState<AdminCreationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _isSubmitting = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  @override
  void dispose() {
    _fullNameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      await ref
          .read(adminRepositoryProvider)
          .createAdmin(
            fullName: AuthFormValidators.normalize(_fullNameController.text),
            email: AuthFormValidators.normalize(_emailController.text),
            password: _passwordController.text,
            phone: AuthFormValidators.normalizeLebanesePhone(
              _phoneController.text,
            ),
          );
      bumpRealtimeScope(ref, const RealtimeScope('users', 'all'));
      if (!mounted) {
        return;
      }
      AppSnackbar.showSuccess(
        context,
        'Admin account created. Verification is required before sign-in.',
      );
      context.go(AppRoutes.users);
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

  @override
  Widget build(BuildContext context) {
    return LoadingOverlay(
      isLoading: _isSubmitting,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Form(
            key: _formKey,
            child: ListView(
              children: [
                AppCard(
                  child: Column(
                    children: [
                      AppTextField(
                        label: 'Full name',
                        hint: 'Full name',
                        controller: _fullNameController,
                        validator: (value) => AuthFormValidators.requiredField(
                          value,
                          fieldLabel: 'Full name',
                          minLength: 3,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      LebaneseMobileField(
                        controller: _phoneController,
                        validator: AuthFormValidators.phoneRequired,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      AppTextField(
                        label: 'Email address',
                        hint: 'name@example.com',
                        controller: _emailController,
                        validator: AuthFormValidators.email,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      AppTextField(
                        label: 'Password',
                        hint: 'Strong administrator password',
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        validator: AuthFormValidators.password,
                        suffix: IconButton(
                          onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword,
                          ),
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility
                                : Icons.visibility_off,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      AppTextField(
                        label: 'Confirm password',
                        hint: 'Re-enter password',
                        controller: _confirmController,
                        obscureText: _obscureConfirm,
                        validator: (value) =>
                            AuthFormValidators.confirmPassword(
                              value: value,
                              password: _passwordController.text,
                            ),
                        suffix: IconButton(
                          onPressed: () => setState(
                            () => _obscureConfirm = !_obscureConfirm,
                          ),
                          icon: Icon(
                            _obscureConfirm
                                ? Icons.visibility
                                : Icons.visibility_off,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      AppButton(
                        label: 'Create Admin',
                        icon: Icons.admin_panel_settings_outlined,
                        isLoading: _isSubmitting,
                        onPressed: _isSubmitting ? null : _submit,
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
  }
}
