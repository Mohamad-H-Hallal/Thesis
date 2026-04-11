import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/domain/auth_models.dart';
import '../../features/auth/presentation/controllers/auth_controller.dart';
import '../../features/auth/presentation/screens/forgot_password_screen.dart';
import '../../features/auth/presentation/screens/login_screen.dart';
import '../../features/auth/presentation/screens/reset_password_screen.dart';
import '../../features/auth/presentation/screens/signup_screen.dart';
import '../../features/auth/presentation/screens/splash_screen.dart';
import '../../features/admin/presentation/screens/category_form_screen.dart';
import '../../features/admin/presentation/screens/project_assignments_screen.dart';
import '../../features/exports/presentation/screens/exports_dashboard_screen.dart';
import '../../features/admin/presentation/screens/project_form_screen.dart';
import '../../features/map/presentation/screens/add_feature_screen.dart';
import '../../features/map/presentation/screens/map_screen.dart';
import '../../features/projects/presentation/screens/project_details_screen.dart';
import '../../features/review/presentation/screens/review_queue_screen.dart';
import '../../features/shell/presentation/app_shell_screen.dart';
import '../network/api_error_message.dart';
import '../providers/providers.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_scaffold.dart';
import 'route_paths.dart';

GoRouter createRouter(Ref ref, {Listenable? refreshListenable}) {
  return GoRouter(
    initialLocation: AppRoutes.splash,
    refreshListenable: refreshListenable,
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
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
        pageBuilder: (_, state) => _buildPage(
          state,
          LoginScreen(
            noticeMessage: state.uri.queryParameters['notice'],
            noticeIsSuccess: state.uri.queryParameters['success'] == 'true',
          ),
        ),
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
          ResetPasswordScreen(email: state.uri.queryParameters['email']),
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
        AppRoutes.categories,
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
        path: AppRoutes.categoryCreate,
        pageBuilder: (_, state) => _buildPage(
          state,
          const AppScaffold(
            title: 'Create Category',
            showBackButton: true,
            showOfflineBanner: false,
            body: CategoryFormScreen(),
          ),
        ),
      ),
      GoRoute(
        path: '/app/categories/:categoryId/edit',
        pageBuilder: (_, state) {
          final categoryId = state.pathParameters['categoryId'] ?? '';
          return _buildPage(
            state,
            AppScaffold(
              title: 'Edit Category',
              showBackButton: true,
              showOfflineBanner: false,
              body: CategoryFormScreen(categoryId: categoryId),
            ),
          );
        },
      ),
      GoRoute(
        path: AppRoutes.projectCreate,
        pageBuilder: (_, state) => _buildPage(
          state,
          const AppScaffold(
            title: 'Create Project',
            showBackButton: true,
            showOfflineBanner: false,
            body: ProjectFormScreen(),
          ),
        ),
      ),
      GoRoute(
        path: '/app/projects/:projectId/edit',
        pageBuilder: (_, state) {
          final projectId = state.pathParameters['projectId'] ?? '';
          return _buildPage(
            state,
            AppScaffold(
              title: 'Edit Project',
              showBackButton: true,
              showOfflineBanner: false,
              body: ProjectFormScreen(projectId: projectId),
            ),
          );
        },
      ),
      GoRoute(
        path: '/app/projects/:projectId/assignments',
        pageBuilder: (_, state) {
          final projectId = state.pathParameters['projectId'] ?? '';
          return _buildPage(
            state,
            AppScaffold(
              title: 'Project Assignments',
              showBackButton: true,
              showOfflineBanner: false,
              body: ProjectAssignmentsScreen(projectId: projectId),
            ),
          );
        },
      ),
      GoRoute(
        path: '/app/projects/:projectId/reviews',
        pageBuilder: (context, state) {
          final projectId = state.pathParameters['projectId'] ?? '';
          final projectName = state.extra is String ? state.extra as String : null;
          return _buildPage(
            state,
            AppScaffold(
              title: 'Review queue',
              showBackButton: true,
              showOfflineBanner: false,
              body: ReviewQueueScreen(
                projectId: projectId,
                projectName: projectName,
              ),
            ),
          );
        },
      ),
      GoRoute(
        path: '/app/projects/:projectId/approved-reviews',
        pageBuilder: (context, state) {
          final projectId = state.pathParameters['projectId'] ?? '';
          final projectName = state.extra is String ? state.extra as String : 'Project';
          return _buildPage(
            state,
            AppScaffold(
              title: 'Approved reviews',
              showBackButton: true,
              showOfflineBanner: false,
              body: ProjectApprovedReviewsScreen(
                projectId: projectId,
                projectName: projectName,
                onOpenMap: (item) => context.push(
                  AppRoutes.mapForProject(item.projectId, featureId: item.id),
                ),
                onReject: (item) async {
                  try {
                    await ref
                        .read(reviewRepositoryProvider)
                        .reviewFeature(featureId: item.id, status: 'rejected');
                    ref.read(workflowRefreshTickProvider.notifier).state++;
                    if (context.mounted) {
                      AppSnackbar.showSuccess(
                        context,
                        'Approved review moved to rejected successfully.',
                      );
                    }
                  } catch (error) {
                    if (context.mounted) {
                      AppSnackbar.showError(
                        context,
                        userFacingErrorMessage(
                          error,
                          fallback:
                              'Unable to update this approved review right now.',
                        ),
                      );
                    }
                  }
                },
              ),
            ),
          );
        },
      ),
      GoRoute(
        path: '/app/projects/:projectId/exports',
        pageBuilder: (context, state) {
          final projectId = state.pathParameters['projectId'] ?? '';
          final projectName = state.extra is String ? state.extra as String : null;
          return _buildPage(
            state,
            AppScaffold(
              title: 'Project exports',
              showBackButton: true,
              showOfflineBanner: false,
              body: ExportsDashboardScreen(
                fixedProjectId: projectId,
                fixedProjectName: projectName,
              ),
            ),
          );
        },
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
          final featureId = state.uri.queryParameters['featureId'];
          final startCapture = state.uri.queryParameters['startCapture'] == '1';
          return _buildPage(
            state,
            Scaffold(
              resizeToAvoidBottomInset: false,
              appBar: AppBar(title: const Text('Project map')),
              body: SafeArea(
                child: MapScreen(
                  initialProjectId: projectId,
                  initialFeatureId: featureId,
                  startCaptureOnOpen: startCapture,
                  lockProjectSelection: true,
                ),
              ),
            ),
          );
        },
      ),
      GoRoute(
        path: AppRoutes.addFeature,
        pageBuilder: (_, state) {
          final projectId = state.uri.queryParameters['projectId'];
          final featureId = state.uri.queryParameters['featureId'];
          final captureSeed = state.extra is AddFeatureCaptureSeed
              ? state.extra as AddFeatureCaptureSeed
              : null;
          return _buildPage(
            state,
            AppScaffold(
              title: featureId == null ? 'Add Feature' : 'Edit Draft',
              showBackButton: true,
              showOfflineBanner: false,
              body: AddFeatureScreen(
                initialProjectId: projectId,
                draftFeatureId: featureId,
                captureSeed: captureSeed,
              ),
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
      AppRoutes.categories,
      AppRoutes.adminCreation,
      AppRoutes.contributorRequests,
      AppRoutes.projects,
      AppRoutes.assignments,
      AppRoutes.reviewQueue,
      AppRoutes.exports,
      AppRoutes.notifications,
      AppRoutes.profile,
      '/app/categories/',
      '/app/projects/',
      AppRoutes.addFeature,
    };
  }

  switch (user.role) {
    case UserRole.admin:
      return <String>{
        AppRoutes.projects,
        AppRoutes.categories,
        AppRoutes.contributorRequests,
        AppRoutes.assignments,
        AppRoutes.reviewQueue,
        AppRoutes.exports,
        AppRoutes.notifications,
        AppRoutes.profile,
        '/app/categories/',
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
