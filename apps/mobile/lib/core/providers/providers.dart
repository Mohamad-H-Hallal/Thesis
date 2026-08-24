import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/foundation.dart';

import '../config/app_env.dart';
import '../network/api_error_message.dart';
import '../network/network_availability.dart';
import '../network/network_availability_base.dart';
import '../../features/admin/data/api_admin_repository.dart';
import '../../features/admin/domain/admin_models.dart';
import '../../features/admin/domain/admin_repository.dart';
import '../../features/auth/data/fake_auth_repository.dart';
import '../../features/auth/data/real_auth_repository.dart';
import '../../features/auth/data/contact_verification_repository.dart';
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
import '../../features/map/data/offline_project_download_service.dart';
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
import '../offline/local_database_security.dart';
import '../offline/local_models.dart';
import '../offline/local_photo_security.dart';
import '../offline/local_store.dart';
import '../offline/local_store_factory.dart';
import '../pagination/paginated_list_controller.dart';
import '../pagination/paginated_result.dart';
import '../privacy/deleted_account_local_cleanup.dart';
import '../security/secure_string_store.dart';
import '../realtime/workflow_realtime_service.dart';
import '../realtime/realtime_models.dart';
import '../realtime/realtime_edit_guard.dart';
import '../realtime/realtime_scope_registry.dart';
import '../router/app_router.dart';
import '../sync/sync_controller.dart';
import '../sync/sync_engine.dart';

export '../realtime/realtime_models.dart' show RealtimeScope;

final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage(
    aOptions: AndroidOptions(
      resetOnError: false,
      migrateOnAlgorithmChange: true,
      migrateWithBackup: true,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
  );
});

final localDatabaseKeyManagerProvider = Provider<LocalDatabaseKeyManager>((
  ref,
) {
  return LocalDatabaseKeyManager(
    FlutterSecureStringStore(ref.watch(secureStorageProvider)),
  );
});

final localPhotoKeyManagerProvider = Provider<LocalPhotoKeyManager>((ref) {
  return LocalPhotoKeyManager(
    FlutterSecureStringStore(ref.watch(secureStorageProvider)),
  );
});

final Provider<ApiClient> apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(storage: ref.watch(secureStorageProvider));
});

final Provider<void> deletedAccountApiBindingProvider = Provider<void>((ref) {
  final client = ref.watch(apiClientProvider);
  client.onAccountDeleted = (ownerUserId) async {
    try {
      await ref
          .read(deletedAccountLocalCleanupProvider)
          .markAndPurge(ownerUserId);
    } finally {
      await ref
          .read(authControllerProvider.notifier)
          .forceLogout(
            message: 'Your TerraLeb account has been deleted.',
            code: 'account_deleted',
          );
    }
  };
  ref.onDispose(() => client.onAccountDeleted = null);
});

final networkAvailabilityServiceProvider = Provider<NetworkAvailabilityService>(
  (ref) => createNetworkAvailabilityService(),
);

final networkOnlineProvider = StreamProvider<bool>((ref) async* {
  final service = ref.watch(networkAvailabilityServiceProvider);
  yield await service.isOnline();
  yield* service.onOnlineStatusChanged;
});

