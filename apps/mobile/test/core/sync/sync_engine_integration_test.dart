import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/core/offline/local_models.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store_web.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_engine.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_retry_policy.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/project.dart';

class TrackingLocalStore extends LocalStore {
  TrackingLocalStore(this._inner);

  final LocalStore _inner;
  final List<String> transitions = <String>[];

  @override
  Future<void> initialize() => _inner.initialize();

  @override
  Future<void> dispose() => _inner.dispose();

  @override
  Future<void> cacheProjects(List<ProjectSummary> projects) {
    return _inner.cacheProjects(projects);
  }

  @override
  Future<List<ProjectSummary>> getCachedProjects() =>
      _inner.getCachedProjects();

  @override
  Future<void> seedIfEmpty({
    required List<ProjectSummary> projects,
    required List<LocalDraftFeature> drafts,
  }) {
    return _inner.seedIfEmpty(projects: projects, drafts: drafts);
  }

  @override
  Future<void> upsertDraft(LocalDraftFeature draft, {bool enqueueSync = true}) {
    return _inner.upsertDraft(draft, enqueueSync: enqueueSync);
  }

  @override
  Future<List<LocalDraftFeature>> getDrafts() => _inner.getDrafts();

  @override
  Future<LocalDraftFeature?> getDraftById(String draftId) =>
      _inner.getDraftById(draftId);

  @override
  Future<void> discardDraft(String draftId) {
    transitions.add('discard:$draftId');
    return _inner.discardDraft(draftId);
  }

  @override
  Future<void> upsertOfflineMapPackage(OfflineMapPackage package) =>
      _inner.upsertOfflineMapPackage(package);

  @override
  Future<OfflineMapPackage?> getCurrentOfflineMapPackage({
    required String ownerUserId,
  }) => _inner.getCurrentOfflineMapPackage(ownerUserId: ownerUserId);

  @override
  Future<void> upsertOfflineProjectPackage(OfflineProjectPackage package) =>
      _inner.upsertOfflineProjectPackage(package);

  @override
  Future<OfflineProjectPackage?> getOfflineProjectPackage({
    required String ownerUserId,
    required String projectId,
  }) => _inner.getOfflineProjectPackage(
    ownerUserId: ownerUserId,
    projectId: projectId,
  );

  @override
  Future<List<OfflineProjectPackage>> getOfflineProjectPackages({
    required String ownerUserId,
  }) => _inner.getOfflineProjectPackages(ownerUserId: ownerUserId);

  @override
  Future<void> deleteOfflineProjectPackage({
    required String ownerUserId,
    required String projectId,
  }) => _inner.deleteOfflineProjectPackage(
    ownerUserId: ownerUserId,
    projectId: projectId,
  );

  @override
  Future<int> countOfflineProjectPackagesUsingBaseMap({
    required String ownerUserId,
    required String baseMapVersion,
  }) => _inner.countOfflineProjectPackagesUsingBaseMap(
    ownerUserId: ownerUserId,
    baseMapVersion: baseMapVersion,
  );

  @override
  Future<int> countUnsyncedDraftsForProject({
    required String ownerUserId,
    required String projectId,
  }) => _inner.countUnsyncedDraftsForProject(
    ownerUserId: ownerUserId,
    projectId: projectId,
  );

  @override
  Future<void> updateDraftStatus(
    String draftId, {
    required String status,
    int? remoteVersion,
  }) {
    return _inner.updateDraftStatus(
      draftId,
      status: status,
      remoteVersion: remoteVersion,
    );
  }

  @override
  Future<int> getPendingSyncCount() => _inner.getPendingSyncCount();

  @override
  Future<SyncQueueStats> getSyncQueueStats() => _inner.getSyncQueueStats();

  @override
  Future<List<SyncQueueItem>> getDueSyncItems(DateTime now, {int limit = 20}) {
    return _inner.getDueSyncItems(now, limit: limit);
  }

  @override
  Future<void> enqueueSyncItem(SyncQueueItem item) =>
      _inner.enqueueSyncItem(item);

  @override
  Future<void> markSyncProcessing(String queueId) {
    transitions.add('processing:$queueId');
    return _inner.markSyncProcessing(queueId);
  }

  @override
  Future<void> markSyncSuccess(
    SyncQueueItem item, {
    int? remoteVersion,
    String? draftStatus,
  }) {
    transitions.add('success:${item.id}');
    return _inner.markSyncSuccess(
      item,
      remoteVersion: remoteVersion,
      draftStatus: draftStatus,
    );
  }

