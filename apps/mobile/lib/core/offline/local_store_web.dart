import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../features/projects/domain/project.dart';
import 'local_database_security.dart';
import 'local_models.dart';
import 'local_store.dart';

class MemoryLocalStore implements LocalStore {
  final Uuid _uuid = const Uuid();
  bool _initialized = false;

  final Map<String, ProjectSummary> _projects = {};
  final Map<String, LocalDraftFeature> _drafts = {};
  final Map<String, SyncQueueItem> _syncQueue = {};
  final Map<String, OfflineMapPackage> _offlinePackages = {};
  final Map<String, OfflineProjectPackage> _offlineProjectPackages = {};

  String _projectKey(String ownerUserId, String projectId) =>
      '$ownerUserId:$projectId';

  String _draftKey(String ownerUserId, String projectId, String draftId) =>
      '$ownerUserId:$projectId:$draftId';

  @override
  Future<void> initialize() async {
    final now = DateTime.now();
    _syncQueue.updateAll((_, item) {
      if (item.status != SyncQueueStatus.deadLetter ||
          item.ownerUserId.isEmpty ||
          item.projectId.isEmpty ||
          item.projectId == '__ambiguous__') {
        return item;
      }
      return item.copyWith(
        status: SyncQueueStatus.failed,
        nextRetryAt: now,
        updatedAt: now,
      );
    });
    if (_initialized) {
      return;
    }
    _syncQueue.updateAll((_, item) {
      if (item.status != SyncQueueStatus.processing) {
        return item;
      }
      return item.copyWith(
        status: SyncQueueStatus.failed,
        nextRetryAt: now,
        lastError:
            'Previous synchronization was interrupted before confirmation.',
        updatedAt: now,
      );
    });
    _initialized = true;
  }

  @override
  Future<void> dispose() async {
    _initialized = false;
    _projects.clear();
    _drafts.clear();
    _syncQueue.clear();
    _offlinePackages.clear();
    _offlineProjectPackages.clear();
  }

  Future<void> _ensureInitialized() async {
    if (!_initialized) {
      await initialize();
    }
  }

  @override
  Future<void> seedIfEmpty({
    required List<ProjectSummary> projects,
    required List<LocalDraftFeature> drafts,
  }) async {
    await _ensureInitialized();

    if (_projects.isEmpty) {
      for (final project in projects) {
        _projects[_projectKey('', project.id)] = project;
      }
    }

    if (_drafts.isEmpty) {
      for (final draft in drafts) {
        _drafts[_draftKey(draft.ownerUserId, draft.projectId, draft.id)] =
            draft;
      }
    }
  }

  @override
  Future<void> cacheProjects(List<ProjectSummary> projects) async {
    await cacheProjectsForOwner(ownerUserId: '', projects: projects);
  }

  @override
  Future<void> cacheProjectsForOwner({
    required String ownerUserId,
    required List<ProjectSummary> projects,
  }) async {
    await _ensureInitialized();
    _projects.removeWhere((key, _) => key.startsWith('$ownerUserId:'));
    _projects.addEntries(
      projects.map(
        (project) => MapEntry(_projectKey(ownerUserId, project.id), project),
      ),
    );
  }

  @override
  Future<List<ProjectSummary>> getCachedProjects() async {
    await _ensureInitialized();
    return _projects.values.toList(growable: false);
  }

  @override
  Future<List<ProjectSummary>> getCachedProjectsForOwner({
    required String ownerUserId,
  }) async {
    await _ensureInitialized();
    return _projects.entries
        .where((entry) => entry.key.startsWith('$ownerUserId:'))
        .map((entry) => entry.value)
        .toList(growable: false);
  }

