import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../auth/domain/auth_models.dart';
import '../../domain/admin_models.dart';

class UsersManagementScreen extends ConsumerStatefulWidget {
  const UsersManagementScreen({super.key});

  @override
  ConsumerState<UsersManagementScreen> createState() =>
      _UsersManagementScreenState();
}

class _UsersManagementScreenState extends ConsumerState<UsersManagementScreen> {
  bool _isUpdating = false;

  Future<void> _toggleAdminRole(ManagedUserSummary user) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          user.role == UserRole.admin
              ? 'Revert admin role'
              : 'Promote to admin',
        ),
        content: Text(
          user.role == UserRole.admin
              ? 'Revert ${user.fullName} to ${user.previousAdminRole?.label ?? 'the previous role'}?'
              : 'Promote ${user.fullName} to admin?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(user.role == UserRole.admin ? 'Revert' : 'Promote'),
          ),
        ],
      ),
    );

    if (confirm != true) {
      return;
    }

    setState(() => _isUpdating = true);
    try {
      final updated = await ref
          .read(adminRepositoryProvider)
          .toggleAdminRole(user.id);
      ref.invalidate(managedUsersProvider);
      ref.invalidate(adminDashboardProvider);
      if (!mounted) {
        return;
      }
      AppSnackbar.showSuccess(
        context,
        updated.role == UserRole.admin
            ? '${updated.fullName} is now an admin.'
            : '${updated.fullName} reverted to ${updated.roleLabel}.',
      );
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(context, error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _isUpdating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authControllerProvider).session;
    final isSuperAdmin = session?.user.isSuperAdmin ?? false;
    final usersAsync = ref.watch(managedUsersProvider);

    return usersAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Users unavailable',
        message: '$error',
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(managedUsersProvider),
      ),
      data: (users) {
        final viewerCount = users
            .where((user) => user.role == UserRole.viewer)
            .length;
        final activeContributors = users
            .where((user) => user.role == UserRole.contributor && user.isActive)
            .length;

        return ListView(
          children: [
            const SectionHeader(
              title: 'Users',
              subtitle:
                  'Directory of viewers, contributors, admins, and the protected super administrator.',
            ),
            const SizedBox(height: AppSpacing.sm),
            AppCard(
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  _MetricChip(
                    icon: Icons.groups_outlined,
                    label: 'Total users',
                    value: '${users.length}',
                  ),
                  _MetricChip(
                    icon: Icons.visibility_outlined,
                    label: 'Viewers',
                    value: '$viewerCount',
                  ),
                  _MetricChip(
                    icon: Icons.edit_location_alt_outlined,
                    label: 'Active contributors',
                    value: '$activeContributors',
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (users.isEmpty)
              const AppEmptyState(
                icon: Icons.groups_outlined,
                title: 'No users found',
                message: 'Users will appear here after account creation.',
              )
            else
              ...users.map(
                (user) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: _UserCard(
                    user: user,
                    isSuperAdmin: isSuperAdmin,
                    isUpdating: _isUpdating,
                    onToggleAdmin: user.canToggleAdminRole && isSuperAdmin
                        ? () => _toggleAdminRole(user)
                        : null,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _UserCard extends StatelessWidget {
  const _UserCard({
    required this.user,
    required this.isSuperAdmin,
    required this.isUpdating,
    required this.onToggleAdmin,
  });

  final ManagedUserSummary user;
  final bool isSuperAdmin;
  final bool isUpdating;
  final VoidCallback? onToggleAdmin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                child: Icon(
                  user.role == UserRole.admin
                      ? Icons.admin_panel_settings_outlined
                      : user.role == UserRole.contributor
                      ? Icons.edit_location_alt_outlined
                      : Icons.visibility_outlined,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.fullName,
                      style: theme.textTheme.titleMedium,
                      softWrap: true,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(user.email, style: theme.textTheme.bodyMedium),
                    if (user.phone?.trim().isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          user.phone!,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(label: Text(user.roleLabel)),
              Chip(label: Text(user.isActive ? 'Active' : 'Inactive')),
              if (user.isProtectedSuperAdmin)
                const Chip(
                  avatar: Icon(Icons.verified_user_outlined, size: 18),
                  label: Text('Protected'),
                ),
              if (user.requestStatus != null)
                Chip(label: Text('Request: ${user.requestStatus!.name}')),
              if (user.previousAdminRole != null && user.role == UserRole.admin)
                Chip(
                  label: Text(
                    'Previous role: ${user.previousAdminRole!.label}',
                  ),
                ),
            ],
          ),
          if (isSuperAdmin && onToggleAdmin != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: isUpdating ? null : onToggleAdmin,
                icon: Icon(
                  user.role == UserRole.admin
                      ? Icons.undo_outlined
                      : Icons.arrow_circle_up_outlined,
                ),
                label: Text(
                  user.role == UserRole.admin
                      ? 'Revert Admin'
                      : 'Promote to Admin',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        borderRadius: AppRadii.md,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: AppSpacing.xs),
          Text('$label: ', style: Theme.of(context).textTheme.bodySmall),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
