import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/foundation.dart';

import '../config/app_env.dart';
import '../network/api_error_message.dart';
import '../../features/admin/data/api_admin_repository.dart';
import '../../features/admin/domain/admin_models.dart';
import '../../features/admin/domain/admin_repository.dart';
import '../../features/auth/data/fake_auth_repository.dart';
import '../../features/auth/data/real_auth_repository.dart';
import '../../features/auth/domain/auth_models.dart';
import '../../features/auth/domain/auth_repository.dart';
import '../../features/auth/presentation/controllers/auth_controller.dart';
import '../../features/drafts/data/mock_drafts_repository.dart';
import '../../features/drafts/domain/draft_item.dart';
import '../../features/exports/data/api_exports_repository.dart';
import '../../features/exports/data/mock_exports_repository.dart';
import '../../features/exports/domain/export_job.dart';
import '../../features/exports/domain/exports_repository.dart';
import '../../features/exports/presentation/controllers/exports_controller.dart';
import '../../features/imports/data/api_imports_repository.dart';
import '../../features/imports/data/mock_imports_repository.dart';
import '../../features/imports/domain/imports_repository.dart';
import '../../features/map/data/api_feature_workflow_repository.dart';
import '../../features/map/data/api_map_repository.dart';
import '../../features/map/data/device_current_location_service.dart';
import '../../features/map/data/offline_tile_cache_manager.dart';
import '../../features/map/domain/current_location_service.dart';
import '../../features/map/domain/feature_workflow_repository.dart';
import '../../features/map/domain/map_feature.dart';
import '../../features/map/domain/map_geometry.dart';
import '../../features/notifications/data/api_notifications_repository.dart';
import '../../features/notifications/data/mock_notifications_repository.dart';
import '../../features/notifications/data/push_notification_service.dart';
import '../../features/notifications/domain/notifications_repository.dart';
import '../../features/notifications/presentation/controllers/notifications_controller.dart';
import '../../features/projects/data/api_projects_repository.dart';
import '../../features/projects/data/mock_projects_repository.dart';
import '../../features/projects/domain/project.dart';
import '../../features/projects/domain/projects_repository.dart';
import '../../features/review/data/api_review_repository.dart';
import '../../features/review/application/review_workflow_service.dart';
import '../../features/review/domain/review_item.dart';
import '../../features/review/domain/review_repository.dart';
import '../../features/review/domain/review_workflow.dart';
import '../network/api_client.dart';
import '../offline/local_models.dart';
import '../offline/local_store.dart';
import '../offline/local_store_factory.dart';
import '../pagination/paginated_list_controller.dart';
import '../pagination/paginated_result.dart';
import '../router/app_router.dart';
import '../sync/sync_controller.dart';
import '../sync/sync_engine.dart';

final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage();
});

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(storage: ref.watch(secureStorageProvider));
});

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  if (AppEnv.useMockAuth) {
    return FakeAuthRepository(
      ref.watch(secureStorageProvider),
      ref.watch(apiClientProvider),
    );
  }

  return RealAuthRepository(
    ref.watch(secureStorageProvider),
    ref.watch(apiClientProvider),
  );
});

final projectsRepositoryProvider = Provider<ProjectsRepository>((ref) {
  if (AppEnv.useMockData) {
    return MockProjectsRepository();
  }
  return ApiProjectsRepository(ref.watch(apiClientProvider));
});

final mapRepositoryProvider = Provider<ApiMapRepository>((ref) {
  return ApiMapRepository(ref.watch(apiClientProvider));
});

final offlineTileCacheManagerProvider = Provider<OfflineTileCacheManager>((
  ref,
) {
  return OfflineTileCacheManager(localStore: ref.watch(localStoreProvider));
});

final currentLocationServiceProvider = Provider<CurrentLocationService>((ref) {
  return const DeviceCurrentLocationService();
});

final featureWorkflowRepositoryProvider = Provider<FeatureWorkflowRepository>((
  ref,
) {
  return ApiFeatureWorkflowRepository(ref.watch(apiClientProvider));
});

final draftsRepositoryProvider = Provider<MockDraftsRepository>((ref) {
  return MockDraftsRepository();
});

final exportsRepositoryProvider = Provider<ExportsRepository>((ref) {
  if (AppEnv.useMockData) {
    return MockExportsRepository();
  }
  return ApiExportsRepository(ref.watch(apiClientProvider));
});

final importsRepositoryProvider = Provider<ImportsRepository>((ref) {
  if (AppEnv.useMockData) {
    return MockImportsRepository();
  }
  return ApiImportsRepository(ref.watch(apiClientProvider));
});

final notificationsRepositoryProvider = Provider<NotificationsRepository>((
  ref,
) {
  if (AppEnv.useMockData) {
    return MockNotificationsRepository();
  }
  return ApiNotificationsRepository(ref.watch(apiClientProvider));
});

