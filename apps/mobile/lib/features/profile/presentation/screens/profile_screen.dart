import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../auth/domain/auth_models.dart';
import '../../../auth/presentation/utils/auth_form_validators.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({
    required this.userName,
    required this.email,
    required this.userRole,
    required this.onLogout,
    required this.isSuperAdmin,
    super.key,
  });

  final String userName;
  final String email;
  final UserRole userRole;
  final bool isSuperAdmin;
  final VoidCallback onLogout;

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _isMutating = false;
  String? _accountAccessError;

  Future<void> _editSupportSettings() async {
    final current = await ref.read(supportSettingsProvider.future);
    if (!mounted) {
      return;
    }

    final emailController = TextEditingController(
      text: current.supportEmail ?? '',
    );
    final phoneController = TextEditingController(
      text: current.supportPhone ?? '',
    );
    final hoursController = TextEditingController(
      text: current.officeHours ?? '',
    );
    final helpController = TextEditingController(text: current.helpText ?? '');
    final formKey = GlobalKey<FormState>();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit help & support'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppTextField(
                    label: 'Support email',
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    validator: (value) {
                      final trimmed = value?.trim() ?? '';
                      if (trimmed.isEmpty) {
                        return null;
                      }
                      return AuthFormValidators.email(trimmed);
                    },
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppTextField(
                    label: 'Support phone',
                    controller: phoneController,
                    keyboardType: TextInputType.phone,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppTextField(
                    label: 'Office hours',
                    controller: hoursController,
                    minLines: 2,
                    maxLines: 3,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppTextField(
                    label: 'Help text',
                    controller: helpController,
                    minLines: 3,
                    maxLines: 6,
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (!(formKey.currentState?.validate() ?? false)) {
                return;
              }
              Navigator.of(context).pop(true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      emailController.dispose();
      phoneController.dispose();
      hoursController.dispose();
      helpController.dispose();
      return;
    }

    setState(() => _isMutating = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .updateSupportSettings(
            supportEmail: AuthFormValidators.normalize(emailController.text),
            supportPhone: AuthFormValidators.normalize(phoneController.text),
            officeHours: AuthFormValidators.normalize(hoursController.text),
            helpText: AuthFormValidators.normalize(helpController.text),
          );
      ref.invalidate(supportSettingsProvider);
      if (mounted) {
        AppSnackbar.showSuccess(
          context,
          'Support settings updated successfully.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to update support settings right now.',
          ),
        );
      }
    } finally {
      emailController.dispose();
      phoneController.dispose();
      hoursController.dispose();
      helpController.dispose();
      if (mounted) {
        setState(() => _isMutating = false);
      }
    }
  }

  Future<void> _selfDeactivate() async {
    setState(() {
      _accountAccessError = null;
    });
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Deactivate account'),
        content: const Text(
          'Deactivate your account? You will be signed out immediately and will not be able to log in again until an administrator reactivates access.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Deactivate'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    setState(() => _isMutating = true);
    try {
      await ref.read(authControllerProvider.notifier).selfDeactivate();
      if (!mounted) {
        return;
      }
      final notice = Uri.encodeComponent(
        'Your account was deactivated successfully.',
      );
      context.go('${AppRoutes.login}?notice=$notice&success=true');
    } catch (error) {
      if (mounted) {
        final message = userFacingErrorMessage(
          error,
          fallback: 'Unable to deactivate your account right now.',
        );
        setState(() {
          _accountAccessError = message;
        });
        AppSnackbar.showError(context, message);
      }
    } finally {
      if (mounted) {
        setState(() => _isMutating = false);
      }
    }
  }

  Future<void> _showChangePasswordDialog() async {
    final result = await showDialog<_ChangePasswordDialogResult>(
      context: context,
      builder: (_) => const _ChangePasswordDialog(),
    );

    if (!mounted || result != _ChangePasswordDialogResult.success) {
      return;
    }

    AppSnackbar.showSuccess(context, 'Password changed successfully.');
  }

  @override
  Widget build(BuildContext context) {
    final supportAsync = ref.watch(supportSettingsProvider);

    return ListView(
      children: [
        const SectionHeader(
          title: 'Profile',
          subtitle: 'Identity, support, and account access controls',
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 28,
                    child: Text(
                      widget.userName.isNotEmpty
                          ? widget.userName[0].toUpperCase()
                          : 'U',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.userName,
                          style: Theme.of(context).textTheme.titleLarge,
                          softWrap: true,
                        ),
                        const SizedBox(height: 4),
                        Text(widget.email, softWrap: true),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  Chip(label: Text(widget.userRole.label)),
                  const Chip(label: Text('Session active')),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        supportAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Help & Support',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.sm),
                const Text(
                  'Support contact details are currently unavailable. Please try again later.',
                  softWrap: true,
                ),
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton.icon(
                  onPressed: () => ref.invalidate(supportSettingsProvider),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
          data: (settings) => AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final editButton = OutlinedButton.icon(
                      onPressed: _isMutating ? null : _editSupportSettings,
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit'),
                    );

                    if (constraints.maxWidth < 420) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Help & Support',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (widget.isSuperAdmin) ...[
                            const SizedBox(height: AppSpacing.sm),
                            editButton,
                          ],
                        ],
                      );
                    }

                    return Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Help & Support',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (widget.isSuperAdmin) editButton,
                      ],
                    );
                  },
                ),
                const SizedBox(height: AppSpacing.sm),
                if (!settings.isConfigured)
                  const Text(
                    'Support contact details are currently unavailable. Please try again later.',
                  )
                else
                  Wrap(
                    spacing: AppSpacing.md,
                    runSpacing: AppSpacing.md,
                    children: [
                      if ((settings.supportEmail ?? '').trim().isNotEmpty)
                        _SupportItem(
                          icon: Icons.email_outlined,
                          label: 'Support email',
                          value: settings.supportEmail!,
                        ),
                      if ((settings.supportPhone ?? '').trim().isNotEmpty)
                        _SupportItem(
                          icon: Icons.phone_outlined,
                          label: 'Support phone',
                          value: settings.supportPhone!,
                        ),
                      if ((settings.officeHours ?? '').trim().isNotEmpty)
                        _SupportItem(
                          icon: Icons.schedule_outlined,
                          label: 'Office hours',
                          value: settings.officeHours!,
                        ),
                      if ((settings.helpText ?? '').trim().isNotEmpty)
                        _SupportItem(
                          icon: Icons.info_outline,
                          label: 'Help',
                          value: settings.helpText!,
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Security', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: _isMutating ? null : _showChangePasswordDialog,
                icon: const Icon(Icons.password_outlined),
                label: const Text('Change password'),
              ),
            ],
          ),
        ),
        if (widget.userRole == UserRole.contributor) ...[
          const SizedBox(height: AppSpacing.md),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Account access',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.sm),
                const Text(
                  'You can deactivate your contributor account only when no active project assignments are still blocking that action.',
                ),
                if (_accountAccessError != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    _accountAccessError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                    softWrap: true,
                  ),
                ],
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton.icon(
                  onPressed: _isMutating ? null : _selfDeactivate,
                  icon: const Icon(Icons.person_off_outlined),
                  label: const Text('Deactivate my account'),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        FilledButton.icon(
          onPressed: widget.onLogout,
          icon: const Icon(Icons.logout),
          label: const Text('Logout'),
        ),
      ],
    );
  }
}