  @override
  Future<void> markSyncFailure(
    SyncQueueItem item, {
    required String error,
    required DateTime nextRetryAt,
  }) {
    transitions.add('failed:${item.id}');
    return _inner.markSyncFailure(item, error: error, nextRetryAt: nextRetryAt);
  }

  @override
  Future<void> markSyncConflict(SyncQueueItem item, {required String error}) {
    transitions.add('conflict:${item.id}');
    return _inner.markSyncConflict(item, error: error);
  }

  @override
  Future<void> markSyncDeadLetter(SyncQueueItem item, {required String error}) {
    transitions.add('dead_letter:${item.id}');
    return _inner.markSyncDeadLetter(item, error: error);
  }
}

LocalDraftFeature _buildDraft({
  required String draftId,
  required int localVersion,
  String ownerUserId = 'user-1',
  String projectId = 'project-1',
}) {
  return LocalDraftFeature(
    id: draftId,
    ownerUserId: ownerUserId,
    projectId: projectId,
    projectName: 'Bekaa Orchard Census 2026',
    geometryType: 'Point',
    geometryJson: '{"type":"Point","coordinates":[35.58,33.92]}',
    attributesJson: '{"tree_type":"olive"}',
    photos: const <DraftPhoto>[],
    status: 'draft',
    localVersion: localVersion,
    updatedAt: DateTime.now(),
  );
}

