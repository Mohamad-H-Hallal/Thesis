import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';
import 'package:lebanese_gis_mobile/features/map/domain/map_feature.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/project.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/projects_repository.dart';
import 'package:lebanese_gis_mobile/features/projects/presentation/screens/home_projects_screen.dart';
import 'package:lebanese_gis_mobile/features/projects/presentation/screens/project_details_screen.dart';

class _NoopAuthRepository implements AuthRepository {
  const _NoopAuthRepository();

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
    required bool rememberMe,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> logout() async {}

  @override
  Future<PasswordResetRequestResult> requestPasswordReset(String email) async {
    return const PasswordResetRequestResult(
      message: 'A verification code has been sent to your email.',
      email: 'viewer@example.com',
    );
  }

  @override
  Future<PasswordResetOtpVerificationResult> verifyPasswordResetOtp({
    required String email,
    required String otp,
  }) async => const PasswordResetOtpVerificationResult(
    message: 'Verification code confirmed.',
    resetToken: 'reset-session-token',
    email: 'viewer@example.com',
  );

  @override
  Future<void> resetPassword({
    required String resetToken,
    required String newPassword,
  }) async {}

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {}

  @override
  Future<AppUser> updateProfile({String? fullName, String? phone}) async {
    return AppUser(
      id: 'user-1',
      fullName: fullName ?? 'viewer user',
      email: 'viewer@example.com',
      role: UserRole.viewer,
      phone: phone,
    );
  }