final pushNotificationServiceProvider = Provider<PushNotificationService>((
  ref,
) {
  final service = PushNotificationService(
    repository: ref.watch(notificationsRepositoryProvider),
    storage: ref.watch(secureStorageProvider),
  );
  ref.onDispose(() {
    service.dispose();
  });
  return service;
});

final authControllerProvider = StateNotifierProvider<AuthController, AuthState>(
  (ref) {
    return AuthController(ref.watch(authRepositoryProvider));
  },
);

final workflowRefreshTickProvider = StateProvider<int>((ref) => 0);

void bumpWorkflowRefresh(WidgetRef ref) {
  ref.read(workflowRefreshTickProvider.notifier).state++;
}

final adminRepositoryProvider = Provider<AdminRepository>((ref) {
  return ApiAdminRepository(ref.watch(apiClientProvider));
});

final localStoreProvider = Provider<LocalStore>((ref) {
  final store = createLocalStore();
  ref.onDispose(() {
    store.dispose();
  });
  return store;
});

List<ProjectSummary> _filterCachedProjectsForScope(
  List<ProjectSummary> cachedProjects, {
  required AuthSession session,
  required ProjectViewScope scope,
}) {
  final user = session.user;

  if (user.role == UserRole.admin) {
    return cachedProjects;
  }

  if (user.role == UserRole.viewer) {
    return cachedProjects
        .where((project) => project.visibleToViewers)
        .toList(growable: false);
  }

  final filtered = switch (scope) {
    ProjectViewScope.public => cachedProjects.where(
      (project) => project.visibleToContributors,
    ),
    ProjectViewScope.assigned => cachedProjects.where(
      (project) => project.isAssignedTo(user.id),
    ),
    ProjectViewScope.all => cachedProjects.where(
      (project) =>
          project.visibleToContributors || project.isAssignedTo(user.id),
    ),
  };

  return filtered.toList(growable: false);
}

Future<List<ProjectSummary>> _cachedProjectsForScope(
  Ref ref, {
  required AuthSession session,
  required ProjectViewScope scope,
}) async {
  final localStore = ref.read(localStoreProvider);
  final cachedProjects = await localStore.getCachedProjects();
  return _filterCachedProjectsForScope(
    cachedProjects,
    session: session,
    scope: scope,
  );
}

Future<void> _mergeProjectsIntoCache(
  Ref ref,
  List<ProjectSummary> projects,
) async {
  final localStore = ref.read(localStoreProvider);
  final cachedProjects = await localStore.getCachedProjects();
  final merged = <String, ProjectSummary>{
    for (final project in cachedProjects) project.id: project,
  };
  for (final project in projects) {
    merged[project.id] = project;
  }
  await localStore.cacheProjects(merged.values.toList(growable: false));
}

bool _isOfflineFeatureFetchError(Object error) {
  final message = userFacingErrorMessage(error, fallback: '').toLowerCase();
  return message.contains('unable to reach the server right now') ||
      message.contains('connection') ||
      message.contains('timed out') ||
      message.contains('offline');
}

final offlineBootstrapProvider = FutureProvider<void>((ref) async {
  final localStore = ref.watch(localStoreProvider);
  await localStore.initialize();

  final authState = ref.watch(authControllerProvider);
  final session = authState.session;
  if (session == null) {
    return;
  }

  if (!AppEnv.useMockData) {
    return;
  }

  final seedProjects = await ref
      .read(projectsRepositoryProvider)
      .fetchProjects(
        userId: session.user.id,
        role: session.user.role,
        scope: _defaultOperationalProjectScope(session.user.role),
      );
  final seedDraftItems = await ref.read(draftsRepositoryProvider).fetchDrafts();

  final seedDrafts = seedDraftItems
      .map(
        (item) => LocalDraftFeature(
          id: item.id,
          ownerUserId: session.user.id,
          projectId: 'seed-project',
          projectName: item.projectName,
          geometryType: item.geometryType,
          geometryJson: '{"type":"Point","coordinates":[35.5,33.9]}',
          attributesJson: '{"source":"seed"}',
          photos: const [],
          status: item.status,
          localVersion: 1,
          updatedAt: DateTime.now().subtract(const Duration(hours: 2)),
        ),
      )
      .toList(growable: false);

  await localStore.seedIfEmpty(projects: seedProjects, drafts: seedDrafts);
});

final projectsProvider = FutureProvider<List<ProjectSummary>>((ref) async {
  await ref.watch(offlineBootstrapProvider.future);
  final localStore = ref.watch(localStoreProvider);
  final authState = ref.watch(authControllerProvider);
  final session = authState.session;
  if (session == null) {
    return const <ProjectSummary>[];
  }

  try {
    final remoteProjects = await ref
        .read(projectsRepositoryProvider)
        .fetchProjects(
          userId: session.user.id,
          role: session.user.role,
          scope: _defaultOperationalProjectScope(session.user.role),
        );
    await localStore.cacheProjects(remoteProjects);
    return remoteProjects;
  } catch (_) {
    return localStore.getCachedProjects();
  }
});