  @override
  Future<void> upsertDraft(
    LocalDraftFeature draft, {
    bool enqueueSync = true,
  }) async {
    await _ensureInitialized();
    final draftKey = _draftKey(draft.ownerUserId, draft.projectId, draft.id);
    SyncQueueItem? previousQueue;
    for (final queueItem in _syncQueue.values) {
      if (queueItem.entityType == 'draft_feature' &&
          queueItem.entityId == draft.id &&
          queueItem.ownerUserId == draft.ownerUserId &&
          queueItem.projectId == draft.projectId) {
        previousQueue = queueItem;
        break;
      }
    }
    final hasPhotoSyncState =
        previousQueue?.payload.containsKey('synced_photo_paths') ?? false;
    final syncedPhotoPaths = hasPhotoSyncState
        ? _payloadPhotoPaths(<String, dynamic>{
            'photo_paths': previousQueue!.payload['synced_photo_paths'],
          }).toSet()
        : <String>{};
    final currentPhotoPaths = draft.photos
        .map((photo) => photo.filePath)
        .toSet();
    final removedSynchronizedPhoto =
        hasPhotoSyncState && !currentPhotoPaths.containsAll(syncedPhotoPaths);
    final effectiveDraft = removedSynchronizedPhoto
        ? draft.copyWith(status: 'rejected')
        : draft;
    _drafts[draftKey] = effectiveDraft;

    if (!enqueueSync) {
      return;
    }

    _syncQueue.removeWhere(
      (_, queueItem) =>
          queueItem.entityType == 'draft_feature' &&
          queueItem.entityId == effectiveDraft.id &&
          queueItem.ownerUserId == effectiveDraft.ownerUserId &&
          queueItem.projectId == effectiveDraft.projectId,
    );

    final now = DateTime.now();
    final queueId = _uuid.v4();
    _syncQueue[queueId] = SyncQueueItem(
      id: queueId,
      entityType: 'draft_feature',
      entityId: effectiveDraft.id,
      operation: effectiveDraft.remoteVersion == null
          ? SyncOperationType.create
          : SyncOperationType.update,
      payload: {
        'draft_id': effectiveDraft.id,
        'owner_user_id': effectiveDraft.ownerUserId,
        'project_id': effectiveDraft.projectId,
        'geometry_type': effectiveDraft.geometryType,
        'geometry':
            jsonDecode(effectiveDraft.geometryJson) as Map<String, dynamic>,
        'attributes':
            jsonDecode(effectiveDraft.attributesJson) as Map<String, dynamic>,
        'photo_paths': effectiveDraft.remoteVersion == null
            ? effectiveDraft.photos
                  .map((photo) => photo.filePath)
                  .toList(growable: false)
            : hasPhotoSyncState
            ? effectiveDraft.photos
                  .map((photo) => photo.filePath)
                  .where((path) => !syncedPhotoPaths.contains(path))
                  .toList(growable: false)
            : const <String>[],
        if (hasPhotoSyncState)
          'synced_photo_paths': syncedPhotoPaths.toList(growable: false),
        'status': effectiveDraft.status,
        'local_version': effectiveDraft.localVersion,
        'remote_version': effectiveDraft.remoteVersion,
      },
      ownerUserId: effectiveDraft.ownerUserId,
      projectId: effectiveDraft.projectId,
      localVersion: effectiveDraft.localVersion,
      idempotencyKey: _uuid.v4(),
      attemptCount: 0,
      status: removedSynchronizedPhoto
          ? SyncQueueStatus.conflict
          : SyncQueueStatus.pending,
      nextRetryAt: removedSynchronizedPhoto ? null : now,
      lastError: removedSynchronizedPhoto
          ? 'A photo already synchronized to the server was removed offline. Review this draft online.'
          : null,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Future<List<LocalDraftFeature>> getDrafts() async {
    await _ensureInitialized();
    final drafts = _drafts.values.toList(growable: false);
    drafts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return drafts;
  }

  @override
  Future<LocalDraftFeature?> getDraftById(String draftId) async {
    await _ensureInitialized();
    for (final draft in _drafts.values) {
      if (draft.id == draftId) {
        return draft;
      }
    }
    return null;
  }

  @override
  Future<List<LocalDraftFeature>> getDraftsForOwner({
    required String ownerUserId,
  }) async {
    await _ensureInitialized();
    final drafts = _drafts.values
        .where((draft) => draft.ownerUserId == ownerUserId)
        .toList(growable: false);
    drafts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return drafts;
  }

  @override
  Future<List<LocalDraftFeature>> getDraftsForProject({
    required String ownerUserId,
    required String projectId,
  }) async {
    final drafts = await getDraftsForOwner(ownerUserId: ownerUserId);
    return drafts
        .where((draft) => draft.projectId == projectId)
        .toList(growable: false);
  }

  @override
  Future<LocalDraftFeature?> getProjectDraft({
    required String ownerUserId,
    required String projectId,
    required String draftId,
  }) async {
    await _ensureInitialized();
    return _drafts[_draftKey(ownerUserId, projectId, draftId)];
  }

  @override
  Future<void> discardDraft(String draftId) async {
    await _ensureInitialized();
    _drafts.removeWhere((_, draft) => draft.id == draftId);
    _syncQueue.removeWhere(
      (_, item) =>
          item.entityType == 'draft_feature' && item.entityId == draftId,
    );
  }

  @override
  Future<void> discardProjectDraft({
    required String ownerUserId,
    required String projectId,
    required String draftId,
  }) async {
    await _ensureInitialized();
    _drafts.remove(_draftKey(ownerUserId, projectId, draftId));
    _syncQueue.removeWhere(
      (_, item) =>
          item.entityType == 'draft_feature' &&
          item.entityId == draftId &&
          item.ownerUserId == ownerUserId &&
          item.projectId == projectId,
    );
  }

  @override
  Future<void> updateDraftStatus(
    String draftId, {
    required String status,
    int? remoteVersion,
  }) async {
    await _ensureInitialized();
    final draft = await getDraftById(draftId);
    if (draft == null) return;

    _drafts[_draftKey(draft.ownerUserId, draft.projectId, draft.id)] = draft
        .copyWith(
          status: status,
          remoteVersion: remoteVersion,
          updatedAt: DateTime.now(),
        );
  }

  @override
  Future<void> updateProjectDraftStatus({
    required String ownerUserId,
    required String projectId,
    required String draftId,
    required String status,
    int? remoteVersion,
  }) async {
    await _ensureInitialized();
    final key = _draftKey(ownerUserId, projectId, draftId);
    final draft = _drafts[key];
    if (draft == null) return;
    _drafts[key] = draft.copyWith(
      status: status,
      remoteVersion: remoteVersion,
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<void> upsertOfflineMapPackage(OfflineMapPackage package) async {
    await _ensureInitialized();
    if (package.isCurrent) {
      _offlinePackages.updateAll((_, existing) {
        if (existing.ownerUserId != package.ownerUserId) {
          return existing;
        }
        return existing.copyWith(isCurrent: false);
      });
    }
    _offlinePackages['${package.ownerUserId}:${package.version}'] = package;
  }

  @override
  Future<OfflineMapPackage?> getCurrentOfflineMapPackage({
    required String ownerUserId,
  }) async {
    await _ensureInitialized();
    for (final package in _offlinePackages.values) {
      if (package.ownerUserId == ownerUserId && package.isCurrent) {
        return package;
      }
    }
    if (ownerUserId.isEmpty) {
      return null;
    }
    for (final entry in _offlinePackages.entries) {
      final package = entry.value;
      if (package.ownerUserId.isEmpty && package.isCurrent) {
        final migratedPackage = package.copyWith(ownerUserId: ownerUserId);
        _offlinePackages.remove(entry.key);
        _offlinePackages['${migratedPackage.ownerUserId}:${migratedPackage.version}'] =
            migratedPackage;
        return migratedPackage;
      }
    }
    return null;
  }

  @override
  Future<void> upsertOfflineProjectPackage(
    OfflineProjectPackage package,
  ) async {
    await _ensureInitialized();
    _offlineProjectPackages['${package.ownerUserId}:${package.projectId}'] =
        package;
    _projects[_projectKey(package.ownerUserId, package.project.id)] =
        package.project;
  }

  @override
  Future<OfflineProjectPackage?> getOfflineProjectPackage({
    required String ownerUserId,
    required String projectId,
  }) async {
    await _ensureInitialized();
    return _offlineProjectPackages['$ownerUserId:$projectId'];
  }

  @override
  Future<List<OfflineProjectPackage>> getOfflineProjectPackages({
    required String ownerUserId,
  }) async {
    await _ensureInitialized();
    final packages = _offlineProjectPackages.values
        .where((package) => package.ownerUserId == ownerUserId)
        .toList(growable: false);
    packages.sort((a, b) => b.refreshedAt.compareTo(a.refreshedAt));
    return packages;
  }

  @override
  Future<void> deleteOfflineProjectPackage({
    required String ownerUserId,
    required String projectId,
  }) async {
    await _ensureInitialized();
    _offlineProjectPackages.remove('$ownerUserId:$projectId');
  }

  @override
  Future<int> countOfflineProjectPackagesUsingBaseMap({
    required String ownerUserId,
    required String baseMapVersion,
  }) async {
    await _ensureInitialized();
    return _offlineProjectPackages.values
        .where(
          (package) =>
              package.ownerUserId == ownerUserId &&
              package.baseMapVersion == baseMapVersion,
        )
        .length;
  }

  @override
  Future<int> countUnsyncedDraftsForProject({
    required String ownerUserId,
    required String projectId,
  }) async {
    await _ensureInitialized();
    final draftKeys = _drafts.values
        .where(
          (draft) =>
              draft.ownerUserId == ownerUserId && draft.projectId == projectId,
        )
        .map((draft) => _draftKey(ownerUserId, projectId, draft.id))
        .toSet();
    return _syncQueue.values
        .where(
          (item) =>
              item.entityType == 'draft_feature' &&
              draftKeys.contains(
                _draftKey(item.ownerUserId, item.projectId, item.entityId),
              ) &&
              (item.status == SyncQueueStatus.pending ||
                  item.status == SyncQueueStatus.processing ||
                  item.status == SyncQueueStatus.failed ||
                  item.status == SyncQueueStatus.conflict ||
                  item.status == SyncQueueStatus.deadLetter),
        )
        .length;
  }

  @override
  Future<int> getPendingSyncCount() async {
    await _ensureInitialized();
    return (await getSyncQueueStats()).actionable;
  }

  @override
  Future<SyncQueueStats> getSyncQueueStats() async {
    return _syncQueueStats(_syncQueue.values);
  }

  @override
  Future<SyncQueueStats> getSyncQueueStatsForOwner({
    required String ownerUserId,
  }) async {
    await _ensureInitialized();

    return _syncQueueStats(
      _syncQueue.values.where((item) => item.ownerUserId == ownerUserId),
    );
  }

  Future<SyncQueueStats> _syncQueueStats(Iterable<SyncQueueItem> items) async {
    await _ensureInitialized();

    var pending = 0;
    var processing = 0;
    var failed = 0;
    var conflict = 0;
    var deadLetter = 0;

    for (final item in items) {
      switch (item.status) {
        case SyncQueueStatus.pending:
          pending += 1;
          break;
        case SyncQueueStatus.processing:
          processing += 1;
          break;
        case SyncQueueStatus.failed:
          failed += 1;
          break;
        case SyncQueueStatus.conflict:
          conflict += 1;
          break;
        case SyncQueueStatus.deadLetter:
          deadLetter += 1;
          break;
      }
    }

    return SyncQueueStats(
      pending: pending,
      processing: processing,
      failed: failed,
      conflict: conflict,
      deadLetter: deadLetter,
    );
  }

  @override
  Future<List<SyncQueueItem>> getDueSyncItems(
    DateTime now, {
    int limit = 20,
  }) async {
    await _ensureInitialized();

    final due = _syncQueue.values
        .where((item) {
          final dueByStatus =
              item.status == SyncQueueStatus.pending ||
              item.status == SyncQueueStatus.failed;
          if (!dueByStatus) {
            return false;
          }

          final retryAt = item.nextRetryAt;
          return retryAt == null || !retryAt.isAfter(now);
        })
        .toList(growable: false);

    due.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return due.take(limit).toList(growable: false);
  }

  @override
  Future<List<SyncQueueItem>> getDueSyncItemsForOwner(
    String ownerUserId,
    DateTime now, {
    int limit = 20,
  }) async {
    await _ensureInitialized();
    final due = _syncQueue.values
        .where((item) {
          if (item.ownerUserId != ownerUserId) {
            return false;
          }
          final dueByStatus =
              item.status == SyncQueueStatus.pending ||
              item.status == SyncQueueStatus.failed;
          if (!dueByStatus) {
            return false;
          }
          final retryAt = item.nextRetryAt;
          return retryAt == null || !retryAt.isAfter(now);
        })
        .toList(growable: false);
    due.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return due.take(limit).toList(growable: false);
  }

  @override
  Future<List<SyncQueueItem>> getSyncItemsForOwner(
    String ownerUserId, {
    int limit = 100,
  }) async {
    await _ensureInitialized();
    final items = _syncQueue.values
        .where((item) => item.ownerUserId == ownerUserId)
        .toList(growable: false);
    items.sort((left, right) {
      final createdComparison = left.createdAt.compareTo(right.createdAt);
      return createdComparison != 0
          ? createdComparison
          : left.id.compareTo(right.id);
    });
    return items.take(limit).toList(growable: false);
  }

  @override
  Future<void> enqueueSyncItem(SyncQueueItem item) async {
    await _ensureInitialized();
    _syncQueue[item.id] = item;
  }

  @override
  Future<void> markSyncProcessing(String queueId) async {
    await _ensureInitialized();
    final item = _syncQueue[queueId];
    if (item == null) return;

    _syncQueue[queueId] = item.copyWith(
      status: SyncQueueStatus.processing,
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<void> markSyncSuccess(
    SyncQueueItem item, {
    int? remoteVersion,
    String? draftStatus,
  }) async {
    await _ensureInitialized();
    final draftKey = _draftKey(item.ownerUserId, item.projectId, item.entityId);
    final draft = _drafts[draftKey];
    if (_isCurrentQueueRevision(item) &&
        (draft == null || draft.localVersion == item.localVersion)) {
      _syncQueue.remove(item.id);
      _drafts.remove(draftKey);
      return;
    }

    if (remoteVersion == null ||
        draft == null ||
        draft.localVersion <= item.localVersion) {
      return;
    }
    if (item.operation == SyncOperationType.create &&
        draft.remoteVersion != null) {
      return;
    }
    if (item.operation == SyncOperationType.update &&
        draft.remoteVersion != item.payload['remote_version']) {
      return;
    }

    MapEntry<String, SyncQueueItem>? replacementEntry;
    for (final entry in _syncQueue.entries) {
      final replacement = entry.value;
      if (replacement.ownerUserId == item.ownerUserId &&
          replacement.projectId == item.projectId &&
          replacement.entityType == item.entityType &&
          replacement.entityId == item.entityId &&
          replacement.operation == item.operation &&
          replacement.localVersion == draft.localVersion) {
        replacementEntry = entry;
        break;
      }
    }
    if (replacementEntry == null) {
      return;
    }

    final acknowledgedPaths = <String>{
      ..._payloadPhotoPaths(<String, dynamic>{
        'photo_paths': item.payload['synced_photo_paths'],
      }),
      ..._payloadPhotoPaths(item.payload),
    };
    final currentPhotoPaths = draft.photos
        .map((photo) => photo.filePath)
        .toSet();
    final removedSynchronizedPhoto = !currentPhotoPaths.containsAll(
      acknowledgedPaths,
    );
    final pendingPhotoPaths = draft.photos
        .map((photo) => photo.filePath)
        .where((path) => !acknowledgedPaths.contains(path))
        .toList(growable: false);
    final replacement = replacementEntry.value;
    final rebasedPayload = Map<String, dynamic>.from(replacement.payload)
      ..['photo_paths'] = pendingPhotoPaths
      ..['synced_photo_paths'] = acknowledgedPaths.toList(growable: false)
      ..['remote_version'] = remoteVersion;
    if (removedSynchronizedPhoto) {
      rebasedPayload['status'] = 'rejected';
    }
    final now = DateTime.now();
    _drafts[draftKey] = draft.copyWith(
      remoteVersion: remoteVersion,
      status: removedSynchronizedPhoto ? 'rejected' : draft.status,
    );
    _syncQueue[replacementEntry.key] = SyncQueueItem(
      id: replacement.id,
      entityType: replacement.entityType,
      entityId: replacement.entityId,
      operation: SyncOperationType.update,
      payload: rebasedPayload,
      ownerUserId: replacement.ownerUserId,
      projectId: replacement.projectId,
      localVersion: replacement.localVersion,
      idempotencyKey: replacement.idempotencyKey,
      attemptCount: 0,
      status: removedSynchronizedPhoto
          ? SyncQueueStatus.conflict
          : SyncQueueStatus.pending,
      nextRetryAt: removedSynchronizedPhoto ? null : now,
      lastError: removedSynchronizedPhoto
          ? 'A photo accepted by the server was removed by a newer offline edit. Review this draft online.'
          : null,
      createdAt: replacement.createdAt,
      updatedAt: now,
    );
  }

  @override
  Future<void> discardRejectedSyncItem(
    SyncQueueItem item, {
    bool includeSupersedingRevision = false,
  }) async {
    await _ensureInitialized();
    if (!includeSupersedingRevision) {
      await markSyncSuccess(item);
      return;
    }
    _syncQueue.removeWhere(
      (_, candidate) =>
          candidate.ownerUserId == item.ownerUserId &&
          candidate.projectId == item.projectId &&
          candidate.entityType == item.entityType &&
          candidate.entityId == item.entityId,
    );
    _drafts.remove(_draftKey(item.ownerUserId, item.projectId, item.entityId));
  }

  @override
  Future<int> discardRejectedSyncItemsForOwner(String ownerUserId) async {
    await _ensureInitialized();
    final queueIds = _syncQueue.entries
        .where((entry) => entry.value.ownerUserId == ownerUserId)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final queueId in queueIds) {
      _syncQueue.remove(queueId);
    }
    _drafts.removeWhere((_, draft) => draft.ownerUserId == ownerUserId);
    return queueIds.length;
  }

  @override
  Future<void> markSyncFailure(
    SyncQueueItem item, {
    required String error,
    required DateTime nextRetryAt,
  }) async {
    await _ensureInitialized();
    if (!_isCurrentQueueRevision(item)) {
      return;
    }
    _syncQueue[item.id] = item.copyWith(
      attemptCount: item.attemptCount + 1,
      status: SyncQueueStatus.failed,
      nextRetryAt: nextRetryAt,
      lastError: error,
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<void> markSyncConflict(
    SyncQueueItem item, {
    required String error,
    int? remoteVersion,
  }) async {
    await _ensureInitialized();
    if (!_isCurrentQueueRevision(item)) {
      return;
    }
    _syncQueue[item.id] = item.copyWith(
      attemptCount: item.attemptCount + 1,
      status: SyncQueueStatus.conflict,
      nextRetryAt: null,
      lastError: error,
      updatedAt: DateTime.now(),
    );
    final draftKey = _draftKey(item.ownerUserId, item.projectId, item.entityId);
    final draft = _drafts[draftKey];
    if (draft != null && draft.localVersion == item.localVersion) {
      _drafts[draftKey] = draft.copyWith(
        status: 'rejected',
        remoteVersion: remoteVersion,
      );
    }
  }

  @override
  Future<void> markSyncDeadLetter(
    SyncQueueItem item, {
    required String error,
  }) async {
    await _ensureInitialized();
    if (!_isCurrentQueueRevision(item)) {
      return;
    }
    _syncQueue[item.id] = item.copyWith(
      attemptCount: item.attemptCount + 1,
      status: SyncQueueStatus.deadLetter,
      nextRetryAt: null,
      lastError: error,
      updatedAt: DateTime.now(),
    );
  }

  bool _isCurrentQueueRevision(SyncQueueItem expected) {
    final current = _syncQueue[expected.id];
    return current != null &&
        current.ownerUserId == expected.ownerUserId &&
        current.projectId == expected.projectId &&
        current.entityType == expected.entityType &&
        current.entityId == expected.entityId &&
        current.operation == expected.operation &&
        current.localVersion == expected.localVersion &&
        current.idempotencyKey == expected.idempotencyKey;
  }

  List<String> _payloadPhotoPaths(Map<String, dynamic> payload) {
    final rawPaths = payload['photo_paths'];
    if (rawPaths is! List) {
      return const <String>[];
    }
    return rawPaths.whereType<String>().toList(growable: false);
  }
}

LocalStore createPlatformLocalStore({
  required LocalDatabaseKeyManager databaseKeyManager,
}) => MemoryLocalStore();
