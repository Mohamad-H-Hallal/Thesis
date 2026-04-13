import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../export_file_actions.dart';
import '../export_request_validation.dart';
import '../controllers/exports_controller.dart';

class ExportsDashboardScreen extends ConsumerStatefulWidget {
  const ExportsDashboardScreen({
    this.fixedProjectId,
    this.fixedProjectName,
    super.key,
  });

  final String? fixedProjectId;
  final String? fixedProjectName;

  @override
  ConsumerState<ExportsDashboardScreen> createState() =>
      _ExportsDashboardScreenState();
}

class _ExportsDashboardScreenState
    extends ConsumerState<ExportsDashboardScreen> {
  String? _selectedProjectId;
  String _selectedProjectName = '';
  ExportFormat _selectedFormat = ExportFormat.geojson;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _fromDateController = TextEditingController();
  final TextEditingController _toDateController = TextEditingController();
  final TextEditingController _bboxController = TextEditingController();
  String? _fromDateError;
  String? _toDateError;
  String? _bboxError;

  @override
  void dispose() {
    _scrollController.dispose();
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
    final errorText = exportState.error?.trim();

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
        final fixedProjectId = widget.fixedProjectId?.trim();
        final hasFixedProject =
            fixedProjectId != null && fixedProjectId.isNotEmpty;
        if (projects.isEmpty) {
          return const AppEmptyState(
            icon: Icons.folder_off_outlined,
            title: 'No projects available',
            message:
                'Create a project first, then return here to request exports.',
          );
        }

        if (hasFixedProject) {
          final project = projects.cast<ProjectSummary?>().firstWhere(
            (item) => item?.id == fixedProjectId,
            orElse: () => null,
          );
          if (project != null) {
            _selectedProjectId = project.id;
            _selectedProjectName = widget.fixedProjectName ?? project.name;
          }
        }

        if (_selectedProjectId == null ||
            projects.every((project) => project.id != _selectedProjectId)) {
          _selectedProjectId = projects.first.id;
          _selectedProjectName = projects.first.name;
        }

        final visibleJobs = hasFixedProject
            ? exportState.jobs
                  .where((job) => job.projectId == _selectedProjectId)
                  .toList(growable: false)
            : exportState.jobs;

        return ListView(
          controller: _scrollController,
          children: [
            SectionHeader(
              title: hasFixedProject ? 'Project exports' : 'Exports',
              subtitle: hasFixedProject
                  ? 'Export approved features from ${_selectedProjectName.isEmpty ? 'this project' : _selectedProjectName}.'
                  : 'Export approved features as GeoJSON or shapefile and track processing.',
            ),
            const SizedBox(height: AppSpacing.md),
            if (errorText != null && errorText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(
                              'Export action needs attention',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(errorText),
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
                  if (hasFixedProject)
                    InputDecorator(
                      decoration: const InputDecoration(labelText: 'Project'),
                      child: Text(
                        _selectedProjectName,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    )
                  else
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
                        final project = projects.firstWhere(
                          (p) => p.id == value,
                        );
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
                  Text(
                    'Optional filters',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Leave these blank to export all approved features for the selected project.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextFormField(
                    controller: _fromDateController,
                    keyboardType: TextInputType.datetime,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.allow(RegExp(r'[\d-]')),
                      LengthLimitingTextInputFormatter(10),
                    ],
                    onChanged: (_) {
                      if (_fromDateError != null || _toDateError != null) {
                        setState(() {
                          _fromDateError = null;
                          if (_toDateError ==
                              'To date must be the same day or later than From date.') {
                            _toDateError = null;
                          }
                        });
                      }
                    },
                    decoration: InputDecoration(
                      labelText: 'From date',
                      hintText: exportDateHint,
                      helperText:
                          '$exportDateExample. Leave blank to include earlier approved features.',
                      errorText: _fromDateError,
                      suffixIcon: IconButton(
                        tooltip: 'Pick from date',
                        onPressed: () => _pickDate(_fromDateController),
                        icon: const Icon(Icons.calendar_today_outlined),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextFormField(
                    controller: _toDateController,
                    keyboardType: TextInputType.datetime,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.allow(RegExp(r'[\d-]')),
                      LengthLimitingTextInputFormatter(10),
                    ],
                    onChanged: (_) {
                      if (_toDateError != null) {
                        setState(() => _toDateError = null);
                      }
                    },
                    decoration: InputDecoration(
                      labelText: 'To date',
                      hintText: exportDateHint,
                      helperText:
                          '$exportDateExample. Leave blank to include the latest approved features.',
                      errorText: _toDateError,
                      suffixIcon: IconButton(
                        tooltip: 'Pick to date',
                        onPressed: () => _pickDate(_toDateController),
                        icon: const Icon(Icons.calendar_today_outlined),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextFormField(
                    controller: _bboxController,
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                      decimal: true,
                    ),
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.allow(RegExp(r'[\d,\-.\s]')),
                    ],
                    onChanged: (_) {
                      if (_bboxError != null) {
                        setState(() => _bboxError = null);
                      }
                    },
                    minLines: 1,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: 'BBOX',
                      hintText: exportBboxHint,
                      helperText:
                          '$exportBboxExample. Use this only when you need a smaller export area.',
                      errorText: _bboxError,
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
            else if (visibleJobs.isEmpty)
              AppEmptyState(
                icon: Icons.archive_outlined,
                title: hasFixedProject
                    ? 'No project exports yet'
                    : 'No export jobs yet',
                message: hasFixedProject
                    ? 'Submit an export request to start processing exports for this project.'
                    : 'Submit an export request to start async processing.',
              )
            else
              ...visibleJobs.map(
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
                      await _handleDownload(controller, job.id);
                    },
                    onOpen: job.localFilePath?.trim().isNotEmpty == true
                        ? () => _openDownloadedFile(job.localFilePath!)
                        : null,
                    onShare: job.localFilePath?.trim().isNotEmpty == true
                        ? () => _shareDownloadedFile(job)
                        : null,
                    onCopyPath: job.localFilePath?.trim().isNotEmpty == true
                        ? () => _copyDownloadPath(job.localFilePath!)
                        : null,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _submit(ExportsController controller) async {
    final projectId = _selectedProjectId;
    if (projectId == null || projectId.isEmpty) {
      AppSnackbar.showError(context, 'Select a project first.');
      return;
    }
    if (!_validateRequestFilters(showAlert: true)) {
      return;
    }

    final fromDate = _fromDateController.text.trim();
    final toDate = _toDateController.text.trim();
    final bbox = _bboxController.text.trim();

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
      return;
    }

    if (mounted) {
      final latestError = ref.read(exportsControllerProvider).error?.trim();
      AppSnackbar.showError(
        context,
        latestError?.isNotEmpty == true
            ? latestError!
            : 'Export request could not be created.',
      );
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _pickDate(TextEditingController controller) async {
    final initialDate =
        DateTime.tryParse(controller.text.trim()) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000, 1, 1),
      lastDate: DateTime(2100, 12, 31),
    );
    if (picked == null) {
      return;
    }

    final month = picked.month.toString().padLeft(2, '0');
    final day = picked.day.toString().padLeft(2, '0');
    controller.text = '${picked.year}-$month-$day';
    if (mounted) {
      setState(() {
        _fromDateError = null;
        _toDateError = null;
      });
    }
  }

  bool _validateRequestFilters({required bool showAlert}) {
    final fromDate = _fromDateController.text.trim();
    final toDate = _toDateController.text.trim();
    final bbox = _bboxController.text.trim();

    final fromDateError = validateExportDateInput('From date', fromDate);
    String? toDateError = validateExportDateInput('To date', toDate);
    final bboxError = validateExportBboxInput(bbox);
    final rangeError = validateExportDateRange(fromDate, toDate);
    if (toDateError == null && rangeError != null) {
      toDateError = rangeError;
    }

    setState(() {
      _fromDateError = fromDateError;
      _toDateError = toDateError;
      _bboxError = bboxError;
    });

    final firstError = fromDateError ?? toDateError ?? bboxError;
    if (firstError == null) {
      return true;
    }

    if (showAlert) {
      AppSnackbar.showError(context, firstError);
      _scrollToTop();
    }
    return false;
  }

  Future<void> _handleDownload(
    ExportsController controller,
    String exportId,
  ) async {
    final downloaded = await controller.downloadExport(exportId);
    final latestError = ref.read(exportsControllerProvider).error?.trim();
    if (!mounted) {
      return;
    }
    if (downloaded == null) {
      AppSnackbar.showError(
        context,
        latestError?.isNotEmpty == true
            ? latestError!
            : 'Export download failed.',
      );
      return;
    }
    final savedPath = downloaded.localFilePath;
    AppSnackbar.showSuccess(
      context,
      savedPath == null || savedPath.isEmpty
          ? 'Export downloaded.'
          : 'Export saved to $savedPath. Use Open, Share, or Copy path below.',
    );
  }

  Future<void> _openDownloadedFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      if (!mounted) {
        return;
      }
      AppSnackbar.showError(
        context,
        'The downloaded export is no longer available at that path.',
      );
      return;
    }

    try {
      await ExportFileActions.openFile(path);
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      AppSnackbar.showError(
        context,
        error.message?.trim().isNotEmpty == true
            ? error.message!
            : 'This device could not open the exported file.',
      );
      return;
    }
  }

  Future<void> _shareDownloadedFile(ExportJob job) async {
    final path = job.localFilePath;
    if (path == null || path.trim().isEmpty) {
      return;
    }
    final file = File(path);
    if (!await file.exists()) {
      if (!mounted) {
        return;
      }
      AppSnackbar.showError(
        context,
        'The downloaded export is no longer available at that path.',
      );
      return;
    }

    try {
      await ExportFileActions.shareFile(
        path: path,
        subject:
            '${job.projectName} ${job.format.name.toUpperCase()} export package',
        text: 'Export package for ${job.projectName}.',
      );
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      AppSnackbar.showError(
        context,
        error.message?.trim().isNotEmpty == true
            ? error.message!
            : 'This device could not open the share sheet for the exported file.',
      );
    }
  }

  Future<void> _copyDownloadPath(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) {
      return;
    }
    AppSnackbar.showInfo(context, 'Export path copied.');
  }

  void _scrollToTop() {
    if (!_scrollController.hasClients) {
      return;
    }
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }
}

class _ExportJobCard extends StatelessWidget {
  const _ExportJobCard({
    required this.job,
    required this.onRefresh,
    required this.onRetry,
    required this.onDownload,
    required this.onOpen,
    required this.onShare,
    required this.onCopyPath,
  });

  final ExportJob job;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onRetry;
  final Future<void> Function() onDownload;
  final Future<void> Function()? onOpen;
  final Future<void> Function()? onShare;
  final Future<void> Function()? onCopyPath;

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
          if (job.localFilePath?.trim().isNotEmpty == true) ...[
            const SizedBox(height: AppSpacing.sm),
            SelectableText(
              'Saved on device: ${job.localFilePath!}',
              style: Theme.of(context).textTheme.bodySmall,
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
              if (onOpen != null)
                OutlinedButton.icon(
                  onPressed: onOpen,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Open'),
                ),
              if (onShare != null)
                OutlinedButton.icon(
                  onPressed: onShare,
                  icon: const Icon(Icons.share_outlined, size: 18),
                  label: const Text('Share'),
                ),
              if (onCopyPath != null)
                OutlinedButton.icon(
                  onPressed: onCopyPath,
                  icon: const Icon(Icons.copy_all_outlined, size: 18),
                  label: const Text('Copy path'),
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
