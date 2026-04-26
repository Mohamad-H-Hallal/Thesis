import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_error_message.dart';
import '../../../core/pagination/paginated_result.dart';
import '../domain/export_job.dart';
import '../domain/exports_repository.dart';

class ApiExportsRepository implements ExportsRepository {
  ApiExportsRepository(this._apiClient);

  final ApiClient _apiClient;
  final Map<String, DateTime> _downloadedAtById = <String, DateTime>{};
  final Map<String, String> _downloadPathById = <String, String>{};

  String get _exportsBasePath => '${AppEnv.apiVersionPrefix}/exports';

  @override
  Future<List<ExportJob>> fetchJobs({required String requestedByUserId}) async {
    final page = await fetchJobsPage(
      requestedByUserId: requestedByUserId,
      limit: 100,
    );
    return page.items;
  }

  @override
  Future<PaginatedResult<ExportJob>> fetchJobsPage({
    required String requestedByUserId,
    String? categoryId,
    String? projectId,
    ExportJobStatus? status,
    ExportFormat? format,
    int page = 1,
    int limit = 20,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        _exportsBasePath,
        queryParameters: <String, dynamic>{
          'page': page,
          'limit': limit,
          if (categoryId?.trim().isNotEmpty ?? false)
            'category_id': categoryId!.trim(),
          if (projectId?.trim().isNotEmpty ?? false) 'project_id': projectId!.trim(),
          if (status != null) 'status': status.name,
          if (format != null) 'format': format.name,
        },
      );
      final payload = response.data ?? const <String, dynamic>{};
      final rows = (payload['data'] as List? ?? const <dynamic>[]);
      final pagination = Map<String, dynamic>.from(
        payload['pagination'] as Map? ?? const <String, dynamic>{},
      );

      final items = rows
          .map((row) {
            final map = Map<String, dynamic>.from(row as Map);
            final id = (map['id'] as String?) ?? '';
            return _mapExportJob(map).copyWith(
              downloadedAt: _downloadedAtById[id],
              localFilePath: _downloadPathById[id],
            );
          })
          .toList(growable: false);
      final total = (pagination['total'] as num?)?.toInt() ?? items.length;
      final hasMore =
          (pagination['has_more'] as bool?) ??
          ((page * limit) < total && items.isNotEmpty);

      return PaginatedResult<ExportJob>(
        items: items,
        page: (pagination['page'] as num?)?.toInt() ?? page,
        limit: (pagination['limit'] as num?)?.toInt() ?? limit,
        total: total,
        hasMore: hasMore,
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load export jobs right now.',
      );
    }
  }

  @override
  Future<ExportDashboardMetrics> fetchSummary({
    required String requestedByUserId,
    String? categoryId,
    String? projectId,
    ExportJobStatus? status,
    ExportFormat? format,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        _exportsBasePath,
        queryParameters: <String, dynamic>{
          'page': 1,
          'limit': 1,
          if (categoryId?.trim().isNotEmpty ?? false)
            'category_id': categoryId!.trim(),
          if (projectId?.trim().isNotEmpty ?? false) 'project_id': projectId!.trim(),
          if (status != null) 'status': status.name,
          if (format != null) 'format': format.name,
        },
      );
      final payload = response.data ?? const <String, dynamic>{};
      final summary = Map<String, dynamic>.from(
        payload['summary'] as Map? ?? const <String, dynamic>{},
      );
      return ExportDashboardMetrics(
        total: _toInt(summary['total']) ?? 0,
        pending: _toInt(summary['pending']) ?? 0,
        processing: _toInt(summary['processing']) ?? 0,
        completed: _toInt(summary['completed']) ?? 0,
        failed: _toInt(summary['failed']) ?? 0,
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load export summary right now.',
      );
    }
  }

  @override
  Future<ExportJob> requestExport({
    required String requestedByUserId,
    required String projectId,
    required String projectName,
    required ExportFormat format,
    required Map<String, dynamic> exportParameters,
  }) async {
    final payload = <String, dynamic>{
      ..._sanitizeExportParameters(exportParameters),
      'format': format.name,
    };
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_exportsBasePath/project/$projectId',
        data: payload,
      );

      final data = Map<String, dynamic>.from(
        (response.data ?? const <String, dynamic>{})['data'] as Map? ??
            const <String, dynamic>{},
      );
      final exportId = data['export_id'] as String?;
      if (exportId == null || exportId.isEmpty) {
        throw StateError('Export ID missing in response.');
      }

      final statusResponse = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_exportsBasePath/$exportId',
      );
      final statusData = Map<String, dynamic>.from(
        (statusResponse.data ?? const <String, dynamic>{})['data'] as Map? ??
            const <String, dynamic>{},
      );
      return _mapExportJob(statusData);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Export request could not be created.',
      );
    }
  }

  @override
  Future<List<ExportJob>> processQueueTick({
    required String requestedByUserId,
  }) async {
    return fetchJobs(requestedByUserId: requestedByUserId);
  }

  @override
  Future<ExportJob?> markDownloaded({
    required String requestedByUserId,
    required String exportId,
  }) async {
    try {
      final downloadResponse = await _apiClient.dio.get<List<int>>(
        '$_exportsBasePath/$exportId/download',
        options: Options(responseType: ResponseType.bytes),
      );

      final fileBytes = _normalizeBytes(downloadResponse.data);
      if (fileBytes == null || fileBytes.isEmpty) {
        throw StateError('The export download returned an empty file.');
      }

      final savedPath = await _saveExportFile(
        exportId: exportId,
        bytes: fileBytes,
        headers: downloadResponse.headers,
      );

      final statusResponse = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_exportsBasePath/$exportId',
      );
      final statusData = Map<String, dynamic>.from(
        (statusResponse.data ?? const <String, dynamic>{})['data'] as Map? ??
            const <String, dynamic>{},
      );
      final downloadedAt = DateTime.now();
      _downloadedAtById[exportId] = downloadedAt;
      _downloadPathById[exportId] = savedPath;
      return _mapExportJob(
        statusData,
      ).copyWith(downloadedAt: downloadedAt, localFilePath: savedPath);
    } on DioException catch (error) {
      throw userFacingDioMessage(error, fallback: 'Export download failed.');
    }
  }

  @override
  Future<ExportJob?> retryFailed({
    required String requestedByUserId,
    required String exportId,
  }) async {
    final jobs = await fetchJobs(requestedByUserId: requestedByUserId);
    ExportJob? failedJob;
    for (final job in jobs) {
      if (job.id == exportId) {
        failedJob = job;
        break;
      }
    }

    if (failedJob == null || failedJob.status != ExportJobStatus.failed) {
      return null;
    }

    return requestExport(
      requestedByUserId: requestedByUserId,
      projectId: failedJob.projectId,
      projectName: failedJob.projectName,
      format: failedJob.format,
      exportParameters: failedJob.exportParameters,
    );
  }

  Map<String, dynamic> _sanitizeExportParameters(Map<String, dynamic> raw) {
    final sanitized = <String, dynamic>{};
    raw.forEach((key, value) {
      if (value == null) {
        return;
      }
      if (value is String) {
        final trimmed = value.trim();
        if (trimmed.isEmpty) {
          return;
        }
        sanitized[key] = trimmed;
        return;
      }
      sanitized[key] = value;
    });
    return sanitized;
  }

  ExportJob _mapExportJob(Map<String, dynamic> row) {
    final status = _toStatus(row['status'] as String?);
    final formatRaw = _toMap(row['export_parameters'])['format'] as String?;
    final format = formatRaw == 'shapefile'
        ? ExportFormat.shapefile
        : ExportFormat.geojson;
    final requestedAtRaw = row['requested_at'] as String?;
    final completedAtRaw = row['completed_at'] as String?;

    return ExportJob(
      id: (row['id'] as String?) ?? '',
      projectId: (row['project_id'] as String?) ?? '',
      projectName: (row['project_name'] as String?) ?? 'Project',
      format: format,
      status: status,
      requestedByUserId: (row['requested_by_user_id'] as String?) ?? '',
      requestedAt: DateTime.tryParse(requestedAtRaw ?? '') ?? DateTime.now(),
      exportParameters: _toMap(row['export_parameters']),
      filePath: row['file_path'] as String?,
      fileSizeBytes: _toInt(row['file_size_bytes']),
      recordCount: _toInt(row['feature_count']),
      errorMessage: row['error_message'] as String?,
      completedAt: DateTime.tryParse(completedAtRaw ?? ''),
      downloadedAt: null,
      localFilePath: null,
    );
  }

  ExportJobStatus _toStatus(String? value) {
    switch (value) {
      case 'processing':
        return ExportJobStatus.processing;
      case 'completed':
        return ExportJobStatus.completed;
      case 'failed':
        return ExportJobStatus.failed;
      default:
        return ExportJobStatus.pending;
    }
  }

  int? _toInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
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

  Future<String> _saveExportFile({
    required String exportId,
    required List<int> bytes,
    required Headers headers,
  }) async {
    final baseDir = await _resolveExportDirectory();
    await baseDir.create(recursive: true);

    final fileName = _fileNameFromHeaders(headers) ?? 'export_$exportId.zip';
    final safeFileName = fileName.replaceAll(RegExp(r'[<>:"/\\|?*]+'), '_');
    final target = File(p.join(baseDir.path, safeFileName));
    await target.writeAsBytes(bytes, flush: true);
    return target.path;
  }

  Future<Directory> _resolveExportDirectory() async {
    final externalDir = await getExternalStorageDirectory();
    if (externalDir != null) {
      return Directory(p.join(externalDir.path, 'exports'));
    }

    final documentsDir = await getApplicationDocumentsDirectory();
    return Directory(p.join(documentsDir.path, 'exports'));
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
      r'filename="?([^";]+)"?',
      caseSensitive: false,
    ).firstMatch(raw);
    if (basicMatch != null) {
      return basicMatch.group(1);
    }

    return null;
  }
}
