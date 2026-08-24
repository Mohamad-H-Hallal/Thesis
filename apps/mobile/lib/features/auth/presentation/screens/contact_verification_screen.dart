import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_dialog_actions.dart';
import '../../../../core/widgets/app_scaffold.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/terraleb_logo.dart';
import '../../domain/auth_failure.dart';
import '../../domain/contact_verification_models.dart';
import '../widgets/auth_viewport.dart';

class ContactVerificationScreen extends ConsumerStatefulWidget {
  const ContactVerificationScreen({this.startedFromLogin = false, super.key});

  final bool startedFromLogin;

  @override
  ConsumerState<ContactVerificationScreen> createState() =>
      _ContactVerificationScreenState();
}

class _ContactVerificationScreenState
    extends ConsumerState<ContactVerificationScreen> {
  final _codeController = TextEditingController();
  ContactVerificationState? _state;
  String? _error;
  bool _loading = true;
  int _resendSeconds = 0;
  Timer? _timer;
  bool _exitDialogVisible = false;

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    try {
      final state = await ref
          .read(contactVerificationRepositoryProvider)
          .status();
      if (!mounted) return;
      final requiresAutomaticFormatCheck =
          state.nextStep == ContactVerificationStep.phoneFormat;
      setState(() {
        _state = state;
        _loading = requiresAutomaticFormatCheck;
      });
      if (requiresAutomaticFormatCheck) {
        await _validateFormat();
      }
    } catch (error) {
      _showFailure(error);
    }
  }

  void _startCooldown(int seconds) {
    _timer?.cancel();
    setState(() => _resendSeconds = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _resendSeconds <= 1) {
        timer.cancel();
        if (mounted) setState(() => _resendSeconds = 0);
        return;
      }
      setState(() => _resendSeconds--);
    });
  }

  Future<void> _sendCode({bool automatic = false}) async {
    final state = _state;
    if (state == null ||
        state.nextStep == ContactVerificationStep.phoneFormat ||
        state.nextStep == ContactVerificationStep.complete ||
        (!automatic && _resendSeconds > 0)) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repository = ref.read(contactVerificationRepositoryProvider);
      final updated = state.nextStep == ContactVerificationStep.email
          ? await repository.sendEmail()
          : await repository.sendPhone();
      if (!mounted) return;
      setState(() {
        _state = updated;
        _loading = false;
      });
      _startCooldown(updated.resendAfterSeconds);
      if (!automatic) AppSnackbar.showSuccess(context, 'A new code was sent.');
    } catch (error) {
      _showFailure(error, quietRateLimit: automatic);
    }
  }

  Future<void> _confirm() async {
    if (_codeController.text.trim().length != 6) {
      setState(() => _error = 'Enter the 6-digit verification code.');
      return;
    }
    final state = _state;
    if (state == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repository = ref.read(contactVerificationRepositoryProvider);
      if (state.nextStep == ContactVerificationStep.email) {
        final result = await repository.confirmEmail(_codeController.text);
        _codeController.clear();
        if (!mounted) return;
        setState(() {
          _state = result.state;
          _loading = false;
        });
        AppSnackbar.showSuccess(context, result.message);
        if (result.state.nextStep == ContactVerificationStep.complete) {
          _returnToLogin(result.message);
          return;
        }
        if (result.state.nextStep == ContactVerificationStep.phone) {
          await _sendCode(automatic: true);
        }
        return;
      }
      final result = await repository.confirmPhone(_codeController.text);
      if (!mounted) return;
      _returnToLogin(result.message);
    } catch (error) {
      _showFailure(error);
    }
  }

  Future<void> _validateFormat({String? correctedPhone}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(contactVerificationRepositoryProvider)
          .validatePhone(correctedPhone: correctedPhone);
      if (!mounted) return;
      AppSnackbar.showSuccess(context, result.message);
      _returnToLogin(result.message);
    } catch (error) {
      _showFailure(error);
    }
  }

  void _showFailure(Object error, {bool quietRateLimit = false}) {
    if (!mounted) return;
    final message = error is AuthFailure
        ? error.message
        : 'Verification is unavailable. Check your connection and try again.';
    setState(() {
      _loading = false;
      if (!(quietRateLimit &&
          error is AuthFailure &&
          error.code == 'rate_limited')) {
        _error = message;
      }
    });
  }

  void _returnToLogin(String message) {
    final notice = Uri.encodeComponent(message);
    context.go('${AppRoutes.login}?notice=$notice&success=true');
  }

  Future<bool> _confirmExit({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    if (_exitDialogVisible) {
      return false;
    }
    _exitDialogVisible = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          AppDialogActions(
            cancel: TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Stay'),
            ),
            confirm: FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(confirmLabel),
            ),
          ),
        ],
      ),
    );
    _exitDialogVisible = false;
    return confirmed == true;
  }

  Future<void> _backToLogin() async {
    final confirmed = await _confirmExit(
      title: 'Leave verification?',
      message: 'Return to login? Your verification progress will be saved.',
      confirmLabel: 'Login',
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref
          .read(contactVerificationRepositoryProvider)
          .clearPendingSession();
      if (!mounted) return;
      _timer?.cancel();
      _codeController.clear();
      TextInput.finishAutofillContext(shouldSave: false);
      ref
          .read(authControllerProvider.notifier)
          .clearTransientAuthenticationAttempt();
      context.go(AppRoutes.login);
    } catch (error) {
      _showFailure(error);
    }
  }

  Future<void> _backToSignup() async {
    final confirmed = await _confirmExit(
      title: 'Return to signup?',
      message: 'This will remove the unfinished account and verification code.',
      confirmLabel: 'Remove',
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref
          .read(contactVerificationRepositoryProvider)
          .cancelPendingSignup();
      if (!mounted) return;
      ref
          .read(authControllerProvider.notifier)
          .clearTransientAuthenticationAttempt();
      context.go(AppRoutes.signup);
    } catch (error) {
      _showFailure(error);
    }
  }

  Future<void> _handleBack() async {
    if (_exitDialogVisible) {
      return;
    }
    final state = _state;
    final isInitialSignupStep =
        state?.nextStep == ContactVerificationStep.email ||
        state?.nextStep == ContactVerificationStep.phoneFormat;
    if (!widget.startedFromLogin && isInitialSignupStep) {
      await _backToSignup();
      return;
    }
    await _backToLogin();
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final emailStep = state?.nextStep == ContactVerificationStep.email;
    final formatStep = state?.nextStep == ContactVerificationStep.phoneFormat;
    final masked = emailStep ? state?.maskedEmail : state?.maskedPhone;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(_handleBack());
        }
      },
      child: AppScaffold(
        title: emailStep
            ? 'Email verification'
            : formatStep
            ? widget.startedFromLogin
                  ? 'Complete verification'
                  : 'Complete signup'
            : 'Verify your mobile number',
        showOfflineBanner: false,
        body: AuthViewport(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const TerraLebLogo(width: 200, height: 72),
              const SizedBox(height: AppSpacing.md),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      emailStep
                          ? 'Verify your email'
                          : formatStep
                          ? widget.startedFromLogin
                                ? 'Finishing verification'
                                : 'Finishing signup'
                          : 'Verify your mobile number',
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      formatStep
                          ? 'TerraLeb is checking the Lebanese mobile-number format automatically. No SMS is sent.'
                          : 'Enter the code sent to ${masked ?? 'your contact'}. If you need another code, use Resend code. Verification requires an internet connection.',
                      textAlign: TextAlign.center,
                    ),
                    if (!formatStep && state?.expiresAt != null) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        'This code expires in about ${((state!.expiresAt!.difference(DateTime.now()).inSeconds.clamp(0, 3600) + 59) ~/ 60)} minute(s).',
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ],
                    if (!formatStep) ...[
                      const SizedBox(height: AppSpacing.md),
                      AppTextField(
                        label: '6-digit code',
                        hint: '000000',
                        controller: _codeController,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.oneTimeCode],
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                        onFieldSubmitted: (_) => _loading ? null : _confirm(),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    if (!formatStep)
                      AppButton(
                        label: _loading ? 'Please wait…' : 'Verify code',
                        icon: Icons.verified_user_outlined,
                        isLoading: _loading,
                        onPressed: _loading ? null : _confirm,
                      )
                    else if (_loading)
                      const Center(child: CircularProgressIndicator()),
                    if (!formatStep) ...[
                      const SizedBox(height: AppSpacing.xs),
                      TextButton(
                        onPressed: _loading || _resendSeconds > 0
                            ? null
                            : _sendCode,
                        child: Text(
                          _resendSeconds > 0
                              ? 'Resend available in ${_resendSeconds}s'
                              : 'Resend code',
                        ),
                      ),
                    ],
                    TextButton(
                      onPressed: _exitDialogVisible ? null : _handleBack,
                      child: Text(
                        !widget.startedFromLogin && (emailStep || formatStep)
                            ? 'Back to signup'
                            : 'Back to login',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
