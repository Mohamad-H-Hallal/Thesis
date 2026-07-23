import 'dart:async';
import 'dart:convert';

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
    this.retryAfter,
    this.discardMessage,
  });

  final SyncPushStatus status;
  final String? error;
  final int? remoteVersion;
  final bool requiresAuthentication;
  final Duration? retryAfter;
  final String? discardMessage;
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
    this.discardMessages = const <String>[],
  });

  final int processed;
  final int succeeded;
  final int failed;
  final int conflicts;
  final int discarded;
  final int deadLettered;
  final int authenticationFailures;
  final List<String> discardMessages;
}

class SyncEngine {
  SyncEngine({
    required LocalStore localStore,
    required ApiClient apiClient,
    this.ownerUserId = '',
  }) : _localStore = localStore,
       _apiClient = apiClient;

  final LocalStore _localStore;
  final ApiClient _apiClient;
  final String ownerUserId;

  Future<SyncRunSummary> syncPending({int limit = 25}) async {
    final dueItems = await _localStore.getDueSyncItemsForOwner(
      ownerUserId,
      DateTime.now(),
      limit: limit,
    );

    var processed = dueItems.length;
    var succeeded = 0;
    var failed = 0;
    var conflicts = 0;
    var discarded = 0;
    var deadLettered = 0;
    var authenticationFailures = 0;
    final discardMessages = <String>[];

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
        final discardMessage = result.discardMessage?.trim();
        if (discardMessage != null &&
            discardMessage.isNotEmpty &&
            !discardMessages.contains(discardMessage)) {
          discardMessages.add(discardMessage);
        }
        if (result.error == 'OFFLINE_SYNC_ACCOUNT_INACTIVE') {
          final ownerDiscarded = await _localStore
              .discardRejectedSyncItemsForOwner(ownerUserId);
          discarded += ownerDiscarded;
          final minimumProcessed = succeeded + discarded;
          if (minimumProcessed > processed) {
            processed = minimumProcessed;
          }
          break;
        }
        discarded += 1;
        await _localStore.discardRejectedSyncItem(
          item,
          includeSupersedingRevision: _mustDiscardSupersedingRevision(
            result.error,
          ),
        );
        continue;
      }

      if (result.status == SyncPushStatus.conflict) {
        conflicts += 1;
        await _localStore.markSyncConflict(
          item,
          error: result.error ?? 'Version conflict detected.',
          remoteVersion: result.remoteVersion,
        );
        continue;
      }

