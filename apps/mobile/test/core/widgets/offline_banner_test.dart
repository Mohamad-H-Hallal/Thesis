import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store_web.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_controller.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_engine.dart';
import 'package:lebanese_gis_mobile/core/widgets/offline_banner.dart';

class _StaticSyncController extends SyncController {
  _StaticSyncController(SyncState initialState, {required this.store})
    : super(
        syncEngine: SyncEngine(
          localStore: store,
          apiClient: ApiClient(dio: Dio()),
        ),
        localStore: store,
      ) {
    state = initialState;
  }

  final MemoryLocalStore store;
}

void main() {
  Future<void> pumpBanner(WidgetTester tester, SyncState state) async {
    final store = MemoryLocalStore();
    await store.initialize();
    addTearDown(store.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncControllerProvider.overrideWith(
            (ref) => _StaticSyncController(state, store: store),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: OfflineBanner())),
      ),
    );
  }

  testWidgets('shows concise pending offline sync copy', (tester) async {
    await pumpBanner(
      tester,
      const SyncState(
        pendingCount: 2,
        conflictCount: 0,
        deadLetterCount: 0,
        isSyncing: false,
        isReady: true,
        isInitializing: false,
        autoSyncRunning: true,
      ),
    );

    expect(find.text('Saved offline'), findsOneWidget);
    expect(
      find.text('Your changes will sync when you are back online.'),
      findsOneWidget,
    );
    expect(find.text('2 to sync'), findsOneWidget);
  });

  testWidgets('shows concise synced copy with the last sync time', (
    tester,
  ) async {
    final localSyncTime = DateTime.utc(2026, 4, 14, 10, 5);

    await pumpBanner(
      tester,
      SyncState(
        pendingCount: 0,
        conflictCount: 0,
        deadLetterCount: 0,
        isSyncing: false,
        isReady: true,
        isInitializing: false,
        autoSyncRunning: true,
        lastSyncAt: localSyncTime,
      ),
    );

    expect(find.text('All changes synced'), findsOneWidget);
    expect(find.text('No saved changes are waiting to sync.'), findsOneWidget);
    expect(find.text('Last sync 13:05'), findsOneWidget);
  });
}
