import '../../map/domain/map_feature.dart';

class GisImportListQuery {
  const GisImportListQuery({this.status, this.projectId, this.categoryId});

  final String? status;
  final String? projectId;
  final String? categoryId;

  @override
  bool operator ==(Object other) {
    return other is GisImportListQuery &&
        other.status == status &&
        other.projectId == projectId &&
        other.categoryId == categoryId;
  }

  @override
  int get hashCode => Object.hash(status, projectId, categoryId);
}

class ImportedFeatureListQuery {
  const ImportedFeatureListQuery({
    required this.importId,
    this.status,
    this.issue,
    this.search,
    this.geometryType,
    this.featureType,
  });

  final String importId;
  final String? status;
  final String? issue;
  final String? search;
  final String? geometryType;
  final String? featureType;

  @override
  bool operator ==(Object other) {
    return other is ImportedFeatureListQuery &&
        other.importId == importId &&
        other.status == status &&
        other.issue == issue &&
        other.search == search &&
        other.geometryType == geometryType &&
        other.featureType == featureType;
  }

  @override
  int get hashCode =>
      Object.hash(importId, status, issue, search, geometryType, featureType);
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
    this.possibleDuplicate = false,
    required this.originalFilename,
    required this.fileSizeBytes,
    required this.fileChecksumSha256,
    required this.fileType,
    this.sourceCrs,
    this.sourceLayerName,
    this.sourceProvider,
    this.sourceDatasetName,
    this.sourceDatasetDate,
    this.sourceAccuracyStatement,
    this.sourceLicenseOrAuthority,
    this.sourceAttribution,
    this.sourceTermsUrl,
    this.sourceRedistributionRules,
    this.provenanceConfirmedAt,
    this.provenanceConfirmedByUserId,
    this.provenanceComplete = false,
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
    this.reviewScope = 'admin',
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
  final bool possibleDuplicate;
  final String originalFilename;
  final int fileSizeBytes;
  final String fileChecksumSha256;
  final String fileType;
  final String? sourceCrs;
  final String? sourceLayerName;
  final String? sourceProvider;
  final String? sourceDatasetName;
  final DateTime? sourceDatasetDate;
  final String? sourceAccuracyStatement;
  final String? sourceLicenseOrAuthority;
  final String? sourceAttribution;
  final String? sourceTermsUrl;
  final String? sourceRedistributionRules;
  final DateTime? provenanceConfirmedAt;
  final String? provenanceConfirmedByUserId;
  final bool provenanceComplete;
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
  final String reviewScope;
  final DateTime uploadedAt;
  final DateTime? processedAt;
  final DateTime? reviewedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get canBeReviewed =>
      status == 'pending_review' || status == 'partially_approved';
}

class ImportSourceProvenance {
  const ImportSourceProvenance({
    required this.provider,
    required this.datasetName,
    this.datasetDate,
    this.accuracyStatement,
    required this.licenseOrAuthority,
    this.attribution,
    this.termsUrl,
    required this.redistributionRules,
  });

  final String provider;
  final String datasetName;
  final String? datasetDate;
  final String? accuracyStatement;
  final String licenseOrAuthority;
  final String? attribution;
  final String? termsUrl;
  final String redistributionRules;

  Map<String, dynamic> toFields() => <String, dynamic>{
    'source_provider': provider.trim(),
    'source_dataset_name': datasetName.trim(),
    if (datasetDate?.trim().isNotEmpty ?? false)
      'source_dataset_date': datasetDate!.trim(),
    if (accuracyStatement?.trim().isNotEmpty ?? false)
      'source_accuracy_statement': accuracyStatement!.trim(),
    'source_license_or_authority': licenseOrAuthority.trim(),
    if (attribution?.trim().isNotEmpty ?? false)
      'source_attribution': attribution!.trim(),
    if (termsUrl?.trim().isNotEmpty ?? false)
      'source_terms_url': termsUrl!.trim(),
    'source_redistribution_rules': redistributionRules.trim(),
    'provenance_confirmed': true,
  };
}