final projectListProvider =
    FutureProvider.family<List<ProjectSummary>, ProjectViewScope>((
      ref,
      scope,
    ) async {
      await ref.watch(offlineBootstrapProvider.future);
      ref.watch(workflowRefreshTickProvider);
      final authState = ref.watch(authControllerProvider);
      final session = authState.session;
      if (session == null) {
        return const <ProjectSummary>[];
      }

      final effectiveScope = _effectiveProjectScopeForRole(
        role: session.user.role,
        requestedScope: scope,
      );

      try {
        final projects = await ref
            .read(projectsRepositoryProvider)
            .fetchProjects(
              userId: session.user.id,
              role: session.user.role,
              scope: effectiveScope,
            );
        await _mergeProjectsIntoCache(ref, projects);
        return projects;
      } catch (_) {
        return _cachedProjectsForScope(
          ref,
          session: session,
          scope: effectiveScope,
        );
      }
    });

final mapProjectsProvider = FutureProvider<List<ProjectSummary>>((ref) async {
  await ref.watch(offlineBootstrapProvider.future);
  ref.watch(workflowRefreshTickProvider);
  final localStore = ref.watch(localStoreProvider);
  final authState = ref.watch(authControllerProvider);
  final session = authState.session;
  if (session == null) {
    return const <ProjectSummary>[];
  }

  try {
    if (session.user.role == UserRole.admin) {
      final projects = await ref
          .read(projectsRepositoryProvider)
          .fetchProjects(
            userId: session.user.id,
            role: session.user.role,
            scope: ProjectViewScope.all,
          );
      await localStore.cacheProjects(projects);
      return projects;
    }

    if (session.user.role == UserRole.viewer) {
      final projects = await ref
          .read(projectsRepositoryProvider)
          .fetchProjects(
            userId: session.user.id,
            role: session.user.role,
            scope: ProjectViewScope.public,
          );
      await localStore.cacheProjects(projects);
      return projects;
    }

    final lists = await Future.wait(<Future<List<ProjectSummary>>>[
      ref
          .read(projectsRepositoryProvider)
          .fetchProjects(
            userId: session.user.id,
            role: session.user.role,
            scope: ProjectViewScope.public,
          ),
      ref
          .read(projectsRepositoryProvider)
          .fetchProjects(
            userId: session.user.id,
            role: session.user.role,
            scope: ProjectViewScope.assigned,
          ),
    ]);

    final merged = <String, ProjectSummary>{};
    for (final list in lists) {
      for (final project in list) {
        merged[project.id] = project;
      }
    }

    final projects = merged.values.toList(growable: false);
    await localStore.cacheProjects(projects);
    return projects;
  } catch (_) {
    return _cachedProjectsForScope(
      ref,
      session: session,
      scope: ProjectViewScope.all,
    );
  }
});

final projectMapFeaturesProvider =
    FutureProvider.family<List<MapFeatureSummary>, String>((
      ref,
      projectId,
    ) async {
      ref.watch(workflowRefreshTickProvider);
      if (projectId.isEmpty) {
        return const <MapFeatureSummary>[];
      }
      final localDrafts = await ref.watch(localDraftFeaturesProvider.future);
      final projectDrafts = localDrafts
          .where((draft) => draft.projectId == projectId)
          .toList(growable: false);
      final localFeatures = projectDrafts
          .map(_mapFeatureFromLocalDraft)
          .toList(growable: false);

      try {
        final remoteFeatures = await ref
            .read(mapRepositoryProvider)
            .fetchProjectFeatures(projectId);
        return _mergeProjectFeatures(remoteFeatures, projectDrafts);
      } catch (error) {
        if (localFeatures.isNotEmpty || _isOfflineFeatureFetchError(error)) {
          return localFeatures;
        }
        rethrow;
      }
    });

final projectMapViewportFeaturesProvider = FutureProvider.autoDispose
    .family<List<MapFeatureSummary>, ProjectMapViewportQuery>((ref, query) async {
      final refreshTick = ref.watch(workflowRefreshTickProvider);
      if (query.projectId.isEmpty) {
        return const <MapFeatureSummary>[];
      }
      final localDrafts = await ref.watch(localDraftFeaturesProvider.future);
      final projectDrafts = localDrafts.where((draft) {
        if (draft.projectId != query.projectId) {
          return false;
        }
        final geometry = _decodeJsonMap(draft.geometryJson);
        final points = geometryPoints(geometry);
        return points.any(
          (point) =>
              point.longitude >= query.minLon &&
              point.longitude <= query.maxLon &&
              point.latitude >= query.minLat &&
              point.latitude <= query.maxLat,
        );
      }).toList(growable: false);

      try {
        final remoteFeatures = await ref.read(mapRepositoryProvider).fetchProjectFeaturesViewport(
              projectId: query.projectId,
              minLon: query.minLon,
              minLat: query.minLat,
              maxLon: query.maxLon,
              maxLat: query.maxLat,
              zoom: query.zoom,
              cacheRevision: refreshTick,
            );
        return _mergeProjectFeatures(remoteFeatures, projectDrafts);
      } catch (error) {
        final localFeatures = projectDrafts
            .map(_mapFeatureFromLocalDraft)
            .toList(growable: false);
        if (localFeatures.isNotEmpty || _isOfflineFeatureFetchError(error)) {
          return localFeatures;
        }
        rethrow;
      }
    });

