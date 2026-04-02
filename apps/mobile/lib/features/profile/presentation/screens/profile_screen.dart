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
import '../../../admin/domain/admin_models.dart';
import '../../../auth/domain/auth_models.dart';
import '../../../auth/presentation/utils/auth_input_formatters.dart';
import '../../../auth/presentation/utils/auth_form_validators.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({
    required this.userName,
    required this.email,
    required this.phone,
    required this.userRole,
    required this.onLogout,
    required this.isSuperAdmin,
    super.key,
  });

  final String userName;
  final String email;
  final String? phone;
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
    final result = await showDialog<_SupportSettingsDialogResult>(
      context: context,
      builder: (_) => _SupportSettingsDialog(settings: current),
    );

    if (!mounted || result != _SupportSettingsDialogResult.success) {
      return;
    }

    ref.invalidate(supportSettingsProvider);
    AppSnackbar.showSuccess(context, 'Support settings updated successfully.');
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

  Future<void> _showEditPhoneDialog() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _EditPhoneDialog(initialPhone: widget.phone),
    );

    if (!mounted || result == null) {
      return;
    }

    AppSnackbar.showSuccess(context, 'Phone number updated successfully.');
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
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(Icons.phone_outlined, size: 18),
                            const SizedBox(width: AppSpacing.xs),
                            Expanded(
                              child: Text(
                                AuthFormValidators.formatLebanesePhone(
                                      widget.phone,
                                    ).trim().isEmpty
                                    ? 'No phone number added'
                                    : AuthFormValidators.formatLebanesePhone(
                                        widget.phone,
                                      ),
                                softWrap: true,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Edit phone number',
                              onPressed: _isMutating
                                  ? null
                                  : _showEditPhoneDialog,
                              icon: const Icon(Icons.edit_outlined),
                            ),
                          ],
                        ),
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
                          value: AuthFormValidators.formatLebanesePhone(
                            settings.supportPhone,
                          ),
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

enum _SupportSettingsDialogResult { success }

class _EditPhoneDialog extends ConsumerStatefulWidget {
  const _EditPhoneDialog({required this.initialPhone});

  final String? initialPhone;

  @override
  ConsumerState<_EditPhoneDialog> createState() => _EditPhoneDialogState();
}

class _EditPhoneDialogState extends ConsumerState<_EditPhoneDialog> {
  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();
  final _phoneFormatter = LebanesePhoneFormatter();
  bool _isSubmitting = false;
  String? _dialogError;

  @override
  void initState() {
    super.initState();
    _phoneController.text = AuthFormValidators.formatLebanesePhone(
      widget.initialPhone,
    );
  }

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _dialogError = null;
    });

    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      await ref
          .read(authControllerProvider.notifier)
          .updateProfile(
            phone: AuthFormValidators.normalizeLebanesePhone(
              _phoneController.text,
            ),
          );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(_phoneController.text.trim());
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _dialogError = userFacingErrorMessage(
          error,
          fallback: 'Unable to update your phone number right now.',
        );
      });
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit phone number'),
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
                    softWrap: true,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
                AppTextField(
                  label: 'Phone number',
                  hint: '70 123 456',
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [_phoneFormatter],
                  validator: AuthFormValidators.phoneRequired,
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

class _SupportSettingsDialog extends ConsumerStatefulWidget {
  const _SupportSettingsDialog({required this.settings});

  final SupportContactSettings settings;

  @override
  ConsumerState<_SupportSettingsDialog> createState() =>
      _SupportSettingsDialogState();
}

class _SupportSettingsDialogState
    extends ConsumerState<_SupportSettingsDialog> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _hoursController = TextEditingController();
  final _helpController = TextEditingController();
  final _phoneFormatter = LebanesePhoneFormatter();

  bool _isSubmitting = false;
  String? _dialogError;

  @override
  void initState() {
    super.initState();
    _emailController.text = widget.settings.supportEmail ?? '';
    _phoneController.text = AuthFormValidators.formatLebanesePhone(
      widget.settings.supportPhone,
    );
    _hoursController.text = widget.settings.officeHours ?? '';
    _helpController.text = widget.settings.helpText ?? '';
  }

  @override
  void dispose() {
    _emailController.dispose();
    _phoneController.dispose();
    _hoursController.dispose();
    _helpController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _dialogError = null;
      _isSubmitting = true;
    });

    if (!(_formKey.currentState?.validate() ?? false)) {
      setState(() => _isSubmitting = false);
      return;
    }

    try {
      final normalizedEmail = AuthFormValidators.normalize(
        _emailController.text,
      );
      final normalizedPhone = AuthFormValidators.normalizeLebanesePhone(
        _phoneController.text,
      );
      final normalizedHours = AuthFormValidators.normalize(
        _hoursController.text,
      );
      final normalizedHelpText = AuthFormValidators.normalize(
        _helpController.text,
      );
      await ref
          .read(adminRepositoryProvider)
          .updateSupportSettings(
            supportEmail: normalizedEmail.isEmpty ? null : normalizedEmail,
            supportPhone: normalizedPhone.isEmpty ? null : normalizedPhone,
            officeHours: normalizedHours.isEmpty ? null : normalizedHours,
            helpText: normalizedHelpText.isEmpty ? null : normalizedHelpText,
          );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(_SupportSettingsDialogResult.success);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _dialogError = userFacingErrorMessage(
          error,
          fallback: 'Unable to update support settings right now.',
        );
      });
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit help & support'),
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
                    softWrap: true,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
                AppTextField(
                  label: 'Support email',
                  controller: _emailController,
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
                  hint: '70 123 456',
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [_phoneFormatter],
                  validator: AuthFormValidators.phoneOptional,
                ),
                const SizedBox(height: AppSpacing.sm),
                AppTextField(
                  label: 'Office hours',
                  controller: _hoursController,
                  minLines: 2,
                  maxLines: 3,
                ),
                const SizedBox(height: AppSpacing.sm),
                AppTextField(
                  label: 'Help text',
                  controller: _helpController,
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
