import '../../features/projects/domain/project.dart';
import 'local_models.dart';
import 'local_photo_encryption.dart';

abstract class LocalStore {
  Future<void> initialize();
  Future<void> dispose();

  Future<void> cacheProjects(List<ProjectSummary> projects);
  Future<List<ProjectSummary>> getCachedProjects();

  Future<void> cacheProjectsForOwner({
    required String ownerUserId,
    required List<ProjectSummary> projects,
  }) => cacheProjects(projects);

  Future<List<ProjectSummary>> getCachedProjectsForOwner({
    required String ownerUserId,
  }) => getCachedProjects();

  Future<void> seedIfEmpty({
    required List<ProjectSummary> projects,
    required List<LocalDraftFeature> drafts,
  });

  Future<void> upsertDraft(LocalDraftFeature draft, {bool enqueueSync = true});
  Future<List<LocalDraftFeature>> getDrafts();
  Future<LocalDraftFeature?> getDraftById(String draftId);
  Future<void> discardDraft(String draftId);
  Future<void> updateDraftStatus(
    String draftId, {
    required String status,
    int? remoteVersion,
  });

  Future<List<LocalDraftFeature>> getDraftsForOwner({
    required String ownerUserId,
  }) async => (await getDrafts())
      .where((draft) => draft.ownerUserId == ownerUserId)
      .toList(growable: false);

  Future<List<LocalDraftFeature>> getDraftsForProject({
    required String ownerUserId,
    required String projectId,
  }) async => (await getDraftsForOwner(
    ownerUserId: ownerUserId,
  )).where((draft) => draft.projectId == projectId).toList(growable: false);

  Future<LocalDraftFeature?> getProjectDraft({
    required String ownerUserId,
    required String projectId,
    required String draftId,
  }) async {
    final drafts = await getDraftsForProject(
      ownerUserId: ownerUserId,
      projectId: projectId,
    );
    for (final draft in drafts) {
      if (draft.id == draftId) {
        return draft;
      }
    }
    return null;
  }

  Future<void> discardProjectDraft({
    required String ownerUserId,
    required String projectId,
    required String draftId,
  }) => discardDraft(draftId);

  Future<void> updateProjectDraftStatus({
    required String ownerUserId,
    required String projectId,
    required String draftId,
    required String status,
    int? remoteVersion,
  }) =>
      updateDraftStatus(draftId, status: status, remoteVersion: remoteVersion);

  Future<void> upsertOfflineMapPackage(OfflineMapPackage package);
  Future<OfflineMapPackage?> getCurrentOfflineMapPackage({
    required String ownerUserId,
  });
  Future<void> upsertOfflineProjectPackage(OfflineProjectPackage package);
  Future<OfflineProjectPackage?> getOfflineProjectPackage({
    required String ownerUserId,
    required String projectId,
  });
  Future<List<OfflineProjectPackage>> getOfflineProjectPackages({
    required String ownerUserId,
  });
  Future<void> deleteOfflineProjectPackage({
    required String ownerUserId,
    required String projectId,
  });
  Future<int> countOfflineProjectPackagesUsingBaseMap({
    required String ownerUserId,
    required String baseMapVersion,
  });
  Future<int> countUnsyncedDraftsForProject({
    required String ownerUserId,
    required String projectId,
  });

  Future<int> getPendingSyncCount();
  Future<SyncQueueStats> getSyncQueueStats();
  Future<List<SyncQueueItem>> getDueSyncItems(DateTime now, {int limit = 20});
  Future<SyncQueueStats> getSyncQueueStatsForOwner({
    required String ownerUserId,
  }) => getSyncQueueStats();
  Future<List<SyncQueueItem>> getDueSyncItemsForOwner(
    String ownerUserId,
    DateTime now, {
    int limit = 20,
  }) async => (await getDueSyncItems(now, limit: limit))
      .where((item) => item.ownerUserId == ownerUserId)
      .take(limit)
      .toList(growable: false);

  /// Returns queued revisions for an owner regardless of retry time or status.
  /// Platform stores override this so a definitive account-wide rejection can
  /// remove future retries, conflicts, and legacy dead letters as well.
  Future<List<SyncQueueItem>> getSyncItemsForOwner(
    String ownerUserId, {
    int limit = 100,
  }) => getDueSyncItemsForOwner(
    ownerUserId,
    DateTime.utc(9999, 12, 31),
    limit: limit,
  );
  Future<void> enqueueSyncItem(SyncQueueItem item);
  Future<void> markSyncProcessing(String queueId);
  Future<void> markSyncSuccess(
    SyncQueueItem item, {
    int? remoteVersion,
    String? draftStatus,
  });

  /// Removes a permanently rejected local bundle. Payload-specific rejection
  /// normally remains revision guarded so a concurrently corrected revision is
  /// not lost. Definitive authorization failures set
  /// [includeSupersedingRevision] so newer revisions of the same inaccessible
  /// owner/project/draft bundle are also removed and cannot retry after restart.
  Future<void> discardRejectedSyncItem(
    SyncQueueItem item, {
    bool includeSupersedingRevision = false,
  }) => markSyncSuccess(item);
  Future<int> discardRejectedSyncItemsForOwner(String ownerUserId) async {
    final items = await getSyncItemsForOwner(ownerUserId, limit: 1000000);
    for (final item in items) {
      await discardRejectedSyncItem(item, includeSupersedingRevision: true);
    }
    return items.length;
  }

  Future<void> markSyncFailure(
    SyncQueueItem item, {
    required String error,
    required DateTime nextRetryAt,
  });
  Future<void> markSyncConflict(
    SyncQueueItem item, {
    required String error,
    int? remoteVersion,
  });
  Future<void> markSyncDeadLetter(SyncQueueItem item, {required String error});
}

abstract interface class DurableDraftPhotoStore {
  /// Retains a picker photo in storage owned by this offline draft.
  Future<String> retainDraftPhoto({
    required String ownerUserId,
    required String projectId,
    required String draftId,
    required String photoId,
    required String sourceFilePath,
    String? suggestedFileName,
  });

  /// Best-effort rollback for files retained before a draft transaction fails.
  Future<void> releaseRetainedDraftPhotos(Iterable<String> filePaths);

  /// Checks that every path is inside the app-owned directory for this exact
  /// owner/project/draft. This is a containment check; callers must also derive
  /// the paths from the matching scoped draft rows instead of queue payloads.
  Future<bool> areRetainedDraftPhotoPathsScoped({
    required String ownerUserId,
    required String projectId,
    required String draftId,
    required Iterable<String> filePaths,
  });
}

abstract interface class ProtectedDraftPhotoStore {
  /// Authenticates and decrypts one exact app-owned draft photo in memory.
  Future<DecryptedOfflinePhoto> readProtectedDraftPhoto(String filePath);
}
