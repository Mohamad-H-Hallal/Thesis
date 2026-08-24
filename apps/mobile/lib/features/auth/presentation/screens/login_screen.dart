import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/web/input_autofill_patch.dart';
import '../../../../core/widgets/animated_reveal.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_dialog_actions.dart';
import '../../../../core/widgets/app_scaffold.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/loading_overlay.dart';
import '../../../../core/widgets/terraleb_logo.dart';
import '../controllers/auth_controller.dart';
import '../utils/auth_form_validators.dart';
import '../utils/auth_input_formatters.dart';
import '../widgets/auth_viewport.dart';
import '../widgets/auth_error_banner.dart';
import '../widgets/auth_legal_links.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({
    this.noticeMessage,
    this.noticeIsSuccess = false,
    super.key,
  });

  final String? noticeMessage;
  final bool noticeIsSuccess;

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
  bool _reactivationDialogVisible = false;
  String? _formLevelError;
  late final ProviderSubscription<AuthState> _authSubscription;

  @override
  void initState() {
    super.initState();
    _authSubscription = ref.listenManual<AuthState>(authControllerProvider, (
      previous,
      next,
    ) {
      final nextError = next.error?.trim();
      if (!mounted ||
          next.status != AuthStatus.unauthenticated ||
          next.errorCode == 'contact_verification_required' ||
          nextError == null ||
          nextError.isEmpty ||
          nextError == previous?.error) {
        return;
      }

      setState(() {
        _formLevelError = nextError;
      });
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      AppSnackbar.showError(context, nextError);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      patchAuthInputAttributes(
        formId: 'login',
        fieldKeys: const <String>['email', 'password'],
      );
      final notice = widget.noticeMessage?.trim();
      if (!mounted || notice == null || notice.isEmpty) {
        return;
      }
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (widget.noticeIsSuccess) {
        AppSnackbar.showSuccess(context, notice);
      } else {
        AppSnackbar.showError(context, notice);
      }
    });
  }

  @override
  void dispose() {
    _authSubscription.close();
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
    if (authState.status == AuthStatus.authenticated) {
      TextInput.finishAutofillContext(shouldSave: true);
      return;
    }

    if (authState.errorCode == 'contact_verification_required') {
      TextInput.finishAutofillContext(shouldSave: false);
      _emailController.clear();
      _passwordController.clear();
      context.go(AppRoutes.contactVerification(fromLogin: true));
      return;
    }

    if (authState.errorCode == 'deactivated_contributor') {
      await _promptForReactivation();
      return;
    }

    TextInput.finishAutofillContext(shouldSave: false);

    final failureMessage = authState.error?.trim().isNotEmpty == true
        ? authState.error!.trim()
        : 'Login failed. Please try again.';
    if (_formLevelError != failureMessage) {
      setState(() {
        _formLevelError = failureMessage;
      });
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      AppSnackbar.showError(context, failureMessage);
    }
  }

  Future<void> _promptForReactivation() async {
    if (_reactivationDialogVisible) {
      return;
    }
    _reactivationDialogVisible = true;
    final activate = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Activate account'),
        content: const Text('Do you want to activate your account to login?'),
        actions: [
          AppDialogActions(
            cancel: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('No'),
            ),
            confirm: FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Yes'),
            ),
          ),
        ],
      ),
    );
    _reactivationDialogVisible = false;

    if (!mounted) {
      return;
    }

    if (activate != true) {
      AppSnackbar.showError(
        context,
        'Your contributor account remains inactive until you reactivate it.',
      );
      return;
    }

    await ref
        .read(authControllerProvider.notifier)
        .reactivateContributorAndLogin(
          email: AuthFormValidators.normalize(_emailController.text),
          password: _passwordController.text,
          rememberMe: _rememberMe,
        );

    if (!mounted) {
      return;
    }

    final authState = ref.read(authControllerProvider);
    if (authState.status == AuthStatus.authenticated) {
      TextInput.finishAutofillContext(shouldSave: true);
      AppSnackbar.showSuccess(
        context,
        'Account reactivated successfully. You are now logged in.',
      );
      return;
    }

    TextInput.finishAutofillContext(shouldSave: false);

    final failureMessage = authState.error?.trim().isNotEmpty == true
        ? authState.error!.trim()
        : 'Account reactivation failed.';
    setState(() {
      _formLevelError = failureMessage;
    });
    AppSnackbar.showError(context, failureMessage);
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
        body: AuthViewport(
          child: AutofillGroup(
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  AnimatedReveal(
                    child: Column(
                      children: <Widget>[
                        const Center(
                          child: TerraLebLogo(width: 240, height: 84),
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
                            hint: 'name@example.com',
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
                                        context.push(AppRoutes.forgotPassword),
                              child: const Text('Forgot password?'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  SizedBox(
                    width: double.infinity,
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: AppSpacing.xxs,
                      children: <Widget>[
                        const Text(
                          'No account yet?',
                          textAlign: TextAlign.center,
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 48),
                            padding: EdgeInsets.zero,
                          ),
                          onPressed: isLoading
                              ? null
                              : () => context.go(AppRoutes.signup),
                          child: const Text('Create account'),
                        ),
                      ],
                    ),
                  ),
                  AuthLegalFooter(
                    onOpenDocument: (slug) =>
                        context.push(AppRoutes.legalDocument(slug)),
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
