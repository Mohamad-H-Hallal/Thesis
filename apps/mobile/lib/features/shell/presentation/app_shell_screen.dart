import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_branding.dart';
import '../../../core/constants/design_tokens.dart';
import '../../../core/providers/providers.dart';
import '../../../core/router/route_paths.dart';
import '../../../core/sync/sync_controller.dart';
import '../../../core/widgets/app_logo.dart';
import '../../../core/widgets/app_scaffold.dart';
import '../../admin/presentation/screens/admin_creation_screen.dart';
import '../../admin/presentation/screens/admin_dashboard_screen.dart';
import '../../admin/presentation/screens/assignments_screen.dart';
import '../../admin/presentation/screens/categories_screen.dart';
import '../../admin/presentation/screens/contributor_requests_screen.dart';
import '../../admin/presentation/screens/projects_management_screen.dart';
import '../../admin/presentation/screens/users_management_screen.dart';
import '../../auth/domain/auth_models.dart';
import '../../drafts/presentation/screens/drafts_screen.dart';
import '../../exports/presentation/screens/exports_dashboard_screen.dart';
import '../../notifications/presentation/screens/notifications_screen.dart';
import '../../profile/presentation/screens/profile_screen.dart';
import '../../projects/domain/project.dart';
import '../../projects/presentation/screens/home_projects_screen.dart';
import '../../review/presentation/screens/review_queue_screen.dart';

class AppShellScreen extends ConsumerWidget {
  const AppShellScreen({required this.location, super.key});

