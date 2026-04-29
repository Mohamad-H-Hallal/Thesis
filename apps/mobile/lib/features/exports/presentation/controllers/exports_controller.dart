import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/domain/auth_models.dart';
import '../../domain/export_job.dart';
import '../../domain/exports_repository.dart';

typedef ExportNotificationEmitter =
    void Function({required String title, required String message});

class ExportsState {
  const ExportsState({required this.isSubmitting, this.error});

  const ExportsState.initial() : this(isSubmitting: false);

  final bool isSubmitting;
  final String? error;

  ExportsState copyWith({bool? isSubmitting, String? error}) {
    return ExportsState(
      isSubmitting: isSubmitting ?? this.isSubmitting,
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
      if (!mounted) {
        return false;
      }
      state = state.copyWith(isSubmitting: false, error: null);
      _emitNotification(
        title: 'Export queued',
        message:
            'Export request for $projectName (${format.name}) has been queued.',
      );
      return true;
    } catch (error) {
      if (!mounted) {
        return false;
      }
      state = state.copyWith(isSubmitting: false, error: error.toString());
      return false;
    }
  }

  Future<ExportJob?> downloadExport(String exportId) async {
    try {
      final updated = await _repository.markDownloaded(
        requestedByUserId: _session.user.id,
        exportId: exportId,
      );
      if (!mounted) {
        return updated;
      }
      if (updated == null) {
        throw StateError('Export file is not ready for download.');
      }
      state = state.copyWith(error: null);
      _emitNotification(
        title: 'Download prepared',
        message: 'Download started for ${updated.projectName}.',
      );
      return updated;
    } catch (error) {
      if (!mounted) {
        return null;
      }
      state = state.copyWith(error: error.toString());
      return null;
    }
  }

  Future<void> retryFailedExport(String exportId) async {
    try {
      await _repository.retryFailed(
        requestedByUserId: _session.user.id,
        exportId: exportId,
      );
      if (!mounted) {
        return;
      }
      state = state.copyWith(error: null);
      _emitNotification(
        title: 'Export retried',
        message: 'Failed export has been re-queued.',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      state = state.copyWith(error: error.toString());
    }
  }
}
