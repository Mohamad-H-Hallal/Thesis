import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
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

  Future<void> _editSupportSettings() async {
    final current = await ref.read(supportSettingsProvider.future);
    if (!mounted) {
      return;
    }

    final emailController = TextEditingController(text: current.supportEmail ?? '');
    final phoneController = TextEditingController(text: current.supportPhone ?? '');
    final hoursController = TextEditingController(text: current.officeHours ?? '');
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
      await ref.read(adminRepositoryProvider).updateSupportSettings(
            supportEmail: AuthFormValidators.normalize(emailController.text),
            supportPhone: AuthFormValidators.normalize(phoneController.text),
            officeHours: AuthFormValidators.normalize(hoursController.text),
            helpText: AuthFormValidators.normalize(helpController.text),
          );
      ref.invalidate(supportSettingsProvider);
      if (mounted) {
        AppSnackbar.showSuccess(context, 'Support settings updated successfully.');
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(context, error.toString());
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
      AppSnackbar.showSuccess(context, 'Your account was deactivated successfully.');
      context.go(AppRoutes.login);
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(context, error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _isMutating = false);
      }
    }
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
                      widget.userName.isNotEmpty ? widget.userName[0].toUpperCase() : 'U',
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
                  Chip(
                    label: Text(
                      widget.isSuperAdmin ? 'Super Admin' : widget.userRole.label,
                    ),
                  ),
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
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.support_agent_outlined),
              title: const Text('Help & Support'),
              subtitle: Text('Support settings are unavailable right now: $error'),
            ),
          ),
          data: (settings) => AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Help & Support',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (widget.isSuperAdmin)
                      OutlinedButton.icon(
                        onPressed: _isMutating ? null : _editSupportSettings,
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Edit'),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                if (!settings.isConfigured)
                  const Text(
                    'Support contact details are not configured yet. The protected super admin can add them here.',
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
        if (widget.userRole != UserRole.admin) ...[
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
                  'You can deactivate your own account if there are no active project assignments blocking that action.',
                ),
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
