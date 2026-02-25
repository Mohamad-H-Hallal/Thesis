import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_logo.dart';
import '../../../../core/widgets/app_scaffold.dart';
import '../../presentation/controllers/auth_controller.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';

class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({this.mode, super.key});

  final String? mode;

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _tokenController = TextEditingController(text: 'mock-reset-token');
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  @override
  void dispose() {
    _tokenController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    try {
      await ref
          .read(authControllerProvider.notifier)
          .resetPassword(
            token: _tokenController.text.trim(),
            newPassword: _passwordController.text,
          );
      if (!mounted) return;
      AppSnackbar.showSuccess(
        context,
        'Password reset complete. Please login.',
      );
      context.go(AppRoutes.login);
    } catch (error) {
      if (!mounted) return;
      AppSnackbar.showError(context, error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mode == 'sent') {
      return AppScaffold(
        title: 'Check your email',
        showOfflineBanner: false,
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppLogo(size: 64),
                const SizedBox(height: 12),
                const Icon(Icons.mark_email_read_outlined, size: 60),
                const SizedBox(height: 12),
                Text(
                  'We sent a reset link to your email.',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                const Text(
                  'Use the link token (simulated) to set a new password.',
                ),
                const SizedBox(height: 16),
                AppButton(
                  label: 'Continue to reset form',
                  icon: Icons.arrow_forward,
                  onPressed: () => context.go(AppRoutes.resetPassword),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final authState = ref.watch(authControllerProvider);
    return AppScaffold(
      title: 'Reset password',
      showOfflineBanner: false,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppLogo(size: 64),
                const SizedBox(height: 14),
                AppTextField(
                  label: 'Reset token',
                  controller: _tokenController,
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Token is required'
                      : null,
                ),
                const SizedBox(height: 12),
                AppTextField(
                  label: 'New password',
                  controller: _passwordController,
                  obscureText: true,
                  validator: (v) => (v == null || v.length < 8)
                      ? 'Minimum 8 characters'
                      : null,
                ),
                const SizedBox(height: 12),
                AppTextField(
                  label: 'Confirm password',
                  controller: _confirmController,
                  obscureText: true,
                  validator: (v) => v != _passwordController.text
                      ? 'Passwords do not match'
                      : null,
                ),
                const SizedBox(height: 16),
                AppButton(
                  label: 'Set new password',
                  icon: Icons.password,
                  onPressed: authState.status == AuthStatus.loading
                      ? null
                      : _submit,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
