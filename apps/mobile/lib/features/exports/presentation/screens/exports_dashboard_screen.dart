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
import '../../domain/export_job.dart';

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
    final authSession = ref.watch(authControllerProvider).session;
    final role = authSession?.user.role;

    if (role != UserRole.admin && role != UserRole.reviewer) {
      return const AppEmptyState(
        icon: Icons.lock_outline,
        title: 'Export Access Restricted',
        message: 'Only admin and reviewer roles can manage export requests.',
      );
    }

    final projectsAsync = ref.watch(projectsProvider);
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
        onAction: () => ref.invalidate(projectsProvider),
      ),
      data: (projects) {
        if (projects.isEmpty) {
          return const AppEmptyState(
            icon: Icons.folder_off_outlined,
            title: 'No projects available',
            message:
                'At least one assigned project is needed to request exports.',
          );
        }

        if (_selectedProjectId == null ||
            projects
                .where((project) => project.id == _selectedProjectId)
                .isEmpty) {
          _selectedProjectId = projects.first.id;
          _selectedProjectName = projects.first.name;
        }

        return ListView(
          children: [
            const SectionHeader(
              title: 'Exports & Reporting',
              subtitle:
                  'Async export queue, download management, and operational dashboard.',
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _MetricCard(
                  label: 'Total jobs',
                  value: '${metrics.total}',
                  icon: Icons.work_outline,
                ),
                _MetricCard(
                  label: 'Pending',
                  value: '${metrics.pending + metrics.processing}',
                  icon: Icons.hourglass_bottom,
                ),
                _MetricCard(
                  label: 'Completed',
                  value: '${metrics.completed}',
                  icon: Icons.check_circle_outline,
                ),
                _MetricCard(
                  label: 'Failed',
                  value: '${metrics.failed}',
                  icon: Icons.error_outline,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Request New Export',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedProjectId,
                    decoration: const InputDecoration(labelText: 'Project'),
                    items: projects
                        .map(
                          (project) => DropdownMenuItem(
                            value: project.id,
                            child: Text(project.name),
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
                  const SizedBox(height: 10),
                  DropdownButtonFormField<ExportFormat>(
                    initialValue: _selectedFormat,
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
                      if (value == null) {
                        return;
                      }
                      setState(() => _selectedFormat = value);
                    },
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _fromDateController,
                          decoration: const InputDecoration(
                            labelText: 'From date (YYYY-MM-DD)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextFormField(
                          controller: _toDateController,
                          decoration: const InputDecoration(
                            labelText: 'To date (YYYY-MM-DD)',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _bboxController,
                    decoration: const InputDecoration(
                      labelText: 'BBOX (minLon,minLat,maxLon,maxLat)',
                      hintText: '35.1,33.1,36.0,34.6',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: exportState.isSubmitting
                            ? null
                            : () async {
                                final projectId = _selectedProjectId;
                                if (projectId == null || projectId.isEmpty) {
                                  AppSnackbar.showError(
                                    context,
                                    'Select a project first.',
                                  );
                                  return;
                                }
                                await controller.requestExport(
                                  projectId: projectId,
                                  projectName: _selectedProjectName,
                                  format: _selectedFormat,
                                  exportParameters: <String, dynamic>{
                                    'date_from': _fromDateController.text
                                        .trim(),
                                    'date_to': _toDateController.text.trim(),
                                    'bbox': _bboxController.text.trim(),
                                  },
                                );
                                if (context.mounted) {
                                  AppSnackbar.showSuccess(
                                    context,
                                    'Export request added to queue.',
                                  );
                                }
                              },
                        icon: const Icon(Icons.playlist_add),
                        label: Text(
                          exportState.isSubmitting
                              ? 'Submitting...'
                              : 'Request Export',
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          await controller.runQueueTick();
                          if (context.mounted) {
                            AppSnackbar.showSuccess(
                              context,
                              'Export worker tick executed.',
                            );
                          }
                        },
                        icon: const Icon(Icons.sync),
                        label: const Text('Run Worker Tick'),
                      ),
                    ],
                  ),
                  if (exportState.lastTickAt != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Last worker tick: ${_formatDateTime(exportState.lastTickAt!)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text('Export Jobs', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (exportState.isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
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
                  padding: const EdgeInsets.only(bottom: 10),
                  child: AppCard(
                    child: Column(
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const CircleAvatar(
                            child: Icon(Icons.inventory_2_outlined),
                          ),
                          title: Text(job.projectName),
                          subtitle: Text(
                            '${job.format.name.toUpperCase()} • requested ${_formatDateTime(job.requestedAt)}',
                          ),
                          trailing: StatusChip(status: job.status.name),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (job.recordCount != null)
                                Chip(
                                  label: Text('Records: ${job.recordCount}'),
                                ),
                              if (job.fileSizeBytes != null)
                                Chip(
                                  label: Text(
                                    'Size: ${_formatBytes(job.fileSizeBytes!)}',
                                  ),
                                ),
                              if (job.downloadedAt != null)
                                Chip(
                                  avatar: const Icon(
                                    Icons.download_done,
                                    size: 16,
                                  ),
                                  label: Text(
                                    'Downloaded ${_formatDateTime(job.downloadedAt!)}',
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (job.errorMessage != null &&
                            job.errorMessage!.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                job.errorMessage!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          ),
                        Row(
                          children: [
                            TextButton.icon(
                              onPressed: () => controller.refresh(),
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('Refresh'),
                            ),
                            const Spacer(),
                            if (job.status == ExportJobStatus.failed)
                              FilledButton.tonalIcon(
                                onPressed: () async {
                                  await controller.retryFailedExport(job.id);
                                  if (context.mounted) {
                                    AppSnackbar.showSuccess(
                                      context,
                                      'Failed export re-queued.',
                                    );
                                  }
                                },
                                icon: const Icon(Icons.restart_alt, size: 18),
                                label: const Text('Retry'),
                              ),
                            if (job.canDownload)
                              FilledButton.icon(
                                onPressed: () async {
                                  await controller.downloadExport(job.id);
                                  if (context.mounted) {
                                    AppSnackbar.showSuccess(
                                      context,
                                      'Download started from ${job.filePath}.',
                                    );
                                  }
                                },
                                icon: const Icon(Icons.download, size: 18),
                                label: const Text('Download'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
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
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(2)} MB';
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 180),
      child: AppCard(
        child: Row(
          children: [
            CircleAvatar(radius: 18, child: Icon(icon, size: 18)),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodySmall),
                Text(value, style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
