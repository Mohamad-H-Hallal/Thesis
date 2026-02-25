import 'export_job.dart';

abstract class ExportsRepository {
  Future<List<ExportJob>> fetchJobs({required String requestedByUserId});

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
