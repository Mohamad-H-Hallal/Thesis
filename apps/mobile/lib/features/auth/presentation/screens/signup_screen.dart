import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/animated_reveal.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_logo.dart';
import '../../../../core/widgets/app_scaffold.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/loading_overlay.dart';
import '../controllers/auth_controller.dart';

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _termsAccepted = false;

  @override
  void dispose() {
    _fullNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_termsAccepted) {
      AppSnackbar.showError(context, 'Please accept terms to continue.');
      return;
    }

    await ref
        .read(authControllerProvider.notifier)
        .signup(
          fullName: _fullNameController.text.trim(),
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );

    final authState = ref.read(authControllerProvider);
    if (authState.error == null && mounted) {
      AppSnackbar.showSuccess(context, 'Account created. Please login.');
      context.go(AppRoutes.login);
      return;
    }

    if (authState.error != null && mounted) {
      AppSnackbar.showError(context, authState.error!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);

    return LoadingOverlay(
      isLoading: authState.status == AuthStatus.loading,
      child: AppScaffold(
        title: 'Create account',
        showOfflineBanner: false,
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Form(
              key: _formKey,
              child: ListView(
                shrinkWrap: true,
                children: [
                  AnimatedReveal(
                    child: Column(
                      children: [
                        const Center(child: AppLogo(size: 72)),
                        const SizedBox(height: 12),
                        Text(
                          'Create contributor account',
                          style: Theme.of(context).textTheme.headlineSmall,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  AnimatedReveal(
                    delay: const Duration(milliseconds: 80),
                    child: AppCard(
                      child: Column(
                        children: [
                          AppTextField(
                            label: 'Full name',
                            controller: _fullNameController,
                            validator: (v) => (v == null || v.trim().length < 3)
                                ? 'Enter your full name'
                                : null,
                          ),
                          const SizedBox(height: 12),
                          AppTextField(
                            label: 'Email',
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            validator: (v) => (v == null || !v.contains('@'))
                                ? 'Enter a valid email'
                                : null,
                          ),
                          const SizedBox(height: 12),
                          AppTextField(
                            label: 'Password',
                            controller: _passwordController,
                            obscureText: true,
                            validator: (v) => (v == null || v.length < 8)
                                ? 'Password must be at least 8 characters'
                                : null,
                          ),
                          const SizedBox(height: 12),
                          AppTextField(
                            label: 'Confirm password',
                            controller: _confirmPasswordController,
                            obscureText: true,
                            validator: (v) {
                              if (v == null || v.isEmpty) {
                                return 'Please confirm password';
                              }
                              if (v != _passwordController.text) {
                                return 'Passwords do not match';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 8),
                          CheckboxListTile(
                            value: _termsAccepted,
                            onChanged: (v) =>
                                setState(() => _termsAccepted = v ?? false),
                            title: const Text(
                              'I accept terms and privacy policy',
                            ),
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding: EdgeInsets.zero,
                          ),
                          const SizedBox(height: 12),
                          AppButton(
                            label: 'Create account',
                            icon: Icons.person_add,
                            onPressed: _submit,
                          ),
                        ],
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => context.go(AppRoutes.login),
                    child: const Text('Back to login'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
