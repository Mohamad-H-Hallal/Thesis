class LegalSection {
  const LegalSection({
    required this.heading,
    required this.paragraphs,
    required this.bullets,
  });

  final String heading;
  final List<String> paragraphs;
  final List<String> bullets;

  factory LegalSection.fromJson(Map<String, dynamic> json) => LegalSection(
    heading: json['heading'] as String? ?? '',
    paragraphs: (json['paragraphs'] as List? ?? const <dynamic>[])
        .whereType<String>()
        .toList(growable: false),
    bullets: (json['bullets'] as List? ?? const <dynamic>[])
        .whereType<String>()
        .toList(growable: false),
  );
}

class LegalDocument {
  const LegalDocument({
    required this.type,
    required this.slug,
    required this.locale,
    required this.version,
    required this.title,
    required this.status,
    required this.summary,
    required this.sections,
    required this.contentSha256,
    this.effectiveAt,
    this.counselApproved = false,
  });

  final String type;
  final String slug;
  final String locale;
  final String version;
  final String title;
  final String status;
  final DateTime? effectiveAt;
  final bool counselApproved;
  final String summary;
  final List<LegalSection> sections;
  final String contentSha256;

  bool get isDraft => status != 'approved' || !counselApproved;

  factory LegalDocument.fromJson(Map<String, dynamic> json) => LegalDocument(
    type: json['type'] as String? ?? '',
    slug: json['slug'] as String? ?? '',
    locale: json['locale'] as String? ?? 'en',
    version: json['version'] as String? ?? '',
    title: json['title'] as String? ?? 'Legal information',
    status: json['status'] as String? ?? 'draft',
    effectiveAt: DateTime.tryParse(json['effective_at'] as String? ?? ''),
    counselApproved: json['counsel_approved'] == true,
    summary: json['summary'] as String? ?? '',
    sections: (json['sections'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => LegalSection.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false),
    contentSha256: json['content_sha256'] as String? ?? '',
  );
}

class LegalAcceptanceStatus {
  const LegalAcceptanceStatus({
    required this.required,
    required this.missingDocuments,
  });

  final bool required;
  final List<LegalDocument> missingDocuments;

  factory LegalAcceptanceStatus.fromJson(Map<String, dynamic> json) =>
      LegalAcceptanceStatus(
        required: json['acceptance_required'] == true,
        missingDocuments:
            (json['required_documents'] as List? ??
                    json['missing'] as List? ??
                    const <dynamic>[])
                .whereType<Map>()
                .map(
                  (item) =>
                      LegalDocument.fromJson(Map<String, dynamic>.from(item)),
                )
                .toList(growable: false),
      );
}

enum PrivacyRequestType {
  accessExport('access_export', 'Data access/export'),
  correction('correction', 'Correction'),
  deletion('deletion', 'Account deletion'),
  restriction('restriction', 'Restriction'),
  objection('objection', 'Objection');

  const PrivacyRequestType(this.apiValue, this.label);

  final String apiValue;
  final String label;
}

class AccountDeletionBlocker {
  const AccountDeletionBlocker({
    required this.code,
    required this.count,
    required this.message,
  });

  final String code;
  final int count;
  final String message;

  factory AccountDeletionBlocker.fromJson(Map<String, dynamic> json) =>
      AccountDeletionBlocker(
        code: json['code'] as String? ?? '',
        count: (json['count'] as num?)?.toInt() ?? 0,
        message: json['message'] as String? ?? '',
      );
}

class AccountDeletionEligibility {
  const AccountDeletionEligibility({
    required this.canRequest,
    required this.operationallyEligible,
    required this.protectedAccount,
    required this.role,
    required this.blockers,
    required this.manualReviewRequired,
    required this.notice,
  });

  final bool canRequest;
  final bool operationallyEligible;
  final bool protectedAccount;
  final String role;
  final List<AccountDeletionBlocker> blockers;
  final bool manualReviewRequired;
  final String notice;

