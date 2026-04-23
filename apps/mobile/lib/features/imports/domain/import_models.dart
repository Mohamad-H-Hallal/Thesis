class GisImportListQuery {
  const GisImportListQuery({this.status, this.projectId});

  final String? status;
  final String? projectId;

  @override
  bool operator ==(Object other) {
    return other is GisImportListQuery &&
        other.status == status &&
        other.projectId == projectId;
  }

  @override
  int get hashCode => Object.hash(status, projectId);
}

class GisImportJob {
  const GisImportJob({
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.uploadedByUserId,
    required this.uploadedByName,
    this.reviewedByUserId,
    this.reviewedByName,
    this.duplicateOfImportJobId,
    required this.originalFilename,
    required this.fileSizeBytes,
    required this.fileChecksumSha256,
    required this.fileType,
    this.sourceCrs,
    this.sourceLayerName,
    required this.status,
    required this.geometryCount,
    required this.pendingFeatureCount,
    required this.approvedFeatureCount,
    required this.rejectedFeatureCount,
    required this.failedFeatureCount,
    required this.warningCount,
    required this.errorCount,
    required this.geometryTypes,
    required this.fileMetadata,
    required this.validationSummary,
    this.processingMessage,
    this.rejectionReason,
    required this.uploadedAt,
    this.processedAt,
    this.reviewedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String projectId;
  final String projectName;
  final String uploadedByUserId;
  final String uploadedByName;
  final String? reviewedByUserId;
  final String? reviewedByName;
  final String? duplicateOfImportJobId;
  final String originalFilename;
  final int fileSizeBytes;
  final String fileChecksumSha256;
  final String fileType;
  final String? sourceCrs;
  final String? sourceLayerName;
  final String status;
  final int geometryCount;
  final int pendingFeatureCount;
  final int approvedFeatureCount;
  final int rejectedFeatureCount;
  final int failedFeatureCount;
  final int warningCount;
  final int errorCount;
  final List<String> geometryTypes;
  final Map<String, dynamic> fileMetadata;
  final Map<String, dynamic> validationSummary;
  final String? processingMessage;
  final String? rejectionReason;
  final DateTime uploadedAt;
  final DateTime? processedAt;
  final DateTime? reviewedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get canBeReviewed =>
      status == 'pending_review' || status == 'partially_approved';
}

class ImportedFeature {
  const ImportedFeature({
    required this.id,
    required this.importJobId,
    required this.sourceIndex,
    this.sourceIdentifier,
    required this.displayTitle,
    this.sourceFeatureName,
    this.geometryType,
    this.geometry,
    required this.attributes,
    required this.status,
    required this.validationWarnings,
    required this.validationErrors,
    required this.validationReport,
    this.duplicateFeatureId,
    this.approvedFeatureId,
    this.reviewedByUserId,
    this.reviewedByName,
    this.reviewedAt,
    this.approvedAt,
    this.reviewReason,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String importJobId;
  final int sourceIndex;
  final String? sourceIdentifier;
  final String displayTitle;
  final String? sourceFeatureName;
  final String? geometryType;
  final Map<String, dynamic>? geometry;
  final Map<String, dynamic> attributes;
  final String status;
  final List<String> validationWarnings;
  final List<String> validationErrors;
  final Map<String, dynamic> validationReport;
  final String? duplicateFeatureId;
  final String? approvedFeatureId;
  final String? reviewedByUserId;
  final String? reviewedByName;
  final DateTime? reviewedAt;
  final DateTime? approvedAt;
  final String? reviewReason;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isActionable =>
      status == 'pending_review' || status == 'rejected';
}

class GisImportDetails {
  const GisImportDetails({required this.job, required this.previewFeatures});

  final GisImportJob job;
  final List<ImportedFeature> previewFeatures;
}
