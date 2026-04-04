import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/offline/local_models.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store_web.dart';
import 'package:lebanese_gis_mobile/features/review/application/review_workflow_service.dart';
import 'package:lebanese_gis_mobile/features/review/domain/review_workflow.dart';

void main() {
  late MemoryLocalStore localStore;
  late List<String> emittedNotifications;
  late ReviewWorkflowService service;

  LocalDraftFeature seedDraft() {
    return LocalDraftFeature(
      id: 'draft-wf-1',
      projectId: 'proj-1',
      projectName: 'Bekaa Orchard Census 2026',
      geometryType: 'Point',
      geometryJson: '{"type":"Point","coordinates":[35.58,33.92]}',
      attributesJson: '{"attributes":{"tree":"olive"}}',
      photos: const <DraftPhoto>[],
      status: DraftWorkflowStatus.draft,
      localVersion: 1,
      updatedAt: DateTime.now(),
    );
  }

  setUp(() async {
    localStore = MemoryLocalStore();
    await localStore.initialize();
    emittedNotifications = <String>[];
    service = ReviewWorkflowService(
      localStore: localStore,
      emitNotification: ({required String title, required String message}) {
        emittedNotifications.add('$title::$message');
      },
    );

    await localStore.upsertDraft(seedDraft(), enqueueSync: false);
  });

  tearDown(() async {
    await localStore.dispose();
  });

  test('submit -> review -> approve workflow is persisted', () async {
    await service.submitDraft(draftId: 'draft-wf-1', actorName: 'Contributor');
    await service.startReview(draftId: 'draft-wf-1', reviewerName: 'Reviewer');
    await service.approveDraft(
      draftId: 'draft-wf-1',
      reviewerName: 'Reviewer',
      note: 'Validated geometry and attributes.',
    );

    final updated = (await localStore.getDrafts()).first;
    final snapshot = DraftWorkflowCodec.fromDraft(updated);

    expect(updated.status, DraftWorkflowStatus.approved);
    expect(snapshot.timeline.map((e) => e.type), <DraftWorkflowEventType>[
      DraftWorkflowEventType.created,
      DraftWorkflowEventType.submitted,
      DraftWorkflowEventType.reviewStarted,
      DraftWorkflowEventType.approved,
    ]);
    expect(snapshot.lastReviewNote, contains('Validated geometry'));
    expect(emittedNotifications.length, 3);
  });

  test('reject requires non-empty note', () async {
    await service.submitDraft(draftId: 'draft-wf-1', actorName: 'Contributor');

    expect(
      () => service.rejectDraft(
        draftId: 'draft-wf-1',
        reviewerName: 'Reviewer',
        note: '',
      ),
      throwsA(isA<StateError>()),
    );
  });
}