  final String location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authControllerProvider);
    final syncState = ref.watch(syncControllerProvider);
    final attentionCount =
        syncState.pendingCount +
        syncState.conflictCount +
        syncState.deadLetterCount;
    final session = authState.session;

    if (session == null) {
      return const SizedBox.shrink();
    }

    final items = _itemsForSession(session.user);
    final mobilePrimaryItems = _mobilePrimaryItems(session.user, items);
    final selectedIndex = _selectedIndex(items, location);
    final selectedItem = items[selectedIndex];
    final body = _bodyForPath(selectedItem.path, session.user);

    return LayoutBuilder(
      builder: (context, constraints) {
        final useSideNav = constraints.maxWidth >= 980;

        final navChildren = items
            .map(
              (item) => NavigationDrawerDestination(
                icon: Icon(item.icon),
                selectedIcon: Icon(item.selectedIcon ?? item.icon),
                label: Text(item.label),
              ),
            )
            .toList(growable: false);

        final logoutAction = IconButton(
          tooltip: 'Logout',
          onPressed: () => _confirmLogout(context, ref),
          icon: const Icon(Icons.logout),
        );

        final syncAction = _buildSyncAction(
          context,
          ref,
          syncState,
          attentionCount,
        );
        final shellActions = <Widget>[
          if (_shouldShowSyncAction(session.user, selectedItem.path))
            syncAction,
          logoutAction,
        ];

        if (useSideNav) {
          return Scaffold(
            body: Row(
              children: [
                SafeArea(
                  right: false,
                  bottom: false,
                  child: SizedBox(
                    width: 340,
                    child: Column(
                      children: [
                        const SizedBox(height: 16),
                        const AppLogo(size: 58),
                        const SizedBox(height: 8),
                        Text(
                          AppBranding.shortName,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          '${session.user.fullName} • ${session.user.roleLabel}',
                          style: Theme.of(context).textTheme.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: NavigationDrawer(
                            selectedIndex: selectedIndex,
                            onDestinationSelected: (index) =>
                                context.go(items[index].path),
                            children: navChildren,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: AppScaffold(
                    title: selectedItem.label,
                    showBackButton: false,
                    actions: shellActions,
                    showOfflineBanner: _shouldShowStatusBanner(
                      session.user,
                      selectedItem.path,
                    ),
                    body: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 280),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: KeyedSubtree(
                        key: ValueKey<String>(selectedItem.path),
                        child: body,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        final primaryItems = mobilePrimaryItems;
        final selectedPrimaryIndex = _selectedIndex(primaryItems, location);

        return AppScaffold(
          title: selectedItem.label,
          showBackButton: false,
          actions: shellActions,
          showOfflineBanner: _shouldShowStatusBanner(
            session.user,
            selectedItem.path,
          ),
          drawer: Drawer(
            child: ListView(
              children: [
                const DrawerHeader(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppLogo(size: 52),
                      SizedBox(height: 10),
                      Text(AppBranding.shortName),
                    ],
                  ),
                ),
                ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.person, size: 18),
                  ),
                  title: Text(session.user.fullName),
                  subtitle: Text(session.user.roleLabel),
                ),
                ...items.map(
                  (item) => ListTile(
                    leading: Icon(item.icon),
                    title: Text(item.label),
                    selected: item.path == selectedItem.path,
                    onTap: () {
                      Navigator.pop(context);
                      context.go(item.path);
                    },
                  ),
                ),
              ],
            ),
          ),
          body: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: KeyedSubtree(
              key: ValueKey<String>(selectedItem.path),
              child: body,
            ),
          ),
          bottomNavigationBar: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  AppSpacing.xs,
                  AppSpacing.sm,
                  AppSpacing.xs,
                ),
                child: ClipRRect(
                  borderRadius: AppRadii.lg,
                  child: NavigationBar(
                    selectedIndex: selectedPrimaryIndex,
                    onDestinationSelected: (index) =>
                        context.go(primaryItems[index].path),
                    height: 72,
                    destinations: primaryItems
                        .map(
                          (item) => NavigationDestination(
                            icon: Icon(item.icon),
                            selectedIcon: Icon(item.selectedIcon ?? item.icon),
                            label: item.mobileLabel ?? item.label,
                          ),
                        )
                        .toList(growable: false),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSyncAction(
    BuildContext context,
    WidgetRef ref,
    SyncState syncState,
    int attentionCount,
  ) {
    final isDisabled =
        syncState.isInitializing || !syncState.isReady || syncState.isSyncing;
    final tooltip = syncState.isInitializing
        ? 'Preparing offline access'
        : !syncState.isReady
        ? 'Offline access is not ready yet'
        : syncState.isSyncing
        ? 'Syncing saved changes'
        : 'Sync saved changes';
    return Stack(
      alignment: Alignment.center,
      children: [
        IconButton(
          tooltip: tooltip,
          onPressed: isDisabled
              ? null
              : () => ref.read(syncControllerProvider.notifier).syncNow(),
          icon: const Icon(Icons.sync),
        ),
        if (attentionCount > 0)
          Positioned(
            right: 8,
            top: 7,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.error,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$attentionCount',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onError,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }

  bool _shouldShowSyncAction(AppUser user, String path) {
    if (user.role == UserRole.viewer || user.role == UserRole.admin) {
      return false;
    }
    return path == AppRoutes.projects ||
        path == AppRoutes.assignedProjects ||
        path == AppRoutes.notifications;
  }

  bool _shouldShowStatusBanner(AppUser user, String path) {
    if (user.role == UserRole.viewer || user.role == UserRole.admin) {
      return false;
    }
    return path == AppRoutes.projects ||
        path == AppRoutes.assignedProjects ||
        path == AppRoutes.drafts ||
        path == AppRoutes.submissions;
  }

  List<_ShellItem> _mobilePrimaryItems(AppUser user, List<_ShellItem> items) {
    if (user.isSuperAdmin) {
      return items
          .where(
            (item) =>
                item.path == AppRoutes.dashboard ||
                item.path == AppRoutes.projects ||
                item.path == AppRoutes.contributorRequests ||
                item.path == AppRoutes.notifications ||
                item.path == AppRoutes.profile,
          )
          .toList(growable: false);
    }

    if (user.role == UserRole.admin) {
      return items
          .where(
            (item) =>
                item.path == AppRoutes.projects ||
                item.path == AppRoutes.contributorRequests ||
                item.path == AppRoutes.reviewQueue ||
                item.path == AppRoutes.notifications ||
                item.path == AppRoutes.profile,
          )
          .toList(growable: false);
    }

    if (user.role == UserRole.contributor) {
      return items;
    }

    return items;
  }

  int _selectedIndex(List<_ShellItem> items, String currentLocation) {
    final index = items.indexWhere(
      (item) => currentLocation.startsWith(item.path),
    );
    return index == -1 ? 0 : index;
  }

  Widget _bodyForPath(String path, AppUser user) {
    if (path == AppRoutes.dashboard && user.isSuperAdmin) {
      return const AdminDashboardScreen();
    }
    if (path == AppRoutes.users && user.isSuperAdmin) {
      return const UsersManagementScreen();
    }
    if (path == AppRoutes.categories && user.role == UserRole.admin) {
      return const CategoriesScreen();
    }
    if (path == AppRoutes.adminCreation && user.isSuperAdmin) {
      return const AdminCreationScreen();
    }
    if (path == AppRoutes.contributorRequests && user.role == UserRole.admin) {
      return const ContributorRequestsScreen();
    }
    if (path == AppRoutes.assignments && user.role == UserRole.admin) {
      return const AssignmentsScreen();
    }
    if (path == AppRoutes.projects) {
      if (user.role == UserRole.admin) {
        return const ProjectsManagementScreen();
      }
      return HomeProjectsScreen(
        scope: ProjectViewScope.public,
        title: 'Projects',
      );
    }
    if (path == AppRoutes.assignedProjects &&
        user.role == UserRole.contributor) {
      return const HomeProjectsScreen(
        scope: ProjectViewScope.assigned,
        title: 'Assigned Projects',
      );
    }
    if (path == AppRoutes.drafts && user.role == UserRole.contributor) {
      return const DraftsScreen(showSubmittedOnly: false);
    }
    if (path == AppRoutes.submissions && user.role == UserRole.contributor) {
      return const DraftsScreen(showSubmittedOnly: true);
    }
    if (path == AppRoutes.reviewQueue && user.role == UserRole.admin) {
      return const ReviewQueueScreen();
    }
    if (path == AppRoutes.exports && user.role == UserRole.admin) {
      return const ExportsDashboardScreen();
    }
    if (path == AppRoutes.notifications) {
      return const NotificationsScreen();
    }
    if (path == AppRoutes.profile) {
      return Consumer(
        builder: (context, ref, _) {
          final session = ref.watch(authControllerProvider).session;
          if (session == null) {
            return const SizedBox.shrink();
          }
          return ProfileScreen(
            userName: session.user.fullName,
            email: session.user.email,
            phone: session.user.phone,
            userRole: session.user.role,
            isSuperAdmin: session.user.isSuperAdmin,
            onLogout: () => _confirmLogout(context, ref),
          );
        },
      );
    }

    if (user.isSuperAdmin) {
      return const AdminDashboardScreen();
    }
    if (user.role == UserRole.admin) {
      return const ProjectsManagementScreen();
    }
    if (user.role == UserRole.contributor) {
      return const HomeProjectsScreen(
        scope: ProjectViewScope.assigned,
        title: 'Assigned Projects',
      );
    }
    return const HomeProjectsScreen(
      scope: ProjectViewScope.public,
      title: 'Projects',
    );
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Do you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(authControllerProvider.notifier).logout();
    }
  }

  List<_ShellItem> _itemsForSession(AppUser user) {
    final base = <_ShellItem>[
      const _ShellItem(
        label: 'Notifications',
        mobileLabel: 'Alerts',
        path: AppRoutes.notifications,
        icon: Icons.notifications_none,
        selectedIcon: Icons.notifications,
      ),
      const _ShellItem(
        label: 'Profile',
        path: AppRoutes.profile,
        icon: Icons.person_outline,
        selectedIcon: Icons.person,
      ),
    ];

    if (user.isSuperAdmin) {
      return <_ShellItem>[
        const _ShellItem(
          label: 'Admin Panel',
          mobileLabel: 'Admin',
          path: AppRoutes.dashboard,
          icon: Icons.dashboard_outlined,
          selectedIcon: Icons.dashboard,
        ),
        const _ShellItem(
          label: 'Users',
          path: AppRoutes.users,
          icon: Icons.groups_outlined,
          selectedIcon: Icons.groups,
        ),
        const _ShellItem(
          label: 'Categories',
          path: AppRoutes.categories,
          icon: Icons.category_outlined,
          selectedIcon: Icons.category,
        ),
        const _ShellItem(
          label: 'Create Admin',
          path: AppRoutes.adminCreation,
          icon: Icons.admin_panel_settings_outlined,
          selectedIcon: Icons.admin_panel_settings,
        ),
        const _ShellItem(
          label: 'Requests',
          path: AppRoutes.contributorRequests,
          icon: Icons.person_add_alt_1_outlined,
          selectedIcon: Icons.person_add_alt_1,
        ),
        const _ShellItem(
          label: 'Projects',
          path: AppRoutes.projects,
          icon: Icons.folder_outlined,
          selectedIcon: Icons.folder,
        ),
        const _ShellItem(
          label: 'Assignments',
          path: AppRoutes.assignments,
          icon: Icons.assignment_outlined,
          selectedIcon: Icons.assignment,
        ),
        const _ShellItem(
          label: 'Reviews',
          path: AppRoutes.reviewQueue,
          icon: Icons.rate_review_outlined,
          selectedIcon: Icons.rate_review,
        ),
        const _ShellItem(
          label: 'Exports',
          path: AppRoutes.exports,
          icon: Icons.file_download_outlined,
          selectedIcon: Icons.file_download,
        ),
        ...base,
      ];
    }

    if (user.role == UserRole.admin) {
      return <_ShellItem>[
        const _ShellItem(
          label: 'Projects',
          path: AppRoutes.projects,
          icon: Icons.folder_outlined,
          selectedIcon: Icons.folder,
        ),
        const _ShellItem(
          label: 'Categories',
          path: AppRoutes.categories,
          icon: Icons.category_outlined,
          selectedIcon: Icons.category,
        ),
        const _ShellItem(
          label: 'Requests',
          path: AppRoutes.contributorRequests,
          icon: Icons.person_add_alt_1_outlined,
          selectedIcon: Icons.person_add_alt_1,
        ),
        const _ShellItem(
          label: 'Assignments',
          path: AppRoutes.assignments,
          icon: Icons.assignment_outlined,
          selectedIcon: Icons.assignment,
        ),
        const _ShellItem(
          label: 'Reviews',
          path: AppRoutes.reviewQueue,
          icon: Icons.rate_review_outlined,
          selectedIcon: Icons.rate_review,
        ),
        const _ShellItem(
          label: 'Exports',
          path: AppRoutes.exports,
          icon: Icons.file_download_outlined,
          selectedIcon: Icons.file_download,
        ),
        ...base,
      ];
    }

    if (user.role == UserRole.viewer) {
      return <_ShellItem>[
        const _ShellItem(
          label: 'Projects',
          path: AppRoutes.projects,
          icon: Icons.folder_outlined,
          selectedIcon: Icons.folder,
        ),
        ...base,
      ];
    }

    return <_ShellItem>[
      const _ShellItem(
        label: 'Projects',
        path: AppRoutes.projects,
        icon: Icons.folder_outlined,
        selectedIcon: Icons.folder,
      ),
      const _ShellItem(
        label: 'Assigned Projects',
        mobileLabel: 'Assigned',
        path: AppRoutes.assignedProjects,
        icon: Icons.assignment_outlined,
        selectedIcon: Icons.assignment,
      ),
      ...base,
    ];
  }
}

class _ShellItem {
  const _ShellItem({
    required this.label,
    required this.path,
    required this.icon,
    this.selectedIcon,
    this.mobileLabel,
  });

  final String label;
  final String path;
  final IconData icon;
  final IconData? selectedIcon;
  final String? mobileLabel;
}