      if (result.requiresAuthentication) {
        authenticationFailures += 1;
      }
      final nextAttempt = item.attemptCount + 1;
      failed += 1;
      final nextRetryAt = DateTime.now().add(
        result.retryAfter ?? SyncRetryPolicy.backoffForAttempt(nextAttempt),
      );
      await _localStore.markSyncFailure(
        item,
        error: result.error ?? 'Sync failed',
        nextRetryAt: nextRetryAt,
      );
    }

    return SyncRunSummary(
      processed: processed,
      succeeded: succeeded,
      failed: failed,
      conflicts: conflicts,
      discarded: discarded,
      deadLettered: deadLettered,
      authenticationFailures: authenticationFailures,
      discardMessages: List<String>.unmodifiable(discardMessages),
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
    final featureId = payload['draft_id'];
    final payloadOwnerUserId = payload['owner_user_id'];
    final projectId = payload['project_id'];
    final geometryType = payload['geometry_type'];
    final geometry = payload['geometry'];
    final attributes = payload['attributes'];
    final status = payload['status'];
    final payloadLocalVersion = payload['local_version'];
    final payloadRemoteVersion = payload['remote_version'];
    final rawPhotoPaths = payload['photo_paths'];
    final rawSyncedPhotoPaths = payload['synced_photo_paths'];
    final hasValidPhotoPaths =
        rawPhotoPaths == null ||
        (rawPhotoPaths is List &&
            rawPhotoPaths.every(
              (path) => path is String && path.trim().isNotEmpty,
            ));
    final queuedPhotoPaths =
        (rawPhotoPaths is List ? rawPhotoPaths : const <dynamic>[])
            .whereType<String>()
            .toList(growable: false);
    final hasValidSyncedPhotoPaths =
        rawSyncedPhotoPaths == null ||
        (rawSyncedPhotoPaths is List &&
            rawSyncedPhotoPaths.every(
              (path) => path is String && path.trim().isNotEmpty,
            ));
    final syncedPhotoPaths =
        (rawSyncedPhotoPaths is List ? rawSyncedPhotoPaths : const <dynamic>[])
            .whereType<String>()
            .toList(growable: false);

    if (ownerUserId.isEmpty || item.ownerUserId != ownerUserId) {
      return const SyncPushResult(
        status: SyncPushStatus.failed,
        error:
            'Synchronization paused because the authenticated session changed. Offline work remains on this device.',
      );
    }

    if (item.ownerUserId.isEmpty ||
        item.projectId.isEmpty ||
        !payload.keys.every(_allowedDraftQueuePayloadKeys.contains) ||
        !_requiredDraftQueuePayloadKeys.every(payload.containsKey) ||
        featureId is! String ||
        featureId.isEmpty ||
        featureId != item.entityId ||
        payloadOwnerUserId is! String ||
        payloadOwnerUserId != item.ownerUserId ||
        projectId is! String ||
        projectId.isEmpty ||
        projectId != item.projectId ||
        item.ownerUserId != ownerUserId ||
        geometryType is! String ||
        geometry is! Map<String, dynamic> ||
        geometry['type'] != geometryType ||
        attributes is! Map<String, dynamic> ||
        status is! String ||
        !_syncableDraftStatuses.contains(status) ||
        payloadLocalVersion is! int ||
        payloadLocalVersion != item.localVersion ||
        !hasValidPhotoPaths ||
        !hasValidSyncedPhotoPaths ||
        queuedPhotoPaths.toSet().length != queuedPhotoPaths.length ||
        syncedPhotoPaths.toSet().length != syncedPhotoPaths.length ||
        item.idempotencyKey.trim().isEmpty) {
      return _localIntegrityFailure();
    }

    try {
      final draft = await _localStore.getProjectDraft(
        ownerUserId: item.ownerUserId,
        projectId: item.projectId,
        draftId: item.entityId,
      );
      if (draft == null ||
          draft.ownerUserId != item.ownerUserId ||
          draft.projectId != item.projectId ||
          draft.id != item.entityId ||
          draft.localVersion != item.localVersion ||
          draft.geometryType != geometryType ||
          draft.status != status) {
        return _localIntegrityFailure();
      }

      Map<String, dynamic> draftGeometry;
      Map<String, dynamic> draftAttributes;
      try {
        draftGeometry = Map<String, dynamic>.from(
          jsonDecode(draft.geometryJson) as Map,
        );
        draftAttributes = Map<String, dynamic>.from(
          jsonDecode(draft.attributesJson) as Map,
        );
      } catch (_) {
        return _localIntegrityFailure();
      }
      if (!_jsonValuesEqual(geometry, draftGeometry) ||
          !_jsonValuesEqual(attributes, draftAttributes)) {
        return _localIntegrityFailure();
      }

      final expectedOperation = draft.remoteVersion == null
          ? SyncOperationType.create
          : SyncOperationType.update;
      if (item.operation != expectedOperation) {
        return _localIntegrityFailure();
      }
      if (payload.containsKey('remote_version') &&
          payloadRemoteVersion != draft.remoteVersion) {
        return _localIntegrityFailure();
      }
      final sortedDraftPhotos = draft.photos.toList(growable: false)
        ..sort((left, right) => left.id.compareTo(right.id));
      final draftPhotoPaths = sortedDraftPhotos
          .map((photo) => photo.filePath)
          .toList(growable: false);
      final photoPaths = expectedOperation == SyncOperationType.create
          ? draftPhotoPaths
          : queuedPhotoPaths;
      final hasValidCreatePhotoSet =
          expectedOperation != SyncOperationType.create ||
          (_stringSetsEqual(
                queuedPhotoPaths.toSet(),
                draftPhotoPaths.toSet(),
              ) &&
              queuedPhotoPaths.length == draftPhotoPaths.length);
      final hasValidUpdatePhotoSet =
          expectedOperation != SyncOperationType.update ||
          (queuedPhotoPaths.every(draftPhotoPaths.contains) &&
              syncedPhotoPaths.every(draftPhotoPaths.contains) &&
              queuedPhotoPaths
                  .toSet()
                  .intersection(syncedPhotoPaths.toSet())
                  .isEmpty);
      if (!hasValidCreatePhotoSet ||
          !hasValidUpdatePhotoSet ||
          queuedPhotoPaths.toSet().length != queuedPhotoPaths.length) {
        return _localIntegrityFailure();
      }
      final durablePhotoStore = _localStore is DurableDraftPhotoStore
          ? _localStore as DurableDraftPhotoStore
          : null;
      if (durablePhotoStore != null &&
          !await durablePhotoStore.areRetainedDraftPhotoPathsScoped(
            ownerUserId: item.ownerUserId,
            projectId: item.projectId,
            draftId: item.entityId,
            filePaths: photoPaths,
          )) {
        // Pre-v7 drafts can still reference picker-owned files outside the new
        // app-owned root. Never upload such a path, but retain it until a safe
        // migration can copy and rebind the exact scoped draft photo rows.
        return const SyncPushResult(
          status: SyncPushStatus.failed,
          error:
              'Offline photo storage could not verify this draft bundle. It remains stored for retry.',
        );
      }

      final session = _apiClient.captureSessionForOwner(ownerUserId);
      if (session == null) {
        return const SyncPushResult(
          status: SyncPushStatus.failed,
          error:
              'Synchronization paused because the authenticated session changed. Offline work remains on this device.',
        );
      }
      final operation = switch (item.operation) {
        SyncOperationType.create => 'create',
        SyncOperationType.update => 'update',
        _ => null,
      };
      if (operation == null) {
        return SyncPushResult(
          status: SyncPushStatus.failed,
          error: 'Unsupported sync operation: ${item.operation.name}.',
        );
      }

      final formData = FormData.fromMap(<String, dynamic>{
        'payload': jsonEncode(<String, dynamic>{
          'draft_id': featureId,
          'offline_owner_user_id': item.ownerUserId,
          'project_id': item.projectId,
          'operation': operation,
          'geom': draftGeometry,
          'attributes': draftAttributes,
          'accuracy_meters': null,
          'expected_version': draft.remoteVersion,
          'submit_for_review':
              status == 'submitted' || status == 'under_review',
        }),
        if (photoPaths.isNotEmpty)
          'photos': await Future.wait(
            photoPaths.map((path) => MultipartFile.fromFile(path)),
          ),
      });
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '${AppEnv.apiVersionPrefix}/features/offline-sync',
        data: formData,
        options: _requestOptions(item, session),
      );

      final acknowledgement = _readAcknowledgement(response, item);
      if (acknowledgement == null) {
        return const SyncPushResult(
          status: SyncPushStatus.failed,
          error:
              'The server response did not confirm this offline submission. It remains stored for retry.',
        );
      }

      return SyncPushResult(
        status: SyncPushStatus.success,
        remoteVersion: acknowledgement.remoteVersion ?? item.localVersion,
      );
    } on DioException catch (error) {
      final statusCode = error.response?.statusCode;
      final message = _extractMessage(error, fallback: 'Offline sync failed.');
      final permanentRejection = _readPermanentRejection(error);

      if (permanentRejection != null) {
        return SyncPushResult(
          status: SyncPushStatus.discarded,
          error: permanentRejection.code,
          discardMessage: permanentRejection.userMessage,
        );
      }

      final versionConflict = _readVersionConflict(error);
      if (versionConflict != null) {
        return versionConflict;
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
        return SyncPushResult(status: SyncPushStatus.failed, error: message);
      }

      return SyncPushResult(
        status: SyncPushStatus.failed,
        error: message,
        retryAfter: statusCode == 429 ? _readRetryAfter(error) : null,
      );
    } catch (_) {
      return const SyncPushResult(
        status: SyncPushStatus.failed,
        error: 'Offline sync was interrupted before confirmation.',
      );
    }
  }

  SyncPushResult _localIntegrityFailure() {
    return const SyncPushResult(
      status: SyncPushStatus.failed,
      error:
          'Offline draft integrity could not be verified. It remains stored and will not be uploaded.',
    );
  }

  bool _mustDiscardSupersedingRevision(String? code) {
    return const <String>{
      'OFFLINE_SYNC_ACCOUNT_INACTIVE',
      'OFFLINE_SYNC_ACCESS_REVOKED',
      'OFFLINE_SYNC_ROLE_FORBIDDEN',
      'OFFLINE_SYNC_PROJECT_UNAVAILABLE',
      'OFFLINE_SYNC_OWNER_MISMATCH',
      'OFFLINE_SYNC_PROJECT_MISMATCH',
      'OFFLINE_SYNC_PARENT_INACCESSIBLE',
    }.contains(code);
  }

  Options _requestOptions(SyncQueueItem item, ApiSessionBinding session) {
    return _apiClient.bindAuthenticatedRequest(
      session: session,
      headers: _offlineRequestHeaders(item),
    );
  }

  Map<String, dynamic> _offlineRequestHeaders(SyncQueueItem item) {
    return <String, dynamic>{
      'Idempotency-Key': item.idempotencyKey,
      'X-Offline-Owner-Id': item.ownerUserId,
      'X-Offline-Project-Id': item.projectId,
    };
  }

  _PermanentRejection? _readPermanentRejection(DioException error) {
    final statusCode = error.response?.statusCode;
    if (statusCode == null || statusCode < 400 || statusCode >= 500) {
      return null;
    }
    final data = error.response?.data;
    if (data is! Map) {
      return null;
    }
    final errorMetadata = data['error'];
    if (errorMetadata is! Map) {
      return null;
    }
    final code = errorMetadata['code'];
    final disposition = errorMetadata['disposition'];
    final retryable = errorMetadata['retryable'];
    if (code is! String ||
        !_permanentRejectionCodes.contains(code) ||
        disposition != 'permanent_rejection' ||
        retryable != false) {
      return null;
    }
    return _PermanentRejection(
      code: code,
      userMessage: _payloadRejectionCodes.contains(code)
          ? _discardedPayloadMessage
          : _discardedAccessMessage,
    );
  }

  SyncPushResult? _readVersionConflict(DioException error) {
    if (error.response?.statusCode != 409) {
      return null;
    }
    final data = error.response?.data;
    final metadata = data is Map ? data['error'] : null;
    if (metadata is! Map ||
        metadata['code'] != 'OFFLINE_SYNC_VERSION_CONFLICT' ||
        metadata['disposition'] != 'conflict' ||
        metadata['retryable'] != false) {
      return null;
    }
    final currentVersion = metadata['current_version'];
    if (currentVersion is! int || currentVersion < 1) {
      return null;
    }
    return SyncPushResult(
      status: SyncPushStatus.conflict,
      remoteVersion: currentVersion,
      error:
          'This offline draft conflicts with a newer server version and needs review.',
    );
  }

  Duration? _readRetryAfter(DioException error) {
    final raw = error.response?.headers.value('retry-after')?.trim();
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final seconds = int.tryParse(raw);
    if (seconds == null || seconds < 0) {
      return null;
    }
    return Duration(seconds: seconds);
  }

  int? _readVersion(dynamic payload) {
    final data = payload?['data'];
    if (data is Map<String, dynamic>) {
      final version = data['version'];
      if (version is int && version > 0) {
        return version;
      }
    }
    if (payload is Map<String, dynamic>) {
      final version = payload['version'];
      if (version is int && version > 0) {
        return version;
      }
    }
    return null;
  }

  _SyncAcknowledgement? _readAcknowledgement(
    Response<Map<String, dynamic>> response,
    SyncQueueItem item,
  ) {
    final statusCode = response.statusCode;
    final payload = response.data;
    if (payload == null || payload['success'] != true) {
      return null;
    }
    final rawData = payload['data'];
    if (rawData is! Map) {
      return null;
    }
    final data = Map<String, dynamic>.from(rawData);
    final outcome = data['outcome'];
    final expectedOutcome = switch (statusCode) {
      201 => 'accepted',
      200 => 'already_synchronized',
      _ => null,
    };
    if (expectedOutcome == null ||
        outcome != expectedOutcome ||
        data['id'] != item.entityId) {
      return null;
    }
    if (data['project_id'] != item.projectId) {
      return null;
    }
    final remoteVersion = _readVersion(payload);
    if (remoteVersion == null) {
      return null;
    }
    return _SyncAcknowledgement(remoteVersion: remoteVersion);
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

const Set<String> _syncableDraftStatuses = <String>{
  'draft',
  'submitted',
  'under_review',
};

const Set<String> _requiredDraftQueuePayloadKeys = <String>{
  'draft_id',
  'owner_user_id',
  'project_id',
  'geometry_type',
  'geometry',
  'attributes',
  'photo_paths',
  'status',
  'local_version',
};

const Set<String> _allowedDraftQueuePayloadKeys = <String>{
  ..._requiredDraftQueuePayloadKeys,
  'remote_version',
  'synced_photo_paths',
};

const Set<String> _permanentRejectionCodes = <String>{
  'OFFLINE_SYNC_ACCOUNT_INACTIVE',
  'OFFLINE_SYNC_ACCESS_REVOKED',
  'OFFLINE_SYNC_ROLE_FORBIDDEN',
  'OFFLINE_SYNC_PROJECT_UNAVAILABLE',
  'OFFLINE_SYNC_OWNER_MISMATCH',
  'OFFLINE_SYNC_PROJECT_MISMATCH',
  'OFFLINE_SYNC_PARENT_INACCESSIBLE',
  'OFFLINE_SYNC_PAYLOAD_REJECTED',
  'OFFLINE_SYNC_ATTACHMENT_REJECTED',
  'OFFLINE_SYNC_IDEMPOTENCY_MISMATCH',
};

const Set<String> _payloadRejectionCodes = <String>{
  'OFFLINE_SYNC_PAYLOAD_REJECTED',
  'OFFLINE_SYNC_ATTACHMENT_REJECTED',
  'OFFLINE_SYNC_IDEMPOTENCY_MISMATCH',
};

const String _discardedAccessMessage =
    'Offline submission discarded because you no longer have access to this project.';
const String _discardedPayloadMessage =
    'Offline submission discarded because its saved data was rejected.';
bool _stringSetsEqual(Set<String> left, Set<String> right) {
  return left.length == right.length && left.containsAll(right);
}

bool _jsonValuesEqual(Object? left, Object? right) {
  if (identical(left, right)) {
    return true;
  }
  if (left is num && right is num) {
    return left == right;
  }
  if (left is String || left is bool || left == null) {
    return left == right;
  }
  if (left is List && right is List) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (!_jsonValuesEqual(left[index], right[index])) {
        return false;
      }
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) {
      return false;
    }
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_jsonValuesEqual(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  return false;
}

class _PermanentRejection {
  const _PermanentRejection({required this.code, required this.userMessage});

  final String code;
  final String userMessage;
}

class _SyncAcknowledgement {
  const _SyncAcknowledgement({this.remoteVersion});

  final int? remoteVersion;
}
