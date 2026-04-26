import 'package:uuid/uuid.dart';

import '../../../core/pagination/paginated_result.dart';
import '../domain/exports_repository.dart';
import '../domain/export_job.dart';

class MockExportsRepository implements ExportsRepository {
  final Uuid _uuid = const Uuid();
  final List<ExportJob> _jobs = <ExportJob>[];

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
    await Future<void>.delayed(const Duration(milliseconds: 240));
    _seedIfEmpty(requestedByUserId);
    final filtered = _jobs
        .where((job) => job.requestedByUserId == requestedByUserId)
        .where((job) => projectId == null || job.projectId == projectId)
        .where((job) => format == null || job.format == format)
        .where((job) => status == null || job.status == status)
        .toList(growable: false)
      ..sort((a, b) => b.requestedAt.compareTo(a.requestedAt));
    final start = (page - 1) * limit;
    final end = (start + limit).clamp(0, filtered.length);
    final items = start >= filtered.length
        ? const <ExportJob>[]
        : filtered.sublist(start, end);
    return PaginatedResult<ExportJob>(
      items: items,
      page: page,
      limit: limit,
      total: filtered.length,
      hasMore: end < filtered.length,
    );
  }

  @override
  Future<ExportDashboardMetrics> fetchSummary({
    required String requestedByUserId,
    String? categoryId,
    String? projectId,
    ExportJobStatus? status,
    ExportFormat? format,
  }) async {
    final page = await fetchJobsPage(
      requestedByUserId: requestedByUserId,
      categoryId: categoryId,
      projectId: projectId,
      status: status,
      format: format,
      page: 1,
      limit: 1000,
    );
    return ExportDashboardMetrics.fromJobs(page.items);
  }

  @override
  Future<ExportJob> requestExport({
    required String requestedByUserId,
    required String projectId,
    required String projectName,
    required ExportFormat format,
    required Map<String, dynamic> exportParameters,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 220));
    final now = DateTime.now();
    final job = ExportJob(
      id: _uuid.v4(),
      projectId: projectId,
      projectName: projectName,
      format: format,
      status: ExportJobStatus.pending,
      requestedByUserId: requestedByUserId,
      requestedAt: now,
      exportParameters: exportParameters,
    );
    _jobs.add(job);
    return job;
  }

  @override
  Future<List<ExportJob>> processQueueTick({
    required String requestedByUserId,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));

    ExportJob? currentProcessing;
    for (final job in _jobs) {
      if (job.requestedByUserId == requestedByUserId &&
          job.status == ExportJobStatus.processing) {
        currentProcessing = job;
        break;
      }
    }

    if (currentProcessing != null) {
      final forceResult =
          currentProcessing.exportParameters['simulate_result'] as String?;
      final shouldFail = forceResult == 'failed'
          ? true
          : forceResult == 'completed'
          ? false
          : _isDeterministicFailure(currentProcessing.id);

      final completed = shouldFail
          ? currentProcessing.copyWith(
              status: ExportJobStatus.failed,
              completedAt: DateTime.now(),
              errorMessage: 'Export pipeline failed for selected parameters.',
            )
          : currentProcessing.copyWith(
              status: ExportJobStatus.completed,
              completedAt: DateTime.now(),
              filePath:
                  '/exports/${currentProcessing.projectName.replaceAll(' ', '_')}_${currentProcessing.format.name}.zip',
              fileSizeBytes:
                  280000 + (currentProcessing.id.hashCode.abs() % 9000000),
              recordCount: 100 + (currentProcessing.id.hashCode.abs() % 5000),
            );

      _replace(completed);
      return fetchJobs(requestedByUserId: requestedByUserId);
    }

    for (final job in _jobs) {
      if (job.requestedByUserId == requestedByUserId &&
          job.status == ExportJobStatus.pending) {
        _replace(job.copyWith(status: ExportJobStatus.processing));
        break;
      }
    }

    return fetchJobs(requestedByUserId: requestedByUserId);
  }

  @override
  Future<ExportJob?> markDownloaded({
    required String requestedByUserId,
    required String exportId,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 160));
    for (final job in _jobs) {
      if (job.id == exportId && job.requestedByUserId == requestedByUserId) {
        if (!job.canDownload) {
          return null;
        }
        final updated = job.copyWith(
          downloadedAt: DateTime.now(),
          localFilePath:
              '/storage/emulated/0/Android/data/com.example.lebanese_gis_mobile/files/exports/${job.projectName.replaceAll(' ', '_')}_${job.format.name}.zip',
        );
        _replace(updated);
        return updated;
      }
    }
    return null;
  }

  @override
  Future<ExportJob?> retryFailed({
    required String requestedByUserId,
    required String exportId,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 170));
    for (final job in _jobs) {
      if (job.id == exportId &&
          job.requestedByUserId == requestedByUserId &&
          job.status == ExportJobStatus.failed) {
        final retried = job.copyWith(
          status: ExportJobStatus.pending,
          errorMessage: null,
          completedAt: null,
          filePath: null,
          fileSizeBytes: null,
          recordCount: null,
        );
        _replace(retried);
        return retried;
      }
    }
    return null;
  }

  void _replace(ExportJob updated) {
    final index = _jobs.indexWhere((job) => job.id == updated.id);
    if (index == -1) {
      _jobs.add(updated);
      return;
    }
    _jobs[index] = updated;
  }

  void _seedIfEmpty(String requestedByUserId) {
    final hasSeed = _jobs.any(
      (job) => job.requestedByUserId == requestedByUserId,
    );
    if (hasSeed) {
      return;
    }

    final seedNow = DateTime.now().subtract(const Duration(hours: 6));
    _jobs.add(
      ExportJob(
        id: _uuid.v4(),
        projectId: 'proj-1',
        projectName: 'Bekaa Orchard Census 2026',
        format: ExportFormat.geojson,
        status: ExportJobStatus.completed,
        requestedByUserId: requestedByUserId,
        requestedAt: seedNow,
        completedAt: seedNow.add(const Duration(minutes: 3)),
        filePath: '/exports/bekaa_seed.geojson.zip',
        fileSizeBytes: 1875000,
        recordCount: 1242,
      ),
    );
  }

  bool _isDeterministicFailure(String id) {
    return id.hashCode.abs() % 7 == 0;
  }
}
