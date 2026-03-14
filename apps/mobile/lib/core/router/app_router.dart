import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/controllers/auth_controller.dart';
import '../../features/auth/domain/auth_models.dart';
import '../../features/auth/presentation/screens/forgot_password_screen.dart';
import '../../features/auth/presentation/screens/login_screen.dart';
import '../../features/auth/presentation/screens/reset_password_screen.dart';
import '../../features/auth/presentation/screens/signup_screen.dart';
import '../../features/auth/presentation/screens/splash_screen.dart';
import '../../features/map/presentation/screens/add_feature_screen.dart';
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
      final role = auth.session?.user.role;
      final isAuthRoute =
          path == AppRoutes.login ||
          path == AppRoutes.signup ||
          path == AppRoutes.forgotPassword ||
          path == AppRoutes.resetPassword;
      final isSplash = path == AppRoutes.splash;

      if (auth.status == AuthStatus.checking) {
        return isSplash ? null : AppRoutes.splash;
      }

      if (!auth.isAuthenticated) {
        if (isAuthRoute) return null;
        return AppRoutes.login;
      }

      final allowedPaths = _allowedPathsForRole(role);
      final isAllowed =
          path == AppRoutes.app ||
          allowedPaths.any((allowedPath) => path.startsWith(allowedPath));
      if (!isAllowed) {
        return role == UserRole.admin ? AppRoutes.projects : AppRoutes.projects;
      }

      if (isSplash || isAuthRoute || path == AppRoutes.app) {
        return AppRoutes.projects;
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
      GoRoute(
        path: AppRoutes.projects,
        pageBuilder: (_, state) =>
            _buildPage(state, AppShellScreen(location: state.uri.path)),
      ),
      GoRoute(
        path: AppRoutes.assignedProjects,
        pageBuilder: (_, state) =>
            _buildPage(state, AppShellScreen(location: state.uri.path)),
      ),
      GoRoute(
        path: AppRoutes.map,
        pageBuilder: (_, state) =>
            _buildPage(state, AppShellScreen(location: state.uri.path)),
      ),
      GoRoute(
        path: AppRoutes.drafts,
        pageBuilder: (_, state) =>
            _buildPage(state, AppShellScreen(location: state.uri.path)),
      ),
      GoRoute(
        path: AppRoutes.submissions,
        pageBuilder: (_, state) =>
            _buildPage(state, AppShellScreen(location: state.uri.path)),
      ),
      GoRoute(
        path: AppRoutes.reviewQueue,
        pageBuilder: (_, state) =>
            _buildPage(state, AppShellScreen(location: state.uri.path)),
      ),
      GoRoute(
        path: AppRoutes.exports,
        pageBuilder: (_, state) =>
            _buildPage(state, AppShellScreen(location: state.uri.path)),
      ),
      GoRoute(
        path: AppRoutes.notifications,
        pageBuilder: (_, state) =>
            _buildPage(state, AppShellScreen(location: state.uri.path)),
      ),
      GoRoute(
        path: AppRoutes.profile,
        pageBuilder: (_, state) =>
            _buildPage(state, AppShellScreen(location: state.uri.path)),
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
              body: ProjectDetailsScreen(projectId: projectId),
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
              body: AddFeatureScreen(initialProjectId: projectId),
            ),
          );
        },
      ),
    ],
  );
}

Set<String> _allowedPathsForRole(UserRole? role) {
  switch (role) {
    case UserRole.admin:
      return <String>{
        AppRoutes.projects,
        AppRoutes.assignedProjects,
        AppRoutes.map,
        AppRoutes.reviewQueue,
        AppRoutes.exports,
        AppRoutes.notifications,
        AppRoutes.profile,
      };
    case UserRole.viewer:
      return <String>{
        AppRoutes.projects,
        AppRoutes.notifications,
        AppRoutes.profile,
      };
    case UserRole.contributor:
    case null:
      return <String>{
        AppRoutes.projects,
        AppRoutes.assignedProjects,
        AppRoutes.map,
        AppRoutes.drafts,
        AppRoutes.submissions,
        AppRoutes.notifications,
        AppRoutes.profile,
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
