import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/config/app_env.dart';
import '../../../../core/pagination/paginated_list_controller.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/utils/lebanon_time.dart';
import '../../../../core/widgets/app_action_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_dialog_actions.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/progressive_list_section.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../../auth/domain/auth_models.dart';
import '../../../auth/presentation/controllers/auth_controller.dart';
import '../../../map/domain/app_tile_provider.dart';
import '../../../map/domain/lebanon_map.dart';
import '../../../map/domain/map_geometry.dart';
import '../../../map/presentation/widgets/basemap_attribution.dart';
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
  String? _selectedCategoryId;
  String? _selectedProjectId;
  String _selectedProjectName = '';
  ExportFormat _selectedFormat = ExportFormat.geojson;
  _ExportJobFormatFilter _jobFormatFilter = _ExportJobFormatFilter.all;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _fromDateController = TextEditingController();
  final TextEditingController _toDateController = TextEditingController();
  final TextEditingController _bboxController = TextEditingController();
  Map<String, dynamic>? _selectedExportPolygon;
  String? _selectedFeatureType;
  String? _selectedCollectorUserId;
  bool _exportAiPredictions = false;
  Timer? _jobsRefreshTimer;
  String? _fromDateError;
  String? _toDateError;
  String? _bboxError;

  @override
  void initState() {
    super.initState();
    if (!AppEnv.realtimePollingFallbackEnabled) {
      return;
    }
    _jobsRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) {
        return;
      }
      final query = _currentJobsQuery();
      final jobsState = ref
          .read(paginatedExportJobsProvider(query))
          .valueOrNull;
      if (jobsState == null) {
        return;
      }
      final hasActiveWork = jobsState.items.any(
        (job) =>
            job.status == ExportJobStatus.pending ||
            job.status == ExportJobStatus.processing,
      );
      if (!hasActiveWork) {
        return;
      }
      unawaited(_refreshJobs(query, silently: true));
    });
  }

  @override
  void dispose() {
    _jobsRefreshTimer?.cancel();
    _scrollController.dispose();
    _fromDateController.dispose();
    _toDateController.dispose();
    _bboxController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);
    if (authState.status == AuthStatus.checking ||
        authState.status == AuthStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final session = authState.session;
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
        final categories = _deriveCategories(projects);
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
            if (_selectedProjectId != project.id) {
              _selectedCollectorUserId = null;
            }
            _selectedCategoryId = project.categoryId;
            _selectedProjectId = project.id;
            _selectedProjectName = widget.fixedProjectName ?? project.name;
          }
        }

        if (!hasFixedProject) {
          _syncProjectSelection(categories, projects);
        }
        final availableProjects = _projectsForCategory(
          projects,
          _selectedCategoryId,
        );
        final selectedProject = projects.cast<ProjectSummary?>().firstWhere(
          (project) => project?.id == _selectedProjectId,
          orElse: () => null,
        );
        final collectorsAsync = selectedProject == null
            ? null
            : ref.watch(exportCollectorsProvider(selectedProject.id));
        final exportCollectors =
            collectorsAsync?.valueOrNull ?? const <ExportCollector>[];
        final selectedCollectorUserId =
            exportCollectors.any(
              (collector) => collector.userId == _selectedCollectorUserId,
            )
            ? _selectedCollectorUserId
            : null;
        final featureTypeOptions = _featureTypeOptions(selectedProject);
        final canExportAiPredictions =
            session?.user.isProtectedSuperAdmin == true &&
            selectedProject != null &&
            selectedProject.publishedAiLayerCount > 0;
        final useAiPredictionExport =
            canExportAiPredictions && _exportAiPredictions;
        final jobsQuery = _currentJobsQuery();
        final jobsAsync = ref.watch(paginatedExportJobsProvider(jobsQuery));
        final jobsController = ref.read(
          paginatedExportJobsProvider(jobsQuery).notifier,
        );
        final jobsState =
            jobsAsync.valueOrNull ??
            const PaginatedListState<ExportJob>.initial();
        final jobsError = jobsAsync.hasError
            ? jobsAsync.error.toString()
            : null;
        final scopedMetrics =
            ref.watch(exportJobsSummaryProvider(jobsQuery)).valueOrNull ??
            const ExportDashboardMetrics(
              total: 0,
              pending: 0,
              processing: 0,
              completed: 0,
              failed: 0,
              expired: 0,
            );

        return ListView(
          controller: _scrollController,
          children: [
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
                      value: '${scopedMetrics.total}',
                      icon: Icons.work_outline,
                    ),
                    _MetricCard(
                      width: cardWidth,
                      label: 'Pending/processing',
                      value:
                          '${scopedMetrics.pending + scopedMetrics.processing}',
                      icon: Icons.hourglass_bottom,
                    ),
                    _MetricCard(
                      width: cardWidth,
                      label: 'Completed',
                      value: '${scopedMetrics.completed}',
                      icon: Icons.check_circle_outline,
                    ),
                    _MetricCard(
                      width: cardWidth,
                      label: 'Failed',
                      value: '${scopedMetrics.failed}',
                      icon: Icons.error_outline,
                    ),
                    _MetricCard(
                      width: cardWidth,
                      label: 'Expired',
                      value: '${scopedMetrics.expired}',
                      icon: Icons.schedule_outlined,
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
                      final resetButton = IconButton(
                        tooltip: 'Reset filters',
                        onPressed: _resetExportFilters,
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
                              child: resetButton,
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
                          resetButton,
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (hasFixedProject)
                    Column(
                      children: [
                        InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Category',
                          ),
                          child: Text(
                            selectedProject?.category ?? 'Category',
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Project',
                          ),
                          child: Text(
                            _selectedProjectName,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ),
                      ],
                    )
                  else
                    Column(
                      children: [
                        DropdownButtonFormField<String?>(
                          initialValue: _selectedCategoryId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Category',
                          ),
                          items: <DropdownMenuItem<String?>>[
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('All categories'),
                            ),
                            ...categories.map(
                              (category) => DropdownMenuItem<String?>(
                                value: category.id,
                                child: Text(
                                  category.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                          onChanged: (value) {
                            setState(() {
                              _selectedCategoryId = value;
                              _selectedProjectId = null;
                              _selectedProjectName = '';
                              _selectedFeatureType = null;
                              _selectedCollectorUserId = null;
                              _exportAiPredictions = false;
                              _selectedExportPolygon = null;
                            });
                          },
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        DropdownButtonFormField<String?>(
                          initialValue: _selectedProjectId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Project',
                          ),
                          items: <DropdownMenuItem<String?>>[
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('All projects'),
                            ),
                            ...availableProjects.map(
                              (project) => DropdownMenuItem<String?>(
                                value: project.id,
                                child: Text(
                                  project.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                          onChanged: (value) {
                            if (value == null) {
                              setState(() {
                                _selectedProjectId = null;
                                _selectedProjectName = '';
                                _selectedFeatureType = null;
                                _selectedCollectorUserId = null;
                                _exportAiPredictions = false;
                                _selectedExportPolygon = null;
                              });
                              return;
                            }
                            final project = availableProjects.firstWhere(
                              (p) => p.id == value,
                            );
                            setState(() {
                              _selectedProjectId = project.id;
                              _selectedProjectName = project.name;
                              _selectedFeatureType = null;
                              _selectedCollectorUserId = null;
                              _exportAiPredictions = false;
                              _selectedExportPolygon = null;
                            });
                          },
                        ),
                      ],
                    ),
                  const SizedBox(height: AppSpacing.sm),
                  DropdownButtonFormField<String?>(
                    key: ValueKey(
                      'export-collector-${selectedProject?.id ?? 'none'}-${exportCollectors.length}',
                    ),
                    initialValue: selectedCollectorUserId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'Collector',
                      suffixIcon: collectorsAsync?.isLoading == true
                          ? const Padding(
                              padding: EdgeInsets.all(14),
                              child: SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : collectorsAsync?.hasError == true
                          ? IconButton(
                              tooltip: 'Retry collectors',
                              onPressed: selectedProject == null
                                  ? null
                                  : () => ref.invalidate(
                                      exportCollectorsProvider(
                                        selectedProject.id,
                                      ),
                                    ),
                              icon: const Icon(Icons.refresh),
                            )
                          : null,
                    ),
                    items: <DropdownMenuItem<String?>>[
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('All collectors'),
                      ),
                      ...exportCollectors.map(
                        (collector) => DropdownMenuItem<String?>(
                          value: collector.userId,
                          child: Text(
                            '${collector.displayName} (${collector.contributionCount})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                    onChanged:
                        selectedProject == null ||
                            useAiPredictionExport ||
                            collectorsAsync?.isLoading == true
                        ? null
                        : (value) {
                            setState(() => _selectedCollectorUserId = value);
                          },
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  DropdownButtonFormField<String?>(
                    initialValue: _selectedFeatureType,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Feature type',
                    ),
                    items: <DropdownMenuItem<String?>>[
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('All features'),
                      ),
                      ...featureTypeOptions.map(
                        (value) => DropdownMenuItem<String?>(
                          value: value,
                          child: Text(value, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ],
                    onChanged: useAiPredictionExport
                        ? null
                        : (value) {
                            setState(() => _selectedFeatureType = value);
                          },
                  ),
                  if (canExportAiPredictions) ...[
                    const SizedBox(height: AppSpacing.sm),
                    CheckboxListTile(
                      value: _exportAiPredictions,
                      onChanged: (value) {
                        setState(() {
                          _exportAiPredictions = value ?? false;
                          if (_exportAiPredictions) {
                            _selectedFeatureType = null;
                            _selectedCollectorUserId = null;
                          }
                        });
                      },
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('Include AI results'),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  Text('Format', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: AppSpacing.sm),
                  _ExportFormatPicker(
                    selectedFormat: _selectedFormat,
                    onChanged: (value) {
                      setState(() => _selectedFormat = value);
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'Optional filters',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final useSplitLayout = constraints.maxWidth >= 540;
                      final fromDateField = TextFormField(
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
                          errorText: _fromDateError,
                          suffixIcon: IconButton(
                            tooltip: 'Pick from date',
                            onPressed: () => _pickDate(_fromDateController),
                            icon: const Icon(Icons.calendar_today_outlined),
                          ),
                        ),
                      );
                      final toDateField = TextFormField(
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
                          errorText: _toDateError,
                          suffixIcon: IconButton(
                            tooltip: 'Pick to date',
                            onPressed: () => _pickDate(_toDateController),
                            icon: const Icon(Icons.calendar_today_outlined),
                          ),
                        ),
                      );

                      if (!useSplitLayout) {
                        return Column(
                          children: [
                            fromDateField,
                            const SizedBox(height: AppSpacing.sm),
                            toDateField,
                          ],
                        );
                      }

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: fromDateField),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(child: toDateField),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextFormField(
                    controller: _bboxController,
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                      decimal: true,
                    ),
                    inputFormatters: <TextInputFormatter>[
                      _BboxTextInputFormatter(),
                    ],
                    onChanged: (_) {
                      if (_bboxError != null) {
                        setState(() => _bboxError = null);
                      }
                    },
                    decoration: InputDecoration(
                      labelText: 'BBOX',
                      hintText: exportBboxHint,
                      errorText: _bboxError,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppActionButtons(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _selectedProjectId == null
                            ? null
                            : _selectExportArea,
                        icon: const Icon(Icons.polyline_outlined),
                        label: Text(
                          _selectedExportPolygon == null
                              ? 'Draw area on map'
                              : 'Change area',
                        ),
                      ),
                      if (_selectedExportPolygon != null)
                        OutlinedButton.icon(
                          onPressed: () {
                            setState(() => _selectedExportPolygon = null);
                          },
                          icon: const Icon(Icons.clear),
                          label: const Text('Clear area'),
                        ),
                    ],
                  ),
                  if (_selectedExportPolygon != null) ...[
                    const SizedBox(height: AppSpacing.xs),
                    const Chip(
                      avatar: Icon(Icons.polyline_outlined, size: 16),
                      label: Text('Polygon area selected'),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed:
                          exportState.isSubmitting || _selectedProjectId == null
                          ? null
                          : () => _submit(
                              controller,
                              selectedProject: selectedProject,
                              useAiPredictionExport: useAiPredictionExport,
                            ),
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
            Text(
              'Export jobs (${jobsState.total})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            _ExportListFilter(
              selected: _jobFormatFilter,
              onChanged: (value) {
                setState(() => _jobFormatFilter = value);
              },
            ),
            const SizedBox(height: AppSpacing.sm),
            if (jobsAsync.isLoading && jobsState.items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (jobsError != null && jobsState.items.isEmpty)
              AppEmptyState(
                icon: Icons.error_outline,
                title: 'Export jobs unavailable',
                message: jobsError,
                actionLabel: 'Retry',
                onAction: () => _refreshJobs(jobsQuery),
              )
            else if (jobsState.items.isEmpty)
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
              ProgressiveListSection<ExportJob>(
                items: jobsState.items,
                resetKey: Object.hash(jobsQuery, jobsState.total),
                hasMore: jobsState.hasMore,
                isLoadingMore: jobsState.isLoadingMore,
                onLoadMore: jobsController.loadMore,
                gridMinItemWidth: 380,
                itemBuilder: (context, job, _) => _ExportJobCard(
                  job: job,
                  onRefresh: () => _refreshJobs(jobsQuery),
                  onRetry: () async {
                    await controller.retryFailedExport(job.id);
                    bumpRealtimeScope(
                      ref,
                      RealtimeScope('exports', session!.user.id),
                    );
                    if (context.mounted) {
                      AppSnackbar.showSuccess(
                        context,
                        'Failed export re-queued.',
                      );
                    }
                  },
                  onDownload: () async {
                    await _handleDownload(controller, job.id);
                    bumpRealtimeScope(
                      ref,
                      RealtimeScope('exports', session!.user.id),
                    );
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
          ],
        );
      },
    );
  }

  ExportJobsQuery _currentJobsQuery() {
    return ExportJobsQuery(
      categoryId: widget.fixedProjectId == null ? _selectedCategoryId : null,
      projectId: widget.fixedProjectId ?? _selectedProjectId,
      format: switch (_jobFormatFilter) {
        _ExportJobFormatFilter.all => null,
        _ExportJobFormatFilter.geojson => ExportFormat.geojson,
        _ExportJobFormatFilter.shapefile => ExportFormat.shapefile,
      },
    );
  }

  Future<void> _refreshJobs(
    ExportJobsQuery query, {
    bool silently = false,
  }) async {
    final controller = ref.read(paginatedExportJobsProvider(query).notifier);
    if (silently) {
      await controller.refreshSilently();
    } else {
      await controller.refresh();
    }
    ref.invalidate(exportJobsSummaryProvider(query));
  }

  void _resetExportFilters() {
    setState(() {
      _selectedFeatureType = null;
      _selectedCollectorUserId = null;
      _exportAiPredictions = false;
      _selectedFormat = ExportFormat.geojson;
      _fromDateController.clear();
      _toDateController.clear();
      _bboxController.clear();
      _selectedExportPolygon = null;
      _fromDateError = null;
      _toDateError = null;
      _bboxError = null;
    });
  }

  Future<void> _submit(
    ExportsController controller, {
    required ProjectSummary? selectedProject,
    required bool useAiPredictionExport,
  }) async {
    final projectId = _selectedProjectId;
    if (projectId == null || projectId.isEmpty) {
      AppSnackbar.showError(context, 'Select a project first.');
      return;
    }
    if (!useAiPredictionExport &&
        (selectedProject?.approvedFeatures ?? 0) <= 0) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Export unavailable'),
          content: Text(
            'Exports can be requested after this project has at least one approved feature.',
          ),
          actions: [
            AppDialogActions.single(
              confirm: FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('OK'),
              ),
            ),
          ],
        ),
      );
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
        'include_photos': !useAiPredictionExport,
        'export_ai_predictions': useAiPredictionExport,
        if (_selectedCategoryId?.trim().isNotEmpty ?? false)
          'category_id': _selectedCategoryId!.trim(),
        if (!useAiPredictionExport &&
            (_selectedFeatureType?.trim().isNotEmpty ?? false))
          'feature_type': _selectedFeatureType!.trim(),
        if (!useAiPredictionExport &&
            (_selectedCollectorUserId?.trim().isNotEmpty ?? false))
          'collector_user_id': _selectedCollectorUserId!.trim(),
        if (_selectedExportPolygon != null)
          'export_polygon': jsonEncode(_selectedExportPolygon),
      },
    );
    if (mounted && success) {
      setState(() => _selectedExportPolygon = null);
      final userId = ref.read(authControllerProvider).session?.user.id;
      if (userId != null) {
        bumpRealtimeScope(ref, RealtimeScope('exports', userId));
      }
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
      kIsWeb
          ? 'Export downloaded by the browser.'
          : savedPath == null || savedPath.isEmpty
          ? 'Export downloaded.'
          : 'Export downloaded. Use Open, Share, or Copy path.',
    );
  }

  Future<void> _openDownloadedFile(String path) async {
    if (kIsWeb) {
      AppSnackbar.showError(
        context,
        'Use the browser downloads list to open this file.',
      );
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
    if (kIsWeb) {
      AppSnackbar.showError(
        context,
        'Use the browser downloads list to share this file.',
      );
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

  Future<void> _selectExportArea() async {
    final polygon = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute<Map<String, dynamic>>(
        builder: (context) =>
            _ExportAreaPickerDialog(initialPolygon: _selectedExportPolygon),
      ),
    );
    if (!mounted || polygon == null) {
      return;
    }
    setState(() => _selectedExportPolygon = polygon);
  }

  List<String> _featureTypeOptions(ProjectSummary? project) {
    if (project == null) {
      return const <String>[];
    }
    final values = <String>{};
    for (final field in project.collectionFormSchema.fields) {
      final normalizedKey = field.key.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      if (normalizedKey == 'featuretype' ||
          normalizedKey == 'type' ||
          normalizedKey == 'class') {
        values.addAll(field.options.where((value) => value.trim().isNotEmpty));
      }
    }
    final sorted = values.toList(growable: false);
    sorted.sort();
    return sorted;
  }

  List<_CategoryOption> _deriveCategories(List<ProjectSummary> projects) {
    final byId = <String, _CategoryOption>{};
    for (final project in projects) {
      final categoryId = project.categoryId;
      if (categoryId == null || categoryId.trim().isEmpty) {
        continue;
      }
      byId.putIfAbsent(
        categoryId,
        () => _CategoryOption(id: categoryId, name: project.category),
      );
    }
    final categories = byId.values.toList(growable: false);
    categories.sort((a, b) => a.name.compareTo(b.name));
    return categories;
  }

  List<ProjectSummary> _projectsForCategory(
    List<ProjectSummary> projects,
    String? categoryId,
  ) {
    final filtered = categoryId == null || categoryId.trim().isEmpty
        ? List<ProjectSummary>.from(projects)
        : projects
              .where((project) => project.categoryId == categoryId)
              .toList(growable: false);
    filtered.sort((a, b) => a.name.compareTo(b.name));
    return filtered;
  }

  void _syncProjectSelection(
    List<_CategoryOption> categories,
    List<ProjectSummary> projects,
  ) {
    final validCategoryIds = categories.map((item) => item.id).toSet();
    if (_selectedCategoryId != null &&
        !validCategoryIds.contains(_selectedCategoryId)) {
      _selectedCategoryId = null;
    }

    final categoryProjects = _projectsForCategory(
      projects,
      _selectedCategoryId,
    );
    final validProjectIds = categoryProjects.map((item) => item.id).toSet();
    if (_selectedProjectId != null &&
        !validProjectIds.contains(_selectedProjectId)) {
      _selectedProjectId = null;
      _selectedProjectName = '';
      _selectedCollectorUserId = null;
    } else {
      if (_selectedProjectId == null) {
        _selectedProjectName = '';
      } else {
        final matchedProject = categoryProjects.firstWhere(
          (project) => project.id == _selectedProjectId,
        );
        _selectedProjectName = matchedProject.name;
      }
    }
  }
}

class _CategoryOption {
  const _CategoryOption({required this.id, required this.name});

  final String id;
  final String name;
}

@visibleForTesting
Widget buildExportAreaPickerForTest({Map<String, dynamic>? initialPolygon}) {
  return _ExportAreaPickerDialog(
    initialPolygon: initialPolygon,
    validateWorkspace: false,
  );
}

Future<Map<String, dynamic>?> openExportAreaPicker(
  BuildContext context, {
  Map<String, dynamic>? initialPolygon,
  String title = 'Draw export area',
  String submitLabel = 'Use area',
}) {
  return Navigator.of(context).push<Map<String, dynamic>>(
    MaterialPageRoute<Map<String, dynamic>>(
      builder: (context) => _ExportAreaPickerDialog(
        initialPolygon: initialPolygon,
        title: title,
        submitLabel: submitLabel,
      ),
    ),
  );
}

class _ExportAreaPickerDialog extends StatefulWidget {
  const _ExportAreaPickerDialog({
    this.initialPolygon,
    this.validateWorkspace = true,
    this.title = 'Draw export area',
    this.submitLabel = 'Use area',
  });

  final Map<String, dynamic>? initialPolygon;
  final bool validateWorkspace;
  final String title;
  final String submitLabel;

  @override
  State<_ExportAreaPickerDialog> createState() =>
      _ExportAreaPickerDialogState();
}

class _ExportAreaPickerDialogState extends State<_ExportAreaPickerDialog> {
  late final MapController _mapController;
  late final MapOptions _mapOptions;
  late final TileProvider _tileProvider;
  final Key _mapKey = ValueKey<String>(
    'export-area-map-${DateTime.now().microsecondsSinceEpoch}',
  );
  final GlobalKey _bottomPanelKey = GlobalKey();
  final List<LatLng> _points = <LatLng>[];
  MapCamera? _latestCamera;
  double _bottomPanelHeight = 0;
  bool _isMapReady = false;
  bool _isClosing = false;
  LebanonBasemapStyle _basemapStyle = LebanonBasemapStyle.street;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _tileProvider = appNetworkTileProvider();
    _mapOptions = MapOptions(
      initialCenter: LebanonMapConfig.center,
      initialZoom: LebanonMapConfig.drawingInitialZoom,
      minZoom: LebanonMapConfig.drawingMinZoom,
      maxZoom: LebanonMapConfig.drawingMaxZoom,
      cameraConstraint: CameraConstraint.containCenter(
        bounds: LebanonMapConfig.bounds,
      ),
      interactionOptions: const InteractionOptions(
        flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
      ),
      onMapReady: () {
        if (!mounted) {
          return;
        }
        setState(() => _isMapReady = true);
      },
      onPositionChanged: (camera, _) {
        _latestCamera = camera;
      },
    );
    final coordinates = widget.initialPolygon?['coordinates'] is List
        ? widget.initialPolygon!['coordinates'] as List
        : null;
    final ring = coordinates?.isNotEmpty == true && coordinates!.first is List
        ? coordinates.first as List
        : const <dynamic>[];
    for (final raw in ring) {
      if (raw is List && raw.length >= 2) {
        final lon = (raw[0] as num?)?.toDouble();
        final lat = (raw[1] as num?)?.toDouble();
        if (lat != null && lon != null) {
          _points.add(LatLng(lat, lon));
        }
      }
    }
    if (_points.length > 1 && _points.first == _points.last) {
      _points.removeLast();
    }
  }

  void _addPoint(LatLng point) {
    if (widget.validateWorkspace && !LebanonMapConfig.contains(point)) {
      AppSnackbar.showError(
        context,
        'Choose points inside the Lebanon workspace.',
      );
      return;
    }
    setState(() => _points.add(point));
  }

  void _addPointFromTap(TapUpDetails details) {
    final camera = _latestCamera ?? _mapController.camera;
    final point = camera.screenOffsetToLatLng(details.localPosition);
    _addPoint(point);
  }

  void _undoPoint() {
    if (_points.isEmpty) {
      return;
    }
    setState(() => _points.removeLast());
  }

  void _clearPoints() {
    if (_points.isEmpty) {
      return;
    }
    setState(_points.clear);
  }

  void _fitWorkspace() {
    if (!_isMapReady) {
      return;
    }
    _mapController.fitCamera(LebanonMapConfig.drawingFit);
  }

  void _zoomBy(double delta) {
    if (!_isMapReady) {
      return;
    }
    final center = _latestCamera?.center ?? LebanonMapConfig.center;
    final zoom =
        ((_latestCamera?.zoom ?? LebanonMapConfig.drawingInitialZoom) + delta)
            .clamp(
              LebanonMapConfig.drawingMinZoom,
              LebanonMapConfig.drawingMaxZoom,
            )
            .toDouble();
    _mapController.move(center, zoom);
  }

  void _toggleBasemap() {
    setState(() {
      _basemapStyle = _basemapStyle == LebanonBasemapStyle.street
          ? LebanonBasemapStyle.satellite
          : LebanonBasemapStyle.street;
    });
  }

  void _measureBottomPanel() {
    final context = _bottomPanelKey.currentContext;
    final box = context?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      return;
    }
    final height = box.size.height;
    if ((height - _bottomPanelHeight).abs() < 0.5) {
      return;
    }
    if (mounted) {
      setState(() => _bottomPanelHeight = height);
    }
  }

  void _closePicker([Map<String, dynamic>? result]) {
    if (_isClosing || !mounted) {
      return;
    }
    _isClosing = true;
    FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final polygonPoints = _points.length >= 3
        ? <LatLng>[..._points, _points.first]
        : _points;
    return PopScope<Map<String, dynamic>?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _closePicker(result);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            icon: const BackButtonIcon(),
            onPressed: _closePicker,
          ),
          title: Text(widget.title),
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _measureBottomPanel();
              }
            });
            const overlayMargin = AppSpacing.sm;
            const verticalRailHeight = 245.0;
            final canShowTools = _bottomPanelHeight > 0;
            final availableAbovePanel =
                constraints.maxHeight - _bottomPanelHeight - overlayMargin * 2;
            final useHorizontalTools =
                availableAbovePanel < verticalRailHeight + overlayMargin;
            final toolsBottom = _bottomPanelHeight + overlayMargin;
            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    key: const ValueKey<String>('export_area_map_clip'),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(18),
                    ),
                    child: FlutterMap(
                      key: _mapKey,
                      mapController: _mapController,
                      options: _mapOptions,
                      children: [
                        if (LebanonMapConfig.shouldRenderTileLayers)
                          TileLayer(
                            key: ValueKey<String>(
                              'export_area_basemap_${_basemapStyle.name}',
                            ),
                            urlTemplate: LebanonMapConfig.basemapUrlTemplate(
                              _basemapStyle,
                            ),
                            tileProvider: _tileProvider,
                            userAgentPackageName: 'lb.gov.gis_collector',
                          ),
                        if (LebanonMapConfig.shouldRenderTileLayers &&
                            LebanonMapConfig.referenceLabelUrlTemplate(
                                  _basemapStyle,
                                ) !=
                                null)
                          TileLayer(
                            key: ValueKey<String>(
                              'export_area_labels_${_basemapStyle.name}',
                            ),
                            urlTemplate:
                                LebanonMapConfig.referenceLabelUrlTemplate(
                                  _basemapStyle,
                                )!,
                            tileProvider: _tileProvider,
                            userAgentPackageName: 'lb.gov.gis_collector',
                          ),
                        if (polygonPoints.length >= 2)
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: polygonPoints,
                                color: Theme.of(context).colorScheme.primary,
                                strokeWidth: 3,
                              ),
                            ],
                          ),
                        if (isValidPolygonRing(polygonPoints))
                          PolygonLayer(
                            polygons: [
                              Polygon(
                                points: polygonPoints,
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.20),
                                borderColor: Theme.of(
                                  context,
                                ).colorScheme.primary,
                                borderStrokeWidth: 2,
                              ),
                            ],
                          ),
                        MarkerLayer(
                          markers: [
                            for (
                              var index = 0;
                              index < _points.length;
                              index += 1
                            )
                              Marker(
                                point: _points[index],
                                width: 34,
                                height: 34,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 2,
                                    ),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Color(0x33000000),
                                        blurRadius: 8,
                                        offset: Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: Center(
                                    child: Text(
                                      '${index + 1}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(color: Colors.white),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        BasemapAttribution(
                          style: _basemapStyle,
                          bottomInset: toolsBottom,
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapUp: _addPointFromTap,
                  ),
                ),
                if (canShowTools)
                  if (useHorizontalTools)
                    Positioned(
                      left: AppSpacing.sm,
                      right: AppSpacing.sm,
                      bottom: toolsBottom,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _ExportAreaHorizontalToolbar(
                          onFitWorkspace: _fitWorkspace,
                          onZoomIn: () => _zoomBy(1),
                          onZoomOut: () => _zoomBy(-1),
                          basemapStyle: _basemapStyle,
                          onToggleBasemap: _toggleBasemap,
                          onUndo: _points.isEmpty ? null : _undoPoint,
                          onClear: _points.isEmpty ? null : _clearPoints,
                        ),
                      ),
                    )
                  else
                    Positioned(
                      right: AppSpacing.sm,
                      bottom: toolsBottom,
                      child: _ExportAreaControlRail(
                        onFitWorkspace: _fitWorkspace,
                        onZoomIn: () => _zoomBy(1),
                        onZoomOut: () => _zoomBy(-1),
                        basemapStyle: _basemapStyle,
                        onToggleBasemap: _toggleBasemap,
                        onUndo: _points.isEmpty ? null : _undoPoint,
                        onClear: _points.isEmpty ? null : _clearPoints,
                      ),
                    ),
                Positioned(
                  left: AppSpacing.sm,
                  right: AppSpacing.sm,
                  bottom: 0,
                  child: KeyedSubtree(
                    key: _bottomPanelKey,
                    child: SafeArea(
                      top: false,
                      minimum: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: _ExportAreaActionPanel(
                        submitLabel: widget.submitLabel,
                        onUseArea: _points.length < 3
                            ? null
                            : () => _closePicker(_polygonGeoJson()),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Map<String, dynamic> _polygonGeoJson() {
    final ring = <LatLng>[..._points, _points.first]
        .map((point) => <double>[point.longitude, point.latitude])
        .toList(growable: false);
    return <String, dynamic>{
      'type': 'Polygon',
      'coordinates': <dynamic>[ring],
    };
  }
}

class _ExportAreaControlRail extends StatelessWidget {
  const _ExportAreaControlRail({
    required this.onFitWorkspace,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.basemapStyle,
    required this.onToggleBasemap,
    required this.onUndo,
    required this.onClear,
  });

  final VoidCallback onFitWorkspace;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final LebanonBasemapStyle basemapStyle;
  final VoidCallback onToggleBasemap;
  final VoidCallback? onUndo;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      color: scheme.surface.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _MapControlButton(
            tooltip: 'Fit workspace',
            icon: Icons.center_focus_strong_outlined,
            onPressed: onFitWorkspace,
            isTop: true,
          ),
          const _MapRailDivider(),
          _MapControlButton(
            tooltip: 'Zoom in',
            icon: Icons.add,
            onPressed: onZoomIn,
          ),
          const _MapRailDivider(),
          _MapControlButton(
            tooltip: 'Zoom out',
            icon: Icons.remove,
            onPressed: onZoomOut,
          ),
          const _MapRailDivider(),
          _MapControlButton(
            tooltip: basemapStyle == LebanonBasemapStyle.street
                ? 'Switch to Satellite'
                : 'Switch to OSM',
            icon: _exportBasemapStyleIcon(basemapStyle),
            onPressed: onToggleBasemap,
          ),
          const _MapRailDivider(),
          _MapControlButton(
            tooltip: 'Undo last point',
            icon: Icons.undo_outlined,
            onPressed: onUndo,
          ),
          const _MapRailDivider(),
          _MapControlButton(
            tooltip: 'Clear polygon',
            icon: Icons.clear_outlined,
            onPressed: onClear,
            isBottom: true,
          ),
        ],
      ),
    );
  }
}

class _ExportAreaHorizontalToolbar extends StatelessWidget {
  const _ExportAreaHorizontalToolbar({
    required this.onFitWorkspace,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.basemapStyle,
    required this.onToggleBasemap,
    required this.onUndo,
    required this.onClear,
  });

  final VoidCallback onFitWorkspace;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final LebanonBasemapStyle basemapStyle;
  final VoidCallback onToggleBasemap;
  final VoidCallback? onUndo;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      color: scheme.surface.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _MapControlButton(
            tooltip: 'Fit workspace',
            icon: Icons.center_focus_strong_outlined,
            onPressed: onFitWorkspace,
            isStart: true,
          ),
          const _MapRailDivider(horizontal: true),
          _MapControlButton(
            tooltip: 'Zoom in',
            icon: Icons.add,
            onPressed: onZoomIn,
          ),
          const _MapRailDivider(horizontal: true),
          _MapControlButton(
            tooltip: 'Zoom out',
            icon: Icons.remove,
            onPressed: onZoomOut,
          ),
          const _MapRailDivider(horizontal: true),
          _MapControlButton(
            tooltip: basemapStyle == LebanonBasemapStyle.street
                ? 'Switch to Satellite'
                : 'Switch to OSM',
            icon: _exportBasemapStyleIcon(basemapStyle),
            onPressed: onToggleBasemap,
          ),
          const _MapRailDivider(horizontal: true),
          _MapControlButton(
            tooltip: 'Undo last point',
            icon: Icons.undo_outlined,
            onPressed: onUndo,
          ),
          const _MapRailDivider(horizontal: true),
          _MapControlButton(
            tooltip: 'Clear polygon',
            icon: Icons.clear_outlined,
            onPressed: onClear,
            isEnd: true,
          ),
        ],
      ),
    );
  }
}

