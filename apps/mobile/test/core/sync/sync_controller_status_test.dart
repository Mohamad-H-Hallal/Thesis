import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/core/network/network_availability_base.dart';
import 'package:lebanese_gis_mobile/core/offline/local_models.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store_web.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_controller.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_engine.dart';

class _AlwaysOnlineNetworkAvailability implements NetworkAvailabilityService {
  const _AlwaysOnlineNetworkAvailability();

  @override
  Stream<bool> get onOnlineStatusChanged => const Stream<bool>.empty();

  @override
  Future<bool> isOnline() async => true;
}

class _ToggleNetworkAvailability implements NetworkAvailabilityService {
  _ToggleNetworkAvailability({required bool online}) : _online = online;

  bool _online;
  final StreamController<bool> _controller = StreamController<bool>.broadcast();

  @override
  Stream<bool> get onOnlineStatusChanged => _controller.stream;

  @override
  Future<bool> isOnline() async => _online;

  void setOnline(bool value) {
    _online = value;
    _controller.add(value);
  }

  Future<void> dispose() => _controller.close();
}

class _CountingSyncEngine extends SyncEngine {
  _CountingSyncEngine({required super.localStore, required super.apiClient});

  int syncCount = 0;
  Completer<void>? release;

  @override
  Future<SyncRunSummary> syncPending({int limit = 25}) async {
    syncCount += 1;
    final blocker = release;
    if (blocker != null) {
      await blocker.future;
    }
    return const SyncRunSummary(
      processed: 1,
      succeeded: 1,
      failed: 0,
      conflicts: 0,
      discarded: 0,
      deadLettered: 0,
      authenticationFailures: 0,
    );
  }
}

LocalDraftFeature _draft({String id = 'draft-1'}) {
  return LocalDraftFeature(
    id: id,
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
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      networkAvailability: const _AlwaysOnlineNetworkAvailability(),
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    expect(controller.state.pendingCount, 0);

    await store.upsertDraft(_draft());

    await controller.refreshStatus();

    expect(controller.state.pendingCount, 1);
    expect(controller.state.isReady, isTrue);
  });

  test(
    'offline to online connectivity change triggers immediate sync',
    () async {
      final store = MemoryLocalStore();
      await store.initialize();
      addTearDown(() async => store.dispose());
      await store.upsertDraft(_draft());

      final network = _ToggleNetworkAvailability(online: false);
      addTearDown(network.dispose);
      final engine = _CountingSyncEngine(
        localStore: store,
        apiClient: ApiClient(dio: Dio()),
      );
      final controller = SyncController(
        syncEngine: engine,
        localStore: store,
        networkAvailability: network,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      expect(engine.syncCount, 0);

      network.setOnline(true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(engine.syncCount, 1);
    },
  );

  test('app resume while online triggers pending offline sync', () async {
    final store = MemoryLocalStore();
    await store.initialize();
    addTearDown(() async => store.dispose());

    final network = _ToggleNetworkAvailability(online: true);
    addTearDown(network.dispose);
    final engine = _CountingSyncEngine(
      localStore: store,
      apiClient: ApiClient(dio: Dio()),
    );
    final controller = SyncController(
      syncEngine: engine,
      localStore: store,
      networkAvailability: network,
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    expect(engine.syncCount, 0);

    await store.upsertDraft(_draft());
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(engine.syncCount, 1);
  });

  test('sync guard prevents duplicate simultaneous sync runs', () async {
    final store = MemoryLocalStore();
    await store.initialize();
    addTearDown(() async => store.dispose());

    final engine = _CountingSyncEngine(
      localStore: store,
      apiClient: ApiClient(dio: Dio()),
    )..release = Completer<void>();
    final controller = SyncController(
      syncEngine: engine,
      localStore: store,
      networkAvailability: const _AlwaysOnlineNetworkAvailability(),
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    final first = controller.syncNow();
    final second = controller.syncNow();
    await Future<void>.delayed(Duration.zero);
    expect(engine.syncCount, 1);

    engine.release!.complete();
    await Future.wait(<Future<void>>[first, second]);
    expect(engine.syncCount, 1);
  });
}
