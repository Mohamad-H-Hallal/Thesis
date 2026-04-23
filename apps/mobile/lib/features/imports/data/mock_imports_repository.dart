import 'dart:math';

import 'package:file_picker/file_picker.dart';

import '../domain/import_models.dart';
import '../domain/imports_repository.dart';

class MockImportsRepository implements ImportsRepository {
  MockImportsRepository() {
    final now = DateTime.now();
    _jobs = <GisImportJob>[
      GisImportJob(
        id: 'mock-import-1',
        projectId: 'mock-project',
        projectName: 'Cedars Survey',
        uploadedByUserId: 'mock-user',
        uploadedByName: 'Field Contributor',
        originalFilename: 'cedars.geojson',
        fileSizeBytes: 20480,
        fileChecksumSha256: 'a' * 64,
        fileType: 'geojson',
        sourceCrs: 'EPSG:4326',
        sourceLayerName: 'imported',
        status: 'pending_review',
        geometryCount: 2,
        pendingFeatureCount: 2,
        approvedFeatureCount: 0,
        rejectedFeatureCount: 0,
        failedFeatureCount: 0,
        warningCount: 1,
        errorCount: 0,
        geometryTypes: const <String>['Point'],
        fileMetadata: const <String, dynamic>{'feature_count': 2},
        validationSummary: const <String, dynamic>{'warning_count': 1},
        processingMessage: 'Import ready for review.',
        rejectionReason: null,
        uploadedAt: now.subtract(const Duration(hours: 3)),
        processedAt: now.subtract(const Duration(hours: 3)),
        reviewedAt: null,
        createdAt: now.subtract(const Duration(hours: 3)),
        updatedAt: now.subtract(const Duration(hours: 3)),
      ),
    ];
    _features = <String, List<ImportedFeature>>{
      'mock-import-1': <ImportedFeature>[
        ImportedFeature(
          id: 'mock-feature-1',
          importJobId: 'mock-import-1',
          sourceIndex: 0,
          sourceIdentifier: '0',
          displayTitle: 'North cedar stand',
          sourceFeatureName: 'North cedar stand',
          geometryType: 'Point',
          geometry: const <String, dynamic>{
            'type': 'Point',
            'coordinates': <double>[35.83, 34.24],
          },
          attributes: const <String, dynamic>{
            'feature_type': 'cedar',
            'name': 'North cedar stand',
          },
          status: 'pending_review',
          validationWarnings: const <String>['Near existing approved feature'],
          validationErrors: const <String>[],
          validationReport: const <String, dynamic>{'duplicate_warning': true},
          createdAt: now.subtract(const Duration(hours: 3)),
          updatedAt: now.subtract(const Duration(hours: 3)),
        ),
      ],
    };
  }

  late List<GisImportJob> _jobs;
  late Map<String, List<ImportedFeature>> _features;

  @override
  Future<List<GisImportJob>> fetchImports({
    String? status,
    String? projectId,
  }) async {
    return _jobs.where((job) {
      if (status != null && status.trim().isNotEmpty && job.status != status) {
        return false;
      }
      if (projectId != null &&
          projectId.trim().isNotEmpty &&
          job.projectId != projectId) {
        return false;
      }
      return true;
    }).toList(growable: false);
  }

  @override
  Future<GisImportDetails> fetchImportDetails(String importId) async {
    final job = _jobs.firstWhere((item) => item.id == importId);
    return GisImportDetails(
      job: job,
      previewFeatures: _features[importId] ?? const <ImportedFeature>[],
    );
  }

  @override
  Future<List<ImportedFeature>> fetchImportFeatures({
    required String importId,
    String? status,
    int page = 1,
    int limit = 100,
  }) async {
    final rows = (_features[importId] ?? const <ImportedFeature>[]).where((
      item,
    ) {
      if (status != null && status.trim().isNotEmpty && item.status != status) {
        return false;
      }
      return true;
    }).toList(growable: false);
    return rows.take(limit).toList(growable: false);
  }