SyncQueueItem _queueItem({
  required String queueId,
  required String draftId,
  required int localVersion,
  String? idempotencyKey,
  Map<String, dynamic>? extra,
  String ownerUserId = 'user-1',
  String projectId = 'project-1',
}) {
  return SyncQueueItem(
    id: queueId,
    entityType: 'draft_feature',
    entityId: draftId,
    operation: SyncOperationType.create,
    payload: <String, dynamic>{
      'draft_id': draftId,
      'owner_user_id': ownerUserId,
      'project_id': projectId,
      'geometry_type': 'Point',
      'geometry': <String, dynamic>{
        'type': 'Point',
        'coordinates': <double>[35.58, 33.92],
      },
      'attributes': <String, dynamic>{'tree_type': 'olive'},
      'status': 'draft',
      'local_version': localVersion,
      ...?extra,
    },
    ownerUserId: ownerUserId,
    projectId: projectId,
    localVersion: localVersion,
    idempotencyKey: idempotencyKey ?? 'idem-$queueId',
    attemptCount: 0,
    status: SyncQueueStatus.pending,
    nextRetryAt: DateTime.now(),
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
}

void main() {
  group('Phase 5 sync queue transitions', () {
    late TrackingLocalStore store;
    late SyncEngine syncEngine;
    late ApiClient apiClient;
    late List<String?> sentIdempotencyKeys;

    setUp(() async {
      store = TrackingLocalStore(MemoryLocalStore());
      await store.initialize();
      final dio = Dio();
      sentIdempotencyKeys = <String?>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            sentIdempotencyKeys.add(
              options.headers['Idempotency-Key'] as String?,
            );
            final payload = options.data is Map<String, dynamic>
                ? Map<String, dynamic>.from(
                    options.data as Map<String, dynamic>,
                  )
                : const <String, dynamic>{};

            if (options.method == 'POST' &&
                options.path.endsWith('/features')) {
              final featureId = (payload['id'] ?? payload['draft_id'] ?? '')
                  .toString();
              if (featureId.contains('failed') ||
                  featureId.contains('retry') ||
                  featureId.contains('idempotency') ||
                  featureId.contains('dead-letter')) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response<Map<String, dynamic>>(
                      requestOptions: options,
                      statusCode: 503,
                      data: const <String, dynamic>{
                        'message': 'Simulated transient network error',
                      },
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
                return;
              }

              if (featureId.contains('conflict')) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response<Map<String, dynamic>>(
                      requestOptions: options,
                      statusCode: 409,
                      data: <String, dynamic>{
                        'message': 'Simulated version conflict',
                        'version': 3,
                      },
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
                return;
              }

              if (featureId.contains('revoked')) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response<Map<String, dynamic>>(
                      requestOptions: options,
                      statusCode: 403,
                      data: const <String, dynamic>{
                        'message':
                            'You are no longer assigned to this project. Offline draft remains saved for retry.',
                      },
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
                return;
              }

              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 201,
                  data: <String, dynamic>{
                    'data': <String, dynamic>{
                      'id': payload['id'] ?? payload['draft_id'],
                      'version': payload['local_version'],
                    },
                  },
                ),
              );
              return;
            }

            if (options.method == 'PUT' &&
                options.path.contains('/features/')) {
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'data': <String, dynamic>{
                      'version': payload['local_version'] ?? 1,
                    },
                  },
                ),
              );
              return;
            }

            if (options.method == 'POST' &&
                options.path.contains('/photos/feature/')) {
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 201,
                  data: const <String, dynamic>{'success': true},
                ),
              );
              return;
            }

            if (options.method == 'POST' && options.path.endsWith('/submit')) {
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 200,
                  data: const <String, dynamic>{'success': true},
                ),
              );
              return;
            }

            handler.reject(
              DioException(
                requestOptions: options,
                response: Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 404,
                  data: const <String, dynamic>{
                    'message': 'Unexpected test route',
                  },
                ),
                type: DioExceptionType.badResponse,
              ),
            );
          },
        ),
      );
      apiClient = ApiClient(dio: dio);
      syncEngine = SyncEngine(
        localStore: store,
        apiClient: apiClient,
        ownerUserId: 'user-1',
      );
    });

    tearDown(() async {
      await store.dispose();
    });

    test('pending -> processing -> success', () async {
      const draftId = 'draft-success';
      const queueId = 'queue-success';

      await store.upsertDraft(
        _buildDraft(draftId: draftId, localVersion: 5),
        enqueueSync: false,
      );

      await store.enqueueSyncItem(
        _queueItem(
          queueId: queueId,
          draftId: draftId,
          localVersion: 5,
          extra: <String, dynamic>{'simulated_remote_version': 1},
        ),
      );

      final summary = await syncEngine.syncPending();

      expect(summary.processed, 1);
      expect(summary.succeeded, 1);
      expect(summary.failed, 0);
      expect(summary.conflicts, 0);
      expect(summary.deadLettered, 0);
      expect(store.transitions, <String>[
        'processing:$queueId',
        'success:$queueId',
      ]);
      expect(await store.getPendingSyncCount(), 0);

      expect(await store.getDraftById(draftId), isNull);
    });

    test('pending -> processing -> failed (transient error)', () async {
      const draftId = 'draft-failed';
      const queueId = 'queue-failed';

      await store.upsertDraft(
        _buildDraft(draftId: draftId, localVersion: 7),
        enqueueSync: false,
      );

      await store.enqueueSyncItem(
        _queueItem(
          queueId: queueId,
          draftId: draftId,
          localVersion: 7,
          extra: <String, dynamic>{'force_fail': true},
        ),
      );

      final summary = await syncEngine.syncPending();

      expect(summary.processed, 1);
      expect(summary.succeeded, 0);
      expect(summary.failed, 1);
      expect(summary.conflicts, 0);
      expect(store.transitions, <String>[
        'processing:$queueId',
        'failed:$queueId',
      ]);
      expect(await store.getPendingSyncCount(), 1);

      final queue = await store.getDueSyncItems(
        DateTime.now().add(const Duration(days: 1)),
      );
      final failedItem = queue.firstWhere((item) => item.id == queueId);
      expect(failedItem.status, SyncQueueStatus.failed);
      expect(failedItem.attemptCount, 1);
      expect(
        failedItem.lastError,
        contains('Simulated transient network error'),
      );

      final drafts = await store.getDrafts();
      final unchanged = drafts.firstWhere((d) => d.id == draftId);
      expect(unchanged.status, 'draft');
    });

    test('pending -> processing -> conflict', () async {
      const draftId = 'draft-conflict';
      const queueId = 'queue-conflict';

      await store.upsertDraft(
        _buildDraft(draftId: draftId, localVersion: 3),
        enqueueSync: false,
      );

      await store.enqueueSyncItem(
        _queueItem(
          queueId: queueId,
          draftId: draftId,
          localVersion: 3,
          extra: <String, dynamic>{'simulated_remote_version': 3},
        ),
      );

      final summary = await syncEngine.syncPending();

      expect(summary.processed, 1);
      expect(summary.succeeded, 0);
      expect(summary.failed, 0);
      expect(summary.conflicts, 1);
      expect(summary.deadLettered, 0);
      expect(store.transitions, <String>[
        'processing:$queueId',
        'conflict:$queueId',
      ]);
      expect(await store.getPendingSyncCount(), 0);
      final stats = await store.getSyncQueueStats();
      expect(stats.conflict, 1);

      final queue = await store.getDueSyncItems(
        DateTime.now().add(const Duration(days: 1)),
      );
      expect(queue.where((item) => item.id == queueId), isEmpty);

      final drafts = await store.getDrafts();
      final conflictedDraft = drafts.firstWhere((d) => d.id == draftId);
      expect(conflictedDraft.status, 'rejected');
      expect(conflictedDraft.remoteVersion, 3);
    });

    test('stale assignment rejection retains draft and queues retry', () async {
      const draftId = 'draft-revoked-assignment';
      const queueId = 'queue-revoked-assignment';

      await store.upsertDraft(
        _buildDraft(draftId: draftId, localVersion: 3),
        enqueueSync: false,
      );

      await store.enqueueSyncItem(
        _queueItem(queueId: queueId, draftId: draftId, localVersion: 3),
      );

      final summary = await syncEngine.syncPending();

      expect(summary.processed, 1);
      expect(summary.succeeded, 0);
      expect(summary.failed, 1);
      expect(summary.discarded, 0);
      expect(summary.conflicts, 0);
      expect(summary.deadLettered, 0);
      expect(store.transitions, <String>[
        'processing:$queueId',
        'failed:$queueId',
      ]);
      expect(await store.getPendingSyncCount(), 1);
      expect(await store.getDraftById(draftId), isNotNull);
    });

    test('retry scheduling window progresses across attempts', () async {
      const draftId = 'draft-retry-window';
      const queueId = 'queue-retry-window';

      await store.upsertDraft(
        _buildDraft(draftId: draftId, localVersion: 9),
        enqueueSync: false,
      );

      await store.enqueueSyncItem(
        _queueItem(
          queueId: queueId,
          draftId: draftId,
          localVersion: 9,
          extra: <String, dynamic>{'force_fail': true},
        ),
      );

      final firstSummary = await syncEngine.syncPending();
      expect(firstSummary.failed, 1);
      expect(firstSummary.deadLettered, 0);

      final afterFirstAttempt = (await store.getDueSyncItems(
        DateTime.now().add(const Duration(days: 1)),
      )).firstWhere((item) => item.id == queueId);

      expect(afterFirstAttempt.attemptCount, 1);
      final firstWindow = afterFirstAttempt.nextRetryAt!.difference(
        afterFirstAttempt.updatedAt,
      );

      final expectedFirst = SyncRetryPolicy.backoffForAttempt(1);
      expect(
        firstWindow.inSeconds,
        inInclusiveRange(expectedFirst.inSeconds - 2, expectedFirst.inSeconds),
      );

      await store.enqueueSyncItem(
        afterFirstAttempt.copyWith(
          status: SyncQueueStatus.failed,
          nextRetryAt: DateTime.now().subtract(const Duration(seconds: 1)),
        ),
      );

      final secondSummary = await syncEngine.syncPending();
      expect(secondSummary.failed, 1);
      expect(secondSummary.deadLettered, 0);

      final afterSecondAttempt = (await store.getDueSyncItems(
        DateTime.now().add(const Duration(days: 1)),
      )).firstWhere((item) => item.id == queueId);

      expect(afterSecondAttempt.attemptCount, 2);
      final secondWindow = afterSecondAttempt.nextRetryAt!.difference(
        afterSecondAttempt.updatedAt,
      );

      final expectedSecond = SyncRetryPolicy.backoffForAttempt(2);
      expect(
        secondWindow.inSeconds,
        inInclusiveRange(
          expectedSecond.inSeconds - 2,
          expectedSecond.inSeconds,
        ),
      );
      expect(secondWindow.inSeconds, greaterThan(firstWindow.inSeconds));
    });

    test('idempotency key is stable across repeated retry attempts', () async {
      const draftId = 'draft-idempotency';
      const queueId = 'queue-idempotency';
      const key = 'idem-fixed-retry-key';

      await store.upsertDraft(
        _buildDraft(draftId: draftId, localVersion: 11),
        enqueueSync: false,
      );

      await store.enqueueSyncItem(
        _queueItem(
          queueId: queueId,
          draftId: draftId,
          localVersion: 11,
          idempotencyKey: key,
          extra: <String, dynamic>{'force_fail': true},
        ),
      );

      final firstSummary = await syncEngine.syncPending();
      expect(firstSummary.failed, 1);
      expect(firstSummary.deadLettered, 0);
      expect(sentIdempotencyKeys.last, key);

      final failedAfterFirst = (await store.getDueSyncItems(
        DateTime.now().add(const Duration(days: 1)),
      )).firstWhere((item) => item.id == queueId);
      expect(failedAfterFirst.idempotencyKey, key);
      expect(failedAfterFirst.attemptCount, 1);

      await store.enqueueSyncItem(
        failedAfterFirst.copyWith(
          status: SyncQueueStatus.failed,
          nextRetryAt: DateTime.now().subtract(const Duration(seconds: 1)),
        ),
      );

      final secondSummary = await syncEngine.syncPending();
      expect(secondSummary.failed, 1);
      expect(secondSummary.deadLettered, 0);
      expect(sentIdempotencyKeys.last, key);

      final failedAfterSecond = (await store.getDueSyncItems(
        DateTime.now().add(const Duration(days: 1)),
      )).firstWhere((item) => item.id == queueId);
      expect(failedAfterSecond.idempotencyKey, key);
      expect(failedAfterSecond.attemptCount, 2);
    });

    test('background sync processes only the authenticated owner', () async {
      const sharedDraftId = 'shared-draft-id';
      await store.upsertDraft(
        _buildDraft(draftId: sharedDraftId, localVersion: 1),
        enqueueSync: false,
      );
      await store.upsertDraft(
        _buildDraft(
          draftId: sharedDraftId,
          localVersion: 1,
          ownerUserId: 'user-2',
          projectId: 'project-2',
        ),
        enqueueSync: false,
      );
      await store.enqueueSyncItem(
        _queueItem(
          queueId: 'queue-user-1',
          draftId: sharedDraftId,
          localVersion: 1,
        ),
      );
      await store.enqueueSyncItem(
        _queueItem(
          queueId: 'queue-user-2',
          draftId: sharedDraftId,
          localVersion: 1,
          ownerUserId: 'user-2',
          projectId: 'project-2',
        ),
      );

      final summary = await syncEngine.syncPending();

      expect(summary.processed, 1);
      expect(summary.succeeded, 1);
      expect(
        await store.getProjectDraft(
          ownerUserId: 'user-1',
          projectId: 'project-1',
          draftId: sharedDraftId,
        ),
        isNull,
      );
      expect(
        await store.getProjectDraft(
          ownerUserId: 'user-2',
          projectId: 'project-2',
          draftId: sharedDraftId,
        ),
        isNotNull,
      );
      expect(
        await store.getDueSyncItemsForOwner(
          'user-2',
          DateTime.now().add(const Duration(days: 1)),
        ),
        hasLength(1),
      );
    });

    test(
      'failed item moves to dead-letter when max attempts is reached',
      () async {
        const draftId = 'draft-dead-letter';
        const queueId = 'queue-dead-letter';

        await store.upsertDraft(
          _buildDraft(draftId: draftId, localVersion: 4),
          enqueueSync: false,
        );

        await store.enqueueSyncItem(
          _queueItem(
            queueId: queueId,
            draftId: draftId,
            localVersion: 4,
            extra: <String, dynamic>{'force_fail': true},
          ).copyWith(
            attemptCount: SyncRetryPolicy.maxAttempts - 1,
            status: SyncQueueStatus.failed,
            nextRetryAt: DateTime.now().subtract(const Duration(seconds: 1)),
          ),
        );

        final summary = await syncEngine.syncPending();

        expect(summary.processed, 1);
        expect(summary.succeeded, 0);
        expect(summary.failed, 0);
        expect(summary.conflicts, 0);
        expect(summary.deadLettered, 1);
        expect(store.transitions, <String>[
          'processing:$queueId',
          'dead_letter:$queueId',
        ]);

        expect(await store.getPendingSyncCount(), 0);
        final stats = await store.getSyncQueueStats();
        expect(stats.deadLetter, 1);

        final dueQueue = await store.getDueSyncItems(
          DateTime.now().add(const Duration(days: 1)),
        );
        expect(dueQueue.where((item) => item.id == queueId), isEmpty);
      },
    );
  });
}
