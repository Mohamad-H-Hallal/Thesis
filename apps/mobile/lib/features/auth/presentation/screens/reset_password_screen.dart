import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/web/input_autofill_patch.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_logo.dart';
import '../../../../core/widgets/app_scaffold.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../utils/auth_form_validators.dart';
import '../utils/auth_input_formatters.dart';
import '../widgets/auth_error_banner.dart';

class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({this.mode, this.token, super.key});

  final String? mode;
  final String? token;

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _tokenController;
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _tokenFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _confirmFocus = FocusNode();
  final _noLeadingSpaceFormatter = NoLeadingSpaceFormatter();

  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _isSubmitting = false;
  String? _formLevelError;

  @override
  void initState() {
    super.initState();
    _tokenController = TextEditingController(text: widget.token ?? '');

    if (widget.mode != 'sent') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        patchAuthInputAttributes(
          formId: 'reset_password',
          fieldKeys: const <String>[
            'reset_token',
            'new_password',
            'confirm_password',
          ],
        );
      });
    }
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _tokenFocus.dispose();
    _passwordFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _formLevelError = null;
    });

    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    FocusScope.of(context).unfocus();
    TextInput.finishAutofillContext();

    try {
      await ref
          .read(authControllerProvider.notifier)
          .resetPassword(
            token: AuthFormValidators.normalize(_tokenController.text),
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
      final message = error.toString();
      setState(() {
        _formLevelError = message;
      });
      AppSnackbar.showError(context, message);
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
    if (widget.mode == 'sent') {
      return AppScaffold(
        title: 'Check your email',
        showOfflineBanner: false,
        showBackButton: true,
        onBack: () => context.go(AppRoutes.login),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const AppLogo(size: 64),
                  const SizedBox(height: AppSpacing.sm),
                  const Icon(Icons.mark_email_read_outlined, size: 60),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'A password reset code is ready for your account.',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  const Text(
                    'If email delivery is not configured yet, use the development reset code shown below to continue.',
                    textAlign: TextAlign.center,
                  ),
                  if ((widget.token ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.md),
                    AppCard(
                      child: Column(
                        children: [
                          Text(
                            'Development reset code',
                            style: Theme.of(context).textTheme.titleMedium,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          SelectableText(
                            widget.token!,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  AppButton(
                    label: 'Continue to reset form',
                    icon: Icons.arrow_forward,
                    onPressed: () {
                      final tokenQuery = (widget.token ?? '').trim().isEmpty
                          ? ''
                          : '?token=${Uri.encodeComponent(widget.token!.trim())}';
                      context.go('${AppRoutes.resetPassword}$tokenQuery');
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return AppScaffold(
      title: 'Reset password',
      showOfflineBanner: false,
      showBackButton: true,
      onBack: () => context.go(AppRoutes.login),
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
                  const AppLogo(size: 64),
                  const SizedBox(height: AppSpacing.sm),
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        if (_formLevelError != null) ...<Widget>[
                          AuthErrorBanner(message: _formLevelError!),
                          const SizedBox(height: AppSpacing.sm),
                        ],
                        AppTextField(
                          label: 'Reset token',
                          hint: 'Paste the reset token from your email',
                          controller: _tokenController,
                          textInputAction: TextInputAction.next,
                          focusNode: _tokenFocus,
                          onFieldSubmitted: (_) => FocusScope.of(
                            context,
                          ).requestFocus(_passwordFocus),
                          inputFormatters: <TextInputFormatter>[
                            _noLeadingSpaceFormatter,
                          ],
                          validator: (value) =>
                              AuthFormValidators.requiredField(
                                value,
                                fieldLabel: 'Reset token',
                              ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        AppTextField(
                          label: 'New password',
                          hint:
                              'At least 8 chars with upper/lower/number/symbol',
                          controller: _passwordController,
                          obscureText: _obscurePassword,
                          textInputAction: TextInputAction.next,
                          focusNode: _passwordFocus,
                          onFieldSubmitted: (_) => FocusScope.of(
                            context,
                          ).requestFocus(_confirmFocus),
                          enableSuggestions: false,
                          autocorrect: false,
                          autofillHints: const <String>[
                            AutofillHints.newPassword,
                          ],
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
                          validator: AuthFormValidators.password,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        AppTextField(
                          label: 'Confirm password',
                          hint: 'Re-enter the new password',
                          controller: _confirmController,
                          obscureText: _obscureConfirmPassword,
                          textInputAction: TextInputAction.done,
                          focusNode: _confirmFocus,
                          onFieldSubmitted: (_) => _submit(),
                          enableSuggestions: false,
                          autocorrect: false,
                          autofillHints: const <String>[
                            AutofillHints.newPassword,
                          ],
                          suffix: IconButton(
                            tooltip: _obscureConfirmPassword
                                ? 'Show password'
                                : 'Hide password',
                            onPressed: () => setState(
                              () => _obscureConfirmPassword =
                                  !_obscureConfirmPassword,
                            ),
                            icon: Icon(
                              _obscureConfirmPassword
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                            ),
                          ),
                          validator: (value) =>
                              AuthFormValidators.confirmPassword(
                                value: value,
                                password: _passwordController.text,
                              ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        AppButton(
                          label: 'Set new password',
                          icon: Icons.password,
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
      ),
    );
  }
}
