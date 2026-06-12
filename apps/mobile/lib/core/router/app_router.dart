import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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
import '../../features/imports/presentation/screens/import_detail_screen.dart';
import '../../features/imports/presentation/screens/import_map_screen.dart';
import '../../features/imports/presentation/screens/imports_screen.dart';
import '../../features/admin/presentation/screens/project_form_screen.dart';
import '../../features/ai/presentation/screens/project_ai_screen.dart';
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

const _selfDeactivatedNotice = 'Your account was deactivated successfully.';
const _accountBlockedNotice = 'Your account has been blocked.';

GoRouter createRouter(Ref ref, {Listenable? refreshListenable}) {
  // On web, project details/map and other pushed routes need real shareable
  // URLs so browser history and hard refresh work as expected.
  GoRouter.optionURLReflectsImperativeAPIs = true;
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
        return isSplash ? null : _splashRedirectFor(state.uri);
      }

      if (!auth.isAuthenticated || user == null) {
        if (auth.errorCode == 'account_blocked') {
          final notice = Uri.encodeComponent(
            auth.error?.trim().isNotEmpty == true
                ? auth.error!.trim()
                : _accountBlockedNotice,
          );
          final target = '${AppRoutes.login}?notice=$notice';
          if (state.uri.toString() == target) {
            return null;
          }
          return target;
        }
        if (auth.errorCode == 'self_deactivated') {
          final notice = Uri.encodeComponent(_selfDeactivatedNotice);
          final target = '${AppRoutes.login}?notice=$notice&success=true';
          if (state.uri.toString() == target) {
            return null;
          }
          return target;
        }
        if (isAuthRoute) {
          return null;
        }
        if (auth.errorCode == 'logged_out') {
          return AppRoutes.login;
        }
        return _loginRedirectFor(state.uri);
      }

      if (isSplash || isAuthRoute || path == AppRoutes.app) {
        return _postAuthRedirectTarget(currentUri: state.uri, user: user);
      }

      final allowedPaths = _allowedPathsForUser(user);
      final isAllowed =
          path == AppRoutes.app ||
          allowedPaths.any((allowedPath) => path.startsWith(allowedPath));
      if (!isAllowed) {
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
        AppRoutes.aiValidation,
        AppRoutes.assignments,
        AppRoutes.reviewQueue,
        AppRoutes.imports,
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
          final projectName = state.extra is String
              ? state.extra as String
              : null;
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
          final projectName = state.extra is String
              ? state.extra as String
              : 'Project';
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
                  AppRoutes.mapForProject(
                    item.projectId,
                    featureId: item.id,
                    focusSource: AppRoutes.focusSourceReviewFeature,
                  ),
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
          final projectName = state.extra is String
              ? state.extra as String
              : null;
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
        path: '/app/projects/:projectId/imports',
        pageBuilder: (context, state) {
          final projectId = state.pathParameters['projectId'] ?? '';
          final projectName = state.extra is String
              ? state.extra as String
              : null;
          return _buildPage(
            state,
            AppScaffold(
              title: 'Project imports',
              showBackButton: true,
              showOfflineBanner: false,
              body: ImportsScreen(
                fixedProjectId: projectId,
                fixedProjectName: projectName,
              ),
            ),
          );
        },
      ),
      GoRoute(
        path: '/app/imports/:importId',
        pageBuilder: (_, state) {
          final importId = state.pathParameters['importId'] ?? '';
          return _buildPage(
            state,
            AppScaffold(
              title: 'Import details',
              showBackButton: true,
              showOfflineBanner: false,
              body: ImportDetailScreen(importId: importId),
            ),
          );
        },
      ),
      GoRoute(
        path: '/app/imports/:importId/map',
        pageBuilder: (_, state) {
          final importId = state.pathParameters['importId'] ?? '';
          final projectId = state.uri.queryParameters['projectId'] ?? '';
          final featureId = state.uri.queryParameters['featureId'];
          final focusSource = state.uri.queryParameters['focusSource'];
          return _buildPage(
            state,
            Scaffold(
              resizeToAvoidBottomInset: false,
              appBar: AppBar(title: const Text('Import map')),
              body: ImportMapScreen(
                importId: importId,
                projectId: projectId,
                initialFeatureId: featureId,
                initialFeatureSource: focusSource,
              ),
            ),
          );
        },
      ),
      GoRoute(
        path: '/app/projects/:projectId/ai/runs/:runId/preview',
        pageBuilder: (_, state) {
          final projectId = state.pathParameters['projectId'] ?? '';
          final runId = state.pathParameters['runId'] ?? '';
          return _buildPage(
            state,
            Scaffold(
              resizeToAvoidBottomInset: false,
              appBar: AppBar(title: const Text('AI preview map')),
              body: ProjectAiPreviewMapScreen(
                projectId: projectId,
                runId: runId,
              ),
            ),
          );
        },
      ),
      GoRoute(
        path: '/app/projects/:projectId/ai',
        pageBuilder: (_, state) {
          final projectId = state.pathParameters['projectId'] ?? '';
          final section = state.uri.queryParameters['section'] ?? 'readiness';
          return _buildPage(
            state,
            AppScaffold(
              title: 'Project AI',
              showBackButton: true,
              showOfflineBanner: false,
              body: ProjectAiScreen(
                projectId: projectId,
                initialSection: section,
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
          final focusSource = state.uri.queryParameters['focusSource'];
          final startCapture = state.uri.queryParameters['startCapture'] == '1';
          return _buildPage(
            state,
            Scaffold(
              resizeToAvoidBottomInset: false,
              appBar: AppBar(title: const Text('Project map')),
              body: MapScreen(
                initialProjectId: projectId,
                initialFeatureId: featureId,
                initialFeatureSource: focusSource,
                startCaptureOnOpen: startCapture,
                lockProjectSelection: true,
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

String _splashRedirectFor(Uri currentUri) {
  final target = _requestedTargetFromUri(currentUri);
  if (target == null) {
    return AppRoutes.splash;
  }
  final splashUri = Uri(
    path: AppRoutes.splash,
    queryParameters: <String, String>{'from': target},
  );
  return splashUri.toString();
}

String _loginRedirectFor(Uri currentUri) {
  final target = _requestedTargetFromUri(currentUri);
  if (target == null) {
    return AppRoutes.login;
  }
  final loginUri = Uri(
    path: AppRoutes.login,
    queryParameters: <String, String>{'from': target},
  );
  return loginUri.toString();
}

String _postAuthRedirectTarget({
  required Uri currentUri,
  required AppUser user,
}) {
  final requested = _requestedTargetFromUri(currentUri);
  if (requested != null && requested.isNotEmpty) {
    final requestedUri = Uri.tryParse(requested);
    if (requestedUri != null) {
      final requestedPath = requestedUri.path;
      final allowedPaths = _allowedPathsForUser(user);
      final isAllowed =
          requestedPath == AppRoutes.app ||
          allowedPaths.any(
            (allowedPath) => requestedPath.startsWith(allowedPath),
          );
      if (isAllowed) {
        return requestedUri.toString();
      }
    }
  }

  if (currentUri.path == AppRoutes.login ||
      currentUri.path == AppRoutes.signup ||
      currentUri.path == AppRoutes.splash ||
      currentUri.path == AppRoutes.forgotPassword ||
      currentUri.path == AppRoutes.resetPassword) {
    return _defaultHomeForUser(user);
  }

  return _defaultHomeForUser(user);
}

String? _requestedTargetFromUri(Uri currentUri) {
  final redirectedTarget = currentUri.queryParameters['from']?.trim();
  if (redirectedTarget != null && redirectedTarget.isNotEmpty) {
    return redirectedTarget;
  }

  final currentPath = currentUri.path;
  if (currentPath == AppRoutes.splash ||
      currentPath == AppRoutes.app ||
      currentPath == AppRoutes.login ||
      currentPath == AppRoutes.signup ||
      currentPath == AppRoutes.forgotPassword ||
      currentPath == AppRoutes.resetPassword) {
    return null;
  }

  final currentTarget = currentUri.toString();
  return currentTarget.isEmpty ? null : currentTarget;
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
      AppRoutes.imports,
      AppRoutes.exports,
      AppRoutes.notifications,
      AppRoutes.profile,
      '/app/imports/',
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
        AppRoutes.imports,
        AppRoutes.exports,
        AppRoutes.notifications,
        AppRoutes.profile,
        '/app/imports/',
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
        AppRoutes.imports,
        AppRoutes.drafts,
        AppRoutes.submissions,
        AppRoutes.aiValidation,
        AppRoutes.notifications,
        AppRoutes.profile,
        '/app/imports/',
        '/app/projects/',
        AppRoutes.addFeature,
      };
  }
}

Page<void> _buildPage(GoRouterState state, Widget child) {
  if (kIsWeb) {
    // Browser route transitions can overlap full-page scrollables/maps long
    // enough to trip transient render/sliver assertions. Keep web swaps direct.
    return NoTransitionPage<void>(key: state.pageKey, child: child);
  }

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