  @override
  Future<GisImportJob> reviewImport({
    required String importId,
    required String status,
    String? reason,
    List<String>? featureIds,
  }) async {
    final features = _features[importId] ?? const <ImportedFeature>[];
    final targetIds = featureIds?.toSet();
    final updatedFeatures = features.map((item) {
      if (targetIds != null &&
          targetIds.isNotEmpty &&
          !targetIds.contains(item.id)) {
        return item;
      }
      return ImportedFeature(
        id: item.id,
        importJobId: item.importJobId,
        sourceIndex: item.sourceIndex,
        sourceIdentifier: item.sourceIdentifier,
        displayTitle: item.displayTitle,
        sourceFeatureName: item.sourceFeatureName,
        geometryType: item.geometryType,
        geometry: item.geometry,
        attributes: item.attributes,
        status: status,
        validationWarnings: item.validationWarnings,
        validationErrors: item.validationErrors,
        validationReport: item.validationReport,
        duplicateFeatureId: item.duplicateFeatureId,
        approvedFeatureId: status == 'approved'
            ? 'approved-${item.id}'
            : item.approvedFeatureId,
        reviewedByUserId: 'mock-admin',
        reviewedByName: 'Mock Admin',
        reviewedAt: DateTime.now(),
        approvedAt: status == 'approved' ? DateTime.now() : item.approvedAt,
        reviewReason: reason,
        createdAt: item.createdAt,
        updatedAt: DateTime.now(),
      );
    }).toList(growable: false);
    _features[importId] = updatedFeatures;

    final approved = updatedFeatures.where((item) => item.status == 'approved').length;
    final rejected = updatedFeatures.where((item) => item.status == 'rejected').length;
    final pending = updatedFeatures.where((item) => item.status == 'pending_review').length;
    final nextStatus = pending > 0
        ? 'pending_review'
        : approved > 0 && rejected > 0
        ? 'partially_approved'
        : approved > 0
        ? 'approved'
        : 'rejected';
    final updatedJob = _jobs
        .map((job) {
          if (job.id != importId) {
            return job;
          }
          return GisImportJob(
            id: job.id,
            projectId: job.projectId,
            projectName: job.projectName,
            uploadedByUserId: job.uploadedByUserId,
            uploadedByName: job.uploadedByName,
            reviewedByUserId: 'mock-admin',
            reviewedByName: 'Mock Admin',
            duplicateOfImportJobId: job.duplicateOfImportJobId,
            originalFilename: job.originalFilename,
            fileSizeBytes: job.fileSizeBytes,
            fileChecksumSha256: job.fileChecksumSha256,
            fileType: job.fileType,
            sourceCrs: job.sourceCrs,
            sourceLayerName: job.sourceLayerName,
            status: nextStatus,
            geometryCount: job.geometryCount,
            pendingFeatureCount: pending,
            approvedFeatureCount: approved,
            rejectedFeatureCount: rejected,
            failedFeatureCount: job.failedFeatureCount,
            warningCount: job.warningCount,
            errorCount: job.errorCount,
            geometryTypes: job.geometryTypes,
            fileMetadata: job.fileMetadata,
            validationSummary: job.validationSummary,
            processingMessage: job.processingMessage,
            rejectionReason: reason,
            uploadedAt: job.uploadedAt,
            processedAt: job.processedAt,
            reviewedAt: DateTime.now(),
            createdAt: job.createdAt,
            updatedAt: DateTime.now(),
          );
        })
        .toList(growable: false);
    _jobs = updatedJob;
    return _jobs.firstWhere((job) => job.id == importId);
  }

  @override
  Future<GisImportJob> uploadImport({
    required String projectId,
    required PlatformFile file,
  }) async {
    final id = 'mock-import-${Random().nextInt(999999)}';
    final now = DateTime.now();
    final job = GisImportJob(
      id: id,
      projectId: projectId,
      projectName: 'Imported Project',
      uploadedByUserId: 'mock-user',
      uploadedByName: 'Field Contributor',
      originalFilename: file.name,
      fileSizeBytes: file.size,
      fileChecksumSha256: 'b' * 64,
      fileType: 'geojson',
      sourceCrs: 'EPSG:4326',
      sourceLayerName: 'imported',
      status: 'pending_review',
      geometryCount: 1,
      pendingFeatureCount: 1,
      approvedFeatureCount: 0,
      rejectedFeatureCount: 0,
      failedFeatureCount: 0,
      warningCount: 0,
      errorCount: 0,
      geometryTypes: const <String>['Point'],
      fileMetadata: <String, dynamic>{'filename': file.name},
      validationSummary: const <String, dynamic>{'warning_count': 0},
      processingMessage: 'Import ready for review.',
      rejectionReason: null,
      uploadedAt: now,
      processedAt: now,
      reviewedAt: null,
      createdAt: now,
      updatedAt: now,
    );
    _jobs = <GisImportJob>[job, ..._jobs];
    _features[id] = <ImportedFeature>[];
    return job;
  }
}
