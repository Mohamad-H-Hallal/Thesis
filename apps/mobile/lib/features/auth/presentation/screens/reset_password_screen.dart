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
  const ResetPasswordScreen({this.email, super.key});

  final String? email;

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _emailController;
  final _otpController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _emailFocus = FocusNode();
  final _otpFocus = FocusNode();
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
    _emailController = TextEditingController(text: widget.email?.trim() ?? '');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      patchAuthInputAttributes(
        formId: 'reset_password',
        fieldKeys: const <String>[
          'email',
          'reset_otp',
          'new_password',
          'confirm_password',
        ],
      );
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _otpController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _emailFocus.dispose();
    _otpFocus.dispose();
    _passwordFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  void _goBack() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }
    context.go(AppRoutes.forgotPassword);
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
      await ref.read(authControllerProvider.notifier).resetPassword(
            email: AuthFormValidators.normalize(_emailController.text),
            otp: AuthFormValidators.normalize(_otpController.text),
            newPassword: _passwordController.text,
          );
      if (!mounted) {
        return;
      }
      AppSnackbar.showSuccess(
        context,
        'Password has been reset successfully.',
      );
      final notice = Uri.encodeComponent(
        'Password has been reset successfully. Please sign in.',
      );
      context.go('${AppRoutes.login}?notice=$notice&success=true');
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = error.toString().trim().isEmpty
          ? 'Unable to reset password right now.'
          : error.toString().trim();
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
    return AppScaffold(
      title: 'Reset password',
      showOfflineBanner: false,
      showBackButton: true,
      onBack: _goBack,
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
                  Text(
                    'Enter the one-time code sent to your email address, then choose a new password.',
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  AppCard(
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
                          onFieldSubmitted: (_) =>
                              FocusScope.of(context).requestFocus(_otpFocus),
                          inputFormatters: <TextInputFormatter>[
                            _noLeadingSpaceFormatter,
                          ],
                          autofillHints: const <String>[
                            AutofillHints.username,
                            AutofillHints.email,
                          ],
                          validator: AuthFormValidators.email,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        AppTextField(
                          label: 'One-time code',
                          hint: 'Enter the 6-digit code',
                          controller: _otpController,
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.next,
                          focusNode: _otpFocus,
                          onFieldSubmitted: (_) => FocusScope.of(
                            context,
                          ).requestFocus(_passwordFocus),
                          inputFormatters: <TextInputFormatter>[
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(6),
                          ],
                          validator: (value) {
                            final trimmed = value?.trim() ?? '';
                            if (trimmed.isEmpty) {
                              return 'Reset code is required.';
                            }
                            if (trimmed.length != 6) {
                              return 'Enter the 6-digit reset code.';
                            }
                            return null;
                          },
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
                          label: 'Confirm new password',
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
                          label: 'Reset password',
                          icon: Icons.password_outlined,
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