class ImportPreviewSummary {
  const ImportPreviewSummary({
    required this.geometryFeatureCount,
    required this.previewFeatureCount,
    required this.outsideWorkspaceFeatureCount,
  });

  final int geometryFeatureCount;
  final int previewFeatureCount;
  final int outsideWorkspaceFeatureCount;
}

class ImportMapBounds {
  const ImportMapBounds({
    required this.minLon,
    required this.minLat,
    required this.maxLon,
    required this.maxLat,
  });

  final double minLon;
  final double minLat;
  final double maxLon;
  final double maxLat;
}

class ImportQuickMapPreview {
  const ImportQuickMapPreview({
    required this.totalFeatureCount,
    required this.geometryFeatureCount,
    required this.renderedFeatureCount,
    required this.isClustered,
    required this.statusCounts,
    required this.features,
    this.bounds,
  });

  final int totalFeatureCount;
  final int geometryFeatureCount;
  final int renderedFeatureCount;
  final bool isClustered;
  final Map<String, int> statusCounts;
  final List<ImportedFeature> features;
  final ImportMapBounds? bounds;
}

class ImportComment {
  const ImportComment({
    required this.id,
    required this.importJobId,
    required this.authorUserId,
    required this.authorName,
    required this.authorRole,
    required this.commentText,
    this.importFeatureId,
    this.featureDisplayTitle,
    required this.createdAt,
  });

  final String id;
  final String importJobId;
  final String authorUserId;
  final String authorName;
  final String authorRole;
  final String commentText;
  final String? importFeatureId;
  final String? featureDisplayTitle;
  final DateTime createdAt;
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
    this.summaryAttributes = const <String, dynamic>{},
    this.attributeCount = 0,
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
    this.isSummary = false,
    this.isAggregate = false,
    this.clusterCount = 1,
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
  final Map<String, dynamic> summaryAttributes;
  final int attributeCount;
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
  final bool isSummary;
  final bool isAggregate;
  final int clusterCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get canBeApproved => status == 'pending_review' || status == 'rejected';

  bool get canBeRejected => status == 'pending_review' || status == 'approved';

  bool get isActionable => canBeApproved || canBeRejected;
}

class GisImportDetails {
  const GisImportDetails({
    required this.job,
    required this.previewFeatures,
    required this.previewSummary,
    this.comments = const <ImportComment>[],
  });

  final GisImportJob job;
  final List<ImportedFeature> previewFeatures;
  final ImportPreviewSummary previewSummary;
  final List<ImportComment> comments;
}

class ImportMapQuery {
  const ImportMapQuery({
    required this.importId,
    required this.projectId,
    required this.minLon,
    required this.minLat,
    required this.maxLon,
    required this.maxLat,
    required this.zoom,
  });

  final String importId;
  final String projectId;
  final double minLon;
  final double minLat;
  final double maxLon;
  final double maxLat;
  final double zoom;

  @override
  bool operator ==(Object other) {
    return other is ImportMapQuery &&
        other.importId == importId &&
        other.projectId == projectId &&
        other.minLon == minLon &&
        other.minLat == minLat &&
        other.maxLon == maxLon &&
        other.maxLat == maxLat &&
        other.zoom == zoom;
  }

  @override
  int get hashCode =>
      Object.hash(importId, projectId, minLon, minLat, maxLon, maxLat, zoom);
}

class ImportFeatureQuery {
  const ImportFeatureQuery({required this.importId, required this.featureId});

  final String importId;
  final String featureId;

  @override
  bool operator ==(Object other) {
    return other is ImportFeatureQuery &&
        other.importId == importId &&
        other.featureId == featureId;
  }

  @override
  int get hashCode => Object.hash(importId, featureId);
}

class ImportMapData {
  const ImportMapData({
    required this.stagedFeatures,
    required this.approvedProjectFeatures,
  });

  final List<ImportedFeature> stagedFeatures;
  final List<MapFeatureSummary> approvedProjectFeatures;
}
