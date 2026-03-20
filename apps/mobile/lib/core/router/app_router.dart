import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/domain/auth_models.dart';
import '../../features/auth/presentation/controllers/auth_controller.dart';
import '../../features/auth/presentation/screens/forgot_password_screen.dart';
import '../../features/auth/presentation/screens/login_screen.dart';
import '../../features/auth/presentation/screens/reset_password_screen.dart';
import '../../features/auth/presentation/screens/signup_screen.dart';
import '../../features/auth/presentation/screens/splash_screen.dart';
import '../../features/map/presentation/screens/add_feature_screen.dart';
import '../../features/map/presentation/screens/map_screen.dart';
import '../../features/projects/presentation/screens/project_details_screen.dart';
import '../../features/shell/presentation/app_shell_screen.dart';
import '../providers/providers.dart';
import '../widgets/app_scaffold.dart';
import 'route_paths.dart';

GoRouter createRouter(Ref ref) {
  final auth = ref.watch(authControllerProvider);

  return GoRouter(
    initialLocation: AppRoutes.splash,
    redirect: (context, state) {
      final path = state.uri.path;
      final user = auth.session?.user;
      final isAuthRoute =
          path == AppRoutes.login ||
          path == AppRoutes.signup ||
          path == AppRoutes.forgotPassword ||
          path == AppRoutes.resetPassword;
      final isSplash = path == AppRoutes.splash;

      if (auth.status == AuthStatus.checking) {
        return isSplash ? null : AppRoutes.splash;
      }

      if (!auth.isAuthenticated || user == null) {
        if (isAuthRoute) {
          return null;
        }
        return AppRoutes.login;
      }

      final allowedPaths = _allowedPathsForUser(user);
      final isAllowed =
          path == AppRoutes.app ||
          allowedPaths.any((allowedPath) => path.startsWith(allowedPath));
      if (!isAllowed) {
        return _defaultHomeForUser(user);
      }

      if (isSplash || isAuthRoute || path == AppRoutes.app) {
        return _defaultHomeForUser(user);
      }

      return null;
    },
    routes: [
      GoRoute(
        path: AppRoutes.splash,
        pageBuilder: (_, state) => _buildPage(state, const SplashScreen()),
      ),
      GoRoute(
        path: AppRoutes.login,
        pageBuilder: (_, state) => _buildPage(state, const LoginScreen()),
      ),
      GoRoute(
        path: AppRoutes.signup,
        pageBuilder: (_, state) => _buildPage(state, const SignupScreen()),
      ),
      GoRoute(
        path: AppRoutes.forgotPassword,
        pageBuilder: (_, state) =>
            _buildPage(state, const ForgotPasswordScreen()),
      ),
      GoRoute(
        path: AppRoutes.resetPassword,
        pageBuilder: (_, state) => _buildPage(
          state,
          ResetPasswordScreen(
            mode: state.uri.queryParameters['mode'],
            token: state.uri.queryParameters['token'],
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.app,
        pageBuilder: (_, state) => _buildPage(
          state,
          const AppShellScreen(location: AppRoutes.projects),
        ),
      ),
      ...[
        AppRoutes.dashboard,
        AppRoutes.users,
        AppRoutes.adminCreation,
        AppRoutes.contributorRequests,
        AppRoutes.projects,
        AppRoutes.assignedProjects,
        AppRoutes.drafts,
        AppRoutes.submissions,
        AppRoutes.assignments,
        AppRoutes.reviewQueue,
        AppRoutes.exports,
        AppRoutes.notifications,
        AppRoutes.profile,
      ].map(
        (path) => GoRoute(
          path: path,
          pageBuilder: (_, state) =>
              _buildPage(state, AppShellScreen(location: state.uri.path)),
        ),
      ),
      GoRoute(
        path: '/app/projects/:projectId',
        pageBuilder: (_, state) {
          final projectId = state.pathParameters['projectId'] ?? '';
          return _buildPage(
            state,
            AppScaffold(
              title: 'Project details',
              showBackButton: true,
              showOfflineBanner: false,
              body: ProjectDetailsScreen(projectId: projectId),
            ),
          );
        },
      ),
      GoRoute(
        path: '/app/projects/:projectId/map',
        pageBuilder: (_, state) {
          final projectId = state.pathParameters['projectId'] ?? '';
          return _buildPage(
            state,
            AppScaffold(
              title: 'Project map',
              showBackButton: true,
              showOfflineBanner: false,
              body: MapScreen(initialProjectId: projectId, lockProjectSelection: true),
            ),
          );
        },
      ),
      GoRoute(
        path: AppRoutes.addFeature,
        pageBuilder: (_, state) {
          final projectId = state.uri.queryParameters['projectId'];
          return _buildPage(
            state,
            AppScaffold(
              title: 'Add Feature',
              showBackButton: true,
              showOfflineBanner: false,
              body: AddFeatureScreen(initialProjectId: projectId),
            ),
          );
        },
      ),
    ],
  );
}

String _defaultHomeForUser(AppUser user) {
  if (user.isSuperAdmin) {
    return AppRoutes.dashboard;
  }
  return AppRoutes.projects;
}

Set<String> _allowedPathsForUser(AppUser user) {
  if (user.isSuperAdmin) {
    return <String>{
      AppRoutes.dashboard,
      AppRoutes.users,
      AppRoutes.adminCreation,
      AppRoutes.contributorRequests,
      AppRoutes.projects,
      AppRoutes.assignments,
      AppRoutes.reviewQueue,
      AppRoutes.exports,
      AppRoutes.notifications,
      AppRoutes.profile,
      '/app/projects/',
      AppRoutes.addFeature,
    };
  }

  switch (user.role) {
    case UserRole.admin:
      return <String>{
        AppRoutes.projects,
        AppRoutes.contributorRequests,
        AppRoutes.assignments,
        AppRoutes.reviewQueue,
        AppRoutes.exports,
        AppRoutes.notifications,
        AppRoutes.profile,
        '/app/projects/',
      };
    case UserRole.viewer:
      return <String>{
        AppRoutes.projects,
        AppRoutes.notifications,
        AppRoutes.profile,
        '/app/projects/',
      };
    case UserRole.contributor:
      return <String>{
        AppRoutes.projects,
        AppRoutes.assignedProjects,
        AppRoutes.drafts,
        AppRoutes.submissions,
        AppRoutes.notifications,
        AppRoutes.profile,
        '/app/projects/',
        AppRoutes.addFeature,
      };
  }
}

CustomTransitionPage<void> _buildPage(GoRouterState state, Widget child) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final slide = Tween<Offset>(
        begin: const Offset(0.02, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));

      return FadeTransition(
        opacity: animation,
        child: SlideTransition(position: slide, child: child),
      );
    },
  );
}
