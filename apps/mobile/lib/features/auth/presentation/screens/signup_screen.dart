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
import '../../../../core/widgets/app_logo.dart';
import '../../../../core/widgets/app_scaffold.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/loading_overlay.dart';
import '../../domain/auth_models.dart';
import '../controllers/auth_controller.dart';
import '../utils/auth_form_validators.dart';
import '../utils/auth_input_formatters.dart';
import '../widgets/auth_error_banner.dart';

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _fullNameFocus = FocusNode();
  final _phoneFocus = FocusNode();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _confirmFocus = FocusNode();
  final _noLeadingSpaceFormatter = NoLeadingSpaceFormatter();
  final _phoneFormatter = LebanesePhoneFormatter();

  UserRole _selectedRole = UserRole.contributor;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  String? _formLevelError;
  String? _emailFieldError;
  String? _phoneFieldError;
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
          nextError == null ||
          nextError.isEmpty ||
          nextError == previous?.error) {
        return;
      }

      setState(() {
        _formLevelError = nextError;
        _emailFieldError = nextError == 'This email is already registered.'
            ? nextError
            : null;
        _phoneFieldError = nextError == 'Enter a valid phone number.'
            ? nextError
            : null;
      });
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      AppSnackbar.showError(context, nextError);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      patchAuthInputAttributes(
        formId: 'signup',
        fieldKeys: const <String>[
          'full_name',
          'phone',
          'email',
          'new_password',
          'confirm_password',
        ],
      );
    });
  }

  @override
  void dispose() {
    _authSubscription.close();
    _fullNameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _fullNameFocus.dispose();
    _phoneFocus.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _formLevelError = null;
      _emailFieldError = null;
      _phoneFieldError = null;
    });

    if (!_formKey.currentState!.validate()) {
      return;
    }

    FocusScope.of(context).unfocus();
    TextInput.finishAutofillContext();

    final successMessage = await ref
        .read(authControllerProvider.notifier)
        .signup(
          fullName: AuthFormValidators.normalize(_fullNameController.text),
          email: AuthFormValidators.normalize(_emailController.text),
          password: _passwordController.text,
          role: _selectedRole,
          phone: AuthFormValidators.normalizeLebanesePhone(
            _phoneController.text,
          ),
        );

    if (!mounted) {
      return;
    }

    final authState = ref.read(authControllerProvider);
    if (successMessage != null &&
        (authState.error == null || authState.error!.trim().isEmpty)) {
      final notice = Uri.encodeComponent(
        successMessage == 'Account created successfully. You can log in now.'
            ? 'Account has been created successfully.'
            : successMessage,
      );
      context.go('${AppRoutes.login}?notice=$notice&success=true');
      return;
    }

    final failureMessage = authState.error?.trim().isNotEmpty == true
        ? authState.error!
        : 'Signup failed. Please review the form and try again.';
    setState(() {
      _formLevelError = failureMessage;
      _emailFieldError = failureMessage == 'This email is already registered.'
          ? failureMessage
          : null;
      _phoneFieldError = failureMessage == 'Enter a valid phone number.'
          ? failureMessage
          : null;
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
        title: 'Create account',
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
                          const Center(child: AppLogo(size: 72)),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            'Create your account',
                            style: Theme.of(context).textTheme.headlineSmall,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            'Choose viewer access for immediate login or request contributor access for field collection.',
                            style: Theme.of(context).textTheme.bodyMedium,
                            textAlign: TextAlign.center,
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
                            Text(
                              'Requested role',
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            SegmentedButton<UserRole>(
                              segments: const <ButtonSegment<UserRole>>[
                                ButtonSegment<UserRole>(
                                  value: UserRole.contributor,
                                  label: Text('Contributor'),
                                  icon: Icon(Icons.edit_location_alt_outlined),
                                ),
                                ButtonSegment<UserRole>(
                                  value: UserRole.viewer,
                                  label: Text('Viewer'),
                                  icon: Icon(Icons.visibility_outlined),
                                ),
                              ],
                              selected: <UserRole>{_selectedRole},
                              onSelectionChanged: isLoading
                                  ? null
                                  : (selection) {
                                      if (selection.isEmpty) {
                                        return;
                                      }
                                      setState(
                                        () => _selectedRole = selection.first,
                                      );
                                    },
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              _selectedRole == UserRole.contributor
                                  ? 'Contributor accounts require admin approval before first login.'
                                  : 'User accounts are active immediately with read-only access.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            AppTextField(
                              label: 'Full name',
                              hint: 'First and last name',
                              controller: _fullNameController,
                              textCapitalization: TextCapitalization.words,
                              textInputAction: TextInputAction.next,
                              focusNode: _fullNameFocus,
                              onFieldSubmitted: (_) => FocusScope.of(
                                context,
                              ).requestFocus(_phoneFocus),
                              inputFormatters: <TextInputFormatter>[
                                _noLeadingSpaceFormatter,
                              ],
                              autofillHints: const <String>[AutofillHints.name],
                              validator: (value) =>
                                  AuthFormValidators.requiredField(
                                    value,
                                    fieldLabel: 'Full name',
                                    minLength: 3,
                                  ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            AppTextField(
                              label: 'Phone number',
                              hint: '70 123 456',
                              controller: _phoneController,
                              keyboardType: TextInputType.phone,
                              textInputAction: TextInputAction.next,
                              focusNode: _phoneFocus,
                              onFieldSubmitted: (_) => FocusScope.of(
                                context,
                              ).requestFocus(_emailFocus),
                              inputFormatters: <TextInputFormatter>[
                                _phoneFormatter,
                              ],
                              autofillHints: const <String>[
                                AutofillHints.telephoneNumber,
                              ],
                              onChanged: (_) {
                                if (_formLevelError == null &&
                                    _phoneFieldError == null) {
                                  return;
                                }
                                setState(() {
                                  _formLevelError = null;
                                  _phoneFieldError = null;
                                });
                              },
                              validator: (value) =>
                                  _phoneFieldError ??
                                  AuthFormValidators.phoneRequired(value),
                            ),
                            const SizedBox(height: AppSpacing.sm),
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
                                if (_formLevelError == null &&
                                    _emailFieldError == null) {
                                  return;
                                }
                                setState(() {
                                  _formLevelError = null;
                                  _emailFieldError = null;
                                });
                              },
                              validator: (value) =>
                                  _emailFieldError ??
                                  AuthFormValidators.email(value),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            AppTextField(
                              label: 'Password',
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
                              hint: 'Re-enter your password',
                              controller: _confirmPasswordController,
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
                            const SizedBox(height: AppSpacing.sm),
                            AppButton(
                              label: _selectedRole == UserRole.contributor
                                  ? 'Request contributor access'
                                  : 'Create viewer account',
                              icon: Icons.person_add,
                              isLoading: isLoading,
                              onPressed: isLoading ? null : _submit,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    TextButton(
                      onPressed: isLoading
                          ? null
                          : () => context.go(AppRoutes.login),
                      child: const Text('Back to login'),
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
