import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/offline/local_models.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store_web.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/project.dart';

void main() {
  test('memory local store initializes itself on first use', () async {
    final store = MemoryLocalStore();

    expect(await store.getCachedProjects(), isEmpty);

    await store.cacheProjects(const <ProjectSummary>[
      ProjectSummary(
        id: 'p1',
        name: 'Runtime Project',
        category: 'Green',
        status: 'active',
        assignedCollectors: 0,
        pendingReviews: 0,
        description: 'Auto-init validation',
      ),
    ]);

    final projects = await store.getCachedProjects();
    expect(projects, hasLength(1));
    expect(projects.first.name, 'Runtime Project');
  });

  test(
    'owner queue listing includes future and non-actionable statuses',
    () async {
      final store = MemoryLocalStore();
      final now = DateTime.utc(2026, 7, 23);
      SyncQueueItem item({
        required String id,
        required String ownerUserId,
        required SyncQueueStatus status,
        DateTime? nextRetryAt,
      }) => SyncQueueItem(
        id: id,
        entityType: 'draft_feature',
        entityId: 'draft-$id',
        operation: SyncOperationType.create,
        payload: <String, dynamic>{
          'owner_user_id': ownerUserId,
          'project_id': 'project-1',
        },
        ownerUserId: ownerUserId,
        projectId: 'project-1',
        localVersion: 1,
        idempotencyKey: 'key-$id',
        attemptCount: 0,
        status: status,
        nextRetryAt: nextRetryAt,
        createdAt: now.add(Duration(minutes: id.codeUnitAt(0))),
        updatedAt: now,
      );

      await store.enqueueSyncItem(
        item(
          id: 'a-future',
          ownerUserId: 'owner-a',
          status: SyncQueueStatus.failed,
          nextRetryAt: now.add(const Duration(days: 30)),
        ),
      );
      await store.enqueueSyncItem(
        item(
          id: 'b-conflict',
          ownerUserId: 'owner-a',
          status: SyncQueueStatus.conflict,
        ),
      );
      await store.enqueueSyncItem(
        item(
          id: 'c-other-owner',
          ownerUserId: 'owner-b',
          status: SyncQueueStatus.pending,
        ),
      );

      final ownerItems = await store.getSyncItemsForOwner('owner-a');

      expect(ownerItems.map((entry) => entry.id).toSet(), <String>{
        'a-future',
        'b-conflict',
      });
    },
  );
}
