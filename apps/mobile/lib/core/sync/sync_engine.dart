import 'dart:async';

import '../network/api_client.dart';
import '../offline/local_store.dart';
import '../offline/local_models.dart';
import 'sync_retry_policy.dart';

enum SyncPushStatus { success, failed, conflict }

class SyncPushResult {
  const SyncPushResult({required this.status, this.error, this.remoteVersion});

  final SyncPushStatus status;
  final String? error;
  final int? remoteVersion;
}

class SyncRunSummary {
  const SyncRunSummary({
    required this.processed,
    required this.succeeded,
    required this.failed,
    required this.conflicts,
    required this.deadLettered,
  });

  final int processed;
  final int succeeded;
  final int failed;
  final int conflicts;
  final int deadLettered;
}

class SyncEngine {
  SyncEngine({required LocalStore localStore, required ApiClient apiClient})
    : _localStore = localStore,
      _apiClient = apiClient;

  final LocalStore _localStore;
  final ApiClient _apiClient;

  Future<SyncRunSummary> syncPending({int limit = 25}) async {
    final dueItems = await _localStore.getDueSyncItems(
      DateTime.now(),
      limit: limit,
    );

    var succeeded = 0;
    var failed = 0;
    var conflicts = 0;
    var deadLettered = 0;

    for (final item in dueItems) {
      await _localStore.markSyncProcessing(item.id);
      final result = await _push(item);

      if (result.status == SyncPushStatus.success) {
        succeeded += 1;
        await _localStore.markSyncSuccess(
          item,
          remoteVersion: result.remoteVersion,
        );
        continue;
      }

      if (result.status == SyncPushStatus.conflict) {
        conflicts += 1;
        await _localStore.updateDraftStatus(
          item.entityId,
          status: 'rejected',
          remoteVersion: result.remoteVersion,
        );
        await _localStore.markSyncConflict(
          item,
          error: result.error ?? 'Version conflict detected.',
        );
        continue;
      }

      final nextAttempt = item.attemptCount + 1;
      if (SyncRetryPolicy.shouldDeadLetter(nextAttempt)) {
        deadLettered += 1;
        await _localStore.markSyncDeadLetter(
          item,
          error:
              'Sync permanently failed after $nextAttempt attempts: ${result.error ?? 'Unknown sync failure.'}',
        );
        continue;
      }

      failed += 1;
      final nextRetryAt = DateTime.now().add(
        SyncRetryPolicy.backoffForAttempt(nextAttempt),
      );
      await _localStore.markSyncFailure(
        item,
        error: result.error ?? 'Sync failed',
        nextRetryAt: nextRetryAt,
      );
    }

    return SyncRunSummary(
      processed: dueItems.length,
      succeeded: succeeded,
      failed: failed,
      conflicts: conflicts,
      deadLettered: deadLettered,
    );
  }

  Future<SyncPushResult> _push(SyncQueueItem item) async {
    await Future<void>.delayed(const Duration(milliseconds: 280));

    // Keep API sync shape ready: idempotency key is prepared for future backend calls.
    _apiClient.dio.options.headers['Idempotency-Key'] = item.idempotencyKey;

    final payload = item.payload;
    final remoteVersion = (payload['simulated_remote_version'] as int?) ?? 0;

    if (item.localVersion <= remoteVersion) {
      return SyncPushResult(
        status: SyncPushStatus.conflict,
        remoteVersion: remoteVersion,
        error: 'Local version is older than remote.',
      );
    }

    if (payload['force_fail'] == true) {
      return const SyncPushResult(
        status: SyncPushStatus.failed,
        error: 'Simulated transient network error.',
      );
    }

    return SyncPushResult(
      status: SyncPushStatus.success,
      remoteVersion: item.localVersion,
    );
  }
}
