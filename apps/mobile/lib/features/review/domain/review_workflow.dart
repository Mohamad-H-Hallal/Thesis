import 'dart:convert';

import '../../../core/offline/local_models.dart';

class DraftWorkflowStatus {
  const DraftWorkflowStatus._();

  static const String draft = 'draft';
  static const String submitted = 'submitted';
  static const String underReview = 'under_review';
  static const String approved = 'approved';
  static const String rejected = 'rejected';

  static bool isSubmissionTrack(String status) {
    return status == submitted || status == underReview || status == approved;
  }

  static bool isDraftTrack(String status) {
    return status == draft || status == rejected;
  }
}

enum DraftWorkflowEventType {
  created,
  submitted,
  reviewStarted,
  approved,
  rejected,
}

class DraftWorkflowEvent {
  const DraftWorkflowEvent({
    required this.type,
    required this.actor,
    required this.at,
    this.note,
  });

  final DraftWorkflowEventType type;
  final String actor;
  final DateTime at;
  final String? note;

  String get label {
    switch (type) {
      case DraftWorkflowEventType.created:
        return 'Draft created';
      case DraftWorkflowEventType.submitted:
        return 'Submitted for review';
      case DraftWorkflowEventType.reviewStarted:
        return 'Review started';
      case DraftWorkflowEventType.approved:
        return 'Approved';
      case DraftWorkflowEventType.rejected:
        return 'Rejected';
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'type': type.name,
      'actor': actor,
      'at': at.toIso8601String(),
      'note': note,
    };
  }

  factory DraftWorkflowEvent.fromMap(Map<String, dynamic> map) {
    return DraftWorkflowEvent(
      type: DraftWorkflowEventType.values.byName(map['type'] as String),
      actor: map['actor'] as String,
      at: DateTime.parse(map['at'] as String),
      note: map['note'] as String?,
    );
  }
}

class DraftWorkflowSnapshot {
  const DraftWorkflowSnapshot({
    required this.status,
    required this.timeline,
    this.lastReviewNote,
  });

  final String status;
  final List<DraftWorkflowEvent> timeline;
  final String? lastReviewNote;
}

class DraftWorkflowCodec {
  const DraftWorkflowCodec._();

  static const String _workflowKey = 'workflow';
  static const String _statusKey = 'status';
  static const String _timelineKey = 'timeline';
  static const String _lastReviewNoteKey = 'last_review_note';

  static DraftWorkflowSnapshot fromDraft(LocalDraftFeature draft) {
    final root = _decodeRoot(draft.attributesJson);
    final workflowRaw = root[_workflowKey];
    if (workflowRaw is! Map) {
      return DraftWorkflowSnapshot(
        status: draft.status,
        timeline: <DraftWorkflowEvent>[
          DraftWorkflowEvent(
            type: DraftWorkflowEventType.created,
            actor: 'Collector',
            at: draft.updatedAt,
          ),
        ],
      );
    }

    final workflow = Map<String, dynamic>.from(workflowRaw);
    final timelineRaw = (workflow[_timelineKey] as List?) ?? const <dynamic>[];
    final timeline = timelineRaw
        .map(
          (entry) => DraftWorkflowEvent.fromMap(
            Map<String, dynamic>.from(entry as Map),
          ),
        )
        .toList(growable: false);

    return DraftWorkflowSnapshot(
      status: (workflow[_statusKey] as String?) ?? draft.status,
      timeline: timeline,
      lastReviewNote: workflow[_lastReviewNoteKey] as String?,
    );
  }

  static LocalDraftFeature applyTransition({
    required LocalDraftFeature draft,
    required String nextStatus,
    required DraftWorkflowEvent event,
  }) {
    final root = _decodeRoot(draft.attributesJson);
    final existingSnapshot = fromDraft(draft);

    final nextTimeline = <DraftWorkflowEvent>[
      ...existingSnapshot.timeline,
      event,
    ];

    root[_workflowKey] = <String, dynamic>{
      _statusKey: nextStatus,
      _timelineKey: nextTimeline.map((e) => e.toMap()).toList(growable: false),
      _lastReviewNoteKey: event.note ?? existingSnapshot.lastReviewNote,
    };

    return draft.copyWith(
      status: nextStatus,
      localVersion: draft.localVersion + 1,
      attributesJson: jsonEncode(root),
      updatedAt: DateTime.now(),
    );
  }

  static Map<String, dynamic> _decodeRoot(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is Map<String, dynamic>) {
        return Map<String, dynamic>.from(decoded);
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return <String, dynamic>{'raw_attributes': rawJson};
  }
}
