import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/offline/local_models.dart';
import 'package:lebanese_gis_mobile/features/review/domain/review_workflow.dart';

void main() {
  LocalDraftFeature seedDraft() {
    return LocalDraftFeature(
      id: 'draft-1',
      projectId: 'proj-1',
      projectName: 'Bekaa',
      geometryType: 'Point',
      attributesJson: '{"attributes":{"tree":"olive"}}',
      photos: const <DraftPhoto>[],
      status: DraftWorkflowStatus.draft,
      localVersion: 1,
      updatedAt: DateTime(2026, 2, 21, 10, 0),
    );
  }

  test('creates fallback timeline when workflow metadata is absent', () {
    final snapshot = DraftWorkflowCodec.fromDraft(seedDraft());

    expect(snapshot.status, DraftWorkflowStatus.draft);
    expect(snapshot.timeline.length, 1);
    expect(snapshot.timeline.first.type, DraftWorkflowEventType.created);
  });

  test('applyTransition updates status, local version and timeline', () {
    final draft = seedDraft();
    final updated = DraftWorkflowCodec.applyTransition(
      draft: draft,
      nextStatus: DraftWorkflowStatus.submitted,
      event: DraftWorkflowEvent(
        type: DraftWorkflowEventType.submitted,
        actor: 'Contributor',
        at: DateTime(2026, 2, 21, 10, 5),
      ),
    );

    final snapshot = DraftWorkflowCodec.fromDraft(updated);
    expect(updated.status, DraftWorkflowStatus.submitted);
    expect(updated.localVersion, draft.localVersion + 1);
    expect(snapshot.timeline.length, 2);
    expect(snapshot.timeline.last.type, DraftWorkflowEventType.submitted);
  });
}
