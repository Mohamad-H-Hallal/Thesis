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
import '../../../../core/widgets/app_scaffold.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/terraleb_logo.dart';
import '../utils/auth_form_validators.dart';
import '../widgets/auth_viewport.dart';
import '../widgets/auth_error_banner.dart';

enum _ResetPasswordStep { otp, password }

class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({this.email, super.key});

  final String? email;

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _otpFormKey = GlobalKey<FormState>();
  final _passwordFormKey = GlobalKey<FormState>();
  final _otpController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _otpFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _confirmFocus = FocusNode();

  _ResetPasswordStep _step = _ResetPasswordStep.otp;
  bool _isSubmitting = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  String? _otpFieldError;
  String? _stepError;
  String? _resetSessionToken;

  String get _email => widget.email?.trim() ?? '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      patchAuthInputAttributes(
        formId: 'reset_password',
        fieldKeys: const <String>[
          'reset_otp',
          'new_password',
          'confirm_password',
        ],
      );
    });
  }

  @override
  void dispose() {
    _otpController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _otpFocus.dispose();
    _passwordFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  void _goBack() {
    if (_step == _ResetPasswordStep.password) {
      setState(() {
        _step = _ResetPasswordStep.otp;
        _stepError = null;
      });
      return;
    }

    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }
    context.go(AppRoutes.forgotPassword);
  }

  Future<void> _verifyOtp() async {
    setState(() {
      _otpFieldError = null;
      _stepError = null;
    });

    if (!_otpFormKey.currentState!.validate()) {
      return;
    }

    setState(() => _isSubmitting = true);
    FocusScope.of(context).unfocus();
    TextInput.finishAutofillContext();

    try {
      final result = await ref
          .read(authControllerProvider.notifier)
          .verifyPasswordResetOtp(
            email: _email,
            otp: _otpController.text.trim(),
          );
      if (!mounted) {
        return;
      }
      setState(() {
        _resetSessionToken = result.resetToken;
        _step = _ResetPasswordStep.password;
      });
      AppSnackbar.showSuccess(context, result.message);
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = error.toString().trim().isEmpty
          ? 'Unable to verify the code right now.'
          : error.toString().trim();
      setState(() {
        _otpFieldError = message;
        _stepError = null;
      });
      _otpFormKey.currentState?.validate();
      AppSnackbar.showError(context, message);
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<void> _submitNewPassword() async {
    setState(() {
      _stepError = null;
    });

    if (!_passwordFormKey.currentState!.validate()) {
      return;
    }

    final resetSessionToken = _resetSessionToken;
    if (resetSessionToken == null || resetSessionToken.isEmpty) {
      setState(() {
        _stepError =
            'Your verification session expired. Please request a new verification code.';
        _step = _ResetPasswordStep.otp;
      });
      return;
    }

    setState(() => _isSubmitting = true);
    FocusScope.of(context).unfocus();
    TextInput.finishAutofillContext();

    try {
      await ref
          .read(authControllerProvider.notifier)
          .resetPassword(
            resetToken: resetSessionToken,
            newPassword: _passwordController.text,
          );
      if (!mounted) {
        return;
      }
      AppSnackbar.showSuccess(
        context,
        'Password has been changed successfully.',
      );
      final notice = Uri.encodeComponent(
        'Password has been changed successfully.',
      );
      context.go('${AppRoutes.login}?notice=$notice&success=true');
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = error.toString().trim().isEmpty
          ? 'Unable to change the password right now.'
          : error.toString().trim();
      setState(() {
        _stepError = message;
      });
      AppSnackbar.showError(context, message);
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Widget _buildOtpStep(BuildContext context) {
    return Form(
      key: _otpFormKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Enter the verification code sent to $_email.',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.md),
          if (_stepError != null) ...<Widget>[
            AuthErrorBanner(message: _stepError!),
            const SizedBox(height: AppSpacing.sm),
          ],
          AppTextField(
            label: 'Verification code',
            hint: 'Enter the 6-digit code',
            controller: _otpController,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            focusNode: _otpFocus,
            onFieldSubmitted: (_) => _verifyOtp(),
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            onChanged: (_) {
              if (_otpFieldError == null && _stepError == null) {
                return;
              }
              setState(() {
                _otpFieldError = null;
                _stepError = null;
              });
            },
            validator: (value) {
              final trimmed = value?.trim() ?? '';
              if (trimmed.isEmpty) {
                return 'Verification code is required.';
              }
              if (trimmed.length != 6) {
                return 'Enter the 6-digit verification code.';
              }
              return _otpFieldError;
            },
          ),
          const SizedBox(height: AppSpacing.md),
          AppButton(
            label: 'Verify code',
            icon: Icons.verified_outlined,
            isLoading: _isSubmitting,
            onPressed: _isSubmitting ? null : _verifyOtp,
          ),
        ],
      ),
    );
  }

  Widget _buildPasswordStep(BuildContext context) {
    return Form(
      key: _passwordFormKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Choose a new password for $_email.',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.md),
          if (_stepError != null) ...<Widget>[
            AuthErrorBanner(message: _stepError!),
            const SizedBox(height: AppSpacing.sm),
          ],
          AppTextField(
            label: 'New password',
            hint: 'At least 8 chars with upper/lower/number/symbol',
            controller: _passwordController,
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.next,
            focusNode: _passwordFocus,
            onFieldSubmitted: (_) =>
                FocusScope.of(context).requestFocus(_confirmFocus),
            enableSuggestions: false,
            autocorrect: false,
            autofillHints: const <String>[AutofillHints.newPassword],
            suffix: IconButton(
              tooltip: _obscurePassword ? 'Show password' : 'Hide password',
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
              icon: Icon(
                _obscurePassword ? Icons.visibility : Icons.visibility_off,
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
            onFieldSubmitted: (_) => _submitNewPassword(),
            enableSuggestions: false,
            autocorrect: false,
            autofillHints: const <String>[AutofillHints.newPassword],
            suffix: IconButton(
              tooltip: _obscureConfirmPassword
                  ? 'Show password'
                  : 'Hide password',
              onPressed: () => setState(
                () => _obscureConfirmPassword = !_obscureConfirmPassword,
              ),
              icon: Icon(
                _obscureConfirmPassword
                    ? Icons.visibility
                    : Icons.visibility_off,
              ),
            ),
            validator: (value) => AuthFormValidators.confirmPassword(
              value: value,
              password: _passwordController.text,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppButton(
            label: 'Change password',
            icon: Icons.password_outlined,
            isLoading: _isSubmitting,
            onPressed: _isSubmitting ? null : _submitNewPassword,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_email.isEmpty) {
      return AppScaffold(
        title: 'Reset password',
        showOfflineBanner: false,
        showBackButton: true,
        onBack: _goBack,
        body: AuthViewport(
          child: AppCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Text(
                  'Start the password reset process from the email verification step.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  label: 'Back to forgot password',
                  icon: Icons.arrow_back,
                  onPressed: _goBack,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return AppScaffold(
      title: 'Reset password',
      showOfflineBanner: false,
      showBackButton: true,
      onBack: _goBack,
      body: AuthViewport(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const TerraLebLogo(width: 200, height: 72),
            const SizedBox(height: AppSpacing.sm),
            Text(
              _step == _ResetPasswordStep.otp
                  ? 'Step 2 of 3: verify the code sent to your email.'
                  : 'Step 3 of 3: choose a new password.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            AppCard(
              child: _step == _ResetPasswordStep.otp
                  ? _buildOtpStep(context)
                  : _buildPasswordStep(context),
            ),
          ],
        ),
      ),
    );
  }
}