final projectFeatureDetailsProvider =
    FutureProvider.autoDispose.family<MapFeatureSummary, String>((ref, featureId) async {
      ref.watch(workflowRefreshTickProvider);
      return ref.read(mapRepositoryProvider).fetchProjectFeatureById(featureId);
    });

final paginatedProjectFeatureBrowserProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<MapFeatureSummary>,
      AsyncValue<PaginatedListState<MapFeatureSummary>>,
      ProjectFeatureBrowserQuery
    >((ref, query) {
      ref.watch(workflowRefreshTickProvider);
      return PaginatedListController<MapFeatureSummary>(
        loadPage: ({required page, required limit}) {
          return ref.read(mapRepositoryProvider).fetchProjectFeaturesPage(
                projectId: query.projectId,
                search: query.search,
                status: query.status,
                geometryType: query.geometryType,
                featureType: query.featureType,
                excludeImportId: query.excludeImportId,
                page: page,
                limit: limit,
              );
        },
      );
    });

final offlineMapPackageProvider = FutureProvider<OfflineMapPackage?>((
  ref,
) async {
  await ref.watch(offlineBootstrapProvider.future);
  final ownerUserId = ref.watch(
    authControllerProvider.select((state) => state.session?.user.id),
  );
  if (ownerUserId == null || ownerUserId.isEmpty) {
    return null;
  }
  final localStore = ref.watch(localStoreProvider);
  final localPackage = await localStore.getCurrentOfflineMapPackage(
    ownerUserId: ownerUserId,
  );
  try {
    final remotePackage = await ref
        .read(mapRepositoryProvider)
        .fetchCurrentOfflineMapPackage();
    final effectivePackage = _mergeOfflineMapPackage(
      remote: remotePackage,
      local: localPackage,
      ownerUserId: ownerUserId,
    );
    if (effectivePackage != null) {
      await localStore.upsertOfflineMapPackage(effectivePackage);
      return effectivePackage;
    }
  } catch (_) {
    // Fall back to local cached package below.
  }

  return localPackage;
});

final projectByIdProvider = FutureProvider.family<ProjectSummary?, String>((
  ref,
  id,
) async {
  await ref.watch(offlineBootstrapProvider.future);
  ref.watch(workflowRefreshTickProvider);
  final authState = ref.watch(authControllerProvider);
  final session = authState.session;
  if (session == null) {
    return null;
  }

  try {
    final project = await ref
        .read(projectsRepositoryProvider)
        .byId(id: id, userId: session.user.id, role: session.user.role);
    if (project != null) {
      await _mergeProjectsIntoCache(ref, <ProjectSummary>[project]);
    }
    return project;
  } catch (_) {
    final cachedProjects = await _cachedProjectsForScope(
      ref,
      session: session,
      scope: ProjectViewScope.all,
    );
    for (final project in cachedProjects) {
      if (project.id == id) {
        return project;
      }
    }
    return null;
  }
});

final draftsProvider = FutureProvider<List<DraftItem>>((ref) async {
  final localDrafts = await ref.watch(localDraftFeaturesProvider.future);
  return localDrafts
      .map((draft) => draft.toDraftItem())
      .toList(growable: false);
});

final localDraftFeaturesProvider = FutureProvider<List<LocalDraftFeature>>((
  ref,
) async {
  await ref.watch(offlineBootstrapProvider.future);
  final localStore = ref.watch(localStoreProvider);
  final drafts = await localStore.getDrafts();
  final session = ref.watch(authControllerProvider).session;
  if (session == null) {
    return const <LocalDraftFeature>[];
  }
  return drafts
      .where((draft) => draft.ownerUserId == session.user.id)
      .toList(growable: false);
});

final reviewQueueDraftsProvider = FutureProvider<List<LocalDraftFeature>>((
  ref,
) async {
  final drafts = await ref.watch(localDraftFeaturesProvider.future);
  return drafts
      .where((draft) {
        return draft.status == DraftWorkflowStatus.submitted ||
            draft.status == DraftWorkflowStatus.underReview;
      })
      .toList(growable: false);
});

final syncEngineProvider = Provider<SyncEngine>((ref) {
  return SyncEngine(
    localStore: ref.watch(localStoreProvider),
    apiClient: ref.watch(apiClientProvider),
  );
});

