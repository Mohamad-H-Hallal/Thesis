import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../offline/local_store.dart';
import 'sync_engine.dart';

class SyncState {
  const SyncState({
    required this.pendingCount,
    required this.conflictCount,
    required this.deadLetterCount,
    required this.isSyncing,
    required this.isReady,
    required this.isInitializing,
    required this.autoSyncRunning,
    this.lastSyncAt,
    this.lastError,
  });

  const SyncState.initial()
    : this(
        pendingCount: 0,
        conflictCount: 0,
        deadLetterCount: 0,
        isSyncing: false,
        isReady: false,
        isInitializing: false,
        autoSyncRunning: false,
      );

  final int pendingCount;
  final int conflictCount;
  final int deadLetterCount;
  final bool isSyncing;
  final bool isReady;
  final bool isInitializing;
  final bool autoSyncRunning;
  final DateTime? lastSyncAt;
  final String? lastError;

  SyncState copyWith({
    int? pendingCount,
    int? conflictCount,
    int? deadLetterCount,
    bool? isSyncing,
    bool? isReady,
    bool? isInitializing,
    bool? autoSyncRunning,
    DateTime? lastSyncAt,
    String? lastError,
  }) {
    return SyncState(
      pendingCount: pendingCount ?? this.pendingCount,
      conflictCount: conflictCount ?? this.conflictCount,
      deadLetterCount: deadLetterCount ?? this.deadLetterCount,
      isSyncing: isSyncing ?? this.isSyncing,
      isReady: isReady ?? this.isReady,
      isInitializing: isInitializing ?? this.isInitializing,
      autoSyncRunning: autoSyncRunning ?? this.autoSyncRunning,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastError: lastError,
    );
  }
}

class SyncController extends StateNotifier<SyncState> {
  SyncController({
    required SyncEngine syncEngine,
    required LocalStore localStore,
  }) : _syncEngine = syncEngine,
       _localStore = localStore,
       super(const SyncState.initial());

  final SyncEngine _syncEngine;
  final LocalStore _localStore;

  Timer? _timer;
  Future<void>? _initializeFuture;

  Future<void> initialize() async {
    if (state.isReady) {
      return;
    }
    if (_initializeFuture != null) {
      return _initializeFuture;
    }

    final future = _initializeInternal();
    _initializeFuture = future;
    try {
      await future;
    } finally {
      _initializeFuture = null;
    }
  }

  Future<void> syncNow({bool background = false}) async {
    if (!state.isReady) {
      await initialize();
      if (!state.isReady) {
        return;
      }
    }

    if (state.isSyncing) {
      return;
    }

    state = state.copyWith(isSyncing: true, lastError: null);

    try {
      final summary = await _syncEngine.syncPending();
      await _refreshPendingCount();

      final statusParts = <String>[];
      if (summary.failed > 0) {
        statusParts.add('${summary.failed} item(s) queued for retry');
      }
      if (summary.conflicts > 0) {
        statusParts.add('${summary.conflicts} conflict(s) need review');
      }
      if (summary.deadLettered > 0) {
        statusParts.add(
          '${summary.deadLettered} item(s) moved to dead-letter queue',
        );
      }

      state = state.copyWith(
        isSyncing: false,
        lastSyncAt: DateTime.now(),
        lastError: statusParts.isEmpty ? null : statusParts.join(' | '),
      );
    } catch (error) {
      await _refreshPendingCount();
      state = state.copyWith(isSyncing: false, lastError: error.toString());
    }
  }

  Future<void> _initializeInternal() async {
    state = state.copyWith(
      isInitializing: true,
      autoSyncRunning: false,
      lastError: null,
    );

    try {
      await _localStore.initialize();
      await _refreshPendingCount();

      _timer ??= Timer.periodic(const Duration(seconds: 25), (_) {
        unawaited(syncNow(background: true));
      });

      state = state.copyWith(
        isReady: true,
        isInitializing: false,
        autoSyncRunning: true,
        lastError: null,
      );
    } catch (error) {
      state = state.copyWith(
        isReady: false,
        isInitializing: false,
        autoSyncRunning: false,
        lastError:
            'Offline sync storage is not ready yet. ${error.toString()}',
      );
    }
  }

  Future<void> _refreshPendingCount() async {
    final stats = await _localStore.getSyncQueueStats();
    state = state.copyWith(
      pendingCount: stats.actionable,
      conflictCount: stats.conflict,
      deadLetterCount: stats.deadLetter,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
