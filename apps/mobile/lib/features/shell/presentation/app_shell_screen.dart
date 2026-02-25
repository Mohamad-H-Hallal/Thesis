import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_branding.dart';
import '../../../core/providers/providers.dart';
import '../../../core/router/route_paths.dart';
import '../../../core/widgets/app_logo.dart';
import '../../../core/widgets/app_scaffold.dart';
import '../../auth/domain/auth_models.dart';
import '../../drafts/presentation/screens/drafts_screen.dart';
import '../../exports/presentation/screens/exports_dashboard_screen.dart';
import '../../map/presentation/screens/map_screen.dart';
import '../../notifications/presentation/screens/notifications_screen.dart';
import '../../profile/presentation/screens/profile_screen.dart';
import '../../projects/presentation/screens/home_projects_screen.dart';
import '../../review/presentation/screens/review_queue_screen.dart';
import '../../submissions/presentation/screens/my_submissions_screen.dart';

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

    final role = session.user.role;
    final items = _itemsForRole(role);
    final selectedIndex = _selectedIndex(items, location);
    final selectedItem = items[selectedIndex];

    final body = _bodyForPath(selectedItem.path, session.user.role);

    return LayoutBuilder(
      builder: (context, constraints) {
        final useSideNav = constraints.maxWidth >= 980;

        final navChildren = <Widget>[];
        for (var i = 0; i < items.length; i++) {
          final item = items[i];
          navChildren.add(
            NavigationDrawerDestination(
              icon: Icon(item.icon),
              selectedIcon: Icon(item.selectedIcon ?? item.icon),
              label: Text(item.label),
            ),
          );
        }

        final logoutAction = IconButton(
          tooltip: 'Logout',
          onPressed: () => ref.read(authControllerProvider.notifier).logout(),
          icon: const Icon(Icons.logout),
        );

        final syncAction = Stack(
          alignment: Alignment.center,
          children: [
            IconButton(
              tooltip: 'Sync now',
              onPressed: () =>
                  ref.read(syncControllerProvider.notifier).syncNow(),
              icon: Icon(syncState.isSyncing ? Icons.sync : Icons.sync),
            ),
            if (attentionCount > 0)
              Positioned(
                right: 8,
                top: 7,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
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

        if (useSideNav) {
          return Scaffold(
            body: SafeArea(
              child: Row(
                children: [
                  SizedBox(
                    width: 280,
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
                          '${session.user.fullName} • ${session.user.role.label}',
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
                  Expanded(
                    child: AppScaffold(
                      title: selectedItem.label,
                      actions: [syncAction, logoutAction],
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
            ),
          );
        }

        return AppScaffold(
          title: selectedItem.label,
          actions: [syncAction, logoutAction],
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
                  subtitle: Text(session.user.role.label),
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
          bottomNavigationBar: items.length > 5
              ? null
              : NavigationBar(
                  selectedIndex: selectedIndex,
                  onDestinationSelected: (index) =>
                      context.go(items[index].path),
                  destinations: items
                      .map(
                        (item) => NavigationDestination(
                          icon: Icon(item.icon),
                          selectedIcon: Icon(item.selectedIcon ?? item.icon),
                          label: item.label,
                        ),
                      )
                      .toList(growable: false),
                ),
        );
      },
    );
  }

  int _selectedIndex(List<_ShellItem> items, String currentLocation) {
    final index = items.indexWhere(
      (item) => currentLocation.startsWith(item.path),
    );
    return index == -1 ? 0 : index;
  }

  Widget _bodyForPath(String path, UserRole role) {
    if (path == AppRoutes.projects) return const HomeProjectsScreen();
    if (path == AppRoutes.map) return const MapScreen();
    if (path == AppRoutes.drafts) {
      return const DraftsScreen(showSubmittedOnly: false);
    }
    if (path == AppRoutes.submissions) {
      return const DraftsScreen(showSubmittedOnly: true);
    }
    if (path == AppRoutes.reviewQueue) return const ReviewQueueScreen();
    if (path == AppRoutes.exports) return const ExportsDashboardScreen();
    if (path == AppRoutes.notifications) return const NotificationsScreen();
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
            role: session.user.role.label,
            onLogout: () => ref.read(authControllerProvider.notifier).logout(),
          );
        },
      );
    }
    if (role == UserRole.contributor) {
      return const MySubmissionsScreen();
    }
    return const ReviewQueueScreen();
  }

  List<_ShellItem> _itemsForRole(UserRole role) {
    final base = <_ShellItem>[
      const _ShellItem(
        label: 'Home/Projects',
        path: AppRoutes.projects,
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
      ),
      const _ShellItem(
        label: 'Map',
        path: AppRoutes.map,
        icon: Icons.map_outlined,
        selectedIcon: Icons.map,
      ),
      const _ShellItem(
        label: 'My Drafts',
        path: AppRoutes.drafts,
        icon: Icons.edit_note_outlined,
        selectedIcon: Icons.edit_note,
      ),
    ];

    if (role == UserRole.admin || role == UserRole.reviewer) {
      base.add(
        const _ShellItem(
          label: 'Review Queue',
          path: AppRoutes.reviewQueue,
          icon: Icons.rate_review_outlined,
          selectedIcon: Icons.rate_review,
        ),
      );
      base.add(
        const _ShellItem(
          label: 'Exports',
          path: AppRoutes.exports,
          icon: Icons.file_download_outlined,
          selectedIcon: Icons.file_download,
        ),
      );
    } else {
      base.add(
        const _ShellItem(
          label: 'My Submissions',
          path: AppRoutes.submissions,
          icon: Icons.upload_file_outlined,
          selectedIcon: Icons.upload_file,
        ),
      );
    }

    base.addAll([
      const _ShellItem(
        label: 'Notifications',
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
    ]);

    return base;
  }
}

class _ShellItem {
  const _ShellItem({
    required this.label,
    required this.path,
    required this.icon,
    this.selectedIcon,
  });

  final String label;
  final String path;
  final IconData icon;
  final IconData? selectedIcon;
}
