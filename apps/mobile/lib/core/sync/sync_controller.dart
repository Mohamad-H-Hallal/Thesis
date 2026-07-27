import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/network_availability_base.dart';
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

class SyncController extends StateNotifier<SyncState>
    with WidgetsBindingObserver {
  SyncController({
    required SyncEngine syncEngine,
    required LocalStore localStore,
    required NetworkAvailabilityService networkAvailability,
    this.ownerUserId = '',
    this.onLocalDataChanged,
  }) : _syncEngine = syncEngine,
       _localStore = localStore,
       _networkAvailability = networkAvailability,
       super(const SyncState.initial());

  final SyncEngine _syncEngine;
  final LocalStore _localStore;
  final NetworkAvailabilityService _networkAvailability;
  final String ownerUserId;
  final VoidCallback? onLocalDataChanged;

  Timer? _timer;
  Future<void>? _initializeFuture;
  Future<void>? _syncFuture;
  StreamSubscription<bool>? _connectivitySubscription;
  bool _lastKnownOnline = false;
  bool _lifecycleObserverRegistered = false;

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

  Future<void> refreshStatus() async {
    try {
      await _localStore.initialize();
      await _refreshPendingCount();
      if (!mounted) {
        return;
      }
      state = state.copyWith(lastError: state.lastError);
    } catch (error) {
      if (!mounted) {
        return;
      }
      state = state.copyWith(
        lastError: 'Saved offline changes are not available yet.',
      );
    }
  }

  Future<void> syncNow({bool background = false}) {
    final inFlight = _syncFuture;
    if (inFlight != null) {
      return inFlight;
    }

    final future = _syncNowInternal(background: background);
    _syncFuture = future;
    return future.whenComplete(() {
      if (identical(_syncFuture, future)) {
        _syncFuture = null;
      }
    });
  }

  Future<void> checkForPendingSync({bool background = true}) async {
    if (_syncFuture != null || state.isSyncing) {
      return _syncFuture;
    }
    await initialize();
    if (!mounted) {
      return;
    }
    await _refreshPendingCount();
    if (!mounted || state.pendingCount <= 0) {
      return;
    }
    final isOnline = await _networkAvailability.isOnline();
    _lastKnownOnline = isOnline;
    if (!isOnline) {
      return;
    }
    await syncNow(background: background);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(checkForPendingSync(background: true));
    }
  }

  Future<void> _syncNowInternal({required bool background}) async {
    try {
      await _localStore.initialize();
    } catch (_) {
      // The controller state update below will expose the error message.
    }

    if (!state.isReady) {
      await initialize();
      if (!mounted) {
        return;
      }
      if (!state.isReady) {
        return;
      }
    }

    final isOnline = await _networkAvailability.isOnline();
    _lastKnownOnline = isOnline;
    if (!mounted) {
      return;
    }
    if (!isOnline) {
      await _refreshPendingCount();
      if (!mounted) {
        return;
      }
      state = state.copyWith(
        isSyncing: false,
        lastError:
            'Reconnect to the internet to sync saved offline contributions.',
      );
      return;
    }

    state = state.copyWith(isSyncing: true, lastError: null);

    try {
      await _localStore.initialize();
      final summary = await _syncEngine.syncPending();
      if (summary.processed > 0) {
        onLocalDataChanged?.call();
      }
      await _refreshPendingCount();
      if (!mounted) {
        return;
      }

      final statusParts = <String>[];
      if (summary.failed > 0) {
        statusParts.add('${summary.failed} item(s) queued for retry');
      }
      if (summary.conflicts > 0) {
        statusParts.add('${summary.conflicts} conflict(s) need review');
      }
      if (summary.discarded > 0) {
        if (summary.discardMessages.isNotEmpty) {
          statusParts.addAll(summary.discardMessages);
        } else {
          statusParts.add(
            '${summary.discarded} offline contribution(s) were discarded because project access changed',
          );
        }
      }
      if (summary.deadLettered > 0) {
        statusParts.add(
          '${summary.deadLettered} item(s) moved to dead-letter queue',
        );
      }
      if (summary.authenticationFailures > 0) {
        statusParts.add(
          'Sign in again to sync saved offline contributions. Your offline work is still stored on this device.',
        );
      }

      state = state.copyWith(
        isSyncing: false,
        lastSyncAt: DateTime.now(),
        lastError: statusParts.isEmpty ? null : statusParts.join(' | '),
      );
    } catch (error) {
      await _refreshPendingCount();
      if (!mounted) {
        return;
      }
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
      _connectivitySubscription ??= _networkAvailability.onOnlineStatusChanged
          .listen((isOnline) {
            unawaited(_handleConnectivityChange(isOnline));
          });
      if (!_lifecycleObserverRegistered) {
        WidgetsBinding.instance.addObserver(this);
        _lifecycleObserverRegistered = true;
      }

      if (!mounted) {
        return;
      }
      _lastKnownOnline = await _networkAvailability.isOnline();
      if (!mounted) {
        return;
      }
      state = state.copyWith(
        isReady: true,
        isInitializing: false,
        autoSyncRunning: true,
        lastError: null,
      );
      unawaited(checkForPendingSync(background: true));
    } catch (error) {
      if (!mounted) {
        return;
      }
      state = state.copyWith(
        isReady: false,
        isInitializing: false,
        autoSyncRunning: false,
        lastError: 'Saved offline changes are not available yet.',
      );
    }
  }

  Future<void> _handleConnectivityChange(bool hasNetworkInterface) async {
    if (!hasNetworkInterface) {
      _lastKnownOnline = false;
      return;
    }
    final wasOnline = _lastKnownOnline;
    final isOnline = await _networkAvailability.isOnline();
    _lastKnownOnline = isOnline;
    if (!mounted || !isOnline || wasOnline) {
      return;
    }
    await checkForPendingSync(background: true);
  }

  Future<void> _refreshPendingCount() async {
    await _localStore.initialize();
    final stats = await _localStore.getSyncQueueStatsForOwner(
      ownerUserId: ownerUserId,
    );
    if (!mounted) {
      return;
    }
    state = state.copyWith(
      pendingCount: stats.actionable,
      conflictCount: stats.conflict,
      deadLetterCount: stats.deadLetter,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _connectivitySubscription?.cancel();
    if (_lifecycleObserverRegistered) {
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }
}
