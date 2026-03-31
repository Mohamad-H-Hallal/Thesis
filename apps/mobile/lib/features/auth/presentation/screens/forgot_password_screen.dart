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

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _emailFocus = FocusNode();
  final _noLeadingSpaceFormatter = NoLeadingSpaceFormatter();
  bool _isSubmitting = false;
  String? _formLevelError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      patchAuthInputAttributes(
        formId: 'forgot_password',
        fieldKeys: const <String>['email'],
      );
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _emailFocus.dispose();
    super.dispose();
  }

  void _goBackToLogin() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }
    context.go(AppRoutes.login);
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

    final normalizedEmail = AuthFormValidators.normalize(_emailController.text);

    try {
      final result = await ref
          .read(authControllerProvider.notifier)
          .requestPasswordReset(normalizedEmail);
      if (!mounted) {
        return;
      }

      AppSnackbar.showSuccess(context, result.message);
      final email = result.email?.trim().isNotEmpty == true
          ? result.email!.trim()
          : normalizedEmail;
      context.push(
        Uri(
          path: AppRoutes.resetPassword,
          queryParameters: <String, String>{'email': email},
        ).toString(),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = error.toString().trim().isEmpty
          ? 'Unable to send a reset code right now.'
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
      title: 'Forgot password',
      showOfflineBanner: false,
      showBackButton: true,
      onBack: _goBackToLogin,
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
                    'Enter your registered email address to receive a one-time password reset code.',
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
                          textInputAction: TextInputAction.done,
                          focusNode: _emailFocus,
                          onFieldSubmitted: (_) => _submit(),
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
                        const SizedBox(height: AppSpacing.md),
                        AppButton(
                          label: 'Send reset code',
                          icon: Icons.email_outlined,
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