final Provider<AuthRepository> authRepositoryProvider =
    Provider<AuthRepository>((ref) {
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

final contactVerificationRepositoryProvider =
    Provider<ContactVerificationRepository>((ref) {
      return ContactVerificationRepository(
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

final offlineProjectDownloadServiceProvider =
    Provider<OfflineProjectDownloadService>((ref) {
      return OfflineProjectDownloadService(
        projectsRepository: ref.watch(projectsRepositoryProvider),
        localStore: ref.watch(localStoreProvider),
        tileCacheManager: ref.watch(offlineTileCacheManagerProvider),
        networkAvailability: ref.watch(networkAvailabilityServiceProvider),
      );
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

final exportCollectorsProvider = FutureProvider.autoDispose
    .family<List<ExportCollector>, String>((ref, projectId) async {
      if (projectId.trim().isEmpty) {
        return const <ExportCollector>[];
      }
      return ref
          .watch(exportsRepositoryProvider)
          .fetchProjectCollectors(projectId: projectId);
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

final StateNotifierProvider<AuthController, AuthState> authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((ref) {
      return AuthController(ref.watch(authRepositoryProvider));
    });

final localDataRevisionProvider = StateProvider<int>((ref) => 0);

final realtimeScopeRegistryProvider = Provider<RealtimeScopeRegistry>((ref) {
  final registry = RealtimeScopeRegistry();
  ref.onDispose(() => unawaited(registry.dispose()));
  return registry;
});

final realtimeScopeRevisionProvider = StateProvider.family<int, RealtimeScope>(
  (ref, scope) => 0,
);

final realtimeConnectionStateProvider = StateProvider<RealtimeConnectionState>(
  (ref) => RealtimeConnectionState.disconnected,
);

final realtimeEditGuardRegistryProvider = Provider<RealtimeEditGuardRegistry>(
  (ref) => RealtimeEditGuardRegistry(),
);

void registerRealtimeScope(Ref ref, RealtimeScope scope) {
  final registry = ref.read(realtimeScopeRegistryProvider);
  registry.register(scope);
  ref.onDispose(() => registry.unregister(scope));
}

void watchRealtimeScope(Ref ref, RealtimeScope scope) {
  registerRealtimeScope(ref, scope);
  ref.watch(realtimeScopeRevisionProvider(scope));
}

void listenRealtimeScope(
  Ref ref,
  RealtimeScope scope,
  void Function() onChanged,
) {
  registerRealtimeScope(ref, scope);
  ref.listen<int>(realtimeScopeRevisionProvider(scope), (_, _) => onChanged());
}

PaginatedListController<T> bindRealtimePaginated<T>(
  Ref ref,
  RealtimeScope scope,
  PaginatedListController<T> controller,
) {
  listenRealtimeScope(ref, scope, () {
    unawaited(controller.refreshSilently());
  });
  return controller;
}

void bumpRealtimeScope(WidgetRef ref, RealtimeScope scope) {
  ref.read(realtimeScopeRevisionProvider(scope).notifier).state++;
}

final workflowRealtimeServiceProvider = Provider<WorkflowRealtimeService>((
  ref,
) {
  final service = WorkflowRealtimeService();
  ref.onDispose(service.dispose);
  return service;
});

final adminRepositoryProvider = Provider<AdminRepository>((ref) {
  return ApiAdminRepository(ref.watch(apiClientProvider));
});

final localStoreProvider = Provider<LocalStore>((ref) {
  final store = createLocalStore(
    databaseKeyManager: ref.watch(localDatabaseKeyManagerProvider),
    photoKeyManager: ref.watch(localPhotoKeyManagerProvider),
  );
  ref.onDispose(() {
    store.dispose();
  });
  return store;
});

final deletedAccountLocalCleanupProvider = Provider<DeletedAccountLocalCleanup>(
  (ref) => DeletedAccountLocalCleanup(
    storage: ref.watch(secureStorageProvider),
    localStore: ref.watch(localStoreProvider),
  ),
);

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

Future<List<ProjectSummary>> _localProjectsForScope(
  Ref ref, {
  required AuthSession session,
  required ProjectViewScope scope,
}) async {
  final localStore = ref.read(localStoreProvider);
  final cachedProjects = await localStore.getCachedProjectsForOwner(
    ownerUserId: session.user.id,
  );
  final downloadedPackages = await localStore.getOfflineProjectPackages(
    ownerUserId: session.user.id,
  );
  final downloadedProjects = downloadedPackages
      .map((package) => package.project)
      .toList(growable: false);

  final merged = <String, ProjectSummary>{
    for (final project in cachedProjects) project.id: project,
    for (final project in downloadedProjects) project.id: project,
  };

  return _filterCachedProjectsForScope(
    merged.values.toList(growable: false),
    session: session,
    scope: scope,
  );
}

Future<List<ProjectSummary>> _downloadedProjectsForScope(
  Ref ref, {
  required AuthSession session,
  required ProjectViewScope scope,
}) async {
  final packages = await ref
      .read(localStoreProvider)
      .getOfflineProjectPackages(ownerUserId: session.user.id);
  return _filterCachedProjectsForScope(
    packages.map((package) => package.project).toList(growable: false),
    session: session,
    scope: scope,
  );
}

List<ProjectSummary> _filterLocalProjectsForQuery(
  List<ProjectSummary> projects, {
  String? query,
  String? status,
  String? categoryId,
}) {
  final normalizedQuery = query?.trim().toLowerCase();
  final normalizedStatus = status?.trim();
  final normalizedCategoryId = categoryId?.trim();

  return projects
      .where((project) {
        if (normalizedStatus != null && normalizedStatus.isNotEmpty) {
          if (project.status != normalizedStatus) {
            return false;
          }
        }

        if (normalizedCategoryId != null && normalizedCategoryId.isNotEmpty) {
          if (project.categoryId != normalizedCategoryId) {
            return false;
          }
        }

        if (normalizedQuery != null && normalizedQuery.isNotEmpty) {
          return project.name.toLowerCase().contains(normalizedQuery) ||
              project.category.toLowerCase().contains(normalizedQuery) ||
              project.description.toLowerCase().contains(normalizedQuery);
        }

        return true;
      })
      .toList(growable: false);
}

PaginatedResult<ProjectSummary> _paginateLocalProjects(
  List<ProjectSummary> projects, {
  required int page,
  required int limit,
}) {
  final safePage = page < 1 ? 1 : page;
  final safeLimit = limit < 1 ? 20 : limit;
  final start = (safePage - 1) * safeLimit;
  final endCandidate = start + safeLimit;
  final end = endCandidate > projects.length ? projects.length : endCandidate;

  return PaginatedResult<ProjectSummary>(
    items: start >= projects.length
        ? const <ProjectSummary>[]
        : projects.sublist(start, end),
    page: safePage,
    limit: safeLimit,
    total: projects.length,
    hasMore: end < projects.length,
  );
}

Future<PaginatedResult<ProjectSummary>> _localProjectsPageForScope(
  Ref ref, {
  required AuthSession session,
  required ProjectViewScope scope,
  String? query,
  String? status,
  String? categoryId,
  required int page,
  required int limit,
}) async {
  final projects = await _localProjectsForScope(
    ref,
    session: session,
    scope: scope,
  );
  final filtered = _filterLocalProjectsForQuery(
    projects,
    query: query,
    status: status,
    categoryId: categoryId,
  );
  return _paginateLocalProjects(filtered, page: page, limit: limit);
}

Future<void> _mergeProjectsIntoCache(
  Ref ref,
  List<ProjectSummary> projects,
) async {
  final localStore = ref.read(localStoreProvider);
  final session = ref.read(authControllerProvider).session;
  if (session == null) {
    return;
  }
  final cachedProjects = await localStore.getCachedProjectsForOwner(
    ownerUserId: session.user.id,
  );
  final merged = <String, ProjectSummary>{
    for (final project in cachedProjects) project.id: project,
  };
  for (final project in projects) {
    merged[project.id] = project;
  }
  await localStore.cacheProjectsForOwner(
    ownerUserId: session.user.id,
    projects: merged.values.toList(growable: false),
  );
}

bool _isOfflineFeatureFetchError(Object error) {
  final message = userFacingErrorMessage(error, fallback: '').toLowerCase();
  return message.contains('unable to reach the server right now') ||
      message.contains('connection') ||
      message.contains('timed out') ||
      message.contains('offline');
}

Future<bool> _shouldUseOfflineProjectOnly(Ref ref, String projectId) async {
  final session = ref.read(authControllerProvider).session;
  if (session == null || projectId.trim().isEmpty) {
    return false;
  }
  final isOnline = await ref
      .read(networkAvailabilityServiceProvider)
      .isOnline();
  if (isOnline) {
    return false;
  }
  final package = await ref
      .read(localStoreProvider)
      .getOfflineProjectPackage(
        ownerUserId: session.user.id,
        projectId: projectId,
      );
  if (package == null) {
    throw StateError(
      'This project is not downloaded for offline use. Connect to the internet and download it first.',
    );
  }
  return true;
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
    await localStore.cacheProjectsForOwner(
      ownerUserId: session.user.id,
      projects: remoteProjects,
    );
    return remoteProjects;
  } catch (_) {
    return _localProjectsForScope(
      ref,
      session: session,
      scope: _defaultOperationalProjectScope(session.user.role),
    );
  }
});

final projectListProvider =
    FutureProvider.family<List<ProjectSummary>, ProjectViewScope>((
      ref,
      scope,
    ) async {
      await ref.watch(offlineBootstrapProvider.future);
      watchRealtimeScope(ref, const RealtimeScope('projects', 'all'));
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
        return _localProjectsForScope(
          ref,
          session: session,
          scope: effectiveScope,
        );
      }
    });

final mapProjectsProvider = FutureProvider<List<ProjectSummary>>((ref) async {
  await ref.watch(offlineBootstrapProvider.future);
  watchRealtimeScope(ref, const RealtimeScope('projects', 'all'));
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
      await localStore.cacheProjectsForOwner(
        ownerUserId: session.user.id,
        projects: projects,
      );
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
      await localStore.cacheProjectsForOwner(
        ownerUserId: session.user.id,
        projects: projects,
      );
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
    await localStore.cacheProjectsForOwner(
      ownerUserId: session.user.id,
      projects: projects,
    );
    return projects;
  } catch (_) {
    if (session.user.role == UserRole.contributor) {
      return _downloadedProjectsForScope(
        ref,
        session: session,
        scope: ProjectViewScope.assigned,
      );
    }
    return _localProjectsForScope(
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
      watchRealtimeScope(ref, RealtimeScope('features', projectId));
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

      final shouldUseOfflineOnly = await _shouldUseOfflineProjectOnly(
        ref,
        projectId,
      );
      if (shouldUseOfflineOnly) {
        return localFeatures;
      }

      try {
        final remoteFeatures = await ref
            .read(mapRepositoryProvider)
            .fetchProjectFeatures(projectId);
        return _mergeProjectFeatures(projectId, remoteFeatures, projectDrafts);
      } catch (error) {
        if (localFeatures.isNotEmpty || _isOfflineFeatureFetchError(error)) {
          return localFeatures;
        }
        rethrow;
      }
    });

final projectMapViewportFeaturesProvider = FutureProvider.autoDispose
    .family<List<MapFeatureSummary>, ProjectMapViewportQuery>((
      ref,
      query,
    ) async {
      final refreshScope = RealtimeScope('features', query.projectId);
      watchRealtimeScope(ref, refreshScope);
      final refreshTick = ref.watch(
        realtimeScopeRevisionProvider(refreshScope),
      );
      if (query.projectId.isEmpty) {
        return const <MapFeatureSummary>[];
      }
      final localDrafts = await ref.watch(localDraftFeaturesProvider.future);
      final projectDrafts = localDrafts
          .where((draft) {
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
          })
          .toList(growable: false);

      final shouldUseOfflineOnly = await _shouldUseOfflineProjectOnly(
        ref,
        query.projectId,
      );
      if (shouldUseOfflineOnly) {
        return projectDrafts
            .map(_mapFeatureFromLocalDraft)
            .toList(growable: false);
      }

      try {
        final remoteFeatures = await ref
            .read(mapRepositoryProvider)
            .fetchProjectFeaturesViewport(
              projectId: query.projectId,
              minLon: query.minLon,
              minLat: query.minLat,
              maxLon: query.maxLon,
              maxLat: query.maxLat,
              zoom: query.zoom,
              featureType: query.featureType,
              cacheRevision: refreshTick,
            );
        return _mergeProjectFeatures(
          query.projectId,
          remoteFeatures,
          projectDrafts,
        );
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

final projectFeatureCountProvider = FutureProvider.autoDispose
    .family<int, ProjectFeatureCountQuery>((ref, query) async {
      watchRealtimeScope(ref, RealtimeScope('features', query.projectId));
      if (query.projectId.isEmpty) {
        return 0;
      }

      final localDrafts = await ref.watch(localDraftFeaturesProvider.future);
      final includeLocalDrafts =
          query.statuses == null || query.statuses!.contains('draft');
      final localDraftCount = includeLocalDrafts
          ? localDrafts
                .where((draft) => draft.projectId == query.projectId)
                .length
          : 0;

      final shouldUseOfflineOnly = await _shouldUseOfflineProjectOnly(
        ref,
        query.projectId,
      );
      if (shouldUseOfflineOnly) {
        return localDraftCount;
      }

      final statuses = query.statuses
          ?.where((status) => status.trim().isNotEmpty)
          .map((status) => status.trim())
          .toSet()
          .toList(growable: false);
      if (statuses != null && statuses.isEmpty) {
        return localDraftCount;
      }

      final repository = ref.read(mapRepositoryProvider);
      if (statuses == null) {
        final total = await repository.fetchProjectFeaturesCount(
          projectId: query.projectId,
          search: query.search,
          geometryType: query.geometryType,
          featureType: query.featureType,
          excludeImportId: query.excludeImportId,
        );
        return total + localDraftCount;
      }

      final totals = await Future.wait(
        statuses.map(
          (status) => repository.fetchProjectFeaturesCount(
            projectId: query.projectId,
            search: query.search,
            status: status,
            geometryType: query.geometryType,
            featureType: query.featureType,
            excludeImportId: query.excludeImportId,
          ),
        ),
      );
      return totals.fold<int>(localDraftCount, (total, value) => total + value);
    });

final projectFeatureDetailsProvider = FutureProvider.autoDispose
    .family<MapFeatureSummary, ProjectFeatureIdentity>((ref, identity) async {
      watchRealtimeScope(ref, RealtimeScope('feature', identity.featureId));
      return ref
          .read(mapRepositoryProvider)
          .fetchProjectFeatureById(
            projectId: identity.projectId,
            featureId: identity.featureId,
          );
    });

final paginatedProjectFeatureBrowserProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<MapFeatureSummary>,
      AsyncValue<PaginatedListState<MapFeatureSummary>>,
      ProjectFeatureBrowserQuery
    >((ref, query) {
      final scope = RealtimeScope('features', query.projectId);
      return bindRealtimePaginated(
        ref,
        scope,
        PaginatedListController<MapFeatureSummary>(
          loadPage: ({required page, required limit}) async {
            final shouldUseOfflineOnly = await _shouldUseOfflineProjectOnly(
              ref,
              query.projectId,
            );
            if (shouldUseOfflineOnly) {
              final drafts = await ref.read(localDraftFeaturesProvider.future);
              final items = drafts
                  .where((draft) => draft.projectId == query.projectId)
                  .map(_mapFeatureFromLocalDraft)
                  .where((feature) {
                    final status = query.status?.trim();
                    if (status != null &&
                        status.isNotEmpty &&
                        feature.status != status) {
                      return false;
                    }
                    final geometryType = query.geometryType?.trim();
                    if (geometryType != null && geometryType.isNotEmpty) {
                      final actual =
                          feature.sourceGeometryType ??
                          feature.geometry['type']?.toString() ??
                          '';
                      if (actual.toLowerCase() != geometryType.toLowerCase()) {
                        return false;
                      }
                    }
                    return true;
                  })
                  .toList(growable: false);
              final start = (page - 1) * limit;
              final end = (start + limit).clamp(0, items.length);
              return PaginatedResult<MapFeatureSummary>(
                items: start >= items.length
                    ? const <MapFeatureSummary>[]
                    : items.sublist(start, end),
                page: page,
                limit: limit,
                total: items.length,
                hasMore: end < items.length,
              );
            }

            return ref
                .read(mapRepositoryProvider)
                .fetchProjectFeaturesPage(
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
        ),
      );
    });

final offlineMapPackageProvider = FutureProvider<OfflineMapPackage?>((
  ref,
) async {
  await ref.watch(offlineBootstrapProvider.future);
  watchRealtimeScope(ref, const RealtimeScope('offline_map', 'all'));
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
  final isOnline = await ref
      .read(networkAvailabilityServiceProvider)
      .isOnline();
  if (!isOnline) {
    return localPackage;
  }
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

final offlineProjectPackageProvider =
    FutureProvider.family<OfflineProjectPackage?, String>((
      ref,
      projectId,
    ) async {
      await ref.watch(offlineBootstrapProvider.future);
      final ownerUserId = ref.watch(
        authControllerProvider.select((state) => state.session?.user.id),
      );
      if (ownerUserId == null || ownerUserId.isEmpty || projectId.isEmpty) {
        return null;
      }
      return ref
          .watch(localStoreProvider)
          .getOfflineProjectPackage(
            ownerUserId: ownerUserId,
            projectId: projectId,
          );
    });

final offlineProjectPackagesProvider =
    FutureProvider<List<OfflineProjectPackage>>((ref) async {
      await ref.watch(offlineBootstrapProvider.future);
      final ownerUserId = ref.watch(
        authControllerProvider.select((state) => state.session?.user.id),
      );
      if (ownerUserId == null || ownerUserId.isEmpty) {
        return const <OfflineProjectPackage>[];
      }
      return ref
          .watch(localStoreProvider)
          .getOfflineProjectPackages(ownerUserId: ownerUserId);
    });

final projectByIdProvider = FutureProvider.family<ProjectSummary?, String>((
  ref,
  id,
) async {
  await ref.watch(offlineBootstrapProvider.future);
  watchRealtimeScope(ref, RealtimeScope('project', id));
  final authState = ref.watch(authControllerProvider);
  final session = authState.session;
  if (session == null) {
    return null;
  }

  final isOnline = await ref
      .read(networkAvailabilityServiceProvider)
      .isOnline();
  if (!isOnline) {
    final offlinePackage = await ref
        .read(localStoreProvider)
        .getOfflineProjectPackage(ownerUserId: session.user.id, projectId: id);
    if (offlinePackage != null) {
      return offlinePackage.project;
    }
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
    final offlinePackage = await ref
        .read(localStoreProvider)
        .getOfflineProjectPackage(ownerUserId: session.user.id, projectId: id);
    if (offlinePackage != null) {
      return offlinePackage.project;
    }

    final cachedProjects = await _localProjectsForScope(
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
  ref.watch(localDataRevisionProvider);
  final localStore = ref.watch(localStoreProvider);
  final session = ref.watch(authControllerProvider).session;
  if (session == null) {
    return const <LocalDraftFeature>[];
  }
  return localStore.getDraftsForOwner(ownerUserId: session.user.id);
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
  final ownerUserId = ref.watch(
    authControllerProvider.select((state) => state.session?.user.id ?? ''),
  );
  return SyncEngine(
    localStore: ref.watch(localStoreProvider),
    apiClient: ref.watch(apiClientProvider),
    ownerUserId: ownerUserId,
  );
});

final syncControllerProvider = StateNotifierProvider<SyncController, SyncState>(
  (ref) {
    final ownerUserId = ref.watch(
      authControllerProvider.select((state) => state.session?.user.id ?? ''),
    );
    final controller = SyncController(
      syncEngine: ref.watch(syncEngineProvider),
      localStore: ref.watch(localStoreProvider),
      networkAvailability: ref.watch(networkAvailabilityServiceProvider),
      ownerUserId: ownerUserId,
      onLocalDataChanged: () {
        ref.read(localDataRevisionProvider.notifier).state++;
      },
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

      const realtimeScope = RealtimeScope('projects', 'all');
      final effectiveScope = _effectiveProjectScopeForRole(
        role: session.user.role,
        requestedScope: scope,
      );
      return bindRealtimePaginated(
        ref,
        realtimeScope,
        PaginatedListController<ProjectSummary>(
          loadPage: ({required page, required limit}) async {
            final isOnline = await ref
                .read(networkAvailabilityServiceProvider)
                .isOnline();
            if (!isOnline) {
              return _localProjectsPageForScope(
                ref,
                session: session,
                scope: effectiveScope,
                page: page,
                limit: limit,
              );
            }

            try {
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
            } catch (error) {
              if (!_isOfflineFeatureFetchError(error)) {
                rethrow;
              }
              return _localProjectsPageForScope(
                ref,
                session: session,
                scope: effectiveScope,
                page: page,
                limit: limit,
              );
            }
          },
        ),
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

      const realtimeScope = RealtimeScope('projects', 'all');
      final effectiveScope = _effectiveProjectScopeForRole(
        role: session.user.role,
        requestedScope: query.scope,
      );
      return bindRealtimePaginated(
        ref,
        realtimeScope,
        PaginatedListController<ProjectSummary>(
          loadPage: ({required page, required limit}) async {
            final isOnline = await ref
                .read(networkAvailabilityServiceProvider)
                .isOnline();
            if (!isOnline) {
              return _localProjectsPageForScope(
                ref,
                session: session,
                scope: effectiveScope,
                query: query.query,
                status: query.status,
                categoryId: query.categoryId,
                page: page,
                limit: limit,
              );
            }

            try {
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
            } catch (error) {
              if (!_isOfflineFeatureFetchError(error)) {
                rethrow;
              }
              return _localProjectsPageForScope(
                ref,
                session: session,
                scope: effectiveScope,
                query: query.query,
                status: query.status,
                categoryId: query.categoryId,
                page: page,
                limit: limit,
              );
            }
          },
        ),
      );
    });

final paginatedManagedUsersProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ManagedUserSummary>,
      AsyncValue<PaginatedListState<ManagedUserSummary>>,
      ManagedUsersQuery
    >((ref, query) {
      ref.watch(
        authControllerProvider.select((state) => state.session?.user.id),
      );
      const scope = RealtimeScope('users', 'all');
      return bindRealtimePaginated(
        ref,
        scope,
        PaginatedListController<ManagedUserSummary>(
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
        ),
      );
    });

final paginatedContributorRequestsProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ManagedUserSummary>,
      AsyncValue<PaginatedListState<ManagedUserSummary>>,
      ContributorRequestsQuery
    >((ref, query) {
      ref.watch(
        authControllerProvider.select((state) => state.session?.user.id),
      );
      const scope = RealtimeScope('users', 'all');
      return bindRealtimePaginated(
        ref,
        scope,
        PaginatedListController<ManagedUserSummary>(
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
        ),
      );
    });

final paginatedManagedAssignmentsProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ManagedAssignmentSummary>,
      AsyncValue<PaginatedListState<ManagedAssignmentSummary>>,
      ManagedAssignmentsQuery
    >((ref, query) {
      ref.watch(
        authControllerProvider.select((state) => state.session?.user.id),
      );
      const scope = RealtimeScope('assignments', 'all');
      return bindRealtimePaginated(
        ref,
        scope,
        PaginatedListController<ManagedAssignmentSummary>(
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
        ),
      );
    });

final paginatedProjectAssignmentsProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ManagedAssignmentSummary>,
      AsyncValue<PaginatedListState<ManagedAssignmentSummary>>,
      ProjectAssignmentsQuery
    >((ref, query) {
      ref.watch(
        authControllerProvider.select((state) => state.session?.user.id),
      );
      final scope = RealtimeScope('project', query.projectId);
      return bindRealtimePaginated(
        ref,
        scope,
        PaginatedListController<ManagedAssignmentSummary>(
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
        ),
      );
    });

final paginatedAvailableContributorsProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ManagedUserSummary>,
      AsyncValue<PaginatedListState<ManagedUserSummary>>,
      AvailableContributorsQuery
    >((ref, query) {
      ref.watch(
        authControllerProvider.select((state) => state.session?.user.id),
      );
      final scope = RealtimeScope('project', query.projectId);
      return bindRealtimePaginated(
        ref,
        scope,
        PaginatedListController<ManagedUserSummary>(
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
        ),
      );
    });

final paginatedProjectCategoriesProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ProjectCategorySummary>,
      AsyncValue<PaginatedListState<ProjectCategorySummary>>,
      ProjectCategoriesQuery
    >((ref, query) {
      ref.watch(
        authControllerProvider.select((state) => state.session?.user.id),
      );
      const scope = RealtimeScope('categories', 'all');
      return bindRealtimePaginated(
        ref,
        scope,
        PaginatedListController<ProjectCategorySummary>(
          loadPage: ({required page, required limit}) {
            return ref
                .read(adminRepositoryProvider)
                .fetchCategoriesPage(
                  query: query.query,
                  page: page,
                  limit: limit,
                );
          },
        ),
      );
    });

final paginatedReviewQueueProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ReviewQueueItem>,
      AsyncValue<PaginatedListState<ReviewQueueItem>>,
      ReviewQueueQuery
    >((ref, query) {
      ref.watch(
        authControllerProvider.select((state) => state.session?.user.id),
      );
      const scope = RealtimeScope('reviews', 'all');
      return bindRealtimePaginated(
        ref,
        scope,
        PaginatedListController<ReviewQueueItem>(
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
        ),
      );
    });

final exportsControllerProvider =
    StateNotifierProvider.autoDispose<ExportsController, ExportsState>((ref) {
      final session = ref.watch(authControllerProvider).session;
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
      final scope = RealtimeScope('exports', session.user.id);
      return bindRealtimePaginated(
        ref,
        scope,
        PaginatedListController<ExportJob>(
          loadPage: ({required page, required limit}) {
            return ref
                .read(exportsRepositoryProvider)
                .fetchJobsPage(
                  requestedByUserId: session.user.id,
                  categoryId: query.categoryId,
                  projectId: query.projectId,
                  status: query.status,
                  format: query.format,
                  page: page,
                  limit: limit,
                );
          },
        ),
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
          expired: 0,
        );
      }
      watchRealtimeScope(ref, RealtimeScope('exports', session.user.id));
      return ref
          .read(exportsRepositoryProvider)
          .fetchSummary(
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
  watchRealtimeScope(ref, const RealtimeScope('users', 'all'));
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
      watchRealtimeScope(ref, const RealtimeScope('users', 'all'));
      return ref
          .read(adminRepositoryProvider)
          .fetchContributorRequests(status: status);
    });

final managedUsersProvider = FutureProvider<List<ManagedUserSummary>>((
  ref,
) async {
  ref.watch(authControllerProvider.select((state) => state.session?.user.id));
  watchRealtimeScope(ref, const RealtimeScope('users', 'all'));
  return ref.read(adminRepositoryProvider).fetchUsers();
});

final managedAssignmentsProvider =
    FutureProvider<List<ManagedAssignmentSummary>>((ref) async {
      ref.watch(
        authControllerProvider.select((state) => state.session?.user.id),
      );
      watchRealtimeScope(ref, const RealtimeScope('assignments', 'all'));
      return ref.read(adminRepositoryProvider).fetchManagedAssignments();
    });

final projectCategoriesProvider = FutureProvider<List<ProjectCategorySummary>>((
  ref,
) async {
  ref.watch(authControllerProvider.select((state) => state.session?.user.id));
  watchRealtimeScope(ref, const RealtimeScope('categories', 'all'));
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
      watchRealtimeScope(ref, RealtimeScope('project', projectId));
      return ref
          .read(adminRepositoryProvider)
          .fetchProjectAssignments(projectId);
    });

final supportSettingsProvider = FutureProvider<SupportContactSettings>((
  ref,
) async {
  ref.watch(authControllerProvider.select((state) => state.session?.user.id));
  watchRealtimeScope(ref, const RealtimeScope('settings', 'support'));
  return ref.read(adminRepositoryProvider).fetchSupportSettings();
});

final reviewQueueProvider = FutureProvider<List<ReviewQueueItem>>((ref) async {
  ref.watch(authControllerProvider.select((state) => state.session?.user.id));
  watchRealtimeScope(ref, const RealtimeScope('reviews', 'all'));
  return ref
      .read(reviewRepositoryProvider)
      .fetchReviewItems(status: 'pending_review');
});

final rejectedReviewQueueProvider = FutureProvider<List<ReviewQueueItem>>((
  ref,
) async {
  ref.watch(authControllerProvider.select((state) => state.session?.user.id));
  watchRealtimeScope(ref, const RealtimeScope('reviews', 'all'));
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
      watchRealtimeScope(ref, RealtimeScope('reviews', projectId));
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
      watchRealtimeScope(ref, RealtimeScope('reviews', projectId));
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
      watchRealtimeScope(ref, RealtimeScope('reviews', projectId));
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
    projectId: draft.projectId,
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
            isLocalFile: true,
          ),
        )
        .toList(growable: false),
  );
}

List<MapFeatureSummary> _mergeProjectFeatures(
  String projectId,
  List<MapFeatureSummary> remote,
  List<LocalDraftFeature> localDrafts,
) {
  final merged = <String, MapFeatureSummary>{};
  for (final item in remote) {
    if (item.projectId != projectId) {
      continue;
    }
    merged[item.id] = item;
  }
  for (final draft in localDrafts) {
    if (draft.projectId != projectId) {
      continue;
    }
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
