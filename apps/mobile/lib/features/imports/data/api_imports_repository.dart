import 'dart:collection';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../../../core/config/app_env.dart';
import '../../../core/maps/tile_query.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_error_message.dart';
import '../../../core/pagination/paginated_result.dart';
import '../../../core/platform/downloaded_file_saver.dart';
import '../../map/domain/map_feature.dart';
import '../domain/import_models.dart';
import '../domain/imports_repository.dart';

class ApiImportsRepository implements ImportsRepository {
  ApiImportsRepository(this._apiClient);

  final ApiClient _apiClient;
  final LinkedHashMap<String, ImportMapData> _importTileCache =
      LinkedHashMap<String, ImportMapData>();
  static const int _importTileCacheMaxEntries = 192;
  static const int _importTileBatchSize = 4;
  int _importTileCacheRevision = 0;
  String? _importTileCacheSessionScope;

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
      final previewSummary = _toPreviewSummary(
        Map<String, dynamic>.from(
          data['preview_summary'] as Map? ?? const <String, dynamic>{},
        ),
      );
      final comments = (data['comments'] as List? ?? const <dynamic>[])
          .map((row) => _toImportComment(Map<String, dynamic>.from(row as Map)))
          .toList(growable: false);
      return GisImportDetails(
        job: job,
        previewFeatures: previewRows,
        previewSummary: previewSummary,
        comments: comments,
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load this GIS import right now.',
      );
    }
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
    _ensureImportTileCacheSessionScope();
    final requestSessionScope = _currentSessionCacheScope;
    if (_importTileCacheRevision != cacheRevision) {
      _importTileCacheRevision = cacheRevision;
      _importTileCache.clear();
    }
    try {
      final tiles = buildVisibleTileQueries(
        minLon: minLon,
        minLat: minLat,
        maxLon: maxLon,
        maxLat: maxLat,
        zoom: zoom,
        buffer: 0,
      );
      final tileResults = <ImportMapData>[];
      Object? firstError;
      for (var start = 0; start < tiles.length; start += _importTileBatchSize) {
        final end = math.min(start + _importTileBatchSize, tiles.length);
        final batch = tiles.sublist(start, end);
        final batchResults = await Future.wait(
          batch.map((tile) async {
            try {
              return await _fetchImportMapTile(
                importId: importId,
                projectId: projectId,
                z: tile.z,
                x: tile.x,
                y: tile.y,
                renderZoom: zoom,
              );
            } on StateError {
              rethrow;
            } catch (error) {
              firstError ??= error;
              return null;
            }
          }),
        );
        for (final result in batchResults) {
          if (result != null) {
            tileResults.add(result);
          }
        }
        _assertImportRequestSessionScope(requestSessionScope);
      }
      if (tileResults.isEmpty && firstError != null) {
        throw firstError!;
      }
      final stagedRows = <String, ImportedFeature>{};
      final approvedRows = <String, MapFeatureSummary>{};
      for (final tile in tileResults) {
        for (final feature in tile.stagedFeatures) {
          stagedRows.putIfAbsent(feature.id, () => feature);
        }
        for (final feature in tile.approvedProjectFeatures) {
          approvedRows.putIfAbsent(feature.id, () => feature);
        }
      }
      _assertImportRequestSessionScope(requestSessionScope);
      return ImportMapData(
        stagedFeatures: stagedRows.values.toList(growable: false),
        approvedProjectFeatures: approvedRows.values.toList(growable: false),
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load the import map right now.',
      );
    }
  }

  Future<ImportMapData> _fetchImportMapTile({
    required String importId,
    required String projectId,
    required int z,
    required int x,
    required int y,
    required double renderZoom,
  }) async {
    _ensureImportTileCacheSessionScope();
    final requestSessionScope = _currentSessionCacheScope;
    final zoomKey = renderZoom.toStringAsFixed(2);
    final cacheKey =
        '$requestSessionScope:$importId:$projectId:$z:$x:$y:$zoomKey';
    final cached = _importTileCache.remove(cacheKey);
    if (cached != null) {
      _importTileCache[cacheKey] = cached;
      return cached;
    }
    final response = await _apiClient.dio.get<Map<String, dynamic>>(
      '$_basePath/$importId/tiles/$z/$x/$y',
      queryParameters: <String, dynamic>{
        'project_id': projectId,
        'zoom': zoomKey,
      },
    );
    final data = Map<String, dynamic>.from(
      response.data?['data'] as Map? ?? const <String, dynamic>{},
    );
    final stagedRows = (data['staged_features'] as List? ?? const <dynamic>[])
        .map((row) {
          final item = Map<String, dynamic>.from(row as Map);
          final responseImportId = item['import_job_id'];
          if (responseImportId is! String || responseImportId != importId) {
            throw StateError(
              'The import map response did not match the active import.',
            );
          }
          return _toImportedFeature(item);
        })
        .toList(growable: false);
    final approvedRows =
        (data['approved_project_features'] as List? ?? const <dynamic>[])
            .map((row) {
              final item = Map<String, dynamic>.from(row as Map);
              final responseProjectId = item['project_id'];
              if (responseProjectId is! String ||
                  responseProjectId != projectId) {
                throw StateError(
                  'The import map response did not match the active project.',
                );
              }
              return _toProjectFeature(item, expectedProjectId: projectId);
            })
            .toList(growable: false);
    final tileData = ImportMapData(
      stagedFeatures: stagedRows,
      approvedProjectFeatures: approvedRows,
    );
    _assertImportRequestSessionScope(requestSessionScope);
    _rememberImportTile(cacheKey, tileData);
    return tileData;
  }

  @override
  Future<ImportQuickMapPreview> fetchImportQuickMapPreview({
    required String importId,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_basePath/$importId/quick-map',
      );
      final data = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      final rows = (data['features'] as List? ?? const <dynamic>[])
          .map(
            (row) => _toImportedFeature(Map<String, dynamic>.from(row as Map)),
          )
          .toList(growable: false);
      final rawStatusCounts = Map<String, dynamic>.from(
        data['status_counts'] as Map? ?? const <String, dynamic>{},
      );
      return ImportQuickMapPreview(
        totalFeatureCount: _toInt(data['total_feature_count']),
        geometryFeatureCount: _toInt(data['geometry_feature_count']),
        renderedFeatureCount: _toInt(data['rendered_feature_count']),
        isClustered: data['is_clustered'] as bool? ?? false,
        bounds: _toImportMapBounds(data['bounds']),
        statusCounts: rawStatusCounts.map(
          (key, value) => MapEntry(key, _toInt(value)),
        ),
        features: rows,
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load this import map preview right now.',
      );
    }
  }

  @override
  Future<ImportedFeature> fetchImportFeatureById({
    required String importId,
    required String featureId,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_basePath/$importId/features/$featureId',
      );
      final data = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return _toImportedFeature(data);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load this imported feature right now.',
      );
    }
  }

  @override
  Future<List<ImportComment>> fetchImportComments(String importId) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_basePath/$importId/comments',
      );
      final rows = (response.data?['data'] as List? ?? const <dynamic>[]);
      return rows
          .map((row) => _toImportComment(Map<String, dynamic>.from(row as Map)))
          .toList(growable: false);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load import comments right now.',
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
    String? search,
    String? geometryType,
    String? featureType,
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
          if (search?.trim().isNotEmpty ?? false) 'search': search!.trim(),
          if (geometryType?.trim().isNotEmpty ?? false)
            'geometry_type': geometryType!.trim(),
          if (featureType?.trim().isNotEmpty ?? false)
            'feature_type': featureType!.trim(),
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
    String? filterStatus,
    String? filterIssue,
    String? filterSearch,
    String? filterGeometryType,
    String? filterFeatureType,
  }) async {
    try {
      final filters = <String, dynamic>{
        if (filterStatus?.trim().isNotEmpty ?? false)
          'status': filterStatus!.trim(),
        if (filterIssue?.trim().isNotEmpty ?? false)
          'issue': filterIssue!.trim(),
        if (filterSearch?.trim().isNotEmpty ?? false)
          'search': filterSearch!.trim(),
        if (filterGeometryType?.trim().isNotEmpty ?? false)
          'geometry_type': filterGeometryType!.trim(),
        if (filterFeatureType?.trim().isNotEmpty ?? false)
          'feature_type': filterFeatureType!.trim(),
      };
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_basePath/$importId/review',
        data: <String, dynamic>{
          'status': status,
          if (reason?.trim().isNotEmpty ?? false) 'reason': reason!.trim(),
          if (featureIds != null && featureIds.isNotEmpty)
            'feature_ids': featureIds,
          if ((featureIds == null || featureIds.isEmpty) && filters.isNotEmpty)
            'filters': filters,
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

  @override
  Future<ImportComment> addImportComment({
    required String importId,
    required String comment,
    String? featureId,
  }) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_basePath/$importId/comments',
        data: <String, dynamic>{
          'comment': comment.trim(),
          if (featureId?.trim().isNotEmpty ?? false)
            'feature_id': featureId!.trim(),
        },
      );
      final row = Map<String, dynamic>.from(
        response.data?['data'] as Map? ?? const <String, dynamic>{},
      );
      return _toImportComment(row);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to save this import comment right now.',
      );
    }
  }

  @override
  Future<String> downloadImport(String importId) async {
    try {
      final response = await _apiClient.dio.get<List<int>>(
        '$_basePath/$importId/download',
        options: Options(responseType: ResponseType.bytes),
      );
      final fileBytes = _normalizeBytes(response.data);
      if (fileBytes == null || fileBytes.isEmpty) {
        throw StateError('The import download returned an empty file.');
      }
      return _saveImportFile(
        importId: importId,
        bytes: fileBytes,
        headers: response.headers,
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(error, fallback: 'Import download failed.');
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
      possibleDuplicate: (row['possible_duplicate'] as bool?) ?? false,
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
      reviewScope: (row['review_scope'] as String?) ?? 'admin',
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
      summaryAttributes: _toMap(row['summary_attributes']),
      attributeCount: _toInt(row['attribute_count']),
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
      isSummary: row['is_summary'] as bool? ?? false,
      isAggregate: row['is_aggregate'] as bool? ?? false,
      clusterCount: math.max(1, _toInt(row['cluster_count'])),
      createdAt: _toDate(row['created_at']),
      updatedAt: _toDate(row['updated_at']),
    );
  }

  ImportPreviewSummary _toPreviewSummary(Map<String, dynamic> row) {
    return ImportPreviewSummary(
      geometryFeatureCount: _toInt(row['geometry_feature_count']),
      previewFeatureCount: _toInt(row['preview_feature_count']),
      outsideWorkspaceFeatureCount: _toInt(
        row['outside_workspace_feature_count'],
      ),
    );
  }

  ImportMapBounds? _toImportMapBounds(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final row = Map<String, dynamic>.from(raw);
    return ImportMapBounds(
      minLon: _toDouble(row['min_lon']) ?? 0,
      minLat: _toDouble(row['min_lat']) ?? 0,
      maxLon: _toDouble(row['max_lon']) ?? 0,
      maxLat: _toDouble(row['max_lat']) ?? 0,
    );
  }

  ImportComment _toImportComment(Map<String, dynamic> row) {
    return ImportComment(
      id: (row['id'] as String?) ?? '',
      importJobId: (row['import_job_id'] as String?) ?? '',
      authorUserId: (row['author_user_id'] as String?) ?? '',
      authorName: (row['author_name'] as String?) ?? 'Admin',
      authorRole: (row['author_role'] as String?) ?? 'admin',
      commentText: (row['comment_text'] as String?) ?? '',
      importFeatureId: row['import_feature_id'] as String?,
      featureDisplayTitle: row['feature_display_title'] as String?,
      createdAt: _toDate(row['created_at']),
    );
  }

  MapFeatureSummary _toProjectFeature(
    Map<String, dynamic> item, {
    required String expectedProjectId,
  }) {
    return MapFeatureSummary(
      id: (item['id'] as String?) ?? '',
      projectId: (item['project_id'] as String?) ?? expectedProjectId,
      status: (item['status'] as String?) ?? 'approved',
      geometry: Map<String, dynamic>.from(
        item['geometry'] as Map? ?? const <String, dynamic>{},
      ),
      attributes: Map<String, dynamic>.from(
        item['attributes'] as Map? ?? const <String, dynamic>{},
      ),
      sourceGeometryType: item['source_geometry_type'] as String?,
      collectedBy: item['collected_by'] as String?,
      reviewedBy: item['reviewed_by'] as String?,
      reviewNotes: item['review_notes'] as String?,
      accuracyMeters: _toDouble(item['accuracy_meters']),
      collectedAt: _toOptionalDate(item['collected_at']),
      submittedAt: _toOptionalDate(item['submitted_at']),
      reviewedAt: _toOptionalDate(item['reviewed_at']),
      photoCount: _toInt(item['photo_count']),
      photos: const <MapFeaturePhoto>[],
      isSummary: item['is_summary'] as bool? ?? false,
      isAggregate: item['is_aggregate'] as bool? ?? false,
      clusterCount: math.max(1, _toInt(item['cluster_count'])),
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

  double? _toDouble(dynamic value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
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

  List<int>? _normalizeBytes(Object? raw) {
    if (raw is List<int>) {
      return raw;
    }
    if (raw is List) {
      return raw.whereType<num>().map((value) => value.toInt()).toList();
    }
    return null;
  }

  Future<String> _saveImportFile({
    required String importId,
    required List<int> bytes,
    required Headers headers,
  }) async {
    final fileName = _fileNameFromHeaders(headers) ?? 'import_$importId.zip';
    final safeFileName = fileName.replaceAll(RegExp(r'[<>:\"/\\\\|?*]+'), '_');
    return saveDownloadedBytes(
      bytes: bytes,
      fileName: safeFileName,
      directoryName: 'imports',
    );
  }

  String? _fileNameFromHeaders(Headers headers) {
    final raw = headers.value('content-disposition');
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }

    final utfMatch = RegExp(
      r"filename\*=UTF-8''([^;]+)",
      caseSensitive: false,
    ).firstMatch(raw);
    if (utfMatch != null) {
      return Uri.decodeFull(utfMatch.group(1)!);
    }

    final basicMatch = RegExp(
      r'filename=\"?([^\";]+)\"?',
      caseSensitive: false,
    ).firstMatch(raw);
    if (basicMatch != null) {
      return basicMatch.group(1);
    }

    return null;
  }

  void _rememberImportTile(String cacheKey, ImportMapData data) {
    _importTileCache[cacheKey] = data;
    while (_importTileCache.length > _importTileCacheMaxEntries) {
      _importTileCache.remove(_importTileCache.keys.first);
    }
  }

  String get _currentSessionCacheScope {
    final session = _apiClient.currentSessionBinding;
    return session == null
        ? 'unauthenticated'
        : '${session.ownerUserId}:${session.generation}';
  }

  void _ensureImportTileCacheSessionScope() {
    final currentScope = _currentSessionCacheScope;
    if (_importTileCacheSessionScope == currentScope) {
      return;
    }
    _importTileCacheSessionScope = currentScope;
    _importTileCache.clear();
  }

  void _assertImportRequestSessionScope(String expectedScope) {
    if (_currentSessionCacheScope != expectedScope) {
      throw StateError(
        'The authenticated session changed while import map features were loading.',
      );
    }
  }
}