final syncControllerProvider = StateNotifierProvider<SyncController, SyncState>(
  (ref) {
    final controller = SyncController(
      syncEngine: ref.watch(syncEngineProvider),
      localStore: ref.watch(localStoreProvider),
    );

    controller.initialize();

    return controller;
  },
);

final pendingSyncCountProvider = Provider<int>((ref) {
  return ref.watch(
    syncControllerProvider.select((state) => state.pendingCount),
  );
});

final notificationsControllerProvider =
    StateNotifierProvider<
      NotificationsController,
      AsyncValue<NotificationsViewState>
    >((ref) {
      final sessionUserId = ref.watch(
        authControllerProvider.select((state) => state.session?.user.id),
      );
      final repository = ref.watch(notificationsRepositoryProvider);
      if (sessionUserId == null || sessionUserId.isEmpty) {
        return NotificationsController.empty(repository);
      }
      return NotificationsController(repository);
    });

final paginatedProjectListProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ProjectSummary>,
      AsyncValue<PaginatedListState<ProjectSummary>>,
      ProjectViewScope
    >((ref, scope) {
      final authState = ref.watch(authControllerProvider);
      final session = authState.session;
      if (session == null) {
        return PaginatedListController<ProjectSummary>(
          loadPage: ({required page, required limit}) async {
            return const PaginatedResult<ProjectSummary>(
              items: <ProjectSummary>[],
              page: 1,
              limit: 20,
              total: 0,
              hasMore: false,
            );
          },
          autoLoad: false,
        );
      }

      ref.watch(workflowRefreshTickProvider);
      final effectiveScope = _effectiveProjectScopeForRole(
        role: session.user.role,
        requestedScope: scope,
      );
      return PaginatedListController<ProjectSummary>(
        loadPage: ({required page, required limit}) async {
          final pageResult = await ref
              .read(projectsRepositoryProvider)
              .fetchProjectsPage(
                userId: session.user.id,
                role: session.user.role,
                scope: effectiveScope,
                page: page,
                limit: limit,
              );
          await _mergeProjectsIntoCache(ref, pageResult.items);
          return pageResult;
        },
      );
    });

final paginatedProjectsProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ProjectSummary>,
      AsyncValue<PaginatedListState<ProjectSummary>>,
      ProjectListQuery
    >((ref, query) {
      final authState = ref.watch(authControllerProvider);
      final session = authState.session;
      if (session == null) {
        return PaginatedListController<ProjectSummary>(
          loadPage: ({required page, required limit}) async {
            return const PaginatedResult<ProjectSummary>(
              items: <ProjectSummary>[],
              page: 1,
              limit: 20,
              total: 0,
              hasMore: false,
            );
          },
          autoLoad: false,
        );
      }

      ref.watch(workflowRefreshTickProvider);
      final effectiveScope = _effectiveProjectScopeForRole(
        role: session.user.role,
        requestedScope: query.scope,
      );
      return PaginatedListController<ProjectSummary>(
        loadPage: ({required page, required limit}) async {
          final pageResult = await ref
              .read(projectsRepositoryProvider)
              .fetchProjectsPage(
                userId: session.user.id,
                role: session.user.role,
                scope: effectiveScope,
                query: query.query,
                status: query.status,
                categoryId: query.categoryId,
                page: page,
                limit: limit,
              );
          await _mergeProjectsIntoCache(ref, pageResult.items);
          return pageResult;
        },
      );
    });

final paginatedManagedUsersProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ManagedUserSummary>,
      AsyncValue<PaginatedListState<ManagedUserSummary>>,
      ManagedUsersQuery
    >((ref, query) {
      ref.watch(authControllerProvider.select((state) => state.session?.user.id));
      ref.watch(workflowRefreshTickProvider);
      return PaginatedListController<ManagedUserSummary>(
        loadPage: ({required page, required limit}) {
          return ref
              .read(adminRepositoryProvider)
              .fetchUsersPage(
                query: query.query,
                role: query.role,
                state: query.state,
                isActive: query.isActive,
                page: page,
                limit: limit,
              );
        },
      );
    });

final paginatedContributorRequestsProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ManagedUserSummary>,
      AsyncValue<PaginatedListState<ManagedUserSummary>>,
      ContributorRequestsQuery
    >((ref, query) {
      ref.watch(authControllerProvider.select((state) => state.session?.user.id));
      ref.watch(workflowRefreshTickProvider);
      return PaginatedListController<ManagedUserSummary>(
        loadPage: ({required page, required limit}) {
          return ref
              .read(adminRepositoryProvider)
              .fetchContributorRequestsPage(
                status: query.status,
                query: query.query,
                page: page,
                limit: limit,
              );
        },
      );
    });

final paginatedManagedAssignmentsProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ManagedAssignmentSummary>,
      AsyncValue<PaginatedListState<ManagedAssignmentSummary>>,
      ManagedAssignmentsQuery
    >((ref, query) {
      ref.watch(authControllerProvider.select((state) => state.session?.user.id));
      ref.watch(workflowRefreshTickProvider);
      return PaginatedListController<ManagedAssignmentSummary>(
        loadPage: ({required page, required limit}) {
          return ref
              .read(adminRepositoryProvider)
              .fetchManagedAssignmentsPage(
                status: query.status,
                query: query.query,
                page: page,
                limit: limit,
              );
        },
      );
    });

final paginatedProjectAssignmentsProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ManagedAssignmentSummary>,
      AsyncValue<PaginatedListState<ManagedAssignmentSummary>>,
      ProjectAssignmentsQuery
    >((ref, query) {
      ref.watch(authControllerProvider.select((state) => state.session?.user.id));
      ref.watch(workflowRefreshTickProvider);
      return PaginatedListController<ManagedAssignmentSummary>(
        loadPage: ({required page, required limit}) {
          return ref
              .read(adminRepositoryProvider)
              .fetchProjectAssignmentsPage(
                projectId: query.projectId,
                status: query.status,
                query: query.query,
                page: page,
                limit: limit,
              );
        },
      );
    });

final paginatedAvailableContributorsProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ManagedUserSummary>,
      AsyncValue<PaginatedListState<ManagedUserSummary>>,
      AvailableContributorsQuery
    >((ref, query) {
      ref.watch(authControllerProvider.select((state) => state.session?.user.id));
      ref.watch(workflowRefreshTickProvider);
      return PaginatedListController<ManagedUserSummary>(
        loadPage: ({required page, required limit}) {
          return ref
              .read(adminRepositoryProvider)
              .fetchAvailableContributorsPage(
                projectId: query.projectId,
                query: query.query,
                page: page,
                limit: limit,
              );
        },
      );
    });

final paginatedProjectCategoriesProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ProjectCategorySummary>,
      AsyncValue<PaginatedListState<ProjectCategorySummary>>,
      ProjectCategoriesQuery
    >((ref, query) {
      ref.watch(authControllerProvider.select((state) => state.session?.user.id));
      ref.watch(workflowRefreshTickProvider);
      return PaginatedListController<ProjectCategorySummary>(
        loadPage: ({required page, required limit}) {
          return ref
              .read(adminRepositoryProvider)
              .fetchCategoriesPage(
                query: query.query,
                page: page,
                limit: limit,
              );
        },
      );
    });

final paginatedReviewQueueProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ReviewQueueItem>,
      AsyncValue<PaginatedListState<ReviewQueueItem>>,
      ReviewQueueQuery
    >((ref, query) {
      ref.watch(authControllerProvider.select((state) => state.session?.user.id));
      ref.watch(workflowRefreshTickProvider);
      return PaginatedListController<ReviewQueueItem>(
        loadPage: ({required page, required limit}) {
          return ref
              .read(reviewRepositoryProvider)
              .fetchReviewItemsPage(
                status: query.status,
                projectId: query.projectId,
                search: query.search,
                page: page,
                limit: limit,
              );
        },
      );
    });

final exportsControllerProvider =
    StateNotifierProvider.autoDispose<ExportsController, ExportsState>((ref) {
      final session = ref.watch(authControllerProvider).session;
      if (session == null) {
        throw StateError(
          'Cannot initialize exports controller without a session.',
        );
      }

      final notifications = ref.read(notificationsControllerProvider.notifier);
      final controller = ExportsController(
        repository: ref.watch(exportsRepositoryProvider),
        session: session,
        emitNotification: ({required String title, required String message}) {
          notifications.pushNotification(title: title, message: message);
        },
      );
      return controller;
    });

final paginatedExportJobsProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ExportJob>,
      AsyncValue<PaginatedListState<ExportJob>>,
      ExportJobsQuery
    >((ref, query) {
      final session = ref.watch(authControllerProvider).session;
      if (session == null) {
        return PaginatedListController<ExportJob>(
          loadPage: ({required page, required limit}) async {
            return const PaginatedResult<ExportJob>(
              items: <ExportJob>[],
              page: 1,
              limit: 20,
              total: 0,
              hasMore: false,
            );
          },
          autoLoad: false,
        );
      }
      ref.watch(workflowRefreshTickProvider);
      return PaginatedListController<ExportJob>(
        loadPage: ({required page, required limit}) {
          return ref.read(exportsRepositoryProvider).fetchJobsPage(
                requestedByUserId: session.user.id,
                categoryId: query.categoryId,
                projectId: query.projectId,
                status: query.status,
                format: query.format,
                page: page,
                limit: limit,
              );
        },
      );
    });

