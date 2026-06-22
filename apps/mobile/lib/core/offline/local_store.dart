import '../../features/projects/domain/project.dart';
import 'local_models.dart';

abstract class LocalStore {
  Future<void> initialize();
  Future<void> dispose();

  Future<void> cacheProjects(List<ProjectSummary> projects);
  Future<List<ProjectSummary>> getCachedProjects();

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
  Future<void> enqueueSyncItem(SyncQueueItem item);
  Future<void> markSyncProcessing(String queueId);
  Future<void> markSyncSuccess(
    SyncQueueItem item, {
    int? remoteVersion,
    String? draftStatus,
  });
  Future<void> markSyncFailure(
    SyncQueueItem item, {
    required String error,
    required DateTime nextRetryAt,
  });
  Future<void> markSyncConflict(SyncQueueItem item, {required String error});
  Future<void> markSyncDeadLetter(SyncQueueItem item, {required String error});
}