class _ExportAreaActionPanel extends StatelessWidget {
  const _ExportAreaActionPanel({
    required this.onUseArea,
    required this.submitLabel,
  });

  final VoidCallback? onUseArea;
  final String submitLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Material(
          elevation: 8,
          color: scheme.surface.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onUseArea,
                icon: const Icon(Icons.check),
                label: Text(submitLabel),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MapControlButton extends StatelessWidget {
  const _MapControlButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.isTop = false,
    this.isBottom = false,
    this.isStart = false,
    this.isEnd = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool isTop;
  final bool isBottom;
  final bool isStart;
  final bool isEnd;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: 19),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.only(
              topLeft: (isTop || isStart)
                  ? const Radius.circular(18)
                  : Radius.zero,
              topRight: (isTop || isEnd)
                  ? const Radius.circular(18)
                  : Radius.zero,
              bottomLeft: (isBottom || isStart)
                  ? const Radius.circular(18)
                  : Radius.zero,
              bottomRight: (isBottom || isEnd)
                  ? const Radius.circular(18)
                  : Radius.zero,
            ),
          ),
        ),
      ),
    );
  }
}

class _MapRailDivider extends StatelessWidget {
  const _MapRailDivider({this.horizontal = false});

  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    if (horizontal) {
      return SizedBox(
        width: 1,
        height: 24,
        child: VerticalDivider(
          width: 1,
          thickness: 1,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      );
    }
    return Divider(
      height: 1,
      indent: 10,
      endIndent: 10,
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}

IconData _exportBasemapStyleIcon(LebanonBasemapStyle style) {
  switch (style) {
    case LebanonBasemapStyle.street:
      return Icons.map_outlined;
    case LebanonBasemapStyle.satellite:
      return Icons.satellite_alt_outlined;
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
    final summaryChips = _buildSummaryChips();
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
              const Chip(label: Text('Approved only')),
              ...summaryChips,
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
                )
              else if (job.status == ExportJobStatus.expired)
                const Chip(
                  avatar: Icon(Icons.schedule_outlined, size: 16),
                  label: Text('File expired'),
                )
              else if (job.completedAt != null)
                Chip(
                  avatar: const Icon(Icons.task_alt, size: 16),
                  label: Text('Ready ${_formatDateTime(job.completedAt!)}'),
                ),
            ],
          ),
          if ((job.displayMessage ?? job.errorMessage)?.trim().isNotEmpty ==
              true) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              (job.displayMessage ?? job.errorMessage)!,
              style: TextStyle(
                color: job.status == ExportJobStatus.expired
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          AppActionButtons(
            maxColumns: 2,
            compactBreakpoint: 360,
            fillRows: true,
            children: [
              OutlinedButton.icon(
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Check status'),
              ),
              if (job.canRetryOrRegenerate)
                FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: Text(
                    job.status == ExportJobStatus.expired
                        ? 'Regenerate'
                        : 'Retry',
                  ),
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

  List<Widget> _buildSummaryChips() {
    final chips = <Widget>[];
    final fromDate = job.exportParameters['date_from']?.toString().trim();
    final toDate = job.exportParameters['date_to']?.toString().trim();
    final bbox = job.exportParameters['bbox']?.toString().trim();
    final featureType = job.exportParameters['feature_type']?.toString().trim();
    final collectorName = job.exportParameters['collector_display_name']
        ?.toString()
        .trim();
    final exportPolygon = job.exportParameters['export_polygon']
        ?.toString()
        .trim();

    if (fromDate != null && fromDate.isNotEmpty) {
      chips.add(Chip(label: Text('From $fromDate')));
    }
    if (toDate != null && toDate.isNotEmpty) {
      chips.add(Chip(label: Text('To $toDate')));
    }
    if (bbox != null && bbox.isNotEmpty) {
      chips.add(
        const Chip(
          avatar: Icon(Icons.crop_free_outlined, size: 16),
          label: Text('Area filter'),
        ),
      );
    }
    if (exportPolygon != null && exportPolygon.isNotEmpty) {
      chips.add(
        const Chip(
          avatar: Icon(Icons.polyline_outlined, size: 16),
          label: Text('Drawn area'),
        ),
      );
    }
    if (featureType != null && featureType.isNotEmpty) {
      chips.add(Chip(label: Text('Type $featureType')));
    }
    if (collectorName != null && collectorName.isNotEmpty) {
      chips.add(
        Chip(
          avatar: const Icon(Icons.person_outline, size: 16),
          label: Text(collectorName),
        ),
      );
    }

    return chips;
  }
}

class _ExportFormatPicker extends StatelessWidget {
  const _ExportFormatPicker({
    required this.selectedFormat,
    required this.onChanged,
  });

  final ExportFormat selectedFormat;
  final ValueChanged<ExportFormat> onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cards = ExportFormat.values
            .map(
              (format) => _ExportFormatOption(
                format: format,
                selected: format == selectedFormat,
                onTap: () => onChanged(format),
              ),
            )
            .toList(growable: false);

        if (constraints.maxWidth < 520) {
          return Column(
            children: [
              for (var index = 0; index < cards.length; index++) ...[
                cards[index],
                if (index != cards.length - 1)
                  const SizedBox(height: AppSpacing.sm),
              ],
            ],
          );
        }

        return Row(
          children: [
            Expanded(child: cards[0]),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: cards[1]),
          ],
        );
      },
    );
  }
}

