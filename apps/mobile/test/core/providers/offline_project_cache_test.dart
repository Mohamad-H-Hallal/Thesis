import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/core/network/network_availability_base.dart';
import 'package:lebanese_gis_mobile/core/offline/local_models.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store_web.dart';
import 'package:lebanese_gis_mobile/core/pagination/paginated_list_controller.dart';
import 'package:lebanese_gis_mobile/core/pagination/paginated_result.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';
import 'package:lebanese_gis_mobile/features/map/data/api_map_repository.dart';
import 'package:lebanese_gis_mobile/features/map/data/offline_tile_cache_manager.dart';
import 'package:lebanese_gis_mobile/features/map/domain/map_feature.dart';
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

class _AlwaysOfflineNetworkAvailability implements NetworkAvailabilityService {
  const _AlwaysOfflineNetworkAvailability();

  @override
  Stream<bool> get onOnlineStatusChanged => const Stream<bool>.empty();

  @override
  Future<bool> isOnline() async => false;
}

class _ThrowingMapRepository extends ApiMapRepository {
  _ThrowingMapRepository() : super(ApiClient(dio: Dio()));

  int viewportFetchCount = 0;

  @override
  Future<List<MapFeatureSummary>> fetchProjectFeaturesViewport({
    required String projectId,
    required double minLon,
    required double minLat,
    required double maxLon,
    required double maxLat,
    required double zoom,
    String? featureType,
    int cacheRevision = 0,
  }) async {
    viewportFetchCount += 1;
    throw StateError('backend should not be called while offline');
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
  Future<OfflineProjectPackage> fetchOfflinePackage({
    required String projectId,
    required String ownerUserId,
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

class _CountingOfflineProjectsRepository extends _OfflineProjectsRepository {
  int pageFetchCount = 0;

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
    pageFetchCount += 1;
    return super.fetchProjectsPage(
      userId: userId,
      role: role,
      scope: scope,
      query: query,
      status: status,
      categoryId: categoryId,
      page: page,
      limit: limit,
    );
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

  @override
  Future<OfflineProjectPackage> fetchOfflinePackage({
    required String projectId,
    required String ownerUserId,
  }) async {
    final project = await byId(
      id: projectId,
      userId: ownerUserId,
      role: UserRole.contributor,
    );
    if (project == null) {
      throw StateError('Project not found');
    }
    final now = DateTime.utc(2026, 4, 14, 12);
    return OfflineProjectPackage(
      ownerUserId: ownerUserId,
      project: project,
      packageVersion: 'test-package',
      appResourcesVersion: 'test-app',
      baseMapVersion: 'test-map',
      downloadedAt: now,
      refreshedAt: now,
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

Future<PaginatedListState<ProjectSummary>> _readPaginatedProjects(
  ProviderContainer container,
  ProjectListQuery query,
) async {
  final provider = paginatedProjectsProvider(query);
  final subscription = container
      .listen<AsyncValue<PaginatedListState<ProjectSummary>>>(
        provider,
        (_, _) {},
        fireImmediately: true,
      );
  try {
    for (var attempt = 0; attempt < 50; attempt += 1) {
      final state = subscription.read();
      if (state.hasValue) {
        return state.requireValue;
      }
      if (state.hasError) {
        Error.throwWithStackTrace(state.error!, state.stackTrace!);
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  } finally {
    subscription.close();
  }
  fail('Timed out waiting for paginated projects to load.');
}

void main() {
  Future<ProviderContainer> containerWithCache(
    List<ProjectSummary> projects,
  ) async {
    final store = MemoryLocalStore();
    await store.initialize();
    await store.cacheProjectsForOwner(
      ownerUserId: 'contributor-1',
      projects: projects,
    );

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
    'map projects exclude cached projects that were not explicitly downloaded',
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

      expect(projects, isEmpty);
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

  test(
    'assigned project page uses downloaded packages while offline without api call',
    () async {
      final store = MemoryLocalStore();
      await store.initialize();
      addTearDown(() async => store.dispose());

      final project = _project(
        id: 'downloaded-assigned-project',
        visibleToContributors: false,
        assigned: true,
      );
      final now = DateTime.utc(2026, 4, 14, 12);
      await store.upsertOfflineProjectPackage(
        OfflineProjectPackage(
          ownerUserId: 'contributor-1',
          project: project,
          packageVersion: 'package-v1',
          appResourcesVersion: 'app-v1',
          baseMapVersion: 'base-v1',
          downloadedAt: now,
          refreshedAt: now,
        ),
      );

      final repository = _CountingOfflineProjectsRepository();
      final container = ProviderContainer(
        overrides: <Override>[
          localStoreProvider.overrideWithValue(store),
          projectsRepositoryProvider.overrideWithValue(repository),
          networkAvailabilityServiceProvider.overrideWithValue(
            const _AlwaysOfflineNetworkAvailability(),
          ),
          authControllerProvider.overrideWith(
            (ref) => _StaticAuthController(_session()),
          ),
        ],
      );
      addTearDown(container.dispose);

      final state = await _readPaginatedProjects(
        container,
        const ProjectListQuery(scope: ProjectViewScope.assigned),
      );

      expect(repository.pageFetchCount, 0);
      expect(state.items.map((item) => item.id), <String>[
        'downloaded-assigned-project',
      ]);
    },
  );

  test(
    'project map viewport uses local drafts without backend calls when offline package exists',
    () async {
      final store = MemoryLocalStore();
      await store.initialize();
      addTearDown(() async => store.dispose());

      final project = _project(
        id: 'assigned-project',
        visibleToContributors: false,
        assigned: true,
      );
      final now = DateTime.utc(2026, 4, 14, 12);
      await store.upsertOfflineProjectPackage(
        OfflineProjectPackage(
          ownerUserId: 'contributor-1',
          project: project,
          packageVersion: 'package-v1',
          appResourcesVersion: 'app-v1',
          baseMapVersion: 'base-v1',
          downloadedAt: now,
          refreshedAt: now,
        ),
      );
      await store.upsertDraft(
        LocalDraftFeature(
          id: 'local-draft-1',
          ownerUserId: 'contributor-1',
          projectId: project.id,
          projectName: project.name,
          geometryType: 'Point',
          geometryJson: '{"type":"Point","coordinates":[35.58,33.92]}',
          attributesJson: '{"crop":"olive"}',
          photos: const <DraftPhoto>[],
          status: 'draft',
          localVersion: 1,
          updatedAt: now,
        ),
        enqueueSync: false,
      );

      final mapRepository = _ThrowingMapRepository();
      final container = ProviderContainer(
        overrides: <Override>[
          localStoreProvider.overrideWithValue(store),
          projectsRepositoryProvider.overrideWithValue(
            _OfflineProjectsRepository(),
          ),
          mapRepositoryProvider.overrideWithValue(mapRepository),
          networkAvailabilityServiceProvider.overrideWithValue(
            const _AlwaysOfflineNetworkAvailability(),
          ),
          authControllerProvider.overrideWith(
            (ref) => _StaticAuthController(_session()),
          ),
        ],
      );
      addTearDown(container.dispose);

      final features = await container.read(
        projectMapViewportFeaturesProvider(
          const ProjectMapViewportQuery(
            projectId: 'assigned-project',
            minLon: 35,
            minLat: 33,
            maxLon: 36,
            maxLat: 34,
            zoom: 12,
          ),
        ).future,
      );

      expect(features.map((item) => item.id), <String>['local-draft-1']);
      expect(mapRepository.viewportFetchCount, 0);
    },
  );

  test(
    'offline package delete keeps unsynced contributions on device',
    () async {
      final store = MemoryLocalStore();
      await store.initialize();
      addTearDown(() async => store.dispose());

      final project = _project(
        id: 'assigned-project',
        visibleToContributors: false,
        assigned: true,
      );
      final now = DateTime.utc(2026, 4, 14, 12);
      await store.upsertOfflineProjectPackage(
        OfflineProjectPackage(
          ownerUserId: 'contributor-1',
          project: project,
          packageVersion: 'package-v1',
          appResourcesVersion: 'app-v1',
          baseMapVersion: 'base-v1',
          downloadedAt: now,
          refreshedAt: now,
        ),
      );
      await store.upsertDraft(
        LocalDraftFeature(
          id: 'local-draft-1',
          ownerUserId: 'contributor-1',
          projectId: project.id,
          projectName: project.name,
          geometryType: 'Point',
          geometryJson: '{"type":"Point","coordinates":[35.58,33.92]}',
          attributesJson: '{"crop":"olive"}',
          photos: const <DraftPhoto>[],
          status: 'draft',
          localVersion: 1,
          updatedAt: now,
        ),
      );

      expect(
        await store.countUnsyncedDraftsForProject(
          ownerUserId: 'contributor-1',
          projectId: project.id,
        ),
        1,
      );

      await store.deleteOfflineProjectPackage(
        ownerUserId: 'contributor-1',
        projectId: project.id,
      );

      expect(
        await store.getOfflineProjectPackage(
          ownerUserId: 'contributor-1',
          projectId: project.id,
        ),
        isNull,
      );
      expect(
        await store.countUnsyncedDraftsForProject(
          ownerUserId: 'contributor-1',
          projectId: project.id,
        ),
        1,
      );
    },
  );

  test('downloaded projects can share one base map version', () async {
    final store = MemoryLocalStore();
    await store.initialize();
    addTearDown(() async => store.dispose());

    final now = DateTime.utc(2026, 4, 14, 12);
    for (final projectId in const <String>['project-a', 'project-b']) {
      await store.upsertOfflineProjectPackage(
        OfflineProjectPackage(
          ownerUserId: 'contributor-1',
          project: _project(
            id: projectId,
            visibleToContributors: false,
            assigned: true,
          ),
          packageVersion: 'package-$projectId',
          appResourcesVersion: 'app-v1',
          baseMapVersion: 'base-v1',
          downloadedAt: now,
          refreshedAt: now,
        ),
      );
    }

    expect(
      await store.countOfflineProjectPackagesUsingBaseMap(
        ownerUserId: 'contributor-1',
        baseMapVersion: 'base-v1',
      ),
      2,
    );

    await store.deleteOfflineProjectPackage(
      ownerUserId: 'contributor-1',
      projectId: 'project-a',
    );

    expect(
      await store.countOfflineProjectPackagesUsingBaseMap(
        ownerUserId: 'contributor-1',
        baseMapVersion: 'base-v1',
      ),
      1,
    );
  });

  test('contribution satellite package is capped at zoom 15', () async {
    final store = MemoryLocalStore();
    await store.initialize();
    addTearDown(() async => store.dispose());

    final manager = OfflineTileCacheManager(localStore: store);
    final basePackage = OfflineMapPackage(
      ownerUserId: 'contributor-1',
      version: 'base-v1',
      zoomLevelMin: 7,
      zoomLevelMax: 13,
      lastUpdatedAt: DateTime.utc(2026, 4, 14, 12),
      isCurrent: true,
    );

    final z15Count = manager.expectedLebanonContributionTileCount(
      package: basePackage.copyWith(zoomLevelMax: 15),
    );
    final z18Count = manager.expectedLebanonContributionTileCount(
      package: basePackage.copyWith(zoomLevelMax: 18),
    );

    expect(z18Count, z15Count);
  });
}
