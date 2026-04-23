import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../features/projects/domain/project.dart';
import 'local_models.dart';
import 'local_store.dart';

class MemoryLocalStore implements LocalStore {
  final Uuid _uuid = const Uuid();
  bool _initialized = false;

  final Map<String, ProjectSummary> _projects = {};
  final Map<String, LocalDraftFeature> _drafts = {};
  final Map<String, SyncQueueItem> _syncQueue = {};
  final Map<String, OfflineMapPackage> _offlinePackages = {};

  @override
  Future<void> initialize() async {
    _initialized = true;
  }

  @override
  Future<void> dispose() async {
    _initialized = false;
    _projects.clear();
    _drafts.clear();
    _syncQueue.clear();
    _offlinePackages.clear();
  }

  void _checkInit() {
    if (!_initialized) {
      throw StateError('LocalStore not initialized.');
    }
  }

  @override
  Future<void> seedIfEmpty({
    required List<ProjectSummary> projects,
    required List<LocalDraftFeature> drafts,
  }) async {
    _checkInit();

    if (_projects.isEmpty) {
      for (final project in projects) {
        _projects[project.id] = project;
      }
    }

    if (_drafts.isEmpty) {
      for (final draft in drafts) {
        _drafts[draft.id] = draft;
      }
    }
  }

  @override
  Future<void> cacheProjects(List<ProjectSummary> projects) async {
    _checkInit();
    _projects
      ..clear()
      ..addEntries(projects.map((p) => MapEntry(p.id, p)));
  }

  @override
  Future<List<ProjectSummary>> getCachedProjects() async {
    _checkInit();
    return _projects.values.toList(growable: false);
  }

  @override
  Future<void> upsertDraft(
    LocalDraftFeature draft, {
    bool enqueueSync = true,
  }) async {
    _checkInit();
    _drafts[draft.id] = draft;

    if (!enqueueSync) {
      return;
    }

    _syncQueue.removeWhere(
      (_, queueItem) =>
          queueItem.entityType == 'draft_feature' &&
          queueItem.entityId == draft.id,
    );

    final now = DateTime.now();
    final queueId = _uuid.v4();
    _syncQueue[queueId] = SyncQueueItem(
      id: queueId,
      entityType: 'draft_feature',
      entityId: draft.id,
      operation: draft.remoteVersion == null
          ? SyncOperationType.create
          : SyncOperationType.update,
      payload: {
        'draft_id': draft.id,
        'project_id': draft.projectId,
        'geometry_type': draft.geometryType,
        'geometry': jsonDecode(draft.geometryJson) as Map<String, dynamic>,
        'attributes': jsonDecode(draft.attributesJson) as Map<String, dynamic>,
        'photo_paths': draft.remoteVersion == null
            ? draft.photos
                  .map((photo) => photo.filePath)
                  .toList(growable: false)
            : const <String>[],
        'status': draft.status,
        'local_version': draft.localVersion,
      },
      localVersion: draft.localVersion,
      idempotencyKey: _uuid.v4(),
      attemptCount: 0,
      status: SyncQueueStatus.pending,
      nextRetryAt: now,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Future<List<LocalDraftFeature>> getDrafts() async {
    _checkInit();
    final drafts = _drafts.values.toList(growable: false);
    drafts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return drafts;
  }

  @override
  Future<LocalDraftFeature?> getDraftById(String draftId) async {
    _checkInit();
    return _drafts[draftId];
  }

  @override
  Future<void> updateDraftStatus(
    String draftId, {
    required String status,
    int? remoteVersion,
  }) async {
    _checkInit();
    final draft = _drafts[draftId];
    if (draft == null) return;

    _drafts[draftId] = draft.copyWith(
      status: status,
      remoteVersion: remoteVersion,
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<void> upsertOfflineMapPackage(OfflineMapPackage package) async {
    _checkInit();
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
    _checkInit();
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
  Future<int> getPendingSyncCount() async {
    _checkInit();
    return (await getSyncQueueStats()).actionable;
  }

  @override
  Future<SyncQueueStats> getSyncQueueStats() async {
    _checkInit();

    var pending = 0;
    var processing = 0;
    var failed = 0;
    var conflict = 0;
    var deadLetter = 0;

    for (final item in _syncQueue.values) {
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
    _checkInit();

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
  Future<void> enqueueSyncItem(SyncQueueItem item) async {
    _checkInit();
    _syncQueue[item.id] = item;
  }

  @override
  Future<void> markSyncProcessing(String queueId) async {
    _checkInit();
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
    _checkInit();
    _syncQueue.remove(item.id);

    final draft = _drafts[item.entityId];
    if (draft == null) return;

    _drafts[item.entityId] = draft.copyWith(
      status: draftStatus ?? draft.status,
      remoteVersion: remoteVersion,
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<void> markSyncFailure(
    SyncQueueItem item, {
    required String error,
    required DateTime nextRetryAt,
  }) async {
    _checkInit();
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
  }) async {
    _checkInit();
    _syncQueue[item.id] = item.copyWith(
      attemptCount: item.attemptCount + 1,
      status: SyncQueueStatus.conflict,
      nextRetryAt: null,
      lastError: error,
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<void> markSyncDeadLetter(
    SyncQueueItem item, {
    required String error,
  }) async {
    _checkInit();
    _syncQueue[item.id] = item.copyWith(
      attemptCount: item.attemptCount + 1,
      status: SyncQueueStatus.deadLetter,
      nextRetryAt: null,
      lastError: error,
      updatedAt: DateTime.now(),
    );
  }
}

LocalStore createPlatformLocalStore() => MemoryLocalStore();
