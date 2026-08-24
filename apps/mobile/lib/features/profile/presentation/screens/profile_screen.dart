import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_action_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_dialog_actions.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../admin/domain/admin_models.dart';
import '../../../auth/domain/auth_models.dart';
import '../../../auth/presentation/utils/auth_input_formatters.dart';
import '../../../auth/presentation/utils/auth_form_validators.dart';
import '../../../auth/presentation/widgets/lebanese_mobile_field.dart';
import '../../../legal/domain/legal_models.dart';
import '../../../legal/presentation/legal_providers.dart';

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
  bool _pushAvailable = false;
  bool _notificationsEnabled = false;
  bool _showSensitiveNotificationPreview = false;
  bool _notificationPreferenceBusy = false;
  String? _accountAccessError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final service = ref.read(pushNotificationServiceProvider);
      await service.initialize();
      final notificationsEnabled = await service
          .notificationsEnabledForCurrentDevice();
      if (!mounted) return;
      setState(() {
        _pushAvailable = service.isAvailable;
        _notificationsEnabled = notificationsEnabled;
        _showSensitiveNotificationPreview = service.showSensitivePreview;
      });
    });
  }

  Future<void> _requestNotificationPermission() async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Enable notifications?'),
        content: const Text(
          'Get updates about assignments, reviews, imports, and exports.',
        ),
        actions: [
          AppDialogActions(
            cancel: TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Not now'),
            ),
            confirm: FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Enable'),
            ),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    setState(() => _notificationPreferenceBusy = true);
    try {
      final granted = await ref
          .read(pushNotificationServiceProvider)
          .requestPermissionAndSync();
      if (mounted) {
        if (granted) {
          setState(() => _notificationsEnabled = true);
          AppSnackbar.showSuccess(context, 'Notifications enabled.');
        } else {
          setState(() => _notificationsEnabled = false);
          AppSnackbar.showError(
            context,
            'Notification permission was not granted. You can change it in system settings.',
          );
        }
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to enable notifications.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _notificationPreferenceBusy = false);
    }
  }

  Future<void> _disableNotifications() async {
    setState(() => _notificationPreferenceBusy = true);
    try {
      await ref.read(pushNotificationServiceProvider).unregisterCurrentDevice();
      if (!mounted) return;
      setState(() => _notificationsEnabled = false);
      AppSnackbar.showSuccess(context, 'Notifications disabled.');
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to disable notifications.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _notificationPreferenceBusy = false);
    }
  }

  Future<void> _setSensitiveNotificationPreview(bool enabled) async {
    setState(() {
      _notificationPreferenceBusy = true;
      _showSensitiveNotificationPreview = enabled;
    });
    try {
      await ref
          .read(pushNotificationServiceProvider)
          .setShowSensitivePreview(enabled);
    } catch (error) {
      if (mounted) {
        setState(() => _showSensitiveNotificationPreview = !enabled);
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to save the notification preview setting.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _notificationPreferenceBusy = false);
    }
  }

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

  Future<void> _cancelDeletionRequest(PrivacyRequestRecord request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel account deletion request?'),
        content: const Text(
          'Your account will remain active. Only this deletion request will be cancelled.',
        ),
        actions: [
          AppDialogActions(
            cancel: TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const AppDialogActionLabel('Keep'),
            ),
            confirm: FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const AppDialogActionLabel('Cancel'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _accountAccessError = null;
      _isMutating = true;
    });
    try {
      await ref.read(legalRepositoryProvider).cancelPrivacyRequest(request.id);
      ref.invalidate(privacyRequestsProvider);
      if (mounted) {
        AppSnackbar.showSuccess(context, 'Deletion request cancelled.');
      }
    } catch (error) {
      if (mounted) {
        final message = userFacingErrorMessage(
          error,
          fallback: 'Unable to cancel the deletion request.',
        );
        setState(() => _accountAccessError = message);
        AppSnackbar.showError(context, message);
      }
    } finally {
      if (mounted) setState(() => _isMutating = false);
    }
  }

  Future<void> _requestAccountDeletion() async {
    setState(() {
      _accountAccessError = null;
      _isMutating = true;
    });

    AccountDeletionEligibility eligibility;
    try {
      eligibility = await ref
          .read(legalRepositoryProvider)
          .fetchAccountDeletionEligibility();
    } catch (error) {
      if (!mounted) return;
      final message = userFacingErrorMessage(
        error,
        fallback: 'Unable to check account-deletion requirements.',
      );
      setState(() => _accountAccessError = message);
      AppSnackbar.showError(context, message);
      return;
    } finally {
      if (mounted) setState(() => _isMutating = false);
    }

    if (!mounted) return;
    if (!eligibility.canRequest) {
      final message = eligibility.protectedAccount
          ? 'The protected super administrator account cannot be deleted.'
          : 'Account deletion cannot be requested for this account.';
      setState(() => _accountAccessError = message);
      AppSnackbar.showError(context, message);
      return;
    }

    final result = await showDialog<_AccountDeletionDialogResult>(
      context: context,
      builder: (_) => _AccountDeletionRequestDialog(eligibility: eligibility),
    );
    if (!mounted || result == null) return;

    setState(() => _isMutating = true);
    try {
      await ref
          .read(legalRepositoryProvider)
          .createPrivacyRequest(
            type: PrivacyRequestType.deletion,
            currentPassword: result.currentPassword,
            details: <String, dynamic>{
              if (result.reason.isNotEmpty) 'reason': result.reason,
              'offline_data_resolved': result.offlineDataResolved,
            },
          );
      ref.invalidate(privacyRequestsProvider);
      if (mounted) {
        AppSnackbar.showSuccess(
          context,
          eligibility.operationallyEligible
              ? 'Account deletion request submitted for verified review.'
              : 'Request submitted. Deletion will wait until the listed project responsibilities are resolved.',
        );
      }
    } catch (error) {
      if (mounted) {
        final message = userFacingErrorMessage(
          error,
          fallback: 'Unable to submit the account deletion request.',
        );
        setState(() => _accountAccessError = message);
        AppSnackbar.showError(context, message);
      }
    } finally {
      if (mounted) setState(() => _isMutating = false);
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
          'Deactivate your account? You will be signed out until an administrator restores access.',
        ),
        actions: [
          AppDialogActions(
            cancel: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            confirm: FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Deactivate'),
            ),
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
    final result = await showDialog<AuthSession>(
      context: context,
      builder: (_) => _ChangeContactDialog.phone(initialValue: widget.phone),
    );

    if (!mounted || result == null) {
      return;
    }
    ref
        .read(authControllerProvider.notifier)
        .completeContactVerification(result);
    AppSnackbar.showSuccess(context, 'Mobile number changed successfully.');
  }

  @override
  Widget build(BuildContext context) {
    final supportAsync = ref.watch(supportSettingsProvider);
    final privacyRequests = ref.watch(privacyRequestsProvider);
    PrivacyRequestRecord? activeDeletionRequest;
    for (final request
        in privacyRequests.asData?.value ?? const <PrivacyRequestRecord>[]) {
      if (request.isActive && request.type == PrivacyRequestType.deletion) {
        activeDeletionRequest = request;
        break;
      }
    }
    final canVerifyPendingDeletion =
        activeDeletionRequest?.status == 'pending_verification';
    final privacyRequestsLoaded = privacyRequests.asData != null;

    return ListView(
      children: [
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
                        Row(
                          children: [
                            const Icon(Icons.email_outlined, size: 18),
                            const SizedBox(width: AppSpacing.xs),
                            Expanded(child: Text(widget.email, softWrap: true)),
                          ],
                        ),
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
                children: [Chip(label: Text(widget.userRole.label))],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Privacy, legal & notifications',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.sm),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.privacy_tip_outlined),
                title: const Text('Privacy & data'),
                subtitle: const Text('Legal information and privacy requests'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppRoutes.privacyCenter),
              ),
              if (_pushAvailable) ...[
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    _notificationsEnabled
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_off_outlined,
                  ),
                  title: const Text('Notifications'),
                  subtitle: Text(
                    _notificationsEnabled
                        ? 'Enabled on this device'
                        : 'Disabled on this device',
                  ),
                  trailing: OutlinedButton(
                    onPressed: _notificationPreferenceBusy
                        ? null
                        : _notificationsEnabled
                        ? _disableNotifications
                        : _requestNotificationPermission,
                    child: Text(_notificationsEnabled ? 'Disable' : 'Enable'),
                  ),
                ),
                if (_notificationsEnabled)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _showSensitiveNotificationPreview,
                    onChanged: _notificationPreferenceBusy
                        ? null
                        : _setSensitiveNotificationPreview,
                    title: const Text('Show notification details'),
                  ),
              ],
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
                const Text('Support details are unavailable.', softWrap: true),
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
                Text(
                  'Help & Support',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.sm),
                if (!settings.isConfigured)
                  const Text('Support details are unavailable.')
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
                if (widget.isSuperAdmin) ...[
                  const SizedBox(height: AppSpacing.sm),
                  AppActionButtons(
                    maxColumns: 1,
                    fillRows: true,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _isMutating ? null : _editSupportSettings,
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Edit'),
                      ),
                    ],
                  ),
                ],
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
              AppActionButtons(
                maxColumns: 1,
                children: [
                  OutlinedButton.icon(
                    onPressed: _isMutating ? null : _showChangePasswordDialog,
                    icon: const Icon(Icons.password_outlined),
                    label: const Text('Change password'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (!widget.isSuperAdmin) ...[
          const SizedBox(height: AppSpacing.md),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Account access',
                  style: Theme.of(context).textTheme.titleMedium,
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
                AppActionButtons(
                  maxColumns: 1,
                  children: [
                    if (widget.userRole == UserRole.contributor)
                      OutlinedButton.icon(
                        onPressed: _isMutating ? null : _selfDeactivate,
                        icon: const Icon(Icons.person_off_outlined),
                        label: const Text('Deactivate my account'),
                      ),
                    if (canVerifyPendingDeletion)
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                        ),
                        onPressed: _isMutating || !privacyRequestsLoaded
                            ? null
                            : () => _cancelDeletionRequest(
                                activeDeletionRequest!,
                              ),
                        icon: const Icon(Icons.close),
                        label: const Text('Cancel deletion request'),
                      ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                      onPressed: _isMutating || !privacyRequestsLoaded
                          ? null
                          : canVerifyPendingDeletion ||
                                activeDeletionRequest == null
                          ? _requestAccountDeletion
                          : activeDeletionRequest.canCancel
                          ? () => _cancelDeletionRequest(activeDeletionRequest!)
                          : null,
                      icon: Icon(
                        activeDeletionRequest?.canCancel == true &&
                                !canVerifyPendingDeletion
                            ? Icons.close
                            : Icons.delete_forever_outlined,
                      ),
                      label: Text(
                        canVerifyPendingDeletion
                            ? 'Verify deletion request'
                            : activeDeletionRequest?.canCancel == true
                            ? 'Cancel deletion request'
                            : activeDeletionRequest != null
                            ? 'Deletion request ${activeDeletionRequest.status.replaceAll('_', ' ')}'
                            : 'Request account deletion',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        AppActionButtons(
          maxColumns: 1,
          children: [
            FilledButton.icon(
              onPressed: widget.onLogout,
              icon: const Icon(Icons.logout),
              label: const Text('Logout'),
            ),
          ],
        ),
      ],
    );
  }
}

enum _ChangePasswordDialogResult { success }

enum _SupportSettingsDialogResult { success }

class _AccountDeletionDialogResult {
  const _AccountDeletionDialogResult({
    required this.currentPassword,
    required this.reason,
    required this.offlineDataResolved,
  });

  final String currentPassword;
  final String reason;
  final bool offlineDataResolved;
}

class _AccountDeletionRequestDialog extends StatefulWidget {
  const _AccountDeletionRequestDialog({required this.eligibility});

  final AccountDeletionEligibility eligibility;

  @override
  State<_AccountDeletionRequestDialog> createState() =>
      _AccountDeletionRequestDialogState();
}

class _AccountDeletionRequestDialogState
    extends State<_AccountDeletionRequestDialog> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _reasonController = TextEditingController();
  bool _obscurePassword = true;
  bool _offlineDataResolved = false;
  bool _showOfflineConfirmationError = false;

  @override
  void dispose() {
    _passwordController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final requiresOfflineConfirmation = widget.eligibility.blockers.any(
      (blocker) => blocker.code == 'OFFLINE_DATA_CONFIRMATION_REQUIRED',
    );
    if (requiresOfflineConfirmation && !_offlineDataResolved) {
      setState(() => _showOfflineConfirmationError = true);
      return;
    }
    Navigator.of(context).pop(
      _AccountDeletionDialogResult(
        currentPassword: _passwordController.text,
        reason: _reasonController.text.trim(),
        offlineDataResolved:
            !requiresOfflineConfirmation || _offlineDataResolved,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final blockers = widget.eligibility.blockers;
    return AlertDialog(
      title: const Text('Request account deletion'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Your account stays active while this request is reviewed.',
                ),
                const SizedBox(height: AppSpacing.sm),
                if (blockers.isNotEmpty) ...[
                  const Text(
                    'Resolve these items before deletion can be completed:',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  for (final blocker in blockers)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                      child: Text(
                        blocker.code == 'ACTIVE_PROJECT_ASSIGNMENTS'
                            ? '• Active or pending assignments: ${blocker.count}'
                            : blocker.code == 'PENDING_CONTRIBUTION_REVIEWS'
                            ? '• Contributions awaiting review: ${blocker.count}'
                            : '• ${blocker.message}',
                      ),
                    ),
                ],
                if (blockers.any(
                  (blocker) =>
                      blocker.code == 'OFFLINE_DATA_CONFIRMATION_REQUIRED',
                )) ...[
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _offlineDataResolved,
                    title: const Text(
                      'I synced or removed private drafts on my devices.',
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (value) => setState(() {
                      _offlineDataResolved = value == true;
                      _showOfflineConfirmationError = false;
                    }),
                  ),
                  if (_showOfflineConfirmationError)
                    Text(
                      'Confirm your offline drafts before continuing.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  label: 'Current password',
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  autofillHints: const [AutofillHints.password],
                  suffix: IconButton(
                    tooltip: _obscurePassword
                        ? 'Show password'
                        : 'Hide password',
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                  validator: (value) => value == null || value.isEmpty
                      ? 'Enter your current password.'
                      : null,
                  onFieldSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: AppSpacing.sm),
                AppTextField(
                  label: 'Reason or context (optional)',
                  controller: _reasonController,
                  maxLength: 1000,
                  maxLines: 3,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        AppDialogActions(
          cancel: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          confirm: FilledButton(onPressed: _submit, child: const Text('Send')),
        ),
      ],
    );
  }
}

class _ChangeContactDialog extends ConsumerStatefulWidget {
  const _ChangeContactDialog.phone({required this.initialValue});

  final String? initialValue;

  @override
  ConsumerState<_ChangeContactDialog> createState() =>
      _ChangeContactDialogState();
}

class _ChangeContactDialogState extends ConsumerState<_ChangeContactDialog> {
  final _formKey = GlobalKey<FormState>();
  final _contactController = TextEditingController();
  final _passwordController = TextEditingController();
  final _codeController = TextEditingController();
  bool _isSubmitting = false;
  bool _codeSent = false;
  bool _obscurePassword = true;
  String? _dialogError;

  @override
  void initState() {
    super.initState();
    _contactController.text = AuthFormValidators.formatLebanesePhone(
      widget.initialValue,
    );
  }

  @override
  void dispose() {
    _contactController.dispose();
    _passwordController.dispose();
    _codeController.dispose();
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
      final repository = ref.read(contactVerificationRepositoryProvider);
      if (!_codeSent) {
        final session = await repository.requestPhoneChange(
          phone: AuthFormValidators.normalizeLebanesePhone(
            _contactController.text,
          ),
          currentPassword: _passwordController.text,
        );
        if (!mounted) return;
        if (session != null) {
          Navigator.of(context).pop(session);
          return;
        }
        if (!mounted) return;
        setState(() {
          _codeSent = true;
          _isSubmitting = false;
        });
        return;
      }
      final session = await repository.confirmPhoneChange(_codeController.text);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(session);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _dialogError = userFacingErrorMessage(
          error,
          fallback: 'Unable to verify the contact change right now.',
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
      title: const Text('Change mobile number'),
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
                if (!_codeSent) ...[
                  LebaneseMobileField(controller: _contactController),
                  const SizedBox(height: AppSpacing.sm),
                  AppTextField(
                    label: 'Current password',
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    validator: AuthFormValidators.loginPassword,
                    suffix: IconButton(
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility
                            : Icons.visibility_off,
                      ),
                    ),
                  ),
                ] else ...[
                  Text(
                    'Your current verified contact remains active until this code is confirmed.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppTextField(
                    label: '6-digit verification code',
                    controller: _codeController,
                    keyboardType: TextInputType.number,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    validator: (value) => (value?.trim().length == 6)
                        ? null
                        : 'Enter the 6-digit verification code.',
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        AppDialogActions(
          cancel: TextButton(
            onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          confirm: FilledButton(
            onPressed: _isSubmitting ? null : _submit,
            child: Text(
              _isSubmitting
                  ? 'Working...'
                  : _codeSent
                  ? 'Verify'
                  : 'Continue',
            ),
          ),
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
        AppDialogActions(
          cancel: TextButton(
            onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          confirm: FilledButton(
            onPressed: _isSubmitting ? null : _submit,
            child: Text(_isSubmitting ? 'Saving...' : 'Save'),
          ),
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
                  hint: 'Phone number',
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
        AppDialogActions(
          cancel: TextButton(
            onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          confirm: FilledButton(
            onPressed: _isSubmitting ? null : _submit,
            child: Text(_isSubmitting ? 'Saving...' : 'Save'),
          ),
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
