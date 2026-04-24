import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/pagination/paginated_list_controller.dart';
import 'package:lebanese_gis_mobile/core/pagination/paginated_result.dart';
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
              (role == UserRole.viewer
                  ? project.visibleToViewers
                  : project.visibleToContributors) &&
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

  @override
  Future<PaginatedResult<ProjectSummary>> fetchProjectsPage({
    required String userId,
    required UserRole role,
    required ProjectViewScope scope,
    String? query,
    String? status,
    String? categoryId,
    int page = 1,
    int limit = 20,
  }) async {
    final items = await fetchProjects(userId: userId, role: role, scope: scope);
    final filtered = items
        .where((project) {
          if (status?.trim().isNotEmpty ?? false) {
            if (project.status != status) {
              return false;
            }
          }
          if (categoryId?.trim().isNotEmpty ?? false) {
            if (project.categoryId != categoryId) {
              return false;
            }
          }
          if (query?.trim().isNotEmpty ?? false) {
            final normalized = query!.trim().toLowerCase();
            return project.name.toLowerCase().contains(normalized) ||
                project.category.toLowerCase().contains(normalized) ||
                project.description.toLowerCase().contains(normalized);
          }
          return true;
        })
        .toList(growable: false);
    final start = (page - 1) * limit;
    final end = (start + limit).clamp(0, filtered.length);
    return PaginatedResult<ProjectSummary>(
      items: start >= filtered.length
          ? const <ProjectSummary>[]
          : filtered.sublist(start, end),
      page: page,
      limit: limit,
      total: filtered.length,
      hasMore: end < filtered.length,
    );
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
      visibleToContributors: project.visibleToContributors,
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
            visibleToContributors: project.visibleToContributors,
          );
        })
        .toList(growable: false);

    return _projects.firstWhere((project) => project.id == projectId);
  }

  @override
  Future<ProjectSummary> updateContributorVisibility({
    required String projectId,
    required bool visibleToContributors,
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
            visibleToViewers: project.visibleToViewers,
            visibleToContributors: visibleToContributors,
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
  bool visibleToContributors = true,
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
    visibleToContributors: visibleToContributors,
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
      paginatedProjectListProvider.overrideWith((ref, scope) {
        return PaginatedListController<ProjectSummary>(
          loadPage: ({required page, required limit}) {
            return fakeRepository.fetchProjectsPage(
              userId: session.user.id,
              role: session.user.role,
              scope: scope,
              page: page,
              limit: limit,
            );
          },
        );
      }),
      paginatedProjectsProvider.overrideWith((ref, query) {
        return PaginatedListController<ProjectSummary>(
          loadPage: ({required page, required limit}) {
            return fakeRepository.fetchProjectsPage(
              userId: session.user.id,
              role: session.user.role,
              scope: query.scope,
              query: query.query,
              status: query.status,
              categoryId: query.categoryId,
              page: page,
              limit: limit,
            );
          },
        );
      }),
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
    'viewer public home shows viewer-visible data without a duplicate page header',
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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();

      expect(find.text('Search visible projects'), findsOneWidget);
      expect(find.text('Published Orchard Survey'), findsOneWidget);
    },
  );

  testWidgets(
    'contributor assigned home shows assignment data without a duplicate page header',
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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();

      expect(find.text('Search assigned projects'), findsOneWidget);
      expect(find.text('Bekaa Collection Campaign'), findsOneWidget);
      expect(find.text('Assignment: approved'), findsOneWidget);
    },
  );

  testWidgets(
    'contributor public home shows read-only state for public projects without a duplicate page header',
    (tester) async {
      final session = _sessionForRole(
        UserRole.contributor,
        userId: 'contributor-1',
      );
      final projects = <ProjectSummary>[
        _project(
          id: 'contributor-visible-project',
          name: 'Contributor Discovery Survey',
          visibleToViewers: false,
          visibleToContributors: true,
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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();

      expect(find.text('Search visible projects'), findsOneWidget);
      expect(find.text('Contributor Discovery Survey'), findsOneWidget);
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

      expect(find.text('Contributor visible'), findsOneWidget);
      expect(find.text('Visible to contributors'), findsOneWidget);

      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Visible to viewers'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Project is now visible to viewers.'), findsOneWidget);
      expect(find.text('Visible to all'), findsOneWidget);
    },
  );

  testWidgets(
    'admin contributor visibility toggle updates project details state after refresh',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final session = _sessionForRole(UserRole.admin, userId: 'admin-1');
      final repository = _FakeProjectsRepository(<ProjectSummary>[
        _project(
          id: 'admin-project',
          name: 'Mount Lebanon Field Survey',
          visibleToViewers: false,
          visibleToContributors: true,
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

      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Visible to contributors'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        find.text('Project is now hidden from contributor discovery.'),
        findsOneWidget,
      );
      expect(find.text('Restricted'), findsOneWidget);
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
      expect(find.text('Read-only access.'), findsOneWidget);
      expect(find.text('Open Map'), findsOneWidget);
      expect(find.text('New Feature'), findsNothing);
      expect(find.text('Drafts'), findsNothing);
      expect(find.text('Visible to viewers'), findsNothing);
      expect(find.textContaining('Pending reviews:'), findsNothing);
      expect(find.text('Queue'), findsNothing);
    },
  );

  testWidgets('unassigned contributor does not see project imports action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final session = _sessionForRole(
      UserRole.contributor,
      userId: 'contributor-1',
    );
    final repository = _FakeProjectsRepository(<ProjectSummary>[
      _project(
        id: 'contributor-project',
        name: 'North Governorate Survey',
        visibleToContributors: true,
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

    expect(find.text('Open Map'), findsOneWidget);
    expect(find.text('Imports'), findsNothing);
    expect(find.text('New feature'), findsNothing);
    expect(find.text('Request access'), findsOneWidget);
  });

  testWidgets(
    'admin project details groups management and workflow actions clearly',
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

      expect(find.text('Admin tools'), findsOneWidget);
      expect(find.text('Project setup'), findsOneWidget);
      expect(find.text('Review workflows'), findsOneWidget);
      expect(find.text('Edit details'), findsOneWidget);
      expect(find.text('Assignments'), findsOneWidget);
      expect(find.text('Pending review'), findsOneWidget);
      expect(find.text('Approved'), findsOneWidget);
      expect(find.text('Exports'), findsOneWidget);
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
        find.text('Tap the preview to open the full project map.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('project details stays responsive on compact screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final session = _sessionForRole(
      UserRole.contributor,
      userId: 'contributor-1',
    );
    final repository = _FakeProjectsRepository(<ProjectSummary>[
      _project(
        id: 'compact-project',
        name: 'Compact Layout Survey',
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
        child: const ProjectDetailsScreen(projectId: 'compact-project'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.ensureVisible(find.text('Open Map'));

    expect(find.text('Compact Layout Survey'), findsOneWidget);
    expect(find.text('Open Map'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
