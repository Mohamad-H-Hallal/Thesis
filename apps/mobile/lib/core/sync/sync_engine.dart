import 'dart:async';

import 'package:dio/dio.dart';

import '../config/app_env.dart';
import '../network/api_client.dart';
import '../offline/local_store.dart';
import '../offline/local_models.dart';
import 'sync_retry_policy.dart';

enum SyncPushStatus { success, failed, conflict, discarded }

class SyncPushResult {
  const SyncPushResult({
    required this.status,
    this.error,
    this.remoteVersion,
    this.requiresAuthentication = false,
  });

  final SyncPushStatus status;
  final String? error;
  final int? remoteVersion;
  final bool requiresAuthentication;
}

class SyncRunSummary {
  const SyncRunSummary({
    required this.processed,
    required this.succeeded,
    required this.failed,
    required this.conflicts,
    required this.discarded,
    required this.deadLettered,
    required this.authenticationFailures,
  });

  final int processed;
  final int succeeded;
  final int failed;
  final int conflicts;
  final int discarded;
  final int deadLettered;
  final int authenticationFailures;
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
    var discarded = 0;
    var deadLettered = 0;
    var authenticationFailures = 0;

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

      if (result.status == SyncPushStatus.discarded) {
        discarded += 1;
        await _localStore.discardDraft(item.entityId);
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

      if (result.requiresAuthentication) {
        authenticationFailures += 1;
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
      discarded: discarded,
      deadLettered: deadLettered,
      authenticationFailures: authenticationFailures,
    );
  }

  Future<SyncPushResult> _push(SyncQueueItem item) async {
    if (item.entityType != 'draft_feature') {
      return SyncPushResult(
        status: SyncPushStatus.failed,
        error: 'Unsupported sync entity: ${item.entityType}.',
      );
    }

    final payload = item.payload;
    final featureId = payload['draft_id'] as String? ?? item.entityId;
    final projectId = payload['project_id'] as String?;
    final geometry = payload['geometry'];
    final attributes = payload['attributes'];
    final status = payload['status'] as String? ?? 'draft';
    final photoPaths = ((payload['photo_paths'] as List?) ?? const <dynamic>[])
        .whereType<String>()
        .where((path) => path.trim().isNotEmpty)
        .toList(growable: false);

    if (projectId == null ||
        projectId.isEmpty ||
        geometry is! Map<String, dynamic> ||
        attributes is! Map<String, dynamic>) {
      return const SyncPushResult(
        status: SyncPushStatus.failed,
        error: 'Offline draft payload is incomplete.',
      );
    }

    final previousHeaders = Map<String, dynamic>.from(
      _apiClient.dio.options.headers,
    );
    _apiClient.dio.options.headers['Idempotency-Key'] = item.idempotencyKey;

    try {
      int? remoteVersion;
      if (item.operation == SyncOperationType.create) {
        final response = await _apiClient.dio.post<Map<String, dynamic>>(
          '${AppEnv.apiVersionPrefix}/features',
          data: <String, dynamic>{
            'id': featureId,
            'client_offline_id': featureId,
            'project_id': projectId,
            'geom': geometry,
            'attributes': attributes,
            'collected_offline': true,
          },
        );
        remoteVersion = _readVersion(response.data);
      } else if (item.operation == SyncOperationType.update) {
        final response = await _apiClient.dio.put<Map<String, dynamic>>(
          '${AppEnv.apiVersionPrefix}/features/$featureId',
          data: <String, dynamic>{'geom': geometry, 'attributes': attributes},
        );
        remoteVersion = _readVersion(response.data);
      } else {
        return SyncPushResult(
          status: SyncPushStatus.failed,
          error: 'Unsupported sync operation: ${item.operation.name}.',
        );
      }

      if (photoPaths.isNotEmpty) {
        final formData = FormData.fromMap(<String, dynamic>{
          'photos': await Future.wait(
            photoPaths.map((path) => MultipartFile.fromFile(path)),
          ),
        });

        await _apiClient.dio.post<Map<String, dynamic>>(
          '${AppEnv.apiVersionPrefix}/photos/feature/$featureId',
          data: formData,
          options: Options(
            headers: <String, dynamic>{'Content-Type': 'multipart/form-data'},
          ),
        );
      }

      if (status == 'submitted' || status == 'under_review') {
        await _apiClient.dio.post<Map<String, dynamic>>(
          '${AppEnv.apiVersionPrefix}/features/$featureId/submit',
        );
      }

      return SyncPushResult(
        status: SyncPushStatus.success,
        remoteVersion: remoteVersion ?? item.localVersion,
      );
    } on DioException catch (error) {
      final statusCode = error.response?.statusCode;
      final message = _extractMessage(error, fallback: 'Offline sync failed.');

      if (statusCode == 409) {
        return SyncPushResult(
          status: SyncPushStatus.conflict,
          error: message,
          remoteVersion: _readVersion(error.response?.data),
        );
      }

      if (statusCode == 401) {
        return const SyncPushResult(
          status: SyncPushStatus.failed,
          error:
              'Sign in again to sync saved offline contributions. Your offline work is still stored on this device.',
          requiresAuthentication: true,
        );
      }

      if (statusCode == 403) {
        return SyncPushResult(status: SyncPushStatus.discarded, error: message);
      }

      return SyncPushResult(status: SyncPushStatus.failed, error: message);
    } finally {
      _apiClient.dio.options.headers
        ..clear()
        ..addAll(previousHeaders);
    }
  }

  int? _readVersion(dynamic payload) {
    final data = payload?['data'];
    if (data is Map<String, dynamic>) {
      final version = data['version'];
      if (version is int) {
        return version;
      }
      if (version is num) {
        return version.toInt();
      }
    }
    if (payload is Map<String, dynamic>) {
      final version = payload['version'];
      if (version is int) {
        return version;
      }
      if (version is num) {
        return version.toInt();
      }
    }
    return null;
  }

  String _extractMessage(DioException error, {required String fallback}) {
    final data = error.response?.data;
    if (data is Map<String, dynamic>) {
      final errors = data['errors'];
      if (errors is List && errors.isNotEmpty) {
        final first = errors.first;
        if (first is Map && first['msg'] is String) {
          final msg = (first['msg'] as String).trim();
          if (msg.isNotEmpty) {
            return msg;
          }
        }
      }
      final message = data['message'] ?? data['error'];
      if (message is String && message.trim().isNotEmpty) {
        return message.trim();
      }
    } else if (data is String && data.trim().isNotEmpty) {
      return data.trim();
    }
    return fallback;
  }
}
