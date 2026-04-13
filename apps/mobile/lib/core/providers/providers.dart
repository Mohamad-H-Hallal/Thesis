import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/foundation.dart';

import '../config/app_env.dart';
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
import '../../features/exports/domain/exports_repository.dart';
import '../../features/exports/presentation/controllers/exports_controller.dart';
import '../../features/map/data/api_feature_workflow_repository.dart';
import '../../features/map/data/api_map_repository.dart';
import '../../features/map/data/device_current_location_service.dart';
import '../../features/map/data/offline_tile_cache_manager.dart';
import '../../features/map/domain/current_location_service.dart';
import '../../features/map/domain/feature_workflow_repository.dart';
import '../../features/map/domain/map_feature.dart';
import '../../features/notifications/data/api_notifications_repository.dart';
import '../../features/notifications/data/mock_notifications_repository.dart';
import '../../features/notifications/domain/app_notification.dart';
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

final notificationsRepositoryProvider = Provider<NotificationsRepository>((
  ref,
) {
  if (AppEnv.useMockData) {
    return MockNotificationsRepository();
  }
  return ApiNotificationsRepository(ref.watch(apiClientProvider));
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

      return ref
          .read(projectsRepositoryProvider)
          .fetchProjects(
            userId: session.user.id,
            role: session.user.role,
            scope: effectiveScope,
          );
    });

final mapProjectsProvider = FutureProvider<List<ProjectSummary>>((ref) async {
  ref.watch(workflowRefreshTickProvider);
  final authState = ref.watch(authControllerProvider);
  final session = authState.session;
  if (session == null) {
    return const <ProjectSummary>[];
  }

  if (session.user.role == UserRole.admin) {
    return ref
        .read(projectsRepositoryProvider)
        .fetchProjects(
          userId: session.user.id,
          role: session.user.role,
          scope: ProjectViewScope.all,
        );
  }

  if (session.user.role == UserRole.viewer) {
    return ref
        .read(projectsRepositoryProvider)
        .fetchProjects(
          userId: session.user.id,
          role: session.user.role,
          scope: ProjectViewScope.public,
        );
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
  return merged.values.toList(growable: false);
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
      } catch (_) {
        if (localFeatures.isNotEmpty) {
          return localFeatures;
        }
        rethrow;
      }
    });

final offlineMapPackageProvider = FutureProvider<OfflineMapPackage?>((
  ref,
) async {
  await ref.watch(offlineBootstrapProvider.future);
  final localStore = ref.watch(localStoreProvider);
  final localPackage = await localStore.getCurrentOfflineMapPackage();
  try {
    final remotePackage = await ref
        .read(mapRepositoryProvider)
        .fetchCurrentOfflineMapPackage();
    final effectivePackage = _mergeOfflineMapPackage(
      remote: remotePackage,
      local: localPackage,
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
  ref.watch(workflowRefreshTickProvider);
  final authState = ref.watch(authControllerProvider);
  final session = authState.session;
  if (session == null) {
    return null;
  }
  return ref
      .read(projectsRepositoryProvider)
      .byId(id: id, userId: session.user.id, role: session.user.role);
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
      AsyncValue<List<AppNotification>>
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

      controller.initialize();
      return controller;
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
}) {
  if (remote == null) {
    return local;
  }
  if (local == null || local.version != remote.version) {
    return remote;
  }
  return OfflineMapPackage(
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
