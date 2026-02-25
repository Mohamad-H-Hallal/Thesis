import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../config/app_env.dart';
import '../../features/auth/data/fake_auth_repository.dart';
import '../../features/auth/data/real_auth_repository.dart';
import '../../features/auth/domain/auth_repository.dart';
import '../../features/auth/presentation/controllers/auth_controller.dart';
import '../../features/drafts/data/mock_drafts_repository.dart';
import '../../features/drafts/domain/draft_item.dart';
import '../../features/exports/data/api_exports_repository.dart';
import '../../features/exports/data/mock_exports_repository.dart';
import '../../features/exports/domain/exports_repository.dart';
import '../../features/exports/presentation/controllers/exports_controller.dart';
import '../../features/notifications/data/api_notifications_repository.dart';
import '../../features/notifications/data/mock_notifications_repository.dart';
import '../../features/notifications/domain/app_notification.dart';
import '../../features/notifications/domain/notifications_repository.dart';
import '../../features/notifications/presentation/controllers/notifications_controller.dart';
import '../../features/projects/data/api_projects_repository.dart';
import '../../features/projects/data/mock_projects_repository.dart';
import '../../features/projects/domain/project.dart';
import '../../features/projects/domain/projects_repository.dart';
import '../../features/review/application/review_workflow_service.dart';
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
  return ApiClient();
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

final draftsRepositoryProvider = Provider<MockDraftsRepository>((ref) {
  return MockDraftsRepository();
});

final exportsRepositoryProvider = Provider<ExportsRepository>((ref) {
  if (AppEnv.useMockData) {
    return MockExportsRepository();
  }
  return ApiExportsRepository(ref.watch(apiClientProvider));
});

final notificationsRepositoryProvider = Provider<NotificationsRepository>((ref) {
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
      .fetchAssignedProjects(userId: session.user.id, role: session.user.role);
  final seedDraftItems = await ref.read(draftsRepositoryProvider).fetchDrafts();

  final seedDrafts = seedDraftItems
      .map(
        (item) => LocalDraftFeature(
          id: item.id,
          projectId: 'seed-project',
          projectName: item.projectName,
          geometryType: item.geometryType,
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
        .fetchAssignedProjects(
          userId: session.user.id,
          role: session.user.role,
        );
    await localStore.cacheProjects(remoteProjects);
    return remoteProjects;
  } catch (_) {
    return localStore.getCachedProjects();
  }
});

final projectByIdProvider = FutureProvider.family<ProjectSummary?, String>((
  ref,
  id,
) async {
  final projects = await ref.watch(projectsProvider.future);
  for (final project in projects) {
    if (project.id == id) {
      return project;
    }
  }
  return null;
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
  return localStore.getDrafts();
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
      return NotificationsController(
        ref.watch(notificationsRepositoryProvider),
      );
    });

final exportsControllerProvider =
    StateNotifierProvider<ExportsController, ExportsState>((ref) {
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

final routerProvider = Provider<GoRouter>((ref) {
  return createRouter(ref);
});