enum _ChangePasswordDialogResult { success }

class _ChangePasswordDialog extends ConsumerStatefulWidget {
  const _ChangePasswordDialog();

  @override
  ConsumerState<_ChangePasswordDialog> createState() =>
      _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends ConsumerState<_ChangePasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _isSubmitting = false;
  String? _dialogError;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _dialogError = null;
    });

    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      await ref
          .read(authControllerProvider.notifier)
          .changePassword(
            currentPassword: _currentController.text,
            newPassword: _newController.text,
          );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(_ChangePasswordDialogResult.success);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _dialogError = userFacingErrorMessage(
          error,
          fallback: 'Unable to change password right now.',
        );
      });
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
    return AlertDialog(
      title: const Text('Change password'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_dialogError != null) ...[
                  Text(
                    _dialogError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
                AppTextField(
                  label: 'Current password',
                  controller: _currentController,
                  obscureText: _obscureCurrent,
                  enableSuggestions: false,
                  autocorrect: false,
                  suffix: IconButton(
                    tooltip: _obscureCurrent
                        ? 'Show password'
                        : 'Hide password',
                    onPressed: () =>
                        setState(() => _obscureCurrent = !_obscureCurrent),
                    icon: Icon(
                      _obscureCurrent ? Icons.visibility : Icons.visibility_off,
                    ),
                  ),
                  validator: (value) => AuthFormValidators.requiredField(
                    value,
                    fieldLabel: 'Current password',
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                AppTextField(
                  label: 'New password',
                  controller: _newController,
                  obscureText: _obscureNew,
                  enableSuggestions: false,
                  autocorrect: false,
                  suffix: IconButton(
                    tooltip: _obscureNew ? 'Show password' : 'Hide password',
                    onPressed: () => setState(() => _obscureNew = !_obscureNew),
                    icon: Icon(
                      _obscureNew ? Icons.visibility : Icons.visibility_off,
                    ),
                  ),
                  validator: AuthFormValidators.password,
                ),
                const SizedBox(height: AppSpacing.sm),
                AppTextField(
                  label: 'Confirm new password',
                  controller: _confirmController,
                  obscureText: _obscureConfirm,
                  enableSuggestions: false,
                  autocorrect: false,
                  suffix: IconButton(
                    tooltip: _obscureConfirm
                        ? 'Show password'
                        : 'Hide password',
                    onPressed: () =>
                        setState(() => _obscureConfirm = !_obscureConfirm),
                    icon: Icon(
                      _obscureConfirm ? Icons.visibility : Icons.visibility_off,
                    ),
                  ),
                  validator: (value) => AuthFormValidators.confirmPassword(
                    value: value,
                    password: _newController.text,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSubmitting ? null : _submit,
          child: Text(_isSubmitting ? 'Saving...' : 'Save'),
        ),
      ],
    );
  }
}

class _SupportItem extends StatelessWidget {
  const _SupportItem({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 420),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodySmall),
                Text(value, softWrap: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
