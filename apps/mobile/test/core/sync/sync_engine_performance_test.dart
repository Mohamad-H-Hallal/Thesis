import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/core/offline/local_models.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store_web.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_engine.dart';

LocalDraftFeature _buildDraft({
  required String id,
  required int version,
}) {
  return LocalDraftFeature(
    id: id,
    projectId: 'project-perf',
    projectName: 'Perf Project',
    geometryType: 'Point',
    geometryJson: '{"type":"Point","coordinates":[35.58,33.92]}',
    attributesJson: '{"tree_type":"olive"}',
    photos: const <DraftPhoto>[],
    status: 'draft',
    localVersion: version,
    updatedAt: DateTime.now(),
  );
}

SyncQueueItem _queueItem({
  required String id,
  required String draftId,
  required int version,
}) {
  return SyncQueueItem(
    id: id,
    entityType: 'draft_feature',
    entityId: draftId,
    operation: SyncOperationType.create,
    payload: <String, dynamic>{
      'draft_id': draftId,
      'project_id': 'project-perf',
      'geometry_type': 'Point',
      'geometry': <String, dynamic>{
        'type': 'Point',
        'coordinates': <double>[35.58, 33.92],
      },
      'attributes': <String, dynamic>{'tree_type': 'olive'},
      'status': 'draft',
      'local_version': version,
    },
    localVersion: version,
    idempotencyKey: 'idem-$id',
    attemptCount: 0,
    status: SyncQueueStatus.pending,
    nextRetryAt: DateTime.now(),
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
}

void main() {
  test('sync engine processes small pending batch within baseline window', () async {
    final store = MemoryLocalStore();
    await store.initialize();

    addTearDown(() async {
      await store.dispose();
    });

    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final payload = options.data is Map<String, dynamic>
              ? Map<String, dynamic>.from(options.data as Map<String, dynamic>)
              : const <String, dynamic>{};

          if (options.method == 'POST' && options.path.endsWith('/features')) {
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 201,
                data: <String, dynamic>{
                  'data': <String, dynamic>{
                    'id': payload['id'] ?? payload['draft_id'],
                    'version': payload['local_version'] ?? 1,
                  },
                },
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

          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: const <String, dynamic>{'success': true},
            ),
          );
        },
      ),
    );

    final engine = SyncEngine(
      localStore: store,
      apiClient: ApiClient(dio: dio),
    );

    const count = 8;
    for (var i = 1; i <= count; i++) {
      final draftId = 'perf-draft-$i';
      final queueId = 'perf-queue-$i';
      await store.upsertDraft(_buildDraft(id: draftId, version: i), enqueueSync: false);
      await store.enqueueSyncItem(_queueItem(id: queueId, draftId: draftId, version: i));
    }

    final stopwatch = Stopwatch()..start();
    final summary = await engine.syncPending(limit: 20);
    stopwatch.stop();

    expect(summary.processed, count);
    expect(summary.succeeded, count);
    expect(summary.failed, 0);
    expect(summary.conflicts, 0);
    expect(summary.deadLettered, 0);
    expect(stopwatch.elapsedMilliseconds, lessThan(4500));
  });
}
