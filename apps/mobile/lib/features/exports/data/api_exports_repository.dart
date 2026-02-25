import 'package:dio/dio.dart';

import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';
import '../domain/export_job.dart';
import '../domain/exports_repository.dart';

class ApiExportsRepository implements ExportsRepository {
  ApiExportsRepository(this._apiClient);

  final ApiClient _apiClient;
  final Map<String, DateTime> _downloadedAtById = <String, DateTime>{};

  String get _exportsBasePath => '${AppEnv.apiVersionPrefix}/exports';

  @override
  Future<List<ExportJob>> fetchJobs({required String requestedByUserId}) async {
    final response = await _apiClient.dio.get<Map<String, dynamic>>(_exportsBasePath);
    final payload = response.data ?? const <String, dynamic>{};
    final rows = (payload['data'] as List? ?? const <dynamic>[]);

    return rows.map((row) {
      final map = Map<String, dynamic>.from(row as Map);
      final id = (map['id'] as String?) ?? '';
      final downloadedAt = _downloadedAtById[id];
      return _mapExportJob(map).copyWith(downloadedAt: downloadedAt);
    }).toList(growable: false);
  }

  @override
  Future<ExportJob> requestExport({
    required String requestedByUserId,
    required String projectId,
    required String projectName,
    required ExportFormat format,
    required Map<String, dynamic> exportParameters,
  }) async {
    final payload = <String, dynamic>{...exportParameters, 'format': format.name};
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
    await _apiClient.dio.get(
      '$_exportsBasePath/$exportId/download',
      options: Options(responseType: ResponseType.bytes),
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
    return _mapExportJob(statusData).copyWith(downloadedAt: downloadedAt);
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

  ExportJob _mapExportJob(Map<String, dynamic> row) {
    final status = _toStatus(row['status'] as String?);
    final formatRaw = _toMap(row['export_parameters'])['format'] as String?;
    final format = formatRaw == 'shapefile' ? ExportFormat.shapefile : ExportFormat.geojson;
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
}
