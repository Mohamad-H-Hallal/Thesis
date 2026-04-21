import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../../core/utils/lebanese_phone.dart';
import '../../../auth/domain/auth_models.dart';
import '../../domain/admin_models.dart';

class UsersManagementScreen extends ConsumerStatefulWidget {
  const UsersManagementScreen({super.key});

  @override
  ConsumerState<UsersManagementScreen> createState() =>
      _UsersManagementScreenState();
}

class _UsersManagementScreenState extends ConsumerState<UsersManagementScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _isUpdating = false;
  bool _showFilters = false;
  UserRole? _roleFilter;
  UserAccountState? _stateFilter;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _toggleAdminRole(ManagedUserSummary user) async {
    final isPromoting = user.role != UserRole.admin;
    final hasAssignments = user.approvedAssignmentCount > 0;
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
              : hasAssignments
              ? 'Promote ${user.fullName} to admin? They are currently assigned to ${user.approvedAssignmentCount} project(s) and will be unassigned before promotion.'
              : 'Promote ${user.fullName} to admin?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              user.role == UserRole.admin
                  ? 'Revert'
                  : hasAssignments
                  ? 'Promote and Unassign'
                  : 'Promote',
            ),
          ),
        ],
      ),
    );

    if (confirm != true) {
      return;
    }

    await _mutate(() async {
      final updated = await ref
          .read(adminRepositoryProvider)
          .toggleAdminRole(
            user.id,
            forceUnassign: isPromoting && hasAssignments,
          );
      _invalidate();
      if (!mounted) {
        return;
      }
      AppSnackbar.showSuccess(
        context,
        updated.role == UserRole.admin
            ? updated.unassignedAssignmentCount > 0
                  ? '${updated.fullName} is now an admin and was unassigned from ${updated.unassignedAssignmentCount} project(s).'
                  : '${updated.fullName} is now an admin.'
            : '${updated.fullName} reverted to ${updated.roleLabel}.',
      );
    });
  }

  Future<void> _toggleBlockState(ManagedUserSummary user) async {
    final shouldBlock = !user.isBlocked;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(shouldBlock ? 'Block account' : 'Unblock account'),
        content: Text(
          shouldBlock
              ? 'Block ${user.fullName}? They will not be able to log in until unblocked.'
              : 'Unblock ${user.fullName}? Their previous access state will be restored.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(shouldBlock ? 'Block' : 'Unblock'),
          ),
        ],
      ),
    );

    if (confirm != true) {
      return;
    }

    await _mutate(() async {
      if (shouldBlock) {
        await ref.read(adminRepositoryProvider).blockUser(user.id);
      } else {
        await ref.read(adminRepositoryProvider).unblockUser(user.id);
      }
      _invalidate();
      if (!mounted) {
        return;
      }
      AppSnackbar.showSuccess(
        context,
        shouldBlock
            ? 'User blocked successfully.'
            : 'User unblocked successfully.',
      );
    });
  }

  Future<void> _mutate(Future<void> Function() action) async {
    setState(() => _isUpdating = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to update this user right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isUpdating = false);
      }
    }
  }

  void _invalidate() {
    bumpWorkflowRefresh(ref);
  }

  List<ManagedUserSummary> _applyFilters(List<ManagedUserSummary> users) {
    final query = _searchController.text.trim().toLowerCase();
    return users
        .where((user) {
          if (_roleFilter != null && user.role != _roleFilter) {
            return false;
          }
          if (_stateFilter != null && user.accountState != _stateFilter) {
            return false;
          }
          if (query.isEmpty) {
            return true;
          }
          return user.fullName.toLowerCase().contains(query) ||
              user.email.toLowerCase().contains(query) ||
              (user.phone?.toLowerCase().contains(query) ?? false);
        })
        .toList(growable: false);
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
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to load users right now. Please try again.',
        ),
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(managedUsersProvider),
      ),
      data: (users) {
        final filtered = _applyFilters(users);

        return ListView(
          children: [
            const SectionHeader(title: 'Users'),
            const SizedBox(height: AppSpacing.sm),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final filterButton = OutlinedButton.icon(
                        onPressed: () =>
                            setState(() => _showFilters = !_showFilters),
                        icon: Icon(
                          _showFilters
                              ? Icons.filter_alt_off_outlined
                              : Icons.filter_alt_outlined,
                        ),
                        label: Text(_showFilters ? 'Hide' : 'Filter'),
                      );

                      final searchBar = SearchBar(
                        controller: _searchController,
                        hintText: 'Search name, email, or phone',
                        leading: const Icon(Icons.search),
                        onChanged: (_) => setState(() {}),
                      );

                      if (constraints.maxWidth < 560) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            searchBar,
                            const SizedBox(height: AppSpacing.sm),
                            filterButton,
                          ],
                        );
                      }

                      return Row(
                        children: [
                          Expanded(child: searchBar),
                          const SizedBox(width: AppSpacing.sm),
                          filterButton,
                        ],
                      );
                    },
                  ),
                  if (_showFilters) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilterChip(
                          label: const Text('All roles'),
                          selected: _roleFilter == null,
                          onSelected: (_) => setState(() => _roleFilter = null),
                        ),
                        ...UserRole.values.map(
                          (role) => FilterChip(
                            label: Text(role.label),
                            selected: _roleFilter == role,
                            onSelected: (_) =>
                                setState(() => _roleFilter = role),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilterChip(
                          label: const Text('All states'),
                          selected: _stateFilter == null,
                          onSelected: (_) =>
                              setState(() => _stateFilter = null),
                        ),
                        ...UserAccountState.values.map(
                          (state) => FilterChip(
                            label: Text(_stateLabel(state)),
                            selected: _stateFilter == state,
                            onSelected: (_) =>
                                setState(() => _stateFilter = state),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (filtered.isEmpty)
              const AppEmptyState(
                icon: Icons.manage_search_outlined,
                title: 'No users match the current filters',
                message:
                    'Try a different search term or clear one of the active filters.',
              )
            else
              ...filtered.map(
                (user) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: _UserCard(
                    user: user,
                    isSuperAdmin: isSuperAdmin,
                    isUpdating: _isUpdating,
                    onToggleAdmin: user.canToggleAdminRole && isSuperAdmin
                        ? () => _toggleAdminRole(user)
                        : null,
                    onToggleBlock: (user.canBlock || user.canUnblock)
                        ? () => _toggleBlockState(user)
                        : null,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  String _stateLabel(UserAccountState state) {
    switch (state) {
      case UserAccountState.active:
        return 'Active';
      case UserAccountState.pending:
        return 'Pending';
      case UserAccountState.rejected:
        return 'Rejected';
      case UserAccountState.blocked:
        return 'Blocked';
      case UserAccountState.inactive:
        return 'Inactive';
    }
  }
}

class _UserCard extends StatelessWidget {
  const _UserCard({
    required this.user,
    required this.isSuperAdmin,
    required this.isUpdating,
    required this.onToggleAdmin,
    required this.onToggleBlock,
  });

  final ManagedUserSummary user;
  final bool isSuperAdmin;
  final bool isUpdating;
  final VoidCallback? onToggleAdmin;
  final VoidCallback? onToggleBlock;

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
                    SelectableText(
                      user.email,
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (user.phone?.trim().isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          LebanesePhone.format(user.phone),
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
              Chip(label: Text(user.accountStateLabel)),
              if (user.isProtectedSuperAdmin)
                const Chip(
                  avatar: Icon(Icons.verified_user_outlined, size: 18),
                  label: Text('Protected'),
                ),
              if (user.requestStatus != null)
                Chip(label: Text('Request: ${user.requestStatus!.name}')),
              if (user.approvedAssignmentCount > 0)
                Chip(
                  label: Text(
                    '${user.approvedAssignmentCount} assigned project${user.approvedAssignmentCount == 1 ? '' : 's'}',
                  ),
                ),
              if (user.previousAdminRole != null && user.role == UserRole.admin)
                Chip(
                  label: Text(
                    'Previous role: ${user.previousAdminRole!.label}',
                  ),
                ),
            ],
          ),
          if (isSuperAdmin && onToggleAdmin != null ||
              onToggleBlock != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (isSuperAdmin && onToggleAdmin != null)
                  FilledButton.tonalIcon(
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
                if (onToggleBlock != null)
                  OutlinedButton.icon(
                    onPressed: isUpdating ? null : onToggleBlock,
                    icon: Icon(
                      user.isBlocked
                          ? Icons.lock_open_outlined
                          : Icons.block_outlined,
                    ),
                    label: Text(user.isBlocked ? 'Unblock User' : 'Block User'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
