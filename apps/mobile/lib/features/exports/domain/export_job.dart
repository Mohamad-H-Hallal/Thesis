enum ExportFormat { shapefile, geojson }

enum ExportJobStatus { pending, processing, completed, failed, expired }

class ExportJobsQuery {
  const ExportJobsQuery({
    this.categoryId,
    this.projectId,
    this.status,
    this.format,
  });

  final String? categoryId;
  final String? projectId;
  final ExportJobStatus? status;
  final ExportFormat? format;

  @override
  bool operator ==(Object other) {
    return other is ExportJobsQuery &&
        other.categoryId == categoryId &&
        other.projectId == projectId &&
        other.status == status &&
        other.format == format;
  }

  @override
  int get hashCode => Object.hash(categoryId, projectId, status, format);
}

class ExportJob {
  const ExportJob({
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.format,
    required this.status,
    required this.requestedByUserId,
    required this.requestedAt,
    this.exportParameters = const <String, dynamic>{},
    this.filePath,
    this.fileSizeBytes,
    this.recordCount,
    this.errorMessage,
    this.displayMessage,
    this.fileStatus,
    this.retentionExpiresAt,
    this.retentionExpiredAt,
    this.canRegenerate,
    this.completedAt,
    this.downloadedAt,
    this.localFilePath,
  });

  final String id;
  final String projectId;
  final String projectName;
  final ExportFormat format;
  final ExportJobStatus status;
  final String requestedByUserId;
  final DateTime requestedAt;
  final Map<String, dynamic> exportParameters;
  final String? filePath;
  final int? fileSizeBytes;
  final int? recordCount;
  final String? errorMessage;
  final String? displayMessage;
  final String? fileStatus;
  final DateTime? retentionExpiresAt;
  final DateTime? retentionExpiredAt;
  final bool? canRegenerate;
  final DateTime? completedAt;
  final DateTime? downloadedAt;
  final String? localFilePath;

  bool get canDownload =>
      status == ExportJobStatus.completed && filePath != null;

  bool get canRetryOrRegenerate =>
      status == ExportJobStatus.failed ||
      status == ExportJobStatus.expired ||
      canRegenerate == true;

  ExportJob copyWith({
    ExportJobStatus? status,
    Map<String, dynamic>? exportParameters,
    String? filePath,
    int? fileSizeBytes,
    int? recordCount,
    String? errorMessage,
    String? displayMessage,
    String? fileStatus,
    DateTime? retentionExpiresAt,
    DateTime? retentionExpiredAt,
    bool? canRegenerate,
    DateTime? completedAt,
    DateTime? downloadedAt,
    String? localFilePath,
  }) {
    return ExportJob(
      id: id,
      projectId: projectId,
      projectName: projectName,
      format: format,
      status: status ?? this.status,
      requestedByUserId: requestedByUserId,
      requestedAt: requestedAt,
      exportParameters: exportParameters ?? this.exportParameters,
      filePath: filePath ?? this.filePath,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      recordCount: recordCount ?? this.recordCount,
      errorMessage: errorMessage ?? this.errorMessage,
      displayMessage: displayMessage ?? this.displayMessage,
      fileStatus: fileStatus ?? this.fileStatus,
      retentionExpiresAt: retentionExpiresAt ?? this.retentionExpiresAt,
      retentionExpiredAt: retentionExpiredAt ?? this.retentionExpiredAt,
      canRegenerate: canRegenerate ?? this.canRegenerate,
      completedAt: completedAt ?? this.completedAt,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      localFilePath: localFilePath ?? this.localFilePath,
    );
  }
}

class ExportDashboardMetrics {
  const ExportDashboardMetrics({
    required this.total,
    required this.pending,
    required this.processing,
    required this.completed,
    required this.failed,
  });

  final int total;
  final int pending;
  final int processing;
  final int completed;
  final int failed;

  static ExportDashboardMetrics fromJobs(List<ExportJob> jobs) {
    var pending = 0;
    var processing = 0;
    var completed = 0;
    var failed = 0;

    for (final job in jobs) {
      switch (job.status) {
        case ExportJobStatus.pending:
          pending += 1;
          break;
        case ExportJobStatus.processing:
          processing += 1;
          break;
        case ExportJobStatus.completed:
          completed += 1;
          break;
        case ExportJobStatus.failed:
          failed += 1;
          break;
        case ExportJobStatus.expired:
          completed += 1;
          break;
      }
    }

    return ExportDashboardMetrics(
      total: jobs.length,
      pending: pending,
      processing: processing,
      completed: completed,
      failed: failed,
    );
  }
}
