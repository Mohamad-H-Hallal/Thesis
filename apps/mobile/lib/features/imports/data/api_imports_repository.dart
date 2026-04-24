import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_error_message.dart';
import '../../../core/pagination/paginated_result.dart';
import '../domain/import_models.dart';
import '../domain/imports_repository.dart';

class ApiImportsRepository implements ImportsRepository {
  ApiImportsRepository(this._apiClient);

  final ApiClient _apiClient;

  String get _basePath => '${AppEnv.apiVersionPrefix}/imports';

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
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        _basePath,
        queryParameters: <String, dynamic>{
          'page': page,
          'limit': limit,
          if (status?.trim().isNotEmpty ?? false) 'status': status!.trim(),
          if (projectId?.trim().isNotEmpty ?? false)
            'project_id': projectId!.trim(),
          if (categoryId?.trim().isNotEmpty ?? false)
            'category_id': categoryId!.trim(),
        },
      );
      final rows = (response.data?['data'] as List? ?? const <dynamic>[]);
      final items = rows
          .map((row) => _toImportJob(Map<String, dynamic>.from(row as Map)))
          .toList(growable: false);
      final pagination = Map<String, dynamic>.from(
        response.data?['pagination'] as Map? ?? const <String, dynamic>{},
      );
      final total = (pagination['total'] as num?)?.toInt() ?? items.length;
      final hasMore =
          (pagination['has_more'] as bool?) ??
          ((page * limit) < total && items.isNotEmpty);
      return PaginatedResult<GisImportJob>(
        items: items,
        page: (pagination['page'] as num?)?.toInt() ?? page,
        limit: (pagination['limit'] as num?)?.toInt() ?? limit,
        total: total,
        hasMore: hasMore,
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load GIS imports right now.',
      );
    }
  }

  @override
  Future<GisImportJob> uploadImport({
    required String projectId,
    required PlatformFile file,
  }) async {
    if ((file.path == null || file.path!.trim().isEmpty) &&
        (file.bytes == null || file.bytes!.isEmpty)) {
      throw 'The selected file could not be read.';
    }

    final multipart = await _toMultipartFile(file);
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_basePath/project/$projectId/upload',
        data: FormData.fromMap(<String, dynamic>{'file': multipart}),
      );
      final row = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return _toImportJob(row);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to upload this GIS file right now.',
      );
    }
  }

  @override
  Future<GisImportDetails> fetchImportDetails(String importId) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_basePath/$importId',
      );
      final data = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      final job = _toImportJob(
        Map<String, dynamic>.from(
          data['job'] as Map? ?? const <String, dynamic>{},
        ),
      );
      final previewRows =
          (data['preview_features'] as List? ?? const <dynamic>[])
              .map(
                (row) =>
                    _toImportedFeature(Map<String, dynamic>.from(row as Map)),
              )
              .toList(growable: false);
      return GisImportDetails(job: job, previewFeatures: previewRows);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load this GIS import right now.',
      );
    }
  }

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
    int page = 1,
    int limit = 20,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_basePath/$importId/features',
        queryParameters: <String, dynamic>{
          'page': page,
          'limit': limit,
          if (status?.trim().isNotEmpty ?? false) 'status': status!.trim(),
          if (issue?.trim().isNotEmpty ?? false) 'issue': issue!.trim(),
        },
      );
      final rows = (response.data?['data'] as List? ?? const <dynamic>[]);
      final items = rows
          .map(
            (row) => _toImportedFeature(Map<String, dynamic>.from(row as Map)),
          )
          .toList(growable: false);
      final pagination = Map<String, dynamic>.from(
        response.data?['pagination'] as Map? ?? const <String, dynamic>{},
      );
      final total = (pagination['total'] as num?)?.toInt() ?? items.length;
      final hasMore =
          (pagination['has_more'] as bool?) ??
          ((page * limit) < total && items.isNotEmpty);
      return PaginatedResult<ImportedFeature>(
        items: items,
        page: (pagination['page'] as num?)?.toInt() ?? page,
        limit: (pagination['limit'] as num?)?.toInt() ?? limit,
        total: total,
        hasMore: hasMore,
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load imported features right now.',
      );
    }
  }

  @override
  Future<GisImportJob> reviewImport({
    required String importId,
    required String status,
    String? reason,
    List<String>? featureIds,
  }) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_basePath/$importId/review',
        data: <String, dynamic>{
          'status': status,
          if (reason?.trim().isNotEmpty ?? false) 'reason': reason!.trim(),
          if (featureIds != null && featureIds.isNotEmpty)
            'feature_ids': featureIds,
        },
      );
      final row = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return _toImportJob(row);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to record this import review right now.',
      );
    }
  }

  Future<MultipartFile> _toMultipartFile(PlatformFile file) async {
    if (kIsWeb || file.path == null || file.path!.trim().isEmpty) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw 'The selected file could not be read.';
      }
      return MultipartFile.fromBytes(bytes, filename: file.name);
    }
    return MultipartFile.fromFile(file.path!, filename: file.name);
  }

  GisImportJob _toImportJob(Map<String, dynamic> row) {
    return GisImportJob(
      id: (row['id'] as String?) ?? '',
      projectId: (row['project_id'] as String?) ?? '',
      projectName: (row['project_name'] as String?) ?? 'Project',
      uploadedByUserId: (row['uploaded_by_user_id'] as String?) ?? '',
      uploadedByName: (row['uploaded_by_name'] as String?) ?? 'Contributor',
      reviewedByUserId: row['reviewed_by_user_id'] as String?,
      reviewedByName: row['reviewed_by_name'] as String?,
      duplicateOfImportJobId: row['duplicate_of_import_job_id'] as String?,
      originalFilename: (row['original_filename'] as String?) ?? 'import',
      fileSizeBytes: _toInt(row['file_size_bytes']),
      fileChecksumSha256: (row['file_checksum_sha256'] as String?) ?? '',
      fileType: (row['file_type'] as String?) ?? 'geojson',
      sourceCrs: row['source_crs'] as String?,
      sourceLayerName: row['source_layer_name'] as String?,
      status: (row['status'] as String?) ?? 'uploaded',
      geometryCount: _toInt(row['geometry_count']),
      pendingFeatureCount: _toInt(row['pending_feature_count']),
      approvedFeatureCount: _toInt(row['approved_feature_count']),
      rejectedFeatureCount: _toInt(row['rejected_feature_count']),
      failedFeatureCount: _toInt(row['failed_feature_count']),
      warningCount: _toInt(row['warning_count']),
      errorCount: _toInt(row['error_count']),
      geometryTypes: ((row['geometry_types'] as List?) ?? const <dynamic>[])
          .map((value) => value.toString())
          .toList(growable: false),
      fileMetadata: _toMap(row['file_metadata']),
      validationSummary: _toMap(row['validation_summary']),
      processingMessage: row['processing_message'] as String?,
      rejectionReason: row['rejection_reason'] as String?,
      uploadedAt: _toDate(row['uploaded_at']),
      processedAt: _toOptionalDate(row['processed_at']),
      reviewedAt: _toOptionalDate(row['reviewed_at']),
      createdAt: _toDate(row['created_at']),
      updatedAt: _toDate(row['updated_at']),
    );
  }

  ImportedFeature _toImportedFeature(Map<String, dynamic> row) {
    return ImportedFeature(
      id: (row['id'] as String?) ?? '',
      importJobId: (row['import_job_id'] as String?) ?? '',
      sourceIndex: _toInt(row['source_index']),
      sourceIdentifier: row['source_identifier'] as String?,
      displayTitle: (row['display_title'] as String?) ?? 'Imported feature',
      sourceFeatureName: row['source_feature_name'] as String?,
      geometryType: row['geometry_type'] as String?,
      geometry: row['geometry'] is Map
          ? Map<String, dynamic>.from(row['geometry'] as Map)
          : null,
      attributes: _toMap(row['attributes']),
      status: (row['status'] as String?) ?? 'pending_review',
      validationWarnings:
          ((row['validation_warnings'] as List?) ?? const <dynamic>[])
              .map((value) => value.toString())
              .toList(growable: false),
      validationErrors:
          ((row['validation_errors'] as List?) ?? const <dynamic>[])
              .map((value) => value.toString())
              .toList(growable: false),
      validationReport: _toMap(row['validation_report']),
      duplicateFeatureId: row['duplicate_feature_id'] as String?,
      approvedFeatureId: row['approved_feature_id'] as String?,
      reviewedByUserId: row['reviewed_by_user_id'] as String?,
      reviewedByName: row['reviewed_by_name'] as String?,
      reviewedAt: _toOptionalDate(row['reviewed_at']),
      approvedAt: _toOptionalDate(row['approved_at']),
      reviewReason: row['review_reason'] as String?,
      createdAt: _toDate(row['created_at']),
      updatedAt: _toDate(row['updated_at']),
    );
  }

  int _toInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value) ?? 0;
    }
    return 0;
  }

  DateTime _toDate(dynamic value) {
    return DateTime.tryParse(value?.toString() ?? '') ?? DateTime.now();
  }

  DateTime? _toOptionalDate(dynamic value) {
    final raw = value?.toString();
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    return DateTime.tryParse(raw);
  }

  Map<String, dynamic> _toMap(dynamic raw) {
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    return const <String, dynamic>{};
  }
}
