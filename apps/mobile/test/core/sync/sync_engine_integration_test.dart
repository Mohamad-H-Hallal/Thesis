import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/config/app_env.dart';
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
  Future<void> discardProjectDraft({
    required String ownerUserId,
    required String projectId,
    required String draftId,
  }) {
    transitions.add('discard:$draftId');
    return _inner.discardProjectDraft(
      ownerUserId: ownerUserId,
      projectId: projectId,
      draftId: draftId,
    );
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
  Future<List<SyncQueueItem>> getSyncItemsForOwner(
    String ownerUserId, {
    int limit = 100,
  }) {
    return _inner.getSyncItemsForOwner(ownerUserId, limit: limit);
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
  Future<void> discardRejectedSyncItem(
    SyncQueueItem item, {
    bool includeSupersedingRevision = false,
  }) {
    transitions.add('discard:${item.entityId}');
    return _inner.discardRejectedSyncItem(
      item,
      includeSupersedingRevision: includeSupersedingRevision,
    );
  }

  @override
  Future<int> discardRejectedSyncItemsForOwner(String ownerUserId) {
    return _inner.discardRejectedSyncItemsForOwner(ownerUserId);
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
  Future<void> markSyncConflict(
    SyncQueueItem item, {
    required String error,
    int? remoteVersion,
  }) {
    transitions.add('conflict:${item.id}');
    return _inner.markSyncConflict(
      item,
      error: error,
      remoteVersion: remoteVersion,
    );
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
  List<DraftPhoto> photos = const <DraftPhoto>[],
  String status = 'draft',
  int? remoteVersion,
}) {
  return LocalDraftFeature(
    id: draftId,
    ownerUserId: ownerUserId,
    projectId: projectId,
    projectName: 'Bekaa Orchard Census 2026',
    geometryType: 'Point',
    geometryJson: '{"type":"Point","coordinates":[35.58,33.92]}',
    attributesJson: '{"tree_type":"olive"}',
    photos: photos,
    status: status,
    localVersion: localVersion,
    remoteVersion: remoteVersion,
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
  SyncOperationType operation = SyncOperationType.create,
}) {
  return SyncQueueItem(
    id: queueId,
    entityType: 'draft_feature',
    entityId: draftId,
    operation: operation,
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
      'photo_paths': <String>[],
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
    late List<Map<String, dynamic>> sentHeaders;
    late List<Map<String, dynamic>> sentPayloads;
    late List<int> sentPhotoCounts;
    late List<String> sentPaths;
    late int featureRequestCount;
    late Future<void> Function(String featureId)? beforeOfflineResponse;

    setUp(() async {
      store = TrackingLocalStore(MemoryLocalStore());
      await store.initialize();
      final dio = Dio();
      apiClient = ApiClient(dio: dio);
      await apiClient.establishAuthenticatedSession(
        accessToken: 'current-token',
        refreshToken: 'current-refresh-token',
        ownerUserId: 'user-1',
      );
      sentIdempotencyKeys = <String?>[];
      sentHeaders = <Map<String, dynamic>>[];
      sentPayloads = <Map<String, dynamic>>[];
      sentPhotoCounts = <int>[];
      sentPaths = <String>[];
      featureRequestCount = 0;
      beforeOfflineResponse = null;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            sentPaths.add(options.path);
            sentHeaders.add(Map<String, dynamic>.from(options.headers));
            sentIdempotencyKeys.add(
              options.headers['Idempotency-Key'] as String?,
            );
            var payload = const <String, dynamic>{};
            var photoCount = 0;
            final requestData = options.data;
            if (requestData is FormData) {
              String? rawPayload;
              for (final field in requestData.fields) {
                if (field.key == 'payload') {
                  rawPayload = field.value;
                  break;
                }
              }
              if (rawPayload != null) {
                payload = Map<String, dynamic>.from(
                  jsonDecode(rawPayload) as Map,
                );
              }
              photoCount = requestData.files
                  .where((file) => file.key == 'photos')
                  .length;
            } else if (requestData is Map<String, dynamic>) {
              payload = Map<String, dynamic>.from(requestData);
            }
            sentPayloads.add(payload);
            sentPhotoCounts.add(photoCount);

            if (options.method == 'POST' &&
                options.path.endsWith('/features/offline-sync')) {
              featureRequestCount += 1;
              final featureId = (payload['draft_id'] ?? '').toString();
              await beforeOfflineResponse?.call(featureId);
              const additionalPermanentRejections = <String, String>{
                'role-forbidden': 'OFFLINE_SYNC_ROLE_FORBIDDEN',
                'project-unavailable': 'OFFLINE_SYNC_PROJECT_UNAVAILABLE',
                'owner-mismatch': 'OFFLINE_SYNC_OWNER_MISMATCH',
                'project-mismatch': 'OFFLINE_SYNC_PROJECT_MISMATCH',
                'parent-inaccessible': 'OFFLINE_SYNC_PARENT_INACCESSIBLE',
                'attachment-rejected': 'OFFLINE_SYNC_ATTACHMENT_REJECTED',
              };
              for (final rejection in additionalPermanentRejections.entries) {
                if (featureId.contains(rejection.key)) {
                  handler.reject(
                    DioException(
                      requestOptions: options,
                      response: Response<Map<String, dynamic>>(
                        requestOptions: options,
                        statusCode:
                            rejection.value ==
                                'OFFLINE_SYNC_ATTACHMENT_REJECTED'
                            ? 422
                            : 403,
                        data: <String, dynamic>{
                          'error': <String, dynamic>{
                            'code': rejection.value,
                            'disposition': 'permanent_rejection',
                            'retryable': false,
                          },
                        },
                      ),
                      type: DioExceptionType.badResponse,
                    ),
                  );
                  return;
                }
              }
              if (featureId.contains('idempotency-mismatch')) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response<Map<String, dynamic>>(
                      requestOptions: options,
                      statusCode: 409,
                      data: const <String, dynamic>{
                        'error': <String, dynamic>{
                          'code': 'OFFLINE_SYNC_IDEMPOTENCY_MISMATCH',
                          'disposition': 'permanent_rejection',
                          'retryable': false,
                        },
                      },
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
                return;
              }
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

              if (featureId.contains('version-conflict')) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response<Map<String, dynamic>>(
                      requestOptions: options,
                      statusCode: 409,
                      data: const <String, dynamic>{
                        'message':
                            'Offline submission conflicts with a newer revision.',
                        'error': <String, dynamic>{
                          'code': 'OFFLINE_SYNC_VERSION_CONFLICT',
                          'disposition': 'conflict',
                          'retryable': false,
                          'current_version': 3,
                        },
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
                        'message': 'Offline synchronization was rejected.',
                        'error': <String, dynamic>{
                          'code': 'OFFLINE_SYNC_ACCESS_REVOKED',
                          'disposition': 'permanent_rejection',
                          'retryable': false,
                        },
                      },
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
                return;
              }

              if (featureId.contains('account-inactive')) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response<Map<String, dynamic>>(
                      requestOptions: options,
                      statusCode: 401,
                      data: const <String, dynamic>{
                        'message': 'Offline synchronization was rejected.',
                        'error': <String, dynamic>{
                          'code': 'OFFLINE_SYNC_ACCOUNT_INACTIVE',
                          'disposition': 'permanent_rejection',
                          'retryable': false,
                        },
                      },
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
                return;
              }

              if (featureId.contains('payload-rejected')) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response<Map<String, dynamic>>(
                      requestOptions: options,
                      statusCode: 422,
                      data: const <String, dynamic>{
                        'message': 'Offline synchronization was rejected.',
                        'error': <String, dynamic>{
                          'code': 'OFFLINE_SYNC_PAYLOAD_REJECTED',
                          'disposition': 'permanent_rejection',
                          'retryable': false,
                        },
                      },
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
                return;
              }

              if (featureId.contains('generic-forbidden')) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response<Map<String, dynamic>>(
                      requestOptions: options,
                      statusCode: 403,
                      data: const <String, dynamic>{
                        'message': 'Forbidden without a definitive sync code.',
                      },
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
                return;
              }

              if (featureId.contains('invalid-disposition')) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response<Map<String, dynamic>>(
                      requestOptions: options,
                      statusCode: 403,
                      data: const <String, dynamic>{
                        'error': <String, dynamic>{
                          'code': 'OFFLINE_SYNC_ACCESS_REVOKED',
                          'disposition': 'temporary_failure',
                          'retryable': true,
                        },
                      },
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
                return;
              }

              if (featureId.contains('unauthorized')) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response<Map<String, dynamic>>(
                      requestOptions: options,
                      statusCode: 401,
                      data: const <String, dynamic>{'message': 'Token expired'},
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
                return;
              }

              if (featureId.contains('rate-limited')) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response<Map<String, dynamic>>(
                      requestOptions: options,
                      statusCode: 429,
                      headers: Headers.fromMap(<String, List<String>>{
                        'retry-after': <String>['60'],
                      }),
                      data: const <String, dynamic>{
                        'message': 'Please retry later.',
                      },
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
                return;
              }

              if (featureId.contains('already-synchronized')) {
                handler.resolve(
                  Response<Map<String, dynamic>>(
                    requestOptions: options,
                    statusCode: 200,
                    data: <String, dynamic>{
                      'success': true,
                      'data': <String, dynamic>{
                        'id': featureId,
                        'project_id': payload['project_id'],
                        'version': 1,
                        'outcome': 'already_synchronized',
                      },
                    },
                  ),
                );
                return;
              }

              if (featureId.contains('malformed-success')) {
                handler.resolve(
                  Response<Map<String, dynamic>>(
                    requestOptions: options,
                    statusCode: 201,
                    data: <String, dynamic>{
                      'success': true,
                      'data': <String, dynamic>{
                        'id': featureId,
                        'project_id': payload['project_id'],
                        'version': 1,
                      },
                    },
                  ),
                );
                return;
              }

              if (featureId.contains('wrong-project-success')) {
                handler.resolve(
                  Response<Map<String, dynamic>>(
                    requestOptions: options,
                    statusCode: 201,
                    data: <String, dynamic>{
                      'success': true,
                      'data': <String, dynamic>{
                        'id': featureId,
                        'project_id': 'another-project',
                        'version': 1,
                        'outcome': 'accepted',
                      },
                    },
                  ),
                );
                return;
              }

              if (featureId.contains('missing-success-flag')) {
                handler.resolve(
                  Response<Map<String, dynamic>>(
                    requestOptions: options,
                    statusCode: 201,
                    data: <String, dynamic>{
                      'data': <String, dynamic>{
                        'id': featureId,
                        'project_id': payload['project_id'],
                        'version': 1,
                        'outcome': 'accepted',
                      },
                    },
                  ),
                );
                return;
              }

              if (featureId.contains('missing-version-success')) {
                handler.resolve(
                  Response<Map<String, dynamic>>(
                    requestOptions: options,
                    statusCode: 201,
                    data: <String, dynamic>{
                      'success': true,
                      'data': <String, dynamic>{
                        'id': featureId,
                        'project_id': payload['project_id'],
                        'outcome': 'accepted',
                      },
                    },
                  ),
                );
                return;
              }

              if (featureId.contains('fractional-version-success')) {
                handler.resolve(
                  Response<Map<String, dynamic>>(
                    requestOptions: options,
                    statusCode: 201,
                    data: <String, dynamic>{
                      'success': true,
                      'data': <String, dynamic>{
                        'id': featureId,
                        'project_id': payload['project_id'],
                        'version': 1.5,
                        'outcome': 'accepted',
                      },
                    },
                  ),
                );
                return;
              }

              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 201,
                  data: <String, dynamic>{
                    'success': true,
                    'data': <String, dynamic>{
                      'id': payload['draft_id'],
                      'project_id': payload['project_id'],
                      'version': payload['operation'] == 'update'
                          ? ((payload['expected_version'] as int?) ?? 0) + 1
                          : 1,
                      'outcome': 'accepted',
                    },
                  },
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
        _queueItem(queueId: queueId, draftId: draftId, localVersion: 5),
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
        _queueItem(queueId: queueId, draftId: draftId, localVersion: 7),
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

    test('unstructured 409 remains queued as a temporary failure', () async {
      const draftId = 'draft-conflict';
      const queueId = 'queue-conflict';

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
      expect(summary.conflicts, 0);
      expect(summary.deadLettered, 0);
      expect(store.transitions, <String>[
        'processing:$queueId',
        'failed:$queueId',
      ]);
      expect(await store.getPendingSyncCount(), 1);
      final stats = await store.getSyncQueueStats();
      expect(stats.failed, 1);
      expect(stats.conflict, 0);

      final queue = await store.getDueSyncItems(
        DateTime.now().add(const Duration(days: 1)),
      );
      expect(queue.where((item) => item.id == queueId), hasLength(1));

      final drafts = await store.getDrafts();
      final conflictedDraft = drafts.firstWhere((d) => d.id == draftId);
      expect(conflictedDraft.status, 'draft');
      expect(conflictedDraft.remoteVersion, isNull);
    });

    test(
      'structured version conflict atomically marks the exact revision',
      () async {
        const draftId = 'draft-version-conflict';
        const queueId = 'queue-version-conflict';
        await store.upsertDraft(
          _buildDraft(draftId: draftId, localVersion: 2, remoteVersion: 1),
          enqueueSync: false,
        );
        await store.enqueueSyncItem(
          _queueItem(
            queueId: queueId,
            draftId: draftId,
            localVersion: 2,
            operation: SyncOperationType.update,
            extra: const <String, dynamic>{'remote_version': 1},
          ),
        );

        final summary = await syncEngine.syncPending();

        expect(summary.conflicts, 1);
        expect(summary.failed, 0);
        final conflicted = await store.getDraftById(draftId);
        expect(conflicted?.status, 'rejected');
        expect(conflicted?.remoteVersion, 3);
        final queue = await store.getSyncItemsForOwner('user-1');
        expect(queue.single.status, SyncQueueStatus.conflict);
        expect(queue.single.lastError, contains('newer server version'));
      },
    );

    test('late conflict cannot reject a newer local revision', () async {
      const draftId = 'draft-version-conflict-newer';
      const queueId = 'queue-version-conflict-newer';
      await store.upsertDraft(
        _buildDraft(draftId: draftId, localVersion: 2, remoteVersion: 1),
        enqueueSync: false,
      );
      await store.enqueueSyncItem(
        _queueItem(
          queueId: queueId,
          draftId: draftId,
          localVersion: 2,
          operation: SyncOperationType.update,
          extra: const <String, dynamic>{'remote_version': 1},
        ),
      );
      beforeOfflineResponse = (featureId) async {
        if (featureId != draftId) return;
        await store.upsertDraft(
          _buildDraft(draftId: draftId, localVersion: 3, remoteVersion: 1),
          enqueueSync: false,
        );
        await store.enqueueSyncItem(
          _queueItem(
            queueId: queueId,
            draftId: draftId,
            localVersion: 3,
            operation: SyncOperationType.update,
            idempotencyKey: 'newer-conflict-revision',
            extra: const <String, dynamic>{'remote_version': 1},
          ),
        );
      };

      final summary = await syncEngine.syncPending();

      expect(summary.conflicts, 1);
      final newer = await store.getDraftById(draftId);
      expect(newer?.localVersion, 3);
      expect(newer?.status, 'draft');
      expect(newer?.remoteVersion, 1);
      final queue = await store.getSyncItemsForOwner('user-1');
      expect(queue.single.localVersion, 3);
      expect(queue.single.status, SyncQueueStatus.pending);
    });

    test('structured idempotency mismatch is permanently discarded', () async {
      const draftId = 'draft-idempotency-mismatch';
      await store.upsertDraft(
        _buildDraft(draftId: draftId, localVersion: 1),
        enqueueSync: false,
      );
      await store.enqueueSyncItem(
        _queueItem(
          queueId: 'queue-idempotency-mismatch',
          draftId: draftId,
          localVersion: 1,
        ),
      );

      final summary = await syncEngine.syncPending();

      expect(summary.discarded, 1);
      expect(summary.failed, 0);
      expect(summary.conflicts, 0);
      expect(await store.getDraftById(draftId), isNull);
      expect(await store.getPendingSyncCount(), 0);
    });

    for (final testCase in const <({String marker, String code})>[
      (marker: 'role-forbidden', code: 'OFFLINE_SYNC_ROLE_FORBIDDEN'),
      (marker: 'project-unavailable', code: 'OFFLINE_SYNC_PROJECT_UNAVAILABLE'),
      (marker: 'owner-mismatch', code: 'OFFLINE_SYNC_OWNER_MISMATCH'),
      (marker: 'project-mismatch', code: 'OFFLINE_SYNC_PROJECT_MISMATCH'),
      (marker: 'parent-inaccessible', code: 'OFFLINE_SYNC_PARENT_INACCESSIBLE'),
      (marker: 'attachment-rejected', code: 'OFFLINE_SYNC_ATTACHMENT_REJECTED'),
    ]) {
      test('${testCase.code} permanently discards its local bundle', () async {
        final draftId = 'draft-${testCase.marker}';
        final queueId = 'queue-${testCase.marker}';
        await store.upsertDraft(
          _buildDraft(draftId: draftId, localVersion: 1),
          enqueueSync: false,
        );
        await store.enqueueSyncItem(
          _queueItem(queueId: queueId, draftId: draftId, localVersion: 1),
        );

        final summary = await syncEngine.syncPending();

        expect(summary.discarded, 1);
        expect(summary.failed, 0);
        expect(store.transitions, <String>[
          'processing:$queueId',
          'discard:$draftId',
        ]);
        expect(await store.getDraftById(draftId), isNull);
        expect(await store.getPendingSyncCount(), 0);
      });
    }

    test(
      'definitive assignment rejection discards the complete local bundle',
      () async {
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
        expect(summary.failed, 0);
        expect(summary.discarded, 1);
        expect(summary.conflicts, 0);
        expect(summary.deadLettered, 0);
        expect(summary.discardMessages, <String>[
          'Offline submission discarded because you no longer have access to this project.',
        ]);
        expect(store.transitions, <String>[
          'processing:$queueId',
          'discard:$draftId',
        ]);
        expect(await store.getPendingSyncCount(), 0);
        expect(await store.getDraftById(draftId), isNull);

        final afterRestart = await syncEngine.syncPending();
        expect(afterRestart.processed, 0);
        await store.discardProjectDraft(
          ownerUserId: 'user-1',
          projectId: 'project-1',
          draftId: draftId,
        );
        expect(await store.getPendingSyncCount(), 0);
      },
    );

    test('unstructured forbidden response is retained for retry', () async {
      const draftId = 'draft-generic-forbidden';
      const queueId = 'queue-generic-forbidden';
      await store.upsertDraft(
        _buildDraft(draftId: draftId, localVersion: 1),
        enqueueSync: false,
      );
      await store.enqueueSyncItem(
        _queueItem(queueId: queueId, draftId: draftId, localVersion: 1),
      );

      final summary = await syncEngine.syncPending();

      expect(summary.failed, 1);
      expect(summary.discarded, 0);
      expect(await store.getDraftById(draftId), isNotNull);
      expect(await store.getPendingSyncCount(), 1);
    });

    test(
      'permanent-looking response with the wrong contract is retained',
      () async {
        const draftId = 'draft-invalid-disposition';
        const queueId = 'queue-invalid-disposition';
        await store.upsertDraft(
          _buildDraft(draftId: draftId, localVersion: 1),
          enqueueSync: false,
        );
        await store.enqueueSyncItem(
          _queueItem(queueId: queueId, draftId: draftId, localVersion: 1),
        );

        final summary = await syncEngine.syncPending();

        expect(summary.failed, 1);
        expect(summary.discarded, 0);
        expect(await store.getDraftById(draftId), isNotNull);
      },
    );

    test('definitive inactive-account rejection discards local data', () async {
      const draftId = 'draft-account-inactive';
      await store.upsertDraft(
        _buildDraft(draftId: draftId, localVersion: 1),
        enqueueSync: false,
      );
      await store.enqueueSyncItem(
        _queueItem(
          queueId: 'queue-account-inactive',
          draftId: draftId,
          localVersion: 1,
        ),
      );

      final summary = await syncEngine.syncPending();

      expect(summary.discarded, 1);
      expect(summary.authenticationFailures, 0);
      expect(await store.getDraftById(draftId), isNull);
    });

    test(
      'offline identity and idempotency headers are request-scoped',
      () async {
        const draftId = 'draft-request-headers';
        const key = 'idem-request-headers';
        await store.upsertDraft(
          _buildDraft(draftId: draftId, localVersion: 2),
          enqueueSync: false,
        );
        await store.enqueueSyncItem(
          _queueItem(
            queueId: 'queue-request-headers',
            draftId: draftId,
            localVersion: 2,
            idempotencyKey: key,
          ),
        );

        final summary = await syncEngine.syncPending();

        expect(summary.succeeded, 1);
        expect(sentHeaders.single['Idempotency-Key'], key);
        expect(sentHeaders.single['X-Offline-Owner-Id'], 'user-1');
        expect(sentHeaders.single['X-Offline-Project-Id'], 'project-1');
        expect(sentHeaders.single['Authorization'], 'Bearer current-token');
        expect(sentPaths, <String>[
          '${AppEnv.apiVersionPrefix}/features/offline-sync',
        ]);
        expect(sentPayloads.single['offline_owner_user_id'], 'user-1');
        expect(sentPayloads.single, <String, dynamic>{
          'draft_id': draftId,
          'offline_owner_user_id': 'user-1',
          'project_id': 'project-1',
          'operation': 'create',
          'geom': <String, dynamic>{
            'type': 'Point',
            'coordinates': <dynamic>[35.58, 33.92],
          },
          'attributes': <String, dynamic>{'tree_type': 'olive'},
          'accuracy_meters': null,
          'expected_version': null,
          'submit_for_review': false,
        });
        expect(sentPhotoCounts, <int>[0]);
        expect(
          apiClient.dio.options.headers['Authorization'],
          'Bearer current-token',
        );
        expect(
          apiClient.dio.options.headers.containsKey('Idempotency-Key'),
          isFalse,
        );
        expect(
          apiClient.dio.options.headers.containsKey('X-Offline-Owner-Id'),
          isFalse,
        );
      },
    );

    test(
      'already-synchronized success performs normal local cleanup',
      () async {
        const draftId = 'draft-already-synchronized';
        await store.upsertDraft(
          _buildDraft(draftId: draftId, localVersion: 1),
          enqueueSync: false,
        );
        await store.enqueueSyncItem(
          _queueItem(
            queueId: 'queue-already-synchronized',
            draftId: draftId,
            localVersion: 1,
          ),
        );

        final first = await syncEngine.syncPending();
        final second = await syncEngine.syncPending();

        expect(first.succeeded, 1);
        expect(second.processed, 0);
        expect(featureRequestCount, 1);
        expect(await store.getDraftById(draftId), isNull);
        expect(await store.getPendingSyncCount(), 0);
      },
    );

    test(
      'malformed or cross-project 2xx acknowledgements retain local bundles',
      () async {
        const draftIds = <String>[
          'draft-malformed-success',
          'draft-wrong-project-success',
          'draft-missing-success-flag',
          'draft-missing-version-success',
          'draft-fractional-version-success',
        ];
        for (final draftId in draftIds) {
          await store.upsertDraft(
            _buildDraft(draftId: draftId, localVersion: 1),
            enqueueSync: false,
          );
          await store.enqueueSyncItem(
            _queueItem(
              queueId: 'queue-$draftId',
              draftId: draftId,
              localVersion: 1,
            ),
          );
        }

        final summary = await syncEngine.syncPending();

        expect(summary.succeeded, 0);
        expect(summary.failed, draftIds.length);
        for (final draftId in draftIds) {
          expect(await store.getDraftById(draftId), isNotNull);
        }
        expect(await store.getPendingSyncCount(), draftIds.length);
      },
    );

    test(
      'late create success rebases and synchronizes a newer local revision',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'offline-sync-rebase-photo-',
        );
        addTearDown(() async {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        });
        final newPhoto = File(
          '${directory.path}${Platform.pathSeparator}new-photo.jpg',
        );
        await newPhoto.writeAsBytes(const <int>[0xff, 0xd8, 0xff, 0xd9]);
        final laterPhoto = File(
          '${directory.path}${Platform.pathSeparator}later-photo.jpg',
        );
        await laterPhoto.writeAsBytes(const <int>[0xff, 0xd8, 0xff, 0xd9]);
        const draftId = 'draft-newer-revision-success';
        const queueId = 'queue-newer-revision-success';
        await store.upsertDraft(
          _buildDraft(draftId: draftId, localVersion: 1),
          enqueueSync: false,
        );
        await store.enqueueSyncItem(
          _queueItem(queueId: queueId, draftId: draftId, localVersion: 1),
        );
        var replacementSaved = false;
        beforeOfflineResponse = (featureId) async {
          if (featureId != draftId || replacementSaved) return;
          replacementSaved = true;
          await store.upsertDraft(
            _buildDraft(
              draftId: draftId,
              localVersion: 2,
              photos: <DraftPhoto>[
                DraftPhoto(
                  id: 'new-photo',
                  filePath: newPhoto.path,
                  createdAt: DateTime.now(),
                ),
              ],
            ),
            enqueueSync: false,
          );
          await store.enqueueSyncItem(
            _queueItem(
              queueId: queueId,
              draftId: draftId,
              localVersion: 2,
              idempotencyKey: 'replacement-idempotency-key',
              extra: <String, dynamic>{
                'photo_paths': <String>[newPhoto.path],
              },
            ),
          );
        };

        final first = await syncEngine.syncPending();

        expect(first.succeeded, 1);
        final rebasedDraft = await store.getDraftById(draftId);
        expect(rebasedDraft?.localVersion, 2);
        expect(rebasedDraft?.remoteVersion, 1);
        final retained = await store.getDueSyncItemsForOwner(
          'user-1',
          DateTime.now().add(const Duration(days: 1)),
        );
        expect(retained, hasLength(1));
        expect(retained.single.localVersion, 2);
        expect(retained.single.operation, SyncOperationType.update);
        expect(retained.single.idempotencyKey, 'replacement-idempotency-key');
        expect(retained.single.payload['photo_paths'], <String>[newPhoto.path]);

        await store.upsertDraft(
          _buildDraft(
            draftId: draftId,
            localVersion: 3,
            remoteVersion: 1,
            photos: <DraftPhoto>[
              DraftPhoto(
                id: 'new-photo',
                filePath: newPhoto.path,
                createdAt: DateTime.now(),
              ),
              DraftPhoto(
                id: 'later-photo',
                filePath: laterPhoto.path,
                createdAt: DateTime.now(),
              ),
            ],
          ),
        );
        final editedQueue = await store.getDueSyncItemsForOwner(
          'user-1',
          DateTime.now().add(const Duration(days: 1)),
        );
        expect(editedQueue, hasLength(1));
        expect(editedQueue.single.operation, SyncOperationType.update);
        expect(editedQueue.single.payload['remote_version'], 1);
        expect(editedQueue.single.payload['photo_paths'], <String>[
          newPhoto.path,
          laterPhoto.path,
        ]);

        final second = await syncEngine.syncPending();

        expect(second.succeeded, 1);
        expect(featureRequestCount, 2);
        expect(sentPayloads.map((payload) => payload['operation']), <String>[
          'create',
          'update',
        ]);
        expect(sentPhotoCounts, <int>[0, 2]);
        expect(await store.getDraftById(draftId), isNull);
        expect(await store.getPendingSyncCount(), 0);
      },
    );

    test(
      'late success turns a removed synchronized photo into a local conflict',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'offline-sync-rebase-remove-',
        );
        addTearDown(() async {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        });
        final photo = File(
          '${directory.path}${Platform.pathSeparator}accepted-photo.jpg',
        );
        await photo.writeAsBytes(const <int>[0xff, 0xd8, 0xff, 0xd9]);
        const draftId = 'draft-newer-revision-removed-photo';
        const queueId = 'queue-newer-revision-removed-photo';
        await store.upsertDraft(
          _buildDraft(
            draftId: draftId,
            localVersion: 1,
            photos: <DraftPhoto>[
              DraftPhoto(
                id: 'accepted-photo',
                filePath: photo.path,
                createdAt: DateTime.now(),
              ),
            ],
          ),
          enqueueSync: false,
        );
        await store.enqueueSyncItem(
          _queueItem(
            queueId: queueId,
            draftId: draftId,
            localVersion: 1,
            extra: <String, dynamic>{
              'photo_paths': <String>[photo.path],
            },
          ),
        );
        beforeOfflineResponse = (featureId) async {
          if (featureId != draftId) return;
          await store.upsertDraft(
            _buildDraft(draftId: draftId, localVersion: 2),
            enqueueSync: false,
          );
          await store.enqueueSyncItem(
            _queueItem(
              queueId: queueId,
              draftId: draftId,
              localVersion: 2,
              idempotencyKey: 'replacement-removed-photo',
            ),
          );
        };

        final summary = await syncEngine.syncPending();

        expect(summary.succeeded, 1);
        final retained = await store.getDraftById(draftId);
        expect(retained?.status, 'rejected');
        expect(retained?.remoteVersion, 1);
        final queue = await store.getSyncItemsForOwner('user-1');
        expect(queue.single.status, SyncQueueStatus.conflict);
        expect(queue.single.lastError, contains('removed'));
        expect(featureRequestCount, 1);
      },
    );

    test(
      'late update success rebases a newer edit to the acknowledged version',
      () async {
        const draftId = 'draft-newer-revision-update';
        const queueId = 'queue-newer-revision-update';
        await store.upsertDraft(
          _buildDraft(draftId: draftId, localVersion: 2, remoteVersion: 1),
          enqueueSync: false,
        );
        await store.enqueueSyncItem(
          _queueItem(
            queueId: queueId,
            draftId: draftId,
            localVersion: 2,
            operation: SyncOperationType.update,
            extra: const <String, dynamic>{'remote_version': 1},
          ),
        );
        var replacementSaved = false;
        beforeOfflineResponse = (featureId) async {
          if (featureId != draftId || replacementSaved) return;
          replacementSaved = true;
          await store.upsertDraft(
            _buildDraft(draftId: draftId, localVersion: 3, remoteVersion: 1),
            enqueueSync: false,
          );
          await store.enqueueSyncItem(
            _queueItem(
              queueId: queueId,
              draftId: draftId,
              localVersion: 3,
              operation: SyncOperationType.update,
              idempotencyKey: 'replacement-update-key',
              extra: const <String, dynamic>{'remote_version': 1},
            ),
          );
        };

        final first = await syncEngine.syncPending();

        expect(first.succeeded, 1);
        final rebased = await store.getDraftById(draftId);
        expect(rebased?.localVersion, 3);
        expect(rebased?.remoteVersion, 2);
        final queue = await store.getDueSyncItemsForOwner(
          'user-1',
          DateTime.now().add(const Duration(days: 1)),
        );
        expect(queue.single.operation, SyncOperationType.update);
        expect(queue.single.payload['remote_version'], 2);

        final second = await syncEngine.syncPending();

        expect(second.succeeded, 1);
        expect(
          sentPayloads.map((payload) => payload['expected_version']),
          <int>[1, 2],
        );
        expect(await store.getDraftById(draftId), isNull);
        expect(await store.getPendingSyncCount(), 0);
      },
    );

    test(
      'late access rejection deletes a newer revision and cannot retry',
      () async {
        const draftId = 'draft-revoked-newer-revision';
        const queueId = 'queue-revoked-newer-revision';
        await store.upsertDraft(
          _buildDraft(draftId: draftId, localVersion: 1),
          enqueueSync: false,
        );
        await store.enqueueSyncItem(
          _queueItem(queueId: queueId, draftId: draftId, localVersion: 1),
        );
        beforeOfflineResponse = (featureId) async {
          if (featureId != draftId) return;
          await store.upsertDraft(
            _buildDraft(draftId: draftId, localVersion: 2),
            enqueueSync: false,
          );
          await store.enqueueSyncItem(
            _queueItem(
              queueId: queueId,
              draftId: draftId,
              localVersion: 2,
              idempotencyKey: 'replacement-after-rejection',
            ),
          );
        };

        final summary = await syncEngine.syncPending();

        expect(summary.discarded, 1);
        expect(await store.getDraftById(draftId), isNull);
        expect(await store.getPendingSyncCount(), 0);

        final afterRestart = SyncEngine(
          localStore: store,
          apiClient: apiClient,
          ownerUserId: 'user-1',
        );
        final retry = await afterRestart.syncPending();
        expect(retry.processed, 0);
        expect(featureRequestCount, 1);
      },
    );

    test(
      'inactive account rejection drains owner items beyond the due page',
      () async {
        const itemCount = 30;
        final draftIds = <String>[];
        for (var index = 0; index < itemCount; index += 1) {
          final draftId = index == 0
              ? 'draft-account-inactive-first'
              : 'draft-z-after-inactive-$index';
          draftIds.add(draftId);
          await store.upsertDraft(
            _buildDraft(draftId: draftId, localVersion: 1),
            enqueueSync: false,
          );
          var queueItem = _queueItem(
            queueId: 'queue-$draftId',
            draftId: draftId,
            localVersion: 1,
          );
          if (index == itemCount - 2) {
            queueItem = queueItem.copyWith(
              status: SyncQueueStatus.failed,
              nextRetryAt: DateTime.now().add(const Duration(days: 30)),
            );
          } else if (index == itemCount - 1) {
            queueItem = queueItem.copyWith(status: SyncQueueStatus.conflict);
          }
          await store.enqueueSyncItem(queueItem);
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }

        final summary = await syncEngine.syncPending();

        expect(summary.processed, itemCount);
        expect(summary.discarded, itemCount);
        expect(summary.failed, 0);
        expect(featureRequestCount, 1);
        for (final draftId in draftIds) {
          expect(await store.getDraftById(draftId), isNull);
        }
        expect(await store.getPendingSyncCount(), 0);
      },
    );

    test(
      'create, photos, and review intent use one atomic bundle request',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'offline-sync-photo-',
        );
        addTearDown(() async {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        });
        final photo = File(
          '${directory.path}${Platform.pathSeparator}photo.jpg',
        );
        await photo.writeAsBytes(const <int>[0xff, 0xd8, 0xff, 0xd9]);
        const draftId = 'draft-full-sequence';
        await store.upsertDraft(
          _buildDraft(
            draftId: draftId,
            localVersion: 1,
            status: 'submitted',
            photos: <DraftPhoto>[
              DraftPhoto(
                id: 'photo-full-sequence',
                filePath: photo.path,
                createdAt: DateTime.now(),
              ),
            ],
          ),
          enqueueSync: false,
        );
        await store.enqueueSyncItem(
          _queueItem(
            queueId: 'queue-full-sequence',
            draftId: draftId,
            localVersion: 1,
            idempotencyKey: 'idem-full-sequence',
            extra: <String, dynamic>{
              'photo_paths': <String>[photo.path],
              'status': 'submitted',
            },
          ),
        );

        final summary = await syncEngine.syncPending();

        expect(summary.succeeded, 1);
        expect(featureRequestCount, 1);
        expect(sentPaths, <String>[
          '${AppEnv.apiVersionPrefix}/features/offline-sync',
        ]);
        expect(sentHeaders, hasLength(1));
        expect(sentHeaders.single['Idempotency-Key'], 'idem-full-sequence');
        expect(sentHeaders.single['X-Offline-Owner-Id'], 'user-1');
        expect(sentHeaders.single['X-Offline-Project-Id'], 'project-1');
        expect(sentHeaders.single['Authorization'], 'Bearer current-token');
        expect(sentPhotoCounts, <int>[1]);
        expect(sentPayloads.single['draft_id'], draftId);
        expect(sentPayloads.single['operation'], 'create');
        expect(sentPayloads.single['expected_version'], isNull);
        expect(sentPayloads.single['submit_for_review'], isTrue);
        expect(sentPayloads.single.containsKey('status'), isFalse);
        expect(sentPayloads.single.containsKey('role'), isFalse);
        expect(
          apiClient.dio.options.headers['Authorization'],
          'Bearer current-token',
        );
        expect(
          apiClient.dio.options.headers.containsKey('Idempotency-Key'),
          isFalse,
        );
      },
    );

    test('update uses the same single bundle endpoint', () async {
      const draftId = 'draft-update-bundle';
      await store.upsertDraft(
        _buildDraft(draftId: draftId, localVersion: 2, remoteVersion: 1),
        enqueueSync: false,
      );
      await store.enqueueSyncItem(
        _queueItem(
          queueId: 'queue-update-bundle',
          draftId: draftId,
          localVersion: 2,
          operation: SyncOperationType.update,
        ),
      );

      final summary = await syncEngine.syncPending();

      expect(summary.succeeded, 1);
      expect(featureRequestCount, 1);
      expect(sentPaths, <String>[
        '${AppEnv.apiVersionPrefix}/features/offline-sync',
      ]);
      expect(sentPayloads.single['operation'], 'update');
      expect(sentPayloads.single['expected_version'], 1);
      expect(sentPhotoCounts.single, 0);
    });

    test(
      'definitive unsafe-payload rejection uses a sanitized message',
      () async {
        const draftId = 'draft-payload-rejected';
        await store.upsertDraft(
          _buildDraft(draftId: draftId, localVersion: 1),
          enqueueSync: false,
        );
        await store.enqueueSyncItem(
          _queueItem(
            queueId: 'queue-payload-rejected',
            draftId: draftId,
            localVersion: 1,
          ),
        );

        final summary = await syncEngine.syncPending();

        expect(summary.discarded, 1);
        expect(summary.discardMessages, <String>[
          'Offline submission discarded because its saved data was rejected.',
        ]);
        expect(await store.getDraftById(draftId), isNull);
      },
    );

    test('retry scheduling window progresses across attempts', () async {
      const draftId = 'draft-retry-window';
      const queueId = 'queue-retry-window';

      await store.upsertDraft(
        _buildDraft(draftId: draftId, localVersion: 9),
        enqueueSync: false,
      );

      await store.enqueueSyncItem(
        _queueItem(queueId: queueId, draftId: draftId, localVersion: 9),
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

    test('tampered local queue identities never reach the network', () async {
      final cases = <String, Map<String, dynamic>>{
        'draft-id': <String, dynamic>{'draft_id': 'different-feature'},
        'owner-id': <String, dynamic>{'owner_user_id': 'user-2'},
        'project-id': <String, dynamic>{'project_id': 'project-2'},
        'status': <String, dynamic>{'status': 'approved'},
        'unknown-field': <String, dynamic>{'reviewer_id': 'admin-1'},
        'photo-path': <String, dynamic>{
          'photo_paths': <String>['another-project-photo.jpg'],
        },
      };
      for (final entry in cases.entries) {
        final draftId = 'draft-tampered-${entry.key}';
        await store.upsertDraft(
          _buildDraft(draftId: draftId, localVersion: 1),
          enqueueSync: false,
        );
        await store.enqueueSyncItem(
          _queueItem(
            queueId: 'queue-tampered-${entry.key}',
            draftId: draftId,
            localVersion: 1,
            extra: entry.value,
          ),
        );
      }

      final summary = await syncEngine.syncPending();

      expect(summary.processed, cases.length);
      expect(summary.failed, cases.length);
      expect(summary.discarded, 0);
      expect(featureRequestCount, 0);
      expect(await store.getPendingSyncCount(), cases.length);
      expect(summary.discardMessages, isEmpty);
      for (final key in cases.keys) {
        expect(await store.getDraftById('draft-tampered-$key'), isNotNull);
      }
    });

    test(
      'expired authentication remains queued after refresh is exhausted',
      () async {
        const draftId = 'draft-unauthorized';
        await store.upsertDraft(
          _buildDraft(draftId: draftId, localVersion: 1),
          enqueueSync: false,
        );
        await store.enqueueSyncItem(
          _queueItem(
            queueId: 'queue-unauthorized',
            draftId: draftId,
            localVersion: 1,
          ),
        );

        final summary = await syncEngine.syncPending();

        expect(summary.authenticationFailures, 1);
        expect(summary.failed, 1);
        expect(summary.discarded, 0);
        expect(await store.getDraftById(draftId), isNotNull);
        expect(await store.getPendingSyncCount(), 1);
      },
    );

    test('rate limiting honors retry-after and retains the payload', () async {
      const draftId = 'draft-rate-limited';
      const queueId = 'queue-rate-limited';
      await store.upsertDraft(
        _buildDraft(draftId: draftId, localVersion: 1),
        enqueueSync: false,
      );
      await store.enqueueSyncItem(
        _queueItem(queueId: queueId, draftId: draftId, localVersion: 1),
      );

      final summary = await syncEngine.syncPending();

      expect(summary.failed, 1);
      expect(summary.deadLettered, 0);
      final retained = (await store.getDueSyncItems(
        DateTime.now().add(const Duration(days: 1)),
      )).singleWhere((item) => item.id == queueId);
      expect(
        retained.nextRetryAt!.difference(retained.updatedAt).inSeconds,
        inInclusiveRange(59, 60),
      );
      expect(await store.getDraftById(draftId), isNotNull);
    });

    test('interrupted local photo read retains the item for retry', () async {
      const draftId = 'draft-missing-photo';
      const missingPath = 'missing-offline-photo.jpg';
      await store.upsertDraft(
        _buildDraft(
          draftId: draftId,
          localVersion: 1,
          photos: <DraftPhoto>[
            DraftPhoto(
              id: 'missing-photo',
              filePath: missingPath,
              createdAt: DateTime.now(),
            ),
          ],
        ),
        enqueueSync: false,
      );
      await store.enqueueSyncItem(
        _queueItem(
          queueId: 'queue-missing-photo',
          draftId: draftId,
          localVersion: 1,
          extra: const <String, dynamic>{
            'photo_paths': <String>[missingPath],
          },
        ),
      );

      final summary = await syncEngine.syncPending();

      expect(summary.failed, 1);
      expect(summary.deadLettered, 0);
      expect(featureRequestCount, 0);
      expect(sentPaths, isEmpty);
      expect(await store.getDraftById(draftId), isNotNull);
      expect(await store.getPendingSyncCount(), 1);
    });

    test(
      'temporary failure remains retryable after the former attempt limit',
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
          ).copyWith(
            attemptCount: SyncRetryPolicy.maxAttempts - 1,
            status: SyncQueueStatus.failed,
            nextRetryAt: DateTime.now().subtract(const Duration(seconds: 1)),
          ),
        );

        final summary = await syncEngine.syncPending();

        expect(summary.processed, 1);
        expect(summary.succeeded, 0);
        expect(summary.failed, 1);
        expect(summary.conflicts, 0);
        expect(summary.deadLettered, 0);
        expect(store.transitions, <String>[
          'processing:$queueId',
          'failed:$queueId',
        ]);

        expect(await store.getPendingSyncCount(), 1);
        final stats = await store.getSyncQueueStats();
        expect(stats.failed, 1);
        expect(stats.deadLetter, 0);

        final dueQueue = await store.getDueSyncItems(
          DateTime.now().add(const Duration(days: 1)),
        );
        final retained = dueQueue.singleWhere((item) => item.id == queueId);
        expect(retained.attemptCount, SyncRetryPolicy.maxAttempts);
        expect(await store.getDraftById(draftId), isNotNull);
      },
    );

    test(
      'legacy dead-letter item is restored without changing its payload',
      () async {
        final legacyItem =
            _queueItem(
              queueId: 'queue-legacy-dead-letter',
              draftId: 'draft-legacy-dead-letter',
              localVersion: 1,
              extra: const <String, dynamic>{
                'private_note': 'preserve exactly',
              },
            ).copyWith(
              status: SyncQueueStatus.deadLetter,
              lastError: 'Legacy failure classification',
            );
        await store.enqueueSyncItem(legacyItem);
        expect((await store.getSyncQueueStats()).deadLetter, 1);

        await store.initialize();

        final stats = await store.getSyncQueueStats();
        expect(stats.deadLetter, 0);
        expect(stats.failed, 1);
        final restored = (await store.getDueSyncItemsForOwner(
          'user-1',
          DateTime.now().add(const Duration(days: 1)),
        )).singleWhere((item) => item.id == legacyItem.id);
        expect(restored.status, SyncQueueStatus.failed);
        expect(restored.lastError, legacyItem.lastError);
        expect(restored.attemptCount, legacyItem.attemptCount);
        expect(restored.payload, legacyItem.payload);
      },
    );
  });
}
