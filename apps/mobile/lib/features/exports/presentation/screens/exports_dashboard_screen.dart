import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../../auth/domain/auth_models.dart';
import '../../../projects/domain/project.dart';
import '../../domain/export_job.dart';
import '../controllers/exports_controller.dart';

class ExportsDashboardScreen extends ConsumerStatefulWidget {
  const ExportsDashboardScreen({super.key});

  @override
  ConsumerState<ExportsDashboardScreen> createState() =>
      _ExportsDashboardScreenState();
}

class _ExportsDashboardScreenState
    extends ConsumerState<ExportsDashboardScreen> {
  String? _selectedProjectId;
  String _selectedProjectName = '';
  ExportFormat _selectedFormat = ExportFormat.geojson;
  final TextEditingController _fromDateController = TextEditingController();
  final TextEditingController _toDateController = TextEditingController();
  final TextEditingController _bboxController = TextEditingController();

  @override
  void dispose() {
    _fromDateController.dispose();
    _toDateController.dispose();
    _bboxController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authControllerProvider).session;
    if (session?.user.role != UserRole.admin) {
      return const AppEmptyState(
        icon: Icons.lock_outline,
        title: 'Export access restricted',
        message: 'Only admin users can manage export requests.',
      );
    }

    final projectsAsync = ref.watch(projectListProvider(ProjectViewScope.all));
    final exportState = ref.watch(exportsControllerProvider);
    final controller = ref.read(exportsControllerProvider.notifier);
    final metrics = exportState.metrics;

    return projectsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Project data unavailable',
        message: '$error',
        actionLabel: 'Retry',
        onAction: () =>
            ref.invalidate(projectListProvider(ProjectViewScope.all)),
      ),
      data: (projects) {
        if (projects.isEmpty) {
          return const AppEmptyState(
            icon: Icons.folder_off_outlined,
            title: 'No projects available',
            message:
                'Create a project first, then return here to request exports.',
          );
        }

        if (_selectedProjectId == null ||
            projects.every((project) => project.id != _selectedProjectId)) {
          _selectedProjectId = projects.first.id;
          _selectedProjectName = projects.first.name;
        }

        return ListView(
          children: [
            const SectionHeader(
              title: 'Exports',
              subtitle:
                  'Request GeoJSON or shapefile exports and track asynchronous processing.',
            ),
            const SizedBox(height: AppSpacing.md),
            if (exportState.error?.trim().isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: AppCard(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.error_outline,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(child: Text(exportState.error!)),
                    ],
                  ),
                ),
              ),
            LayoutBuilder(
              builder: (context, constraints) {
                final cardWidth = constraints.maxWidth < 640
                    ? constraints.maxWidth
                    : (constraints.maxWidth - AppSpacing.sm * 3) / 2;
                return Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    _MetricCard(
                      width: cardWidth,
                      label: 'Total jobs',
                      value: '${metrics.total}',
                      icon: Icons.work_outline,
                    ),
                    _MetricCard(
                      width: cardWidth,
                      label: 'Pending/processing',
                      value: '${metrics.pending + metrics.processing}',
                      icon: Icons.hourglass_bottom,
                    ),
                    _MetricCard(
                      width: cardWidth,
                      label: 'Completed',
                      value: '${metrics.completed}',
                      icon: Icons.check_circle_outline,
                    ),
                    _MetricCard(
                      width: cardWidth,
                      label: 'Failed',
                      value: '${metrics.failed}',
                      icon: Icons.error_outline,
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: AppSpacing.md),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final refreshButton = IconButton(
                        tooltip: 'Refresh export jobs',
                        onPressed: exportState.isLoading
                            ? null
                            : controller.refresh,
                        icon: const Icon(Icons.refresh),
                      );
                      if (constraints.maxWidth < 420) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Request export',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: refreshButton,
                            ),
                          ],
                        );
                      }
                      return Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Request export',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          refreshButton,
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedProjectId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Project'),
                    items: projects
                        .map(
                          (project) => DropdownMenuItem(
                            value: project.id,
                            child: Text(
                              project.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      final project = projects.firstWhere((p) => p.id == value);
                      setState(() {
                        _selectedProjectId = project.id;
                        _selectedProjectName = project.name;
                      });
                    },
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  DropdownButtonFormField<ExportFormat>(
                    initialValue: _selectedFormat,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Format'),
                    items: ExportFormat.values
                        .map(
                          (format) => DropdownMenuItem(
                            value: format,
                            child: Text(format.name.toUpperCase()),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _selectedFormat = value);
                      }
                    },
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextFormField(
                    controller: _fromDateController,
                    decoration: const InputDecoration(
                      labelText: 'From date (YYYY-MM-DD)',
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextFormField(
                    controller: _toDateController,
                    decoration: const InputDecoration(
                      labelText: 'To date (YYYY-MM-DD)',
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextFormField(
                    controller: _bboxController,
                    minLines: 1,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'BBOX (minLon,minLat,maxLon,maxLat)',
                      hintText: '35.1,33.1,36.0,34.6',
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: exportState.isSubmitting
                          ? null
                          : () => _submit(controller),
                      icon: const Icon(Icons.playlist_add),
                      label: Text(
                        exportState.isSubmitting
                            ? 'Submitting...'
                            : 'Request Export',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text('Export jobs', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            if (exportState.isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (exportState.jobs.isEmpty)
              const AppEmptyState(
                icon: Icons.archive_outlined,
                title: 'No export jobs yet',
                message: 'Submit an export request to start async processing.',
              )
            else
              ...exportState.jobs.map(
                (job) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: _ExportJobCard(
                    job: job,
                    onRefresh: controller.refresh,
                    onRetry: () async {
                      await controller.retryFailedExport(job.id);
                      if (context.mounted) {
                        AppSnackbar.showSuccess(
                          context,
                          'Failed export re-queued.',
                        );
                      }
                    },
                    onDownload: () async {
                      await controller.downloadExport(job.id);
                      if (context.mounted) {
                        AppSnackbar.showSuccess(
                          context,
                          'Download started from ${job.filePath}.',
                        );
                      }
                    },
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _submit(
    ExportsController controller,
  ) async {
    final projectId = _selectedProjectId;
    if (projectId == null || projectId.isEmpty) {
      AppSnackbar.showError(context, 'Select a project first.');
      return;
    }
    final fromDate = _fromDateController.text.trim();
    final toDate = _toDateController.text.trim();
    final bbox = _bboxController.text.trim();

    if (fromDate.isNotEmpty && !_isIsoDate(fromDate)) {
      AppSnackbar.showError(context, 'From date must use YYYY-MM-DD.');
      return;
    }
    if (toDate.isNotEmpty && !_isIsoDate(toDate)) {
      AppSnackbar.showError(context, 'To date must use YYYY-MM-DD.');
      return;
    }
    if (bbox.isNotEmpty && !_isBbox(bbox)) {
      AppSnackbar.showError(
        context,
        'BBOX must use minLon,minLat,maxLon,maxLat.',
      );
      return;
    }

    final success = await controller.requestExport(
      projectId: projectId,
      projectName: _selectedProjectName,
      format: _selectedFormat,
      exportParameters: <String, dynamic>{
        'date_from': fromDate,
        'date_to': toDate,
        'bbox': bbox,
      },
    );
    if (mounted && success) {
      AppSnackbar.showSuccess(context, 'Export request added to queue.');
    }
  }
}

class _ExportJobCard extends StatelessWidget {
  const _ExportJobCard({
    required this.job,
    required this.onRefresh,
    required this.onRetry,
    required this.onDownload,
  });

  final ExportJob job;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onRetry;
  final Future<void> Function() onDownload;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CircleAvatar(child: Icon(Icons.inventory_2_outlined)),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.projectName,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${job.format.name.toUpperCase()} • requested ${_formatDateTime(job.requestedAt)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              StatusChip(status: job.status.name),
              if (job.recordCount != null)
                Chip(label: Text('Records ${job.recordCount}')),
              if (job.fileSizeBytes != null)
                Chip(label: Text('Size ${_formatBytes(job.fileSizeBytes!)}')),
              if (job.downloadedAt != null)
                Chip(
                  avatar: const Icon(Icons.download_done, size: 16),
                  label: Text(
                    'Downloaded ${_formatDateTime(job.downloadedAt!)}',
                  ),
                ),
            ],
          ),
          if (job.errorMessage?.trim().isNotEmpty == true) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              job.errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Refresh'),
              ),
              if (job.status == ExportJobStatus.failed)
                FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('Retry'),
                ),
              if (job.canDownload)
                FilledButton.icon(
                  onPressed: onDownload,
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('Download'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.width,
    required this.label,
    required this.value,
    required this.icon,
  });

  final double width;
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: AppCard(
        child: Row(
          children: [
            CircleAvatar(radius: 18, child: Icon(icon, size: 18)),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.bodySmall),
                  Text(value, style: Theme.of(context).textTheme.titleLarge),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.year}-$month-$day $hour:$minute';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

bool _isIsoDate(String value) {
  return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value);
}

bool _isBbox(String value) {
  final parts = value.split(',');
  if (parts.length != 4) {
    return false;
  }
  return parts.every((part) => double.tryParse(part.trim()) != null);
}
