import '../../../core/offline/local_models.dart';
import '../../../core/offline/local_store.dart';
import '../domain/review_workflow.dart';

typedef ReviewNotificationEmitter =
    void Function({required String title, required String message});

class ReviewWorkflowService {
  ReviewWorkflowService({
    required LocalStore localStore,
    required ReviewNotificationEmitter emitNotification,
  }) : _localStore = localStore,
       _emitNotification = emitNotification;

  final LocalStore _localStore;
  final ReviewNotificationEmitter _emitNotification;

  Future<void> submitDraft({
    required String draftId,
    required String actorName,
  }) async {
    await _transition(
      draftId: draftId,
      actorName: actorName,
      expectedCurrentStatuses: const <String>[
        DraftWorkflowStatus.draft,
        DraftWorkflowStatus.rejected,
      ],
      nextStatus: DraftWorkflowStatus.submitted,
      eventType: DraftWorkflowEventType.submitted,
      note: null,
      notificationTitle: 'Draft submitted',
      notificationMessage:
          'A feature was submitted and is waiting in the review queue.',
    );
  }

  Future<void> startReview({
    required String draftId,
    required String reviewerName,
  }) async {
    await _transition(
      draftId: draftId,
      actorName: reviewerName,
      expectedCurrentStatuses: const <String>[DraftWorkflowStatus.submitted],
      nextStatus: DraftWorkflowStatus.underReview,
      eventType: DraftWorkflowEventType.reviewStarted,
      note: null,
      notificationTitle: 'Review started',
      notificationMessage:
          'Draft $draftId is now under review by $reviewerName.',
    );
  }

  Future<void> approveDraft({
    required String draftId,
    required String reviewerName,
    required String note,
  }) async {
    await _transition(
      draftId: draftId,
      actorName: reviewerName,
      expectedCurrentStatuses: const <String>[
        DraftWorkflowStatus.submitted,
        DraftWorkflowStatus.underReview,
      ],
      nextStatus: DraftWorkflowStatus.approved,
      eventType: DraftWorkflowEventType.approved,
      note: note,
      notificationTitle: 'Draft approved',
      notificationMessage:
          'Draft $draftId was approved. ${note.isEmpty ? '' : 'Note: $note'}',
    );
  }

  Future<void> rejectDraft({
    required String draftId,
    required String reviewerName,
    required String note,
  }) async {
    if (note.trim().isEmpty) {
      throw StateError('Rejection note is required.');
    }
    await _transition(
      draftId: draftId,
      actorName: reviewerName,
      expectedCurrentStatuses: const <String>[
        DraftWorkflowStatus.submitted,
        DraftWorkflowStatus.underReview,
      ],
      nextStatus: DraftWorkflowStatus.rejected,
      eventType: DraftWorkflowEventType.rejected,
      note: note,
      notificationTitle: 'Draft rejected',
      notificationMessage:
          'Draft $draftId was rejected. ${note.isEmpty ? '' : 'Note: $note'}',
    );
  }

  Future<void> _transition({
    required String draftId,
    required String actorName,
    required List<String> expectedCurrentStatuses,
    required String nextStatus,
    required DraftWorkflowEventType eventType,
    required String? note,
    required String notificationTitle,
    required String notificationMessage,
  }) async {
    final draft = await _getDraftById(draftId);
    if (!expectedCurrentStatuses.contains(draft.status)) {
      throw StateError(
        'Invalid transition from "${draft.status}" to "$nextStatus".',
      );
    }

    final event = DraftWorkflowEvent(
      type: eventType,
      actor: actorName,
      at: DateTime.now(),
      note: note,
    );

    final updated = DraftWorkflowCodec.applyTransition(
      draft: draft,
      nextStatus: nextStatus,
      event: event,
    );

    await _localStore.upsertDraft(updated, enqueueSync: true);
    _emitNotification(title: notificationTitle, message: notificationMessage);
  }

  Future<LocalDraftFeature> _getDraftById(String draftId) async {
    final drafts = await _localStore.getDrafts();
    for (final draft in drafts) {
      if (draft.id == draftId) {
        return draft;
      }
    }
    throw StateError('Draft $draftId not found.');
  }
}
