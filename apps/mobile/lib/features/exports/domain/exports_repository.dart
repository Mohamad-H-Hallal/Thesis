import 'export_job.dart';
import '../../../core/pagination/paginated_result.dart';

abstract class ExportsRepository {
  Future<List<ExportJob>> fetchJobs({required String requestedByUserId});

  Future<PaginatedResult<ExportJob>> fetchJobsPage({
    required String requestedByUserId,
    String? categoryId,
    String? projectId,
    ExportJobStatus? status,
    ExportFormat? format,
    int page = 1,
    int limit = 20,
  });

  Future<ExportDashboardMetrics> fetchSummary({
    required String requestedByUserId,
    String? categoryId,
    String? projectId,
    ExportJobStatus? status,
    ExportFormat? format,
  });

  Future<ExportJob> requestExport({
    required String requestedByUserId,
    required String projectId,
    required String projectName,
    required ExportFormat format,
    required Map<String, dynamic> exportParameters,
  });

  Future<List<ExportJob>> processQueueTick({required String requestedByUserId});

  Future<ExportJob?> markDownloaded({
    required String requestedByUserId,
    required String exportId,
  });

  Future<ExportJob?> retryFailed({
    required String requestedByUserId,
    required String exportId,
  });
}