  @override
  Future<AuthSession> reactivateContributorAndLogin({
    required String email,
    required String password,
    required bool rememberMe,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> selfDeactivate() async {}

  @override
  Future<AuthSession?> restoreSession() async => null;

  @override
  Future<String> signup({
    required String fullName,
    required String email,
    required String password,
    required UserRole role,
    String? phone,
  }) {
    throw UnimplementedError();
  }
}

class _AuthenticatedAuthController extends AuthController {
  _AuthenticatedAuthController(AuthSession session)
    : super(const _NoopAuthRepository()) {
    state = AuthState.authenticated(session);
  }
}

class _FakeProjectsRepository implements ProjectsRepository {
  _FakeProjectsRepository(this._projects);

  List<ProjectSummary> _projects;

  @override
  Future<ProjectSummary?> byId({
    required String id,
    required String userId,
    required UserRole role,
  }) async {
    final scopes = switch (role) {
      UserRole.admin => const <ProjectViewScope>[
        ProjectViewScope.all,
        ProjectViewScope.public,
      ],
      UserRole.viewer => const <ProjectViewScope>[ProjectViewScope.public],
      UserRole.contributor => const <ProjectViewScope>[
        ProjectViewScope.assigned,
        ProjectViewScope.public,
      ],
    };
    for (final scope in scopes) {
      final visibleProjects = await fetchProjects(
        userId: userId,
        role: role,
        scope: scope,
      );
      for (final project in visibleProjects) {
        if (project.id == id) {
          return project;
        }
      }
    }
    return null;
  }

  @override
  Future<List<ProjectSummary>> fetchProjects({
    required String userId,
    required UserRole role,
    required ProjectViewScope scope,
  }) async {
    Iterable<ProjectSummary> filtered = _projects;
    switch (scope) {
      case ProjectViewScope.public:
        filtered = filtered.where(
          (project) =>
              project.visibleToViewers &&
              (project.status == 'active' || project.status == 'completed'),
        );
        break;
      case ProjectViewScope.assigned:
        filtered = filtered.where((project) => project.isAssignedTo(userId));
        break;
      case ProjectViewScope.all:
        break;
    }

    return filtered
        .map((project) => _withAssignment(project, userId: userId))
        .toList(growable: false);
  }

  ProjectSummary _withAssignment(
    ProjectSummary project, {
    required String userId,
  }) {
    ProjectAssignment? assignment;
    for (final item in project.assignments) {
      if (item.userId == userId) {
        assignment = item;
        break;
      }
    }
    return ProjectSummary(
      id: project.id,
      name: project.name,
      category: project.category,
      status: project.status,
      assignedCollectors: project.assignedCollectors,
      pendingReviews: project.pendingReviews,
      description: project.description,
      assignments: project.assignments,
      collectionFormSchema: project.collectionFormSchema,
      requiresPhotos: project.requiresPhotos,
      minPhotos: project.minPhotos,
      maxPhotos: project.maxPhotos,
      allowedGeometryTypes: project.allowedGeometryTypes,
      maxGpsAccuracyMeters: project.maxGpsAccuracyMeters,
      visibleToViewers: project.visibleToViewers,
      currentUserAssignmentRole: assignment?.role,
      currentUserAssignmentStatus: assignment?.status,
    );
  }

  @override
  Future<ProjectSummary> updateViewerVisibility({
    required String projectId,
    required bool visibleToViewers,
  }) async {
    _projects = _projects
        .map((project) {
          if (project.id != projectId) {
            return project;
          }
          return ProjectSummary(
            id: project.id,
            name: project.name,
            category: project.category,
            status: project.status,
            assignedCollectors: project.assignedCollectors,
            pendingReviews: project.pendingReviews,
            description: project.description,
            assignments: project.assignments,
            collectionFormSchema: project.collectionFormSchema,
            requiresPhotos: project.requiresPhotos,
            minPhotos: project.minPhotos,
            maxPhotos: project.maxPhotos,
            allowedGeometryTypes: project.allowedGeometryTypes,
            maxGpsAccuracyMeters: project.maxGpsAccuracyMeters,
            visibleToViewers: visibleToViewers,
          );
        })
        .toList(growable: false);

    return _projects.firstWhere((project) => project.id == projectId);
  }

  @override
  Future<void> requestProjectAccess({required String projectId}) async {}

  @override
  Future<void> cancelProjectAccessRequest({required String projectId}) async {}
}

AuthSession _sessionForRole(UserRole role, {String userId = 'user-1'}) {
  return AuthSession(
    accessToken: 'token-$userId',
    refreshToken: 'refresh-$userId',
    user: AppUser(
      id: userId,
      fullName: '${role.name} user',
      email: '${role.name}@example.com',
      role: role,
    ),
  );
}

ProjectSummary _project({
  required String id,
  required String name,
  bool visibleToViewers = false,
  List<ProjectAssignment> assignments = const <ProjectAssignment>[],
}) {
  return ProjectSummary(
    id: id,
    name: name,
    category: 'Fruit Trees',
    status: 'active',
    assignedCollectors: 1,
    pendingReviews: 0,
    description: '$name description',
    assignments: assignments,
    visibleToViewers: visibleToViewers,
  );
}

Widget _wrapWithScope({
  required AuthSession session,
  required List<ProjectSummary> projects,
  required Widget child,
  _FakeProjectsRepository? repository,
}) {
  final fakeRepository = repository ?? _FakeProjectsRepository(projects);
  return ProviderScope(
    overrides: <Override>[
      authControllerProvider.overrideWith(
        (ref) => _AuthenticatedAuthController(session),
      ),
      projectsRepositoryProvider.overrideWithValue(fakeRepository),
      projectListProvider.overrideWith((ref, scope) {
        ref.watch(workflowRefreshTickProvider);
        return fakeRepository.fetchProjects(
          userId: session.user.id,
          role: session.user.role,
          scope: scope,
        );
      }),
      projectByIdProvider.overrideWith((ref, id) {
        ref.watch(workflowRefreshTickProvider);
        return fakeRepository.byId(
          id: id,
          userId: session.user.id,
          role: session.user.role,
        );
      }),
      projectMapFeaturesProvider.overrideWith(
        (ref, projectId) async => const <MapFeatureSummary>[],
      ),
      offlineMapPackageProvider.overrideWith((ref) async => null),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  testWidgets(
    'viewer public home shows Projects title and viewer-visible data',
    (tester) async {
      final session = _sessionForRole(UserRole.viewer);
      final projects = <ProjectSummary>[
        _project(
          id: 'viewer-project',
          name: 'Published Orchard Survey',
          visibleToViewers: true,
        ),
      ];

      await tester.pumpWidget(
        _wrapWithScope(
          session: session,
          projects: projects,
          child: const HomeProjectsScreen(
            scope: ProjectViewScope.public,
            title: 'Projects',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Projects'), findsOneWidget);
      expect(find.text('Published Orchard Survey'), findsOneWidget);
      expect(find.textContaining('Published:'), findsOneWidget);
    },
  );

  testWidgets(
    'contributor assigned home shows Assigned Projects title and assignment data',
    (tester) async {
      final session = _sessionForRole(
        UserRole.contributor,
        userId: 'contributor-1',
      );
      final projects = <ProjectSummary>[
        _project(
          id: 'assigned-project',
          name: 'Bekaa Collection Campaign',
          assignments: <ProjectAssignment>[
            ProjectAssignment(
              userId: 'contributor-1',
              role: ProjectAssignmentRole.contributor,
              status: ProjectAssignmentStatus.approved,
              assignedAt: DateTime.utc(2026, 3, 14),
            ),
          ],
        ),
      ];

      await tester.pumpWidget(
        _wrapWithScope(
          session: session,
          projects: projects,
          child: const HomeProjectsScreen(
            scope: ProjectViewScope.assigned,
            title: 'Assigned Projects',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Assigned Projects'), findsOneWidget);
      expect(find.text('Bekaa Collection Campaign'), findsOneWidget);
      expect(find.textContaining('Assigned:'), findsOneWidget);
      expect(find.text('Assignment: approved'), findsOneWidget);
    },
  );

  testWidgets(
    'contributor public home shows Projects title and read-only state for public projects',
    (tester) async {
      final session = _sessionForRole(
        UserRole.contributor,
        userId: 'contributor-1',
      );
      final projects = <ProjectSummary>[
        _project(
          id: 'viewer-project',
          name: 'Published Orchard Survey',
          visibleToViewers: true,
        ),
      ];

      await tester.pumpWidget(
        _wrapWithScope(
          session: session,
          projects: projects,
          child: const HomeProjectsScreen(
            scope: ProjectViewScope.public,
            title: 'Projects',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Projects'), findsOneWidget);
      expect(find.text('Read-only public view'), findsOneWidget);
    },
  );

  testWidgets(
    'admin visibility toggle updates project details state after refresh',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final session = _sessionForRole(UserRole.admin, userId: 'admin-1');
      final repository = _FakeProjectsRepository(<ProjectSummary>[
        _project(
          id: 'admin-project',
          name: 'Mount Lebanon Field Survey',
          visibleToViewers: false,
        ),
      ]);

      await tester.pumpWidget(
        _wrapWithScope(
          session: session,
          projects: const <ProjectSummary>[],
          repository: repository,
          child: const ProjectDetailsScreen(projectId: 'admin-project'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Contributor only'), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Project is now visible to viewers.'), findsOneWidget);
      expect(find.text('Viewer visible'), findsOneWidget);
    },
  );

  testWidgets(
    'viewer project details remain read-only without contributor actions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final session = _sessionForRole(UserRole.viewer, userId: 'viewer-1');
      final repository = _FakeProjectsRepository(<ProjectSummary>[
        _project(
          id: 'viewer-project',
          name: 'North Governorate Survey',
          visibleToViewers: true,
        ),
      ]);

      await tester.pumpWidget(
        _wrapWithScope(
          session: session,
          projects: const <ProjectSummary>[],
          repository: repository,
          child: const ProjectDetailsScreen(projectId: 'viewer-project'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Viewer access'), findsOneWidget);
      expect(find.text('Read only'), findsOneWidget);
      expect(find.text('Open Map'), findsNothing);
      expect(find.text('New Feature'), findsNothing);
      expect(find.text('Drafts'), findsNothing);
      expect(find.text('Visible to viewers'), findsNothing);
    },
  );

  testWidgets(
    'project details places the quick map below the main project summary',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final session = _sessionForRole(
        UserRole.contributor,
        userId: 'contributor-1',
      );
      final repository = _FakeProjectsRepository(<ProjectSummary>[
        _project(
          id: 'contributor-project',
          name: 'Bekaa Valley Survey',
          assignments: <ProjectAssignment>[
            ProjectAssignment(
              userId: 'contributor-1',
              role: ProjectAssignmentRole.contributor,
              status: ProjectAssignmentStatus.approved,
              assignedAt: DateTime.utc(2026, 4, 1),
            ),
          ],
        ),
      ]);

      await tester.pumpWidget(
        _wrapWithScope(
          session: session,
          projects: const <ProjectSummary>[],
          repository: repository,
          child: const ProjectDetailsScreen(projectId: 'contributor-project'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final summaryTitleTop = tester.getTopLeft(
        find.text('Bekaa Valley Survey'),
      );
      final quickMapTop = tester.getTopLeft(find.text('Project map'));

      expect(quickMapTop.dy, greaterThan(summaryTitleTop.dy));
      expect(find.text('Map Preview'), findsOneWidget);
      expect(
        find.text(
          'Check the Lebanon workspace before opening the full project map.',
        ),
        findsOneWidget,
      );
      expect(find.text('Open map'), findsOneWidget);
    },
  );
}
