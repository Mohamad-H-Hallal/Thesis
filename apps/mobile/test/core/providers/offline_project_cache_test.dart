import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store_web.dart';
import 'package:lebanese_gis_mobile/core/pagination/paginated_result.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/project.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/projects_repository.dart';

class _NoopAuthRepository implements AuthRepository {
  const _NoopAuthRepository();

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {}

  @override
  Future<void> logout() async {}

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
    required bool rememberMe,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<PasswordResetRequestResult> requestPasswordReset(String email) async {
    throw UnimplementedError();
  }

  @override
  Future<PasswordResetOtpVerificationResult> verifyPasswordResetOtp({
    required String email,
    required String otp,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> resetPassword({
    required String resetToken,
    required String newPassword,
  }) async {}

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

  @override
  Future<AppUser> updateProfile({String? fullName, String? phone}) async {
    throw UnimplementedError();
  }
}

class _StaticAuthController extends AuthController {
  _StaticAuthController(AuthSession session)
    : super(const _NoopAuthRepository()) {
    state = AuthState.authenticated(session);
  }
}

class _OfflineProjectsRepository implements ProjectsRepository {
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
    throw Exception('offline');
  }

  @override
  Future<ProjectSummary?> byId({
    required String id,
    required String userId,
    required UserRole role,
  }) async {
    throw Exception('offline');
  }

  @override
  Future<List<ProjectSummary>> fetchProjects({
    required String userId,
    required UserRole role,
    required ProjectViewScope scope,
  }) async {
    throw Exception('offline');
  }

  @override
  Future<void> cancelProjectAccessRequest({required String projectId}) async {
    throw UnimplementedError();
  }

  @override
  Future<void> requestProjectAccess({required String projectId}) async {
    throw UnimplementedError();
  }

  @override
  Future<ProjectSummary> updateContributorVisibility({
    required String projectId,
    required bool visibleToContributors,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<ProjectSummary> updateViewerVisibility({
    required String projectId,
    required bool visibleToViewers,
  }) async {
    throw UnimplementedError();
  }
}

class _FlakyProjectsRepository implements ProjectsRepository {
  _FlakyProjectsRepository({
    required this.publicProjects,
    required this.assignedProjects,
  });

  bool online = true;
  final List<ProjectSummary> publicProjects;
  final List<ProjectSummary> assignedProjects;

  @override
  Future<ProjectSummary?> byId({
    required String id,
    required String userId,
    required UserRole role,
  }) async {
    if (!online) {
      throw Exception('offline');
    }
    return <ProjectSummary>[...publicProjects, ...assignedProjects]
        .where((project) => project.id == id)
        .cast<ProjectSummary?>()
        .firstWhere((project) => project != null, orElse: () => null);
  }

  @override
  Future<List<ProjectSummary>> fetchProjects({
    required String userId,
    required UserRole role,
    required ProjectViewScope scope,
  }) async {
    if (!online) {
      throw Exception('offline');
    }
    return switch (scope) {
      ProjectViewScope.public => publicProjects,
      ProjectViewScope.assigned => assignedProjects,
      ProjectViewScope.all => <ProjectSummary>[
        ...publicProjects,
        ...assignedProjects,
      ],
    };
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
    final filtered = items.where((project) {
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
    }).toList(growable: false);
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

  @override
  Future<void> cancelProjectAccessRequest({required String projectId}) async {
    throw UnimplementedError();
  }

  @override
  Future<void> requestProjectAccess({required String projectId}) async {
    throw UnimplementedError();
  }

  @override
  Future<ProjectSummary> updateContributorVisibility({
    required String projectId,
    required bool visibleToContributors,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<ProjectSummary> updateViewerVisibility({
    required String projectId,
    required bool visibleToViewers,
  }) async {
    throw UnimplementedError();
  }
}

AuthSession _session() {
  return AuthSession(
    accessToken: 'token',
    refreshToken: 'refresh',
    user: const AppUser(
      id: 'contributor-1',
      fullName: 'Field Contributor',
      email: 'contributor@example.com',
      role: UserRole.contributor,
    ),
  );
}

ProjectSummary _project({
  required String id,
  required bool visibleToContributors,
  required bool assigned,
}) {
  return ProjectSummary(
    id: id,
    name: 'Project $id',
    category: 'Orchards',
    status: 'active',
    assignedCollectors: assigned ? 1 : 0,
    pendingReviews: 0,
    description: 'Cached project $id',
    visibleToViewers: false,
    visibleToContributors: visibleToContributors,
    currentUserAssignmentStatus: assigned
        ? ProjectAssignmentStatus.approved
        : null,
    currentUserAssignmentRole: assigned
        ? ProjectAssignmentRole.contributor
        : null,
  );
}

ProviderContainer _container({
  required MemoryLocalStore store,
  required ProjectsRepository projectsRepository,
}) {
  return ProviderContainer(
    overrides: <Override>[
      localStoreProvider.overrideWithValue(store),
      projectsRepositoryProvider.overrideWithValue(projectsRepository),
      authControllerProvider.overrideWith(
        (ref) => _StaticAuthController(_session()),
      ),
    ],
  );
}

void main() {
  Future<ProviderContainer> containerWithCache(
    List<ProjectSummary> projects,
  ) async {
    final store = MemoryLocalStore();
    await store.initialize();
    await store.cacheProjects(projects);

    final container = _container(
      store: store,
      projectsRepository: _OfflineProjectsRepository(),
    );
    addTearDown(() async {
      await store.dispose();
      container.dispose();
    });
    return container;
  }

  test(
    'project list falls back to cached contributor public projects while offline',
    () async {
      final container = await containerWithCache(<ProjectSummary>[
        _project(
          id: 'public-project',
          visibleToContributors: true,
          assigned: false,
        ),
        _project(
          id: 'assigned-project',
          visibleToContributors: false,
          assigned: true,
        ),
        _project(
          id: 'hidden-project',
          visibleToContributors: false,
          assigned: false,
        ),
      ]);

      final projects = await container.read(
        projectListProvider(ProjectViewScope.public).future,
      );

      expect(projects.map((item) => item.id), <String>['public-project']);
    },
  );

  test(
    'project list falls back to cached assigned contributor projects while offline',
    () async {
      final container = await containerWithCache(<ProjectSummary>[
        _project(
          id: 'public-project',
          visibleToContributors: true,
          assigned: false,
        ),
        _project(
          id: 'assigned-project',
          visibleToContributors: false,
          assigned: true,
        ),
      ]);

      final projects = await container.read(
        projectListProvider(ProjectViewScope.assigned).future,
      );

      expect(projects.map((item) => item.id), <String>['assigned-project']);
    },
  );

  test(
    'map projects fall back to cached union of contributor public and assigned projects while offline',
    () async {
      final container = await containerWithCache(<ProjectSummary>[
        _project(
          id: 'public-project',
          visibleToContributors: true,
          assigned: false,
        ),
        _project(
          id: 'assigned-project',
          visibleToContributors: false,
          assigned: true,
        ),
        _project(
          id: 'hidden-project',
          visibleToContributors: false,
          assigned: false,
        ),
      ]);

      final projects = await container.read(mapProjectsProvider.future);

      expect(projects.map((item) => item.id).toSet(), <String>{
        'public-project',
        'assigned-project',
      });
    },
  );

  test(
    'project details fall back to cached project by id while offline',
    () async {
      final container = await containerWithCache(<ProjectSummary>[
        _project(
          id: 'public-project',
          visibleToContributors: true,
          assigned: false,
        ),
        _project(
          id: 'assigned-project',
          visibleToContributors: false,
          assigned: true,
        ),
      ]);

      final project = await container.read(
        projectByIdProvider('assigned-project').future,
      );

      expect(project, isNotNull);
      expect(project!.id, 'assigned-project');
    },
  );

  test(
    'project list caches contributor scopes for later offline relaunch',
    () async {
      final store = MemoryLocalStore();
      await store.initialize();
      addTearDown(() async => store.dispose());

      final repository = _FlakyProjectsRepository(
        publicProjects: <ProjectSummary>[
          _project(
            id: 'public-project',
            visibleToContributors: true,
            assigned: false,
          ),
        ],
        assignedProjects: <ProjectSummary>[
          _project(
            id: 'assigned-project',
            visibleToContributors: false,
            assigned: true,
          ),
        ],
      );

      final onlineContainer = _container(
        store: store,
        projectsRepository: repository,
      );
      addTearDown(onlineContainer.dispose);

      await onlineContainer.read(
        projectListProvider(ProjectViewScope.public).future,
      );
      await onlineContainer.read(
        projectListProvider(ProjectViewScope.assigned).future,
      );

      repository.online = false;

      final offlineContainer = _container(
        store: store,
        projectsRepository: repository,
      );
      addTearDown(offlineContainer.dispose);

      final publicProjects = await offlineContainer.read(
        projectListProvider(ProjectViewScope.public).future,
      );
      final assignedProjects = await offlineContainer.read(
        projectListProvider(ProjectViewScope.assigned).future,
      );

      expect(publicProjects.map((item) => item.id), <String>['public-project']);
      expect(assignedProjects.map((item) => item.id), <String>[
        'assigned-project',
      ]);
    },
  );
}
