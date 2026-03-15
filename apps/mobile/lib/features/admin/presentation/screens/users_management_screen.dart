import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../auth/domain/auth_models.dart';
import '../../domain/admin_models.dart';

class UsersManagementScreen extends ConsumerWidget {
  const UsersManagementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        return ListView(
          children: [
            const SectionHeader(
              title: 'Users',
              subtitle: 'Directory of viewers, contributors, admins, and the protected super administrator.',
            ),
            const SizedBox(height: AppSpacing.sm),
            if (users.isEmpty)
              const AppEmptyState(
                icon: Icons.groups_outlined,
                title: 'No users found',
                message: 'Users will appear here after account creation.',
              )
            else
              ...users.map((user) => _UserTile(user: user)),
          ],
        );
      },
    );
  }
}

class _UserTile extends StatelessWidget {
  const _UserTile({required this.user});

  final ManagedUserSummary user;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(
            child: Icon(
              user.role == UserRole.admin
                  ? Icons.admin_panel_settings_outlined
                  : user.role == UserRole.contributor
                  ? Icons.edit_location_alt_outlined
                  : Icons.visibility_outlined,
            ),
          ),
          title: Text(user.fullName),
          subtitle: Text('${user.email}\n${user.phone ?? 'No phone'}'),
          isThreeLine: true,
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Chip(label: Text(user.roleLabel)),
              const SizedBox(height: 4),
              Text(
                user.isActive ? 'Active' : 'Inactive',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