  factory AccountDeletionEligibility.fromJson(
    Map<String, dynamic> json,
  ) => AccountDeletionEligibility(
    canRequest: json['can_request'] == true,
    operationallyEligible: json['operationally_eligible'] == true,
    protectedAccount: json['protected_account'] == true,
    role: json['role'] as String? ?? '',
    blockers: (json['blockers'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .map(
          (item) =>
              AccountDeletionBlocker.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false),
    manualReviewRequired: json['manual_review_required'] == true,
    notice: json['notice'] as String? ?? '',
  );
}

class PrivacyRequestRecord {
  const PrivacyRequestRecord({
    required this.id,
    required this.type,
    required this.status,
    required this.requestedAt,
    required this.internalTargetAt,
    this.userMessage,
    this.completedAt,
    this.cancelledAt,
    this.exportStatus,
    this.exportExpiresAt,
  });

  final String id;
  final PrivacyRequestType type;
  final String status;
  final DateTime requestedAt;
  final DateTime internalTargetAt;
  final String? userMessage;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  final String? exportStatus;
  final DateTime? exportExpiresAt;

  static const activeStatuses = <String>{
    'pending_verification',
    'submitted',
    'in_review',
    'scheduled',
    'processing',
    'failed',
  };

  bool get isActive => activeStatuses.contains(status);
  bool get canCancel =>
      status == 'pending_verification' ||
      status == 'submitted' ||
      status == 'in_review';
  bool get canDownload =>
      type == PrivacyRequestType.accessExport &&
      status == 'completed' &&
      exportStatus == 'ready' &&
      (exportExpiresAt?.isAfter(DateTime.now()) ?? false);

  factory PrivacyRequestRecord.fromJson(Map<String, dynamic> json) {
    final rawType = json['request_type'] as String? ?? '';
    final type = PrivacyRequestType.values.firstWhere(
      (candidate) => candidate.apiValue == rawType,
      orElse: () => PrivacyRequestType.accessExport,
    );
    return PrivacyRequestRecord(
      id: json['id'] as String? ?? '',
      type: type,
      status: json['status'] as String? ?? 'submitted',
      requestedAt:
          DateTime.tryParse(json['requested_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      internalTargetAt:
          DateTime.tryParse(json['internal_target_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      userMessage: json['last_user_visible_message'] as String?,
      completedAt: DateTime.tryParse(json['completed_at'] as String? ?? ''),
      cancelledAt: DateTime.tryParse(json['cancelled_at'] as String? ?? ''),
      exportStatus: json['export_status'] as String?,
      exportExpiresAt: DateTime.tryParse(
        json['export_expires_at'] as String? ?? '',
      ),
    );
  }
}

class PrivacyAdminRequest {
  const PrivacyAdminRequest({
    required this.id,
    required this.type,
    required this.status,
    required this.requesterLabel,
    required this.requestedAt,
    required this.internalTargetAt,
    required this.overdue,
    required this.requestDetails,
    this.requesterContact,
    this.requesterRole,
    this.userMessage,
    this.failureCode,
  });

  final String id;
  final PrivacyRequestType type;
  final String status;
  final String requesterLabel;
  final String? requesterContact;
  final String? requesterRole;
  final DateTime requestedAt;
  final DateTime internalTargetAt;
  final bool overdue;
  final Map<String, dynamic> requestDetails;
  final String? userMessage;
  final String? failureCode;

  bool get isActive => PrivacyRequestRecord.activeStatuses.contains(status);

  factory PrivacyAdminRequest.fromJson(Map<String, dynamic> json) {
    final rawType = json['request_type'] as String? ?? '';
    return PrivacyAdminRequest(
      id: json['id'] as String? ?? '',
      type: PrivacyRequestType.values.firstWhere(
        (candidate) => candidate.apiValue == rawType,
        orElse: () => PrivacyRequestType.accessExport,
      ),
      status: json['status'] as String? ?? 'submitted',
      requesterLabel: json['requester_label'] as String? ?? 'Former user',
      requesterContact: json['requester_contact'] as String?,
      requesterRole: json['requester_role'] as String?,
      requestedAt:
          DateTime.tryParse(json['requested_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      internalTargetAt:
          DateTime.tryParse(json['internal_target_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      overdue: json['overdue'] == true,
      requestDetails: Map<String, dynamic>.from(
        json['request_details'] as Map? ?? const <String, dynamic>{},
      ),
      userMessage: json['last_user_visible_message'] as String?,
      failureCode: json['failure_code'] as String?,
    );
  }
}

class ContentReportRecord {
  const ContentReportRecord({
    required this.id,
    required this.projectId,
    this.projectTitle,
    required this.entityType,
    required this.entityId,
    required this.reasonCode,
    required this.status,
    required this.createdAt,
    required this.internalTargetAt,
    required this.overdue,
    this.description,
    this.reporterLabel,
    this.reporterContact,
    this.userMessage,
    this.outcomeCode,
    this.entityAvailable,
  });

  final String id;
  final String projectId;
  final String? projectTitle;
  final String entityType;
  final String entityId;
  final String reasonCode;
  final String status;
  final DateTime createdAt;
  final DateTime internalTargetAt;
  final bool overdue;
  final String? description;
  final String? reporterLabel;
  final String? reporterContact;
  final String? userMessage;
  final String? outcomeCode;
  final bool? entityAvailable;

  factory ContentReportRecord.fromJson(Map<String, dynamic> json) =>
      ContentReportRecord(
        id: json['id'] as String? ?? '',
        projectId: json['project_id'] as String? ?? '',
        projectTitle: json['project_title'] as String?,
        entityType: json['entity_type'] as String? ?? '',
        entityId: json['entity_id'] as String? ?? '',
        reasonCode: json['reason_code'] as String? ?? '',
        status: json['status'] as String? ?? 'submitted',
        createdAt:
            DateTime.tryParse(json['created_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        internalTargetAt:
            DateTime.tryParse(json['internal_target_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        overdue: json['overdue'] == true,
        description: json['description'] as String?,
        reporterLabel: json['reporter_label'] as String?,
        reporterContact: json['reporter_contact'] as String?,
        userMessage: json['user_visible_message'] as String?,
        outcomeCode: json['outcome_code'] as String?,
        entityAvailable: json['entity_available'] as bool?,
      );
}

class PrivacyQueueCounts {
  const PrivacyQueueCounts({
    required this.openPrivacyRequests,
    required this.overduePrivacyRequests,
    required this.openContentReports,
    required this.overdueContentReports,
  });

  final int openPrivacyRequests;
  final int overduePrivacyRequests;
  final int openContentReports;
  final int overdueContentReports;

  factory PrivacyQueueCounts.fromJson(
    Map<String, dynamic> json,
  ) => PrivacyQueueCounts(
    openPrivacyRequests: (json['open_privacy_requests'] as num?)?.toInt() ?? 0,
    overduePrivacyRequests:
        (json['overdue_privacy_requests'] as num?)?.toInt() ?? 0,
    openContentReports: (json['open_content_reports'] as num?)?.toInt() ?? 0,
    overdueContentReports:
        (json['overdue_content_reports'] as num?)?.toInt() ?? 0,
  );
}

class WorkflowHistoryRecord {
  const WorkflowHistoryRecord({
    required this.toStatus,
    required this.occurredAt,
    required this.actorKind,
    this.fromStatus,
    this.userMessage,
  });

  final String? fromStatus;
  final String toStatus;
  final DateTime occurredAt;
  final String actorKind;
  final String? userMessage;

  factory WorkflowHistoryRecord.fromJson(Map<String, dynamic> json) =>
      WorkflowHistoryRecord(
        fromStatus: json['from_status'] as String?,
        toStatus: json['to_status'] as String? ?? '',
        occurredAt:
            DateTime.tryParse(json['occurred_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        actorKind: json['actor_kind'] as String? ?? 'system',
        userMessage: json['user_visible_message'] as String?,
      );
}

class PrivacyAdminRequestDetail {
  const PrivacyAdminRequestDetail({
    required this.request,
    required this.history,
  });

  final PrivacyAdminRequest request;
  final List<WorkflowHistoryRecord> history;
}

class ContentReportDetail {
  const ContentReportDetail({required this.report, required this.history});

  final ContentReportRecord report;
  final List<WorkflowHistoryRecord> history;
}