final exportJobsSummaryProvider =
    FutureProvider.family<ExportDashboardMetrics, ExportJobsQuery>((
      ref,
      query,
    ) async {
      final session = ref.watch(authControllerProvider).session;
      if (session == null) {
        return const ExportDashboardMetrics(
          total: 0,
          pending: 0,
          processing: 0,
          completed: 0,
          failed: 0,
        );
      }
      ref.watch(workflowRefreshTickProvider);
      return ref.read(exportsRepositoryProvider).fetchSummary(
            requestedByUserId: session.user.id,
            categoryId: query.categoryId,
            projectId: query.projectId,
            status: query.status,
            format: query.format,
          );
    });

final reviewWorkflowServiceProvider = Provider<ReviewWorkflowService>((ref) {
  final notifications = ref.read(notificationsControllerProvider.notifier);
  return ReviewWorkflowService(
    localStore: ref.watch(localStoreProvider),
    emitNotification: ({required String title, required String message}) {
      notifications.pushNotification(title: title, message: message);
    },
  );
});

final reviewRepositoryProvider = Provider<ReviewRepository>((ref) {
  return ApiReviewRepository(ref.watch(apiClientProvider));
});

class _RouterRefreshNotifier extends ChangeNotifier {
  void refresh() => notifyListeners();
}

final routerRefreshNotifierProvider = Provider<_RouterRefreshNotifier>((ref) {
  final notifier = _RouterRefreshNotifier();
  ref.listen<AuthState>(authControllerProvider, (previous, next) {
    notifier.refresh();
  });
  ref.onDispose(notifier.dispose);
  return notifier;
});

final routerProvider = Provider<GoRouter>((ref) {
  return createRouter(
    ref,
    refreshListenable: ref.watch(routerRefreshNotifierProvider),
  );
});

final adminDashboardProvider = FutureProvider<AdminDashboardSummary>((
  ref,
) async {
  ref.watch(authControllerProvider.select((state) => state.session?.user.id));
  ref.watch(workflowRefreshTickProvider);
  return ref.read(adminRepositoryProvider).fetchDashboardSummary();
});

final contributorRequestsProvider =
    FutureProvider.family<List<ManagedUserSummary>, ContributorRequestStatus>((
      ref,
      status,
    ) async {
      ref.watch(
        authControllerProvider.select((state) => state.session?.user.id),
      );
      ref.watch(workflowRefreshTickProvider);
      return ref
          .read(adminRepositoryProvider)
          .fetchContributorRequests(status: status);
    });

final managedUsersProvider = FutureProvider<List<ManagedUserSummary>>((
  ref,
) async {
  ref.watch(authControllerProvider.select((state) => state.session?.user.id));
  ref.watch(workflowRefreshTickProvider);
  return ref.read(adminRepositoryProvider).fetchUsers();
});

final managedAssignmentsProvider =
    FutureProvider<List<ManagedAssignmentSummary>>((ref) async {
      ref.watch(
        authControllerProvider.select((state) => state.session?.user.id),
      );
      ref.watch(workflowRefreshTickProvider);
      return ref.read(adminRepositoryProvider).fetchManagedAssignments();
    });

final projectCategoriesProvider = FutureProvider<List<ProjectCategorySummary>>((
  ref,
) async {
  ref.watch(authControllerProvider.select((state) => state.session?.user.id));
  ref.watch(workflowRefreshTickProvider);
  return ref.read(adminRepositoryProvider).fetchCategories();
});

final projectAssignmentsProvider =
    FutureProvider.family<List<ManagedAssignmentSummary>, String>((
      ref,
      projectId,
    ) async {
      ref.watch(
        authControllerProvider.select((state) => state.session?.user.id),
      );
      ref.watch(workflowRefreshTickProvider);
      return ref
          .read(adminRepositoryProvider)
          .fetchProjectAssignments(projectId);
    });

final supportSettingsProvider = FutureProvider<SupportContactSettings>((
  ref,
) async {
  ref.watch(authControllerProvider.select((state) => state.session?.user.id));
  ref.watch(workflowRefreshTickProvider);
  return ref.read(adminRepositoryProvider).fetchSupportSettings();
});

final reviewQueueProvider = FutureProvider<List<ReviewQueueItem>>((ref) async {
  ref.watch(authControllerProvider.select((state) => state.session?.user.id));
  ref.watch(workflowRefreshTickProvider);
  return ref
      .read(reviewRepositoryProvider)
      .fetchReviewItems(status: 'pending_review');
});

final rejectedReviewQueueProvider = FutureProvider<List<ReviewQueueItem>>((
  ref,
) async {
  ref.watch(authControllerProvider.select((state) => state.session?.user.id));
  ref.watch(workflowRefreshTickProvider);
  return ref
      .read(reviewRepositoryProvider)
      .fetchReviewItems(status: 'rejected');
});

final projectReviewQueueProvider =
    FutureProvider.family<List<ReviewQueueItem>, String>((
      ref,
      projectId,
    ) async {
      ref.watch(
        authControllerProvider.select((state) => state.session?.user.id),
      );
      ref.watch(workflowRefreshTickProvider);
      if (projectId.trim().isEmpty) {
        return const <ReviewQueueItem>[];
      }
      return ref
          .read(reviewRepositoryProvider)
          .fetchReviewItems(status: 'pending_review', projectId: projectId);
    });

