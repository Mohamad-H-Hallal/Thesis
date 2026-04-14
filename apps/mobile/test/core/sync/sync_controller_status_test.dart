import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/core/offline/local_models.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store_web.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_controller.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_engine.dart';
import 'package:dio/dio.dart';

void main() {
  test('refreshStatus exposes queued offline drafts immediately', () async {
    final store = MemoryLocalStore();
    await store.initialize();
    addTearDown(() async => store.dispose());

    final controller = SyncController(
      syncEngine: SyncEngine(
        localStore: store,
        apiClient: ApiClient(dio: Dio()),
      ),
      localStore: store,
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    expect(controller.state.pendingCount, 0);

    await store.upsertDraft(
      LocalDraftFeature(
        id: 'draft-1',
        ownerUserId: 'contributor-1',
        projectId: 'project-1',
        projectName: 'Bekaa Orchard Census',
        geometryType: 'Point',
        geometryJson: '{"type":"Point","coordinates":[35.58,33.92]}',
        attributesJson: '{"tree_type":"olive"}',
        photos: const <DraftPhoto>[],
        status: 'draft',
        localVersion: 1,
        updatedAt: DateTime.utc(2026, 4, 14, 12),
      ),
    );

    await controller.refreshStatus();

    expect(controller.state.pendingCount, 1);
    expect(controller.state.isReady, isTrue);
  });
}
