import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/config/app_branding.dart';
import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/web/input_autofill_patch.dart';
import '../../../../core/widgets/animated_reveal.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_logo.dart';
import '../../../../core/widgets/app_scaffold.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/loading_overlay.dart';
import '../controllers/auth_controller.dart';
import '../utils/auth_form_validators.dart';
import '../utils/auth_input_formatters.dart';
import '../widgets/auth_error_banner.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _noLeadingSpaceFormatter = NoLeadingSpaceFormatter();
  bool _obscurePassword = true;
  bool _rememberMe = true;
  String? _formLevelError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      patchAuthInputAttributes(
        formId: 'login',
        fieldKeys: const <String>['email', 'password'],
      );
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _formLevelError = null;
    });

    if (!_formKey.currentState!.validate()) {
      return;
    }

    FocusScope.of(context).unfocus();
    TextInput.finishAutofillContext();

    await ref
        .read(authControllerProvider.notifier)
        .login(
          email: AuthFormValidators.normalize(_emailController.text),
          password: _passwordController.text,
          rememberMe: _rememberMe,
        );

    if (!mounted) {
      return;
    }

    final authState = ref.read(authControllerProvider);
    if (authState.status == AuthStatus.unauthenticated &&
        authState.error != null &&
        authState.error!.trim().isNotEmpty) {
      setState(() {
        _formLevelError = authState.error;
      });
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      AppSnackbar.showError(context, authState.error!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);
    final isLoading = authState.status == AuthStatus.loading;

    return LoadingOverlay(
      isLoading: isLoading,
      child: AppScaffold(
        title: 'Sign in',
        showOfflineBanner: false,
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: AutofillGroup(
              child: Form(
                key: _formKey,
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(AppSpacing.md),
                  children: <Widget>[
                    AnimatedReveal(
                      child: Column(
                        children: <Widget>[
                          const Center(child: AppLogo(size: 84)),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            AppBranding.shortName,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            'Secure ministry access for field collection operations',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    AnimatedReveal(
                      delay: const Duration(milliseconds: 80),
                      child: AppCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            if (_formLevelError != null) ...<Widget>[
                              AuthErrorBanner(message: _formLevelError!),
                              const SizedBox(height: AppSpacing.sm),
                            ],
                            AppTextField(
                              label: 'Email address',
                              hint: 'name@gov.lb',
                              controller: _emailController,
                              keyboardType: TextInputType.emailAddress,
                              textInputAction: TextInputAction.next,
                              focusNode: _emailFocus,
                              onFieldSubmitted: (_) => FocusScope.of(
                                context,
                              ).requestFocus(_passwordFocus),
                              inputFormatters: <TextInputFormatter>[
                                _noLeadingSpaceFormatter,
                              ],
                              autofillHints: const <String>[
                                AutofillHints.username,
                                AutofillHints.email,
                              ],
                              onChanged: (_) {
                                if (_formLevelError == null) {
                                  return;
                                }
                                setState(() {
                                  _formLevelError = null;
                                });
                              },
                              validator: AuthFormValidators.email,
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            AppTextField(
                              label: 'Password',
                              hint: 'Enter your password',
                              controller: _passwordController,
                              obscureText: _obscurePassword,
                              textInputAction: TextInputAction.done,
                              focusNode: _passwordFocus,
                              onFieldSubmitted: (_) => _submit(),
                              enableSuggestions: false,
                              autocorrect: false,
                              autofillHints: const <String>[
                                AutofillHints.password,
                              ],
                              onChanged: (_) {
                                if (_formLevelError == null) {
                                  return;
                                }
                                setState(() {
                                  _formLevelError = null;
                                });
                              },
                              suffix: IconButton(
                                tooltip: _obscurePassword
                                    ? 'Show password'
                                    : 'Hide password',
                                onPressed: () => setState(
                                  () => _obscurePassword = !_obscurePassword,
                                ),
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility
                                      : Icons.visibility_off,
                                ),
                              ),
                              validator: AuthFormValidators.loginPassword,
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            CheckboxListTile(
                              value: _rememberMe,
                              onChanged: isLoading
                                  ? null
                                  : (value) => setState(
                                      () => _rememberMe = value ?? true,
                                    ),
                              title: const Text('Remember me'),
                              controlAffinity: ListTileControlAffinity.leading,
                              contentPadding: EdgeInsets.zero,
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            AppButton(
                              label: 'Login',
                              icon: Icons.login,
                              isLoading: isLoading,
                              onPressed: isLoading ? null : _submit,
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: isLoading
                                    ? null
                                    : () =>
                                          context.go(AppRoutes.forgotPassword),
                                child: const Text('Forgot password?'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: AppSpacing.xxs,
                      children: <Widget>[
                        const Text('No account yet?'),
                        TextButton(
                          onPressed: isLoading
                              ? null
                              : () => context.go(AppRoutes.signup),
                          child: const Text('Create account'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