final projectRejectedReviewQueueProvider =
    FutureProvider.family<List<ReviewQueueItem>, String>((
      ref,
      projectId,
    ) async {
      ref.watch(
        authControllerProvider.select((state) => state.session?.user.id),
      );
      ref.watch(workflowRefreshTickProvider);
      if (projectId.trim().isEmpty) {
        return const <ReviewQueueItem>[];
      }
      return ref
          .read(reviewRepositoryProvider)
          .fetchReviewItems(status: 'rejected', projectId: projectId);
    });

final projectApprovedReviewQueueProvider =
    FutureProvider.family<List<ReviewQueueItem>, String>((
      ref,
      projectId,
    ) async {
      ref.watch(
        authControllerProvider.select((state) => state.session?.user.id),
      );
      ref.watch(workflowRefreshTickProvider);
      if (projectId.trim().isEmpty) {
        return const <ReviewQueueItem>[];
      }
      return ref
          .read(reviewRepositoryProvider)
          .fetchReviewItems(status: 'approved', projectId: projectId);
    });

ProjectViewScope _defaultOperationalProjectScope(UserRole role) {
  switch (role) {
    case UserRole.admin:
      return ProjectViewScope.all;
    case UserRole.viewer:
      return ProjectViewScope.public;
    case UserRole.contributor:
      return ProjectViewScope.assigned;
  }
}

ProjectViewScope _effectiveProjectScopeForRole({
  required UserRole role,
  required ProjectViewScope requestedScope,
}) {
  switch (role) {
    case UserRole.admin:
      return requestedScope == ProjectViewScope.assigned
          ? ProjectViewScope.all
          : requestedScope;
    case UserRole.viewer:
      return ProjectViewScope.public;
    case UserRole.contributor:
      return requestedScope == ProjectViewScope.all
          ? ProjectViewScope.assigned
          : requestedScope;
  }
}

MapFeatureSummary _mapFeatureFromLocalDraft(LocalDraftFeature draft) {
  return MapFeatureSummary(
    id: draft.id,
    status: switch (draft.status) {
      'submitted' || 'under_review' => 'pending_review',
      'approved' => 'approved',
      'rejected' => 'rejected',
      _ => 'draft',
    },
    geometry: _decodeJsonMap(draft.geometryJson),
    attributes: _decodeJsonMap(draft.attributesJson),
    collectedAt: draft.updatedAt,
    photoCount: draft.photos.length,
    photos: draft.photos
        .map(
          (photo) => MapFeaturePhoto(
            id: photo.id,
            filePath: photo.filePath,
            takenAt: photo.createdAt,
          ),
        )
        .toList(growable: false),
  );
}

List<MapFeatureSummary> _mergeProjectFeatures(
  List<MapFeatureSummary> remote,
  List<LocalDraftFeature> localDrafts,
) {
  final merged = <String, MapFeatureSummary>{};
  for (final item in remote) {
    merged[item.id] = item;
  }
  for (final draft in localDrafts) {
    final item = _mapFeatureFromLocalDraft(draft);
    if (draft.remoteVersion != null && merged.containsKey(item.id)) {
      continue;
    }
    merged[item.id] = item;
  }
  final values = merged.values.toList(growable: false);
  values.sort((a, b) {
    final left = a.collectedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final right = b.collectedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return right.compareTo(left);
  });
  return values;
}

Map<String, dynamic> _decodeJsonMap(String rawJson) {
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
  } catch (_) {}
  return const <String, dynamic>{};
}

OfflineMapPackage? _mergeOfflineMapPackage({
  required OfflineMapPackage? remote,
  required OfflineMapPackage? local,
  required String ownerUserId,
}) {
  if (remote == null) {
    return local;
  }
  if (local == null || local.version != remote.version) {
    return OfflineMapPackage(
      ownerUserId: ownerUserId,
      version: remote.version,
      zoomLevelMin: remote.zoomLevelMin,
      zoomLevelMax: remote.zoomLevelMax,
      downloadedAt: null,
      lastUpdatedAt: remote.lastUpdatedAt,
      tileCount: 0,
      sizeBytes: 0,
      tileSource: remote.tileSource,
      isCurrent: remote.isCurrent,
    );
  }
  return OfflineMapPackage(
    ownerUserId: ownerUserId,
    version: remote.version,
    zoomLevelMin: remote.zoomLevelMin,
    zoomLevelMax: remote.zoomLevelMax,
    downloadedAt: local.downloadedAt,
    lastUpdatedAt: remote.lastUpdatedAt,
    tileCount: local.tileCount,
    sizeBytes: local.sizeBytes,
    tileSource: remote.tileSource,
    isCurrent: remote.isCurrent,
  );
}
