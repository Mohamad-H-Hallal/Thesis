import 'dart:math';

import 'package:file_picker/file_picker.dart';

import '../../../core/pagination/paginated_result.dart';
import '../../map/domain/map_feature.dart';
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
        possibleDuplicate: false,
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
        reviewScope: 'admin',
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
    String? categoryId,
  }) async {
    final page = await fetchImportsPage(
      status: status,
      projectId: projectId,
      categoryId: categoryId,
      limit: 100,
    );
    return page.items;
  }

  @override
  Future<PaginatedResult<GisImportJob>> fetchImportsPage({
    String? status,
    String? projectId,
    String? categoryId,
    int page = 1,
    int limit = 20,
  }) async {
    final filtered = _jobs
        .where((job) {
          if (status != null &&
              status.trim().isNotEmpty &&
              job.status != status) {
            return false;
          }
          if (projectId != null &&
              projectId.trim().isNotEmpty &&
              job.projectId != projectId) {
            return false;
          }
          if (categoryId != null &&
              categoryId.trim().isNotEmpty &&
              job.fileMetadata['category_id']?.toString() != categoryId) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
    final start = (page - 1) * limit;
    final end = (start + limit).clamp(0, filtered.length);
    final items = start >= filtered.length
        ? const <GisImportJob>[]
        : filtered.sublist(start, end);
    return PaginatedResult<GisImportJob>(
      items: items,
      page: page,
      limit: limit,
      total: filtered.length,
      hasMore: end < filtered.length,
    );
  }

  @override
  Future<GisImportDetails> fetchImportDetails(String importId) async {
    final job = _jobs.firstWhere((item) => item.id == importId);
    return GisImportDetails(
      job: job,
      previewFeatures: _features[importId] ?? const <ImportedFeature>[],
      previewSummary: ImportPreviewSummary(
        geometryFeatureCount:
            (_features[importId] ?? const <ImportedFeature>[]).length,
        previewFeatureCount:
            (_features[importId] ?? const <ImportedFeature>[]).length,
        outsideWorkspaceFeatureCount: 0,
      ),
    );
  }

  @override
  Future<GisImportJob> updateImportProvenance({
    required String importId,
    required ImportSourceProvenance provenance,
  }) async {
    return (await fetchImportDetails(importId)).job;
  }

  @override
  Future<ImportMapData> fetchImportMapData({
    required String importId,
    required String projectId,
    required double minLon,
    required double minLat,
    required double maxLon,
    required double maxLat,
    required double zoom,
    int cacheRevision = 0,
  }) async {
    return ImportMapData(
      stagedFeatures: (_features[importId] ?? const <ImportedFeature>[])
          .map(
            (feature) => ImportedFeature(
              id: feature.id,
              importJobId: feature.importJobId,
              sourceIndex: feature.sourceIndex,
              sourceIdentifier: feature.sourceIdentifier,
              displayTitle: feature.displayTitle,
              sourceFeatureName: feature.sourceFeatureName,
              geometryType: feature.geometryType,
              geometry: feature.geometry,
              attributes: const <String, dynamic>{},
              status: feature.status,
              validationWarnings: const <String>[],
              validationErrors: const <String>[],
              validationReport: const <String, dynamic>{},
              duplicateFeatureId: feature.duplicateFeatureId,
              approvedFeatureId: feature.approvedFeatureId,
              reviewedByUserId: feature.reviewedByUserId,
              reviewedByName: feature.reviewedByName,
              reviewedAt: feature.reviewedAt,
              approvedAt: feature.approvedAt,
              reviewReason: feature.reviewReason,
              isSummary: true,
              createdAt: feature.createdAt,
              updatedAt: feature.updatedAt,
            ),
          )
          .toList(growable: false),
      approvedProjectFeatures: <MapFeatureSummary>[
        MapFeatureSummary(
          id: 'mock-approved-feature-1',
          projectId: projectId,
          status: 'approved',
          geometry: <String, dynamic>{
            'type': 'Point',
            'coordinates': <double>[35.84, 34.25],
          },
          attributes: <String, dynamic>{'name': 'Approved context feature'},
          isSummary: true,
        ),
      ],
    );
  }

  @override
  Future<ImportQuickMapPreview> fetchImportQuickMapPreview({
    required String importId,
  }) async {
    final features = _features[importId] ?? const <ImportedFeature>[];
    final geometryFeatureCount = features
        .where((feature) => feature.geometry != null)
        .length;
    final previewFeatures = geometryFeatureCount == 0
        ? const <ImportedFeature>[]
        : <ImportedFeature>[
            ImportedFeature(
              id: 'mock-preview-geometry-$importId',
              importJobId: importId,
              sourceIndex: 0,
              displayTitle: '$geometryFeatureCount staged feature preview',
              geometryType: 'Polygon',
              geometry: const <String, dynamic>{
                'type': 'Polygon',
                'coordinates': <dynamic>[
                  <dynamic>[
                    <double>[35.48, 33.88],
                    <double>[35.52, 33.88],
                    <double>[35.52, 33.92],
                    <double>[35.48, 33.92],
                    <double>[35.48, 33.88],
                  ],
                ],
              },
              attributes: const <String, dynamic>{},
              status: 'pending_review',
              validationWarnings: const <String>[],
              validationErrors: const <String>[],
              validationReport: const <String, dynamic>{},
              isSummary: true,
              isAggregate: true,
              clusterCount: geometryFeatureCount,
              createdAt: DateTime(2026, 4, 25),
              updatedAt: DateTime(2026, 4, 25),
            ),
          ];
    return ImportQuickMapPreview(
      totalFeatureCount: features.length,
      geometryFeatureCount: geometryFeatureCount,
      renderedFeatureCount: previewFeatures.length,
      isClustered: geometryFeatureCount > 1,
      statusCounts: <String, int>{
        for (final status in features.map((feature) => feature.status).toSet())
          status: features.where((feature) => feature.status == status).length,
      },
      bounds: const ImportMapBounds(
        minLon: 35.1,
        minLat: 33.1,
        maxLon: 36.2,
        maxLat: 34.4,
      ),
      features: previewFeatures,
    );
  }

  @override
  Future<ImportedFeature> fetchImportFeatureById({
    required String importId,
    required String featureId,
  }) async {
    final feature = (_features[importId] ?? const <ImportedFeature>[])
        .cast<ImportedFeature?>()
        .firstWhere((item) => item?.id == featureId, orElse: () => null);
    if (feature == null) {
      throw 'Imported feature not found.';
    }
    return feature;
  }

  @override
  Future<List<ImportComment>> fetchImportComments(String importId) async =>
      const <ImportComment>[];

  @override
  Future<List<ImportedFeature>> fetchImportFeatures({
    required String importId,
    String? status,
    String? issue,
    int page = 1,
    int limit = 100,
  }) async {
    final result = await fetchImportFeaturesPage(
      importId: importId,
      status: status,
      issue: issue,
      page: page,
      limit: limit,
    );
    return result.items;
  }

  @override
  Future<PaginatedResult<ImportedFeature>> fetchImportFeaturesPage({
    required String importId,
    String? status,
    String? issue,
    String? search,
    String? geometryType,
    String? featureType,
    int page = 1,
    int limit = 20,
  }) async {
    final rows = (_features[importId] ?? const <ImportedFeature>[])
        .where((item) {
          if (status != null &&
              status.trim().isNotEmpty &&
              item.status != status) {
            return false;
          }
          if (issue != null &&
              issue.trim().isNotEmpty &&
              !item.validationErrors.contains(issue) &&
              !item.validationWarnings.contains(issue)) {
            return false;
          }
          if (geometryType != null && geometryType.trim().isNotEmpty) {
            final normalized = geometryType.trim();
            final itemType = item.geometryType ?? '';
            final matches = switch (normalized) {
              'point' => itemType == 'Point' || itemType == 'MultiPoint',
              'line' =>
                itemType == 'LineString' || itemType == 'MultiLineString',
              'polygon' => itemType == 'Polygon' || itemType == 'MultiPolygon',
              _ => itemType == normalized,
            };
            if (!matches) {
              return false;
            }
          }
          if (featureType != null && featureType.trim().isNotEmpty) {
            final normalizedFeatureType = featureType.trim().toLowerCase();
            final matchingValues = item.attributes.entries
                .where(
                  (entry) => _looksLikeFeatureTypeField(entry.key, entry.key),
                )
                .map((entry) => '${entry.value}'.trim().toLowerCase())
                .where((value) => value.isNotEmpty);
            if (!matchingValues.contains(normalizedFeatureType)) {
              return false;
            }
          }
          if (search != null && search.trim().isNotEmpty) {
            final needle = search.trim().toLowerCase();
            final haystack = <String>[
              item.displayTitle,
              item.sourceFeatureName ?? '',
              item.geometryType ?? '',
              item.attributes.toString(),
              ...item.validationWarnings,
              ...item.validationErrors,
            ].join(' ').toLowerCase();
            if (!haystack.contains(needle)) {
              return false;
            }
          }
          return true;
        })
        .toList(growable: false);
    final start = (page - 1) * limit;
    final end = (start + limit).clamp(0, rows.length);
    final items = start >= rows.length
        ? const <ImportedFeature>[]
        : rows.sublist(start, end);
    return PaginatedResult<ImportedFeature>(
      items: items,
      page: page,
      limit: limit,
      total: rows.length,
      hasMore: end < rows.length,
    );
  }

  @override
  Future<GisImportJob> reviewImport({
    required String importId,
    required String status,
    String? reason,
    List<String>? featureIds,
    String? filterStatus,
    String? filterIssue,
    String? filterSearch,
    String? filterGeometryType,
    String? filterFeatureType,
  }) async {
    final features = _features[importId] ?? const <ImportedFeature>[];
    final targetIds = featureIds?.toSet();
    final allowedStatuses = status == 'approved'
        ? const <String>{'pending_review', 'rejected'}
        : const <String>{'pending_review', 'approved'};
    final filteredResult = await fetchImportFeaturesPage(
      importId: importId,
      status: filterStatus,
      issue: filterIssue,
      search: filterSearch,
      geometryType: filterGeometryType,
      featureType: filterFeatureType,
      page: 1,
      limit: features.length,
    );
    final filteredIds = filteredResult.items.map((item) => item.id).toSet();
    final updatedFeatures = features
        .map((item) {
          if (targetIds != null &&
              targetIds.isNotEmpty &&
              !targetIds.contains(item.id)) {
            return item;
          }
          if ((targetIds == null || targetIds.isEmpty) &&
              !filteredIds.contains(item.id)) {
            return item;
          }
          if (!allowedStatuses.contains(item.status)) {
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
        })
        .toList(growable: false);
    _features[importId] = updatedFeatures;

    final approved = updatedFeatures
        .where((item) => item.status == 'approved')
        .length;
    final rejected = updatedFeatures
        .where((item) => item.status == 'rejected')
        .length;
    final pending = updatedFeatures
        .where((item) => item.status == 'pending_review')
        .length;
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
            possibleDuplicate: job.possibleDuplicate,
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
            reviewScope: job.reviewScope,
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
    ImportSourceProvenance? provenance,
  }) async {
    final id = 'mock-import-${Random().nextInt(999999)}';
    final now = DateTime.now();
    final job = GisImportJob(
      id: id,
      projectId: projectId,
      projectName: 'Imported Project',
      uploadedByUserId: 'mock-user',
      uploadedByName: 'Field Contributor',
      possibleDuplicate: false,
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
      reviewScope: 'admin',
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

  @override
  Future<ImportComment> addImportComment({
    required String importId,
    required String comment,
    String? featureId,
  }) async {
    return ImportComment(
      id: 'comment-1',
      importJobId: importId,
      authorUserId: 'mock-admin',
      authorName: 'Mock Admin',
      authorRole: 'admin',
      commentText: comment,
      importFeatureId: featureId,
      featureDisplayTitle: featureId == null ? null : 'Linked feature',
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<String> downloadImport(String importId) async =>
      '/mock/imports/$importId.zip';
}

bool _looksLikeFeatureTypeField(String key, String label) {
  final normalized = '${key.toLowerCase()} ${label.toLowerCase()}';
  return normalized.contains('type') ||
      normalized.contains('species') ||
      normalized.contains('crop') ||
      normalized.contains('tree') ||
      normalized.contains('orchard');
}
