import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/progressive_list_section.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../../auth/domain/auth_models.dart';
import '../../../projects/domain/project.dart';
import '../../domain/import_models.dart';
import '../import_providers.dart';

class ImportsScreen extends ConsumerStatefulWidget {
  const ImportsScreen({this.fixedProjectId, this.fixedProjectName, super.key});

  final String? fixedProjectId;
  final String? fixedProjectName;

  @override
  ConsumerState<ImportsScreen> createState() => _ImportsScreenState();
}

class _ImportsScreenState extends ConsumerState<ImportsScreen> {
  static const _allowedExtensions = <String>[
    'zip',
    'geojson',
    'json',
    'kml',
    'kmz',
  ];

  final ScrollController _scrollController = ScrollController();
  String? _selectedCategory;
  String? _selectedProjectId;
  String? _selectedAdminCategoryId;
  String? _selectedAdminProjectId;
  PlatformFile? _selectedFile;
  bool _isUploading = false;
  String _statusFilter = 'all';
  List<GisImportJob>? _cachedJobs;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authControllerProvider).session;
    if (session == null) {
      return const SizedBox.shrink();
    }
    final user = session.user;
    if (user.role == UserRole.viewer) {
      return const AppEmptyState(
        icon: Icons.lock_outline,
        title: 'GIS import unavailable',
        message: 'Only contributors and admins can use staged GIS imports.',
      );
    }

    final projectScope = user.role == UserRole.admin
        ? ProjectViewScope.all
        : ProjectViewScope.assigned;
    final projectsAsync = ref.watch(projectListProvider(projectScope));

    return projectsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Import workspace unavailable',
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to load import projects right now.',
        ),
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(projectListProvider(projectScope)),
      ),
      data: (projects) {
        final fixedProjectId = widget.fixedProjectId?.trim();
        final hasFixedProject =
            fixedProjectId != null && fixedProjectId.isNotEmpty;
        final categories = _deriveCategories(projects);
        final uploadableProjects = _uploadableProjects(projects);
        if (hasFixedProject) {
          final project = projects.cast<ProjectSummary?>().firstWhere(
            (item) => item?.id == fixedProjectId,
            orElse: () => null,
          );
          if (project != null) {
            _selectedCategory = project.categoryId;
            _selectedProjectId = project.id;
            _selectedAdminCategoryId = project.categoryId;
            _selectedAdminProjectId = project.id;
          }
        } else if (user.role == UserRole.contributor) {
          _syncSelection(categories, uploadableProjects);
        } else {
          _syncAdminSelection(categories, projects);
        }

        final jobsQuery = GisImportListQuery(
          status: _statusFilter == 'all' ? null : _statusFilter,
          projectId: hasFixedProject
              ? fixedProjectId
              : user.role == UserRole.admin
              ? _selectedAdminProjectId
              : null,
        );
        final jobsAsync = ref.watch(importJobsProvider(jobsQuery));
        final latestJobs = jobsAsync.asData?.value;
        final jobsError = jobsAsync.asError?.error;
        if (latestJobs != null) {
          _cachedJobs = latestJobs;
        }
        final effectiveJobs = latestJobs ?? _cachedJobs;
        if (effectiveJobs == null && jobsAsync.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (effectiveJobs == null && jobsAsync.hasError) {
          return AppEmptyState(
            icon: Icons.error_outline,
            title: 'Imports unavailable',
            message: userFacingErrorMessage(
              jobsError ?? 'Unknown error',
              fallback: 'Unable to load GIS imports right now.',
            ),
            actionLabel: 'Retry',
            onAction: () => ref.invalidate(importJobsProvider(jobsQuery)),
          );
        }

        final filteredJobs = _filterJobs(
          jobs: effectiveJobs ?? const <GisImportJob>[],
          projects: projects,
          selectedCategory: hasFixedProject
              ? _selectedCategory
              : user.role == UserRole.admin
              ? _selectedAdminCategoryId
              : null,
          selectedProjectId: hasFixedProject
              ? _selectedProjectId
              : user.role == UserRole.admin
              ? _selectedAdminProjectId
              : null,
        );
        final adminProjects = _projectsForCategory(
          projects,
          _selectedAdminCategoryId,
        );
        final fixedProject = hasFixedProject
            ? projects.cast<ProjectSummary?>().firstWhere(
                (project) => project?.id == fixedProjectId,
                orElse: () => null,
              )
            : null;

        return ListView(
          controller: _scrollController,
          key: PageStorageKey<String>('imports-${user.role.name}'),
          children: [
            if (jobsAsync.isLoading)
              const Padding(
                padding: EdgeInsets.only(bottom: AppSpacing.sm),
                child: LinearProgressIndicator(),
              ),
            if (jobsAsync.hasError && effectiveJobs != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Import list refresh failed',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        userFacingErrorMessage(
                          jobsError ?? 'Unknown error',
                          fallback: 'Unable to refresh GIS imports right now.',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (user.role == UserRole.contributor) ...[
              _buildUploadCard(
                context,
                categories: categories,
                projects: uploadableProjects,
                fixedProject: fixedProject,
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            Text(
              user.role == UserRole.admin
                  ? 'Import review queue'
                  : 'Import history',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '${filteredJobs.length} import${filteredJobs.length == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ..._statusOptions.map(
                        (option) => ChoiceChip(
                          label: Text(option.label),
                          selected: _statusFilter == option.value,
                          onSelected: (_) {
                            setState(() {
                              _statusFilter = option.value;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  if (user.role == UserRole.admin) ...[
                    const SizedBox(height: AppSpacing.sm),
                    if (hasFixedProject && fixedProject != null) ...[
                      InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Category filter',
                        ),
                        child: Text(
                          fixedProject.category,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Project filter',
                        ),
                        child: Text(
                          widget.fixedProjectName ?? fixedProject.name,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ),
                    ] else ...[
                      DropdownButtonFormField<String?>(
                        initialValue: _selectedAdminCategoryId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Category filter',
                        ),
                        items: <DropdownMenuItem<String?>>[
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('All categories'),
                          ),
                          ...categories.map(
                            (option) => DropdownMenuItem<String?>(
                              value: option.id,
                              child: Text(
                                option.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          setState(() {
                            _selectedAdminCategoryId = value;
                            final nextProjects = _projectsForCategory(
                              projects,
                              value,
                            );
                            final validIds = nextProjects
                                .map((item) => item.id)
                                .toSet();
                            if (_selectedAdminProjectId != null &&
                                !validIds.contains(_selectedAdminProjectId)) {
                              _selectedAdminProjectId = null;
                            }
                          });
                        },
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      DropdownButtonFormField<String?>(
                        initialValue: _selectedAdminProjectId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Project filter',
                        ),
                        items: <DropdownMenuItem<String?>>[
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('All projects'),
                          ),
                          ...adminProjects.map(
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
                          setState(() {
                            _selectedAdminProjectId = value;
                          });
                        },
                      ),
                    ],
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (filteredJobs.isEmpty)
              AppEmptyState(
                icon: Icons.upload_file_outlined,
                title: user.role == UserRole.contributor
                    ? 'No imports submitted yet'
                    : 'No imports match this filter',
                message: user.role == UserRole.contributor
                    ? 'Choose a project, upload a GIS file, and it will appear here after staging.'
                    : 'Contributor uploads awaiting review will appear here when they match the selected filters.',
              )
            else
              ProgressiveListSection<GisImportJob>(
                items: filteredJobs,
                resetKey: Object.hash(
                  user.role,
                  _statusFilter,
                  hasFixedProject ? fixedProjectId : _selectedCategory,
                  hasFixedProject
                      ? fixedProjectId
                      : user.role == UserRole.admin
                      ? _selectedAdminProjectId
                      : _selectedProjectId,
                  filteredJobs.length,
                ),
                itemBuilder: (context, job, _) => _ImportJobCard(
                  job: job,
                  onTap: () => context.push(AppRoutes.importDetails(job.id)),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildUploadCard(
    BuildContext context, {
    required List<_ImportCategoryOption> categories,
    required List<ProjectSummary> projects,
    ProjectSummary? fixedProject,
  }) {
    final filteredProjects = fixedProject != null
        ? <ProjectSummary>[fixedProject]
        : projects
              .where((project) => project.categoryId == _selectedCategory)
              .toList(growable: false);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Submit new import',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          if (fixedProject != null) ...[
            InputDecorator(
              decoration: const InputDecoration(labelText: 'Category'),
              child: Text(
                fixedProject.category,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            InputDecorator(
              decoration: const InputDecoration(labelText: 'Project'),
              child: Text(
                widget.fixedProjectName ?? fixedProject.name,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          ] else ...[
            DropdownButtonFormField<String>(
              initialValue: _selectedCategory,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Category'),
              items: categories
                  .map(
                    (option) => DropdownMenuItem<String>(
                      value: option.id,
                      child: Text(option.name, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (value) {
                setState(() {
                  _selectedCategory = value;
                  final nextProjects = projects
                      .where((project) => project.categoryId == value)
                      .toList(growable: false);
                  _selectedProjectId = nextProjects.isNotEmpty
                      ? nextProjects.first.id
                      : null;
                });
              },
            ),
            const SizedBox(height: AppSpacing.sm),
            DropdownButtonFormField<String>(
              initialValue: _selectedProjectId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Project'),
              items: filteredProjects
                  .map(
                    (project) => DropdownMenuItem<String>(
                      value: project.id,
                      child: Text(
                        project.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (value) {
                setState(() {
                  _selectedProjectId = value;
                });
              },
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: AppRadii.md,
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _selectedFile?.name ?? 'No GIS file selected yet',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    _selectedFile == null
                        ? 'Supported formats: zipped shapefile, GeoJSON, KML, KMZ.'
                        : '${_selectedFile!.extension?.toUpperCase() ?? 'FILE'} • ${_formatBytes(_selectedFile!.size)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _isUploading ? null : _pickFile,
                        icon: const Icon(Icons.attach_file),
                        label: const Text('Choose file'),
                      ),
                      FilledButton.icon(
                        onPressed:
                            _isUploading ||
                                _selectedProjectId == null ||
                                _selectedFile == null
                            ? null
                            : _submitUpload,
                        icon: Icon(
                          _isUploading
                              ? Icons.hourglass_top
                              : Icons.upload_file,
                        ),
                        label: Text(
                          _isUploading ? 'Uploading...' : 'Upload import',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: _allowedExtensions,
      allowMultiple: false,
      withData: kIsWeb,
    );
    if (result == null || result.files.isEmpty) {
      return;
    }
    setState(() {
      _selectedFile = result.files.single;
    });
  }

  Future<void> _submitUpload() async {
    final projectId = _selectedProjectId;
    final file = _selectedFile;
    if (projectId == null || file == null) {
      return;
    }

    setState(() {
      _isUploading = true;
    });
    try {
      final job = await ref
          .read(importsRepositoryProvider)
          .uploadImport(projectId: projectId, file: file);
      if (!mounted) {
        return;
      }
      setState(() {
        _isUploading = false;
        _selectedFile = null;
        _statusFilter = 'all';
      });
      bumpWorkflowRefresh(ref);
      AppSnackbar.showSuccess(
        context,
        'GIS import uploaded. ${job.pendingFeatureCount} staged feature(s) are ready for review.',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isUploading = false;
      });
      AppSnackbar.showError(
        context,
        userFacingErrorMessage(
          error,
          fallback: 'Unable to upload this GIS import right now.',
        ),
      );
    }
  }

  List<_ImportCategoryOption> _deriveCategories(List<ProjectSummary> projects) {
    final byId = <String, _ImportCategoryOption>{};
    for (final project in projects) {
      final categoryId = project.categoryId;
      if (categoryId == null || categoryId.trim().isEmpty) {
        continue;
      }
      byId.putIfAbsent(
        categoryId,
        () => _ImportCategoryOption(id: categoryId, name: project.category),
      );
    }
    return byId.values.toList(growable: false)
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  List<ProjectSummary> _uploadableProjects(List<ProjectSummary> projects) {
    return projects
        .where((project) => project.status == 'active')
        .toList(growable: false)
      ..sort((a, b) => a.name.compareTo(b.name));
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

  void _syncSelection(
    List<_ImportCategoryOption> categories,
    List<ProjectSummary> uploadableProjects,
  ) {
    if (categories.isEmpty || uploadableProjects.isEmpty) {
      _selectedCategory = null;
      _selectedProjectId = null;
      return;
    }
    final validCategoryIds = categories.map((item) => item.id).toSet();
    if (_selectedCategory == null ||
        !validCategoryIds.contains(_selectedCategory)) {
      _selectedCategory = categories.first.id;
    }
    final categoryProjects = uploadableProjects
        .where((project) => project.categoryId == _selectedCategory)
        .toList(growable: false);
    final validProjectIds = categoryProjects.map((item) => item.id).toSet();
    if (categoryProjects.isEmpty) {
      _selectedProjectId = null;
    } else if (_selectedProjectId == null ||
        !validProjectIds.contains(_selectedProjectId)) {
      _selectedProjectId = categoryProjects.first.id;
    }
  }

  void _syncAdminSelection(
    List<_ImportCategoryOption> categories,
    List<ProjectSummary> projects,
  ) {
    final validCategoryIds = categories.map((item) => item.id).toSet();
    if (_selectedAdminCategoryId != null &&
        !validCategoryIds.contains(_selectedAdminCategoryId)) {
      _selectedAdminCategoryId = null;
    }

    final categoryProjects = _projectsForCategory(
      projects,
      _selectedAdminCategoryId,
    );
    final validProjectIds = categoryProjects.map((item) => item.id).toSet();
    if (_selectedAdminProjectId != null &&
        !validProjectIds.contains(_selectedAdminProjectId)) {
      _selectedAdminProjectId = null;
    }
  }

  List<GisImportJob> _filterJobs({
    required List<GisImportJob> jobs,
    required List<ProjectSummary> projects,
    required String? selectedCategory,
    required String? selectedProjectId,
  }) {
    final projectById = <String, ProjectSummary>{
      for (final project in projects) project.id: project,
    };
    return jobs
        .where((job) {
          if (selectedProjectId != null &&
              selectedProjectId.trim().isNotEmpty &&
              job.projectId != selectedProjectId) {
            return false;
          }
          if (selectedCategory != null && selectedCategory.trim().isNotEmpty) {
            final project = projectById[job.projectId];
            if (project?.categoryId != selectedCategory) {
              return false;
            }
          }
          return true;
        })
        .toList(growable: false);
  }

  List<_StatusOption> get _statusOptions => const <_StatusOption>[
    _StatusOption('all', 'All'),
    _StatusOption('pending_review', 'Pending'),
    _StatusOption('approved', 'Approved'),
    _StatusOption('partially_approved', 'Partially approved'),
    _StatusOption('rejected', 'Rejected'),
    _StatusOption('failed', 'Failed'),
  ];

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    final kb = bytes / 1024;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(kb >= 100 ? 0 : 1)} KB';
    }
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(mb >= 100 ? 0 : 1)} MB';
  }
}

class _ImportJobCard extends StatelessWidget {
  const _ImportJobCard({required this.job, required this.onTap});

  final GisImportJob job;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        job.originalFilename,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        job.projectName,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                StatusChip(status: job.status),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(label: Text('${job.geometryCount} geometries')),
                Chip(label: Text('${job.warningCount} warnings')),
                Chip(label: Text('${job.errorCount} errors')),
                Chip(label: Text(job.fileType.toUpperCase())),
              ],
            ),
            if (job.rejectionReason?.trim().isNotEmpty ?? false) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Reason: ${job.rejectionReason}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ImportCategoryOption {
  const _ImportCategoryOption({required this.id, required this.name});

  final String id;
  final String name;
}

class _StatusOption {
  const _StatusOption(this.value, this.label);

  final String value;
  final String label;
}
