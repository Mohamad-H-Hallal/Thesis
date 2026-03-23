import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/domain/auth_models.dart';
import '../../domain/export_job.dart';
import '../../domain/exports_repository.dart';

typedef ExportNotificationEmitter =
    void Function({required String title, required String message});

class ExportsState {
  const ExportsState({
    required this.jobs,
    required this.isLoading,
    required this.isSubmitting,
    required this.workerRunning,
    this.lastTickAt,
    this.error,
  });

  const ExportsState.initial()
    : this(
        jobs: const <ExportJob>[],
        isLoading: false,
        isSubmitting: false,
        workerRunning: false,
      );

  final List<ExportJob> jobs;
  final bool isLoading;
  final bool isSubmitting;
  final bool workerRunning;
  final DateTime? lastTickAt;
  final String? error;

  ExportDashboardMetrics get metrics => ExportDashboardMetrics.fromJobs(jobs);

  ExportsState copyWith({
    List<ExportJob>? jobs,
    bool? isLoading,
    bool? isSubmitting,
    bool? workerRunning,
    DateTime? lastTickAt,
    String? error,
  }) {
    return ExportsState(
      jobs: jobs ?? this.jobs,
      isLoading: isLoading ?? this.isLoading,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      workerRunning: workerRunning ?? this.workerRunning,
      lastTickAt: lastTickAt ?? this.lastTickAt,
      error: error,
    );
  }
}

class ExportsController extends StateNotifier<ExportsState> {
  ExportsController({
    required ExportsRepository repository,
    required AuthSession session,
    required ExportNotificationEmitter emitNotification,
  }) : _repository = repository,
       _session = session,
       _emitNotification = emitNotification,
       super(const ExportsState.initial());

  final ExportsRepository _repository;
  final AuthSession _session;
  final ExportNotificationEmitter _emitNotification;

  Timer? _queueTimer;

  Future<void> initialize() async {
    await refresh();
    _queueTimer ??= Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(runQueueTick(background: true));
    });
    state = state.copyWith(workerRunning: true);
  }

  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final jobs = await _repository.fetchJobs(
        requestedByUserId: _session.user.id,
      );
      state = state.copyWith(isLoading: false, jobs: jobs, error: null);
    } catch (error) {
      state = state.copyWith(isLoading: false, error: error.toString());
    }
  }

  Future<bool> requestExport({
    required String projectId,
    required String projectName,
    required ExportFormat format,
    required Map<String, dynamic> exportParameters,
  }) async {
    state = state.copyWith(isSubmitting: true, error: null);
    try {
      await _repository.requestExport(
        requestedByUserId: _session.user.id,
        projectId: projectId,
        projectName: projectName,
        format: format,
        exportParameters: exportParameters,
      );
      final jobs = await _repository.fetchJobs(
        requestedByUserId: _session.user.id,
      );
      state = state.copyWith(isSubmitting: false, jobs: jobs);
      _emitNotification(
        title: 'Export queued',
        message:
            'Export request for $projectName (${format.name}) has been queued.',
      );
      return true;
    } catch (error) {
      state = state.copyWith(isSubmitting: false, error: error.toString());
      return false;
    }
  }

  Future<void> runQueueTick({bool background = false}) async {
    final beforeStatuses = <String, ExportJobStatus>{
      for (final job in state.jobs) job.id: job.status,
    };

    try {
      final jobs = await _repository.processQueueTick(
        requestedByUserId: _session.user.id,
      );
      state = state.copyWith(
        jobs: jobs,
        lastTickAt: DateTime.now(),
        error: null,
      );

      _emitStatusNotifications(beforeStatuses, jobs);
    } catch (error) {
      if (!background) {
        state = state.copyWith(error: error.toString());
      }
    }
  }

  Future<void> downloadExport(String exportId) async {
    try {
      final updated = await _repository.markDownloaded(
        requestedByUserId: _session.user.id,
        exportId: exportId,
      );
      if (updated == null) {
        throw StateError('Export file is not ready for download.');
      }
      final jobs = await _repository.fetchJobs(
        requestedByUserId: _session.user.id,
      );
      state = state.copyWith(jobs: jobs, error: null);
      _emitNotification(
        title: 'Download prepared',
        message: 'Download started for ${updated.projectName}.',
      );
    } catch (error) {
      state = state.copyWith(error: error.toString());
    }
  }

  Future<void> retryFailedExport(String exportId) async {
    try {
      await _repository.retryFailed(
        requestedByUserId: _session.user.id,
        exportId: exportId,
      );
      final jobs = await _repository.fetchJobs(
        requestedByUserId: _session.user.id,
      );
      state = state.copyWith(jobs: jobs, error: null);
      _emitNotification(
        title: 'Export retried',
        message: 'Failed export has been re-queued.',
      );
    } catch (error) {
      state = state.copyWith(error: error.toString());
    }
  }

  void _emitStatusNotifications(
    Map<String, ExportJobStatus> beforeStatuses,
    List<ExportJob> afterJobs,
  ) {
    for (final job in afterJobs) {
      final before = beforeStatuses[job.id];
      if (before == null || before == job.status) {
        continue;
      }

      if (job.status == ExportJobStatus.completed) {
        _emitNotification(
          title: 'Export ready',
          message:
              '${job.projectName} (${job.format.name}) is ready for download.',
        );
      } else if (job.status == ExportJobStatus.failed) {
        _emitNotification(
          title: 'Export failed',
          message:
              '${job.projectName} (${job.format.name}) failed. Retry is available.',
        );
      }
    }
  }

  @override
  void dispose() {
    _queueTimer?.cancel();
    super.dispose();
  }
}