class _ExportFormatOption extends StatelessWidget {
  const _ExportFormatOption({
    required this.format,
    required this.selected,
    required this.onTap,
  });

  final ExportFormat format;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final borderColor = selected
        ? colorScheme.primary
        : colorScheme.outlineVariant;
    final background = selected
        ? colorScheme.primaryContainer
        : colorScheme.surface;

    final (icon, title) = switch (format) {
      ExportFormat.geojson => (Icons.public, 'GeoJSON'),
      ExportFormat.shapefile => (Icons.folder_zip_outlined, 'Shapefile'),
    };

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: borderColor),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: selected ? colorScheme.primary : null),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle, color: colorScheme.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ExportListFilter extends StatelessWidget {
  const _ExportListFilter({required this.selected, required this.onChanged});

  final _ExportJobFormatFilter selected;
  final ValueChanged<_ExportJobFormatFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _ExportJobFormatFilter.values
          .map(
            (filter) => ChoiceChip(
              label: Text(filter.label),
              selected: filter == selected,
              onSelected: (_) => onChanged(filter),
            ),
          )
          .toList(growable: false),
    );
  }
}

class _BboxTextInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (text.isEmpty) {
      return newValue;
    }

    if (text.length > 48 || RegExp(r'[^0-9,.\-]').hasMatch(text)) {
      return oldValue;
    }

    final parts = text.split(',');
    if (parts.length > 4) {
      return oldValue;
    }

    for (final part in parts) {
      if (part.isEmpty) {
        continue;
      }
      if (!RegExp(r'^-?\d{0,3}(\.\d{0,8})?$').hasMatch(part)) {
        return oldValue;
      }
    }

    return newValue;
  }
}

enum _ExportJobFormatFilter {
  all('All'),
  geojson('GeoJSON'),
  shapefile('Shapefile');

  const _ExportJobFormatFilter(this.label);

  final String label;
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
  return formatLebanonDateTime(value);
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
