import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/pagination/paginated_result.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/utils/lebanon_time.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../../projects/domain/project.dart';
import '../../domain/ai_models.dart';
import '../ai_permissions.dart';
import '../ai_providers.dart';

class ProjectAiScreen extends ConsumerStatefulWidget {
  const ProjectAiScreen({
    required this.projectId,
    this.initialSection = 'readiness',
    super.key,
  });

  final String projectId;
  final String initialSection;

  @override
  ConsumerState<ProjectAiScreen> createState() => _ProjectAiScreenState();
}

class _ProjectAiScreenState extends ConsumerState<ProjectAiScreen> {
  late String _section;

  @override
  void initState() {
    super.initState();
    _section = _normalizedSection(widget.initialSection);
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authControllerProvider).session;
    final projectAsync = ref.watch(projectByIdProvider(widget.projectId));

    return projectAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'AI workspace unavailable',
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to load this project right now.',
        ),
      ),
      data: (project) {
        if (project == null) {
          return const AppEmptyState(
            icon: Icons.search_off,
            title: 'Project not found',
            message: 'The requested project is unavailable.',
          );
        }

        if (!canManageProjectAi(user: session?.user, project: project)) {
          return const AppEmptyState(
            icon: Icons.lock_outline,
            title: 'AI access restricted',
            message: 'Only the protected super-admin can manage project AI.',
          );
        }

        return ListView(
          padding: const EdgeInsets.only(bottom: AppSpacing.xl),
          children: [
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    project.name,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  const Text(
                    'AI uses approved project data. Regional worker results appear here after review.',
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: 'readiness',
                        icon: Icon(Icons.fact_check_outlined),
                        label: Text('Ready', maxLines: 1),
                      ),
                      ButtonSegment(
                        value: 'settings',
                        icon: Icon(Icons.tune_outlined),
                        label: Text('Settings', maxLines: 1),
                      ),
                      ButtonSegment(
                        value: 'runs',
                        icon: Icon(Icons.manage_history_outlined),
                        label: Text('Runs', maxLines: 1),
                      ),
                    ],
                    selected: {_section},
                    onSelectionChanged: (selection) {
                      setState(() => _section = selection.first);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (_section == 'readiness')
              ProjectAiReadinessSection(project: project)
            else if (_section == 'settings')
              ProjectAiSettingsSection(project: project)
            else
              ProjectAiRunsSection(project: project),
          ],
        );
      },
    );
  }
}

class ProjectAiReadinessSection extends ConsumerStatefulWidget {
  const ProjectAiReadinessSection({required this.project, super.key});

  final ProjectSummary project;

  @override
  ConsumerState<ProjectAiReadinessSection> createState() =>
      _ProjectAiReadinessSectionState();
}

class _ProjectAiReadinessSectionState
    extends ConsumerState<ProjectAiReadinessSection> {
  bool _refreshing = false;
  DateTime? _lastCheckedAt;

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(aiSettingsProvider(widget.project.id));
    return settingsAsync.when(
      loading: () =>
          const AppCard(child: Center(child: CircularProgressIndicator())),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'AI readiness unavailable',
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to load AI settings right now.',
        ),
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(aiSettingsProvider(widget.project.id)),
      ),
      data: (settings) {
        final query = AiReadinessQuery(
          projectId: widget.project.id,
          labelField: settings.labelField,
          minSamplesPerClass: settings.minSamplesPerClass,
          scopeType: settings.scopeType,
        );
        final readinessAsync = ref.watch(aiReadinessProvider(query));
        return readinessAsync.when(
          loading: () =>
              const AppCard(child: Center(child: CircularProgressIndicator())),
          error: (error, _) => AppEmptyState(
            icon: Icons.error_outline,
            title: 'AI readiness unavailable',
            message: userFacingErrorMessage(
              error,
              fallback: 'Unable to check AI readiness right now.',
            ),
            actionLabel: 'Retry',
            onAction: () => ref.invalidate(aiReadinessProvider(query)),
          ),
          data: (readiness) => _ReadinessCard(
            readiness: readiness,
            refreshing: _refreshing,
            lastCheckedAt: _lastCheckedAt,
            onRefresh: () => _refreshReadiness(query),
          ),
        );
      },
    );
  }

  Future<void> _refreshReadiness(AiReadinessQuery query) async {
    if (_refreshing) {
      return;
    }
    setState(() => _refreshing = true);
    try {
      ref.invalidate(aiReadinessProvider(query));
      await ref.read(aiReadinessProvider(query).future);
      if (!mounted) {
        return;
      }
      setState(() => _lastCheckedAt = DateTime.now());
      AppSnackbar.showSuccess(context, 'Readiness checked.');
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to refresh AI readiness right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
  }
}

class _ReadinessCard extends StatelessWidget {
  const _ReadinessCard({
    required this.readiness,
    required this.refreshing,
    required this.onRefresh,
    this.lastCheckedAt,
  });

  final AiReadinessResult readiness;
  final bool refreshing;
  final DateTime? lastCheckedAt;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final title = switch (readiness.status) {
      'ready' => 'Ready for regional AI',
      'warning' => 'Warning: ready for regional AI with limitations',
      _ => 'Not ready for AI yet',
    };
    final message = switch (readiness.status) {
      'ready' => 'Approved project data is enough for an AI run.',
      'warning' => 'A regional run can be prepared, but review the limits.',
      _ => 'Resolve blockers before preparing an AI run.',
    };

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.fact_check_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AI Readiness',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Checks whether approved project data is enough for an AI run.',
                    ),
                  ],
                ),
              ),
              StatusChip(status: readiness.status),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          Text(message),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(
                label: Text('Total approved ${readiness.approvedFeatureCount}'),
              ),
              Chip(label: Text('Labeled ${readiness.labeledFeatureCount}')),
              Chip(
                label: Text('Eligible classes ${readiness.eligibleClassCount}'),
              ),
              Chip(
                label: Text(
                  'Eligible samples ${readiness.eligibleFeatureCount}',
                ),
              ),
              Chip(
                label: Text('${readiness.missingLabelCount} missing labels'),
              ),
              Chip(
                label: Text('${readiness.invalidGeometryCount} invalid geom'),
              ),
              Chip(label: Text('Min ${readiness.minSamplesPerClass}/class')),
            ],
          ),
          if (readiness.classesBelowMinimum.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            _KeyValueList(
              title: 'Classes excluded from AI run',
              rows: readiness.classesBelowMinimum
                  .map(
                    (item) => MapEntry(
                      item.label,
                      '${item.sampleCount} samples, below ${readiness.minSamplesPerClass}',
                    ),
                  )
                  .toList(growable: false),
            ),
          ],
          if (!readiness.isNotReady) ...[
            const SizedBox(height: AppSpacing.sm),
            const _NoticeRow(
              icon: Icons.travel_explore_outlined,
              text: 'Regional AI only. National AI requires wider coverage.',
            ),
          ],
          if (readiness.spatialExtent != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              'Spatial extent',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(_formatExtent(readiness.spatialExtent!)),
          ],
          const SizedBox(height: AppSpacing.md),
          _KeyValueList(
            title: 'Class counts',
            emptyText: 'No labeled classes found.',
            rows: readiness.labelCounts
                .map(
                  (item) => MapEntry(item.label, item.sampleCount.toString()),
                )
                .toList(growable: false),
          ),
          const SizedBox(height: AppSpacing.md),
          _KeyValueList(
            title: 'Source/provenance counts',
            emptyText: readiness.sourceColumnAvailable
                ? 'No approved source counts returned.'
                : 'Source provenance is not available in this database.',
            rows: readiness.sourceCounts
                .map(
                  (item) => MapEntry(item.source, item.featureCount.toString()),
                )
                .toList(growable: false),
          ),
          if (readiness.warnings.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            _MessageList(title: 'Warnings', messages: readiness.warnings),
          ],
          if (readiness.blockers.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            _MessageList(title: 'Blockers', messages: readiness.blockers),
          ],
          const SizedBox(height: AppSpacing.md),
          FilledButton.tonalIcon(
            onPressed: refreshing ? null : onRefresh,
            icon: refreshing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            label: Text(refreshing ? 'Refreshing...' : 'Refresh readiness'),
          ),
          if (lastCheckedAt != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Readiness checked.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class ProjectAiSettingsSection extends ConsumerStatefulWidget {
  const ProjectAiSettingsSection({required this.project, super.key});

  final ProjectSummary project;

  @override
  ConsumerState<ProjectAiSettingsSection> createState() =>
      _ProjectAiSettingsSectionState();
}

class _ProjectAiSettingsSectionState
    extends ConsumerState<ProjectAiSettingsSection> {
  bool _isEnabled = false;
  String? _labelField;
  String _scopeType = 'project';
  String _preferredModel = 'auto';
  final TextEditingController _minSamplesController = TextEditingController();
  String? _initializedFor;
  bool _saving = false;

  @override
  void dispose() {
    _minSamplesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(aiSettingsProvider(widget.project.id));
    return settingsAsync.when(
      loading: () =>
          const AppCard(child: Center(child: CircularProgressIndicator())),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'AI settings unavailable',
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to load AI settings right now.',
        ),
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(aiSettingsProvider(widget.project.id)),
      ),
      data: (settings) {
        _initializeFromSettings(settings);
        final labelProbeQuery = AiReadinessQuery(
          projectId: widget.project.id,
          labelField: _labelField ?? _schemaPreferredLabelField(widget.project),
          scopeType: 'project',
        );
        final labelProbeAsync = ref.watch(aiReadinessProvider(labelProbeQuery));
        final labelCandidates =
            labelProbeAsync.asData?.value.candidateLabelFields ??
            const <AiLabelFieldCandidate>[];
        final labelFields = _labelFieldOptions(
          widget.project,
          _labelField,
          labelCandidates,
        );
        final selectedLabelField = _selectedLabelField(
          labelFields,
          _labelField,
        );
        final selectedLabelOption = _optionFor(labelFields, selectedLabelField);
        if (selectedLabelField != null && selectedLabelField != _labelField) {
          _labelField = selectedLabelField;
        }
        final hasMappedEquivalentFields = labelCandidates.any(
          (candidate) => candidate.aliasOf?.trim().isNotEmpty == true,
        );

        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(title: 'AI Settings'),
              const SizedBox(height: AppSpacing.sm),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _isEnabled,
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _isEnabled = value),
                title: const Text('Enable AI for this project'),
                subtitle: const Text(
                  'Settings prepare worker runs but do not start one.',
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              DropdownButtonFormField<String>(
                initialValue: selectedLabelField,
                decoration: const InputDecoration(labelText: 'Label field'),
                items: labelFields
                    .map(
                      (field) => DropdownMenuItem<String>(
                        value: field.key,
                        enabled: field.enabled,
                        child: Text(field.label),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _labelField = value),
              ),
              const SizedBox(height: AppSpacing.xs),
              const Text(
                'Choose the field the AI should learn as the class label.',
              ),
              if (labelProbeAsync.isLoading) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Checking approved label data...',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (hasMappedEquivalentFields) ...[
                const SizedBox(height: AppSpacing.xs),
                const _NoticeRow(
                  icon: Icons.merge_type_outlined,
                  text:
                      'Equivalent imported fields were detected and mapped automatically.',
                ),
              ],
              if (selectedLabelOption != null &&
                  !selectedLabelOption.enabled) ...[
                const SizedBox(height: AppSpacing.xs),
                _NoticeRow(
                  icon: Icons.warning_amber_outlined,
                  text:
                      '${selectedLabelOption.key} has no usable approved labels.',
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<String>(
                initialValue: 'project',
                decoration: const InputDecoration(labelText: 'Scope type'),
                items: const [
                  DropdownMenuItem(value: 'project', child: Text('Project')),
                  DropdownMenuItem(
                    value: 'custom_polygon',
                    enabled: false,
                    child: Text('Custom polygon - future'),
                  ),
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _scopeType = value);
                        }
                      },
              ),
              const SizedBox(height: AppSpacing.xs),
              const Text('Project scope uses approved data from this project.'),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _minSamplesController,
                enabled: !_saving,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Minimum samples per class',
                  hintText: '50',
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<String>(
                initialValue: _preferredModel,
                decoration: const InputDecoration(
                  labelText: 'Model preference',
                ),
                items: const [
                  DropdownMenuItem(value: 'auto', child: Text('Auto')),
                  DropdownMenuItem(
                    value: 'random_forest',
                    child: Text('Random Forest'),
                  ),
                  DropdownMenuItem(value: 'svm', child: Text('SVM')),
                  DropdownMenuItem(value: 'xgboost', child: Text('XGBoost')),
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _preferredModel = value);
                        }
                      },
              ),
              const SizedBox(height: AppSpacing.md),
              const _NoticeRow(
                icon: Icons.info_outline,
                text: 'Saving settings does not run AI.',
              ),
              const SizedBox(height: AppSpacing.md),
              FilledButton.icon(
                onPressed: _saving ? null : _saveSettings,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(_saving ? 'Saving...' : 'Save settings'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _initializeFromSettings(AiProjectSettings settings) {
    final key =
        '${settings.projectId}:${settings.updatedKey}:${settings.labelField}:${settings.minSamplesPerClass}:${settings.scopeType}';
    if (_initializedFor == key) {
      return;
    }
    _initializedFor = key;
    _isEnabled = settings.isEnabled;
    _labelField = settings.labelField ?? _preferredLabelField(widget.project);
    _scopeType = 'project';
    _preferredModel =
        settings.modelPreferences['preferred_model'] as String? ?? 'auto';
    _minSamplesController.text = settings.minSamplesPerClass.toString();
  }

  Future<void> _saveSettings() async {
    final minSamples =
        int.tryParse(_minSamplesController.text.trim())?.clamp(1, 10000) ?? 50;
    setState(() => _saving = true);
    try {
      await ref
          .read(aiRepositoryProvider)
          .saveSettings(
            projectId: widget.project.id,
            settings: AiProjectSettings(
              projectId: widget.project.id,
              isEnabled: _isEnabled,
              labelField: _labelField,
              scopeType: _scopeType,
              minSamplesPerClass: minSamples,
              modelPreferences: <String, dynamic>{
                'preferred_model': _preferredModel,
              },
            ),
          );
      bumpWorkflowRefresh(ref);
      if (mounted) {
        AppSnackbar.showSuccess(context, 'AI settings saved successfully.');
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to save AI settings right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }
}

class ProjectAiRunsSection extends ConsumerStatefulWidget {
  const ProjectAiRunsSection({required this.project, super.key});

  final ProjectSummary project;

  @override
  ConsumerState<ProjectAiRunsSection> createState() =>
      _ProjectAiRunsSectionState();
}

class _ProjectAiRunsSectionState extends ConsumerState<ProjectAiRunsSection> {
  String? _selectedRunId;
  bool _creatingDraft = false;

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(aiSettingsProvider(widget.project.id));
    final runsAsync = ref.watch(
      aiRunsProvider(AiRunsQuery(projectId: widget.project.id)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(title: 'AI Runs'),
              const SizedBox(height: AppSpacing.sm),
              const Text(
                'View AI run records, worker logs, and regional proof-of-concept results.',
              ),
              const SizedBox(height: AppSpacing.md),
              settingsAsync.when(
                loading: () => const LinearProgressIndicator(),
                error: (error, _) => Text(
                  userFacingErrorMessage(
                    error,
                    fallback: 'Unable to load settings for draft creation.',
                  ),
                ),
                data: (settings) {
                  final canCreateDraft =
                      !_creatingDraft &&
                      (settings.labelField?.trim().isNotEmpty ?? false);
                  return FilledButton.tonalIcon(
                    onPressed: canCreateDraft
                        ? () => _createDraftRun(settings)
                        : null,
                    icon: _creatingDraft
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.note_add_outlined),
                    label: Text(
                      _creatingDraft
                          ? 'Creating...'
                          : 'Create draft run record',
                    ),
                  );
                },
              ),
              const SizedBox(height: AppSpacing.xs),
              const Text('This does not start AI processing.'),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        runsAsync.when(
          loading: () =>
              const AppCard(child: Center(child: CircularProgressIndicator())),
          error: (error, _) => AppEmptyState(
            icon: Icons.error_outline,
            title: 'AI runs unavailable',
            message: userFacingErrorMessage(
              error,
              fallback: 'Unable to load AI runs right now.',
            ),
            actionLabel: 'Retry',
            onAction: () => ref.invalidate(
              aiRunsProvider(AiRunsQuery(projectId: widget.project.id)),
            ),
          ),
          data: (page) {
            if (page.items.isEmpty) {
              return const AppCard(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.history_outlined),
                  title: Text('No AI run records yet'),
                  subtitle: Text(
                    'Create a draft when settings and readiness are ready to review.',
                  ),
                ),
              );
            }
            return AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final run in page.items) ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.manage_history_outlined),
                      title: Text(
                        'Run ${run.id.substring(0, run.id.length.clamp(0, 8))}',
                      ),
                      subtitle: Text(
                        '${_friendlyStatusLabel(run.status)} - ${run.labelField ?? 'No label'} - ${run.eligibleFeatureCount} eligible',
                      ),
                      trailing: StatusChip(status: run.status),
                      onTap: () => setState(
                        () => _selectedRunId = _selectedRunId == run.id
                            ? null
                            : run.id,
                      ),
                    ),
                    if (run.failureReason?.trim().isNotEmpty ?? false)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: Text('Failure: ${run.failureReason}'),
                      ),
                    if (_selectedRunId == run.id) ...[
                      const SizedBox(height: AppSpacing.sm),
                      _AiRunDetailCard(runId: run.id),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    if (run != page.items.last) const Divider(height: 1),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Future<void> _createDraftRun(AiProjectSettings settings) async {
    setState(() => _creatingDraft = true);
    try {
      final run = await ref
          .read(aiRepositoryProvider)
          .createRun(
            projectId: widget.project.id,
            status: 'draft',
            labelField: settings.labelField,
            scopeType: settings.scopeType,
            minSamplesPerClass: settings.minSamplesPerClass,
          );
      _selectedRunId = run.id;
      bumpWorkflowRefresh(ref);
      if (mounted) {
        AppSnackbar.showSuccess(
          context,
          'Draft AI run record created. No worker command was started.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to create AI draft run right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _creatingDraft = false);
      }
    }
  }
}

class _AiRunDetailCard extends ConsumerWidget {
  const _AiRunDetailCard({required this.runId});

  final String runId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runAsync = ref.watch(aiRunProvider(runId));
    final metricsAsync = ref.watch(aiRunMetricsProvider(runId));
    final layersAsync = ref.watch(aiRunLayersProvider(runId));
    final logsAsync = ref.watch(aiRunLogsProvider(runId));
    final reviewsAsync = ref.watch(aiRunReviewsProvider(runId));

    return runAsync.when(
      loading: () =>
          const AppCard(child: Center(child: CircularProgressIndicator())),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'AI run unavailable',
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to load this AI run right now.',
        ),
      ),
      data: (run) => Padding(
        padding: const EdgeInsets.only(
          left: AppSpacing.md,
          right: AppSpacing.xs,
          bottom: AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Run summary',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                StatusChip(status: run.status),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            _RunStatusSection(run: run),
            if (run.failureReason?.trim().isNotEmpty ?? false) ...[
              const SizedBox(height: AppSpacing.md),
              _NoticeRow(
                icon: Icons.error_outline,
                text: 'Failure reason: ${_safeText(run.failureReason!)}',
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            _WhatHappenedSection(run: run, metricsAsync: metricsAsync),
            const SizedBox(height: AppSpacing.md),
            _LimitationSection(run: run),
            const SizedBox(height: AppSpacing.md),
            _NextStepSection(run: run, layersAsync: layersAsync),
            const SizedBox(height: AppSpacing.md),
            _AiOutputLayersSection(
              run: run,
              layersAsync: layersAsync,
              reviewsAsync: reviewsAsync,
            ),
            const SizedBox(height: AppSpacing.md),
            _ReviewSection(run: run, reviewsAsync: reviewsAsync),
            const SizedBox(height: AppSpacing.md),
            _OutputPathsSection(paths: _outputPaths(run.metadata)),
            const SizedBox(height: AppSpacing.sm),
            _LogsSection(asyncValue: logsAsync),
            const SizedBox(height: AppSpacing.sm),
            _TechnicalDetailsSection(run: run),
          ],
        ),
      ),
    );
  }
}

class _RunStatusSection extends StatelessWidget {
  const _RunStatusSection({required this.run});

  final AiRun run;

  @override
  Widget build(BuildContext context) {
    return _KeyValueList(title: 'Run status', rows: _runStatusRows(run));
  }
}

class _WhatHappenedSection extends StatelessWidget {
  const _WhatHappenedSection({required this.run, required this.metricsAsync});

  final AiRun run;
  final AsyncValue<List<AiRunMetric>> metricsAsync;

  @override
  Widget build(BuildContext context) {
    final rows = _whatHappenedRows(run);
    final mode = _executionMode(run);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('What happened', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        _NoticeRow(
          icon: Icons.auto_awesome_outlined,
          text: _whatHappenedMessage(mode),
        ),
        if (rows.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          _KeyValueList(title: 'Result summary', rows: rows),
        ],
        if (mode == 'regional_model_eval') ...[
          const SizedBox(height: AppSpacing.sm),
          _ModelResultSection(run: run, metricsAsync: metricsAsync),
        ],
        const SizedBox(height: AppSpacing.sm),
        _ClassCountsSection(run: run),
      ],
    );
  }
}

class _OutputPathsSection extends StatelessWidget {
  const _OutputPathsSection({required this.paths});

  final List<String> paths;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      expandedAlignment: Alignment.centerLeft,
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      title: const Text('Technical output files'),
      children: [
        SizedBox(
          width: double.infinity,
          child: _KeyValueList(
            title: 'Output files',
            emptyText: 'No technical output files recorded yet.',
            rows: paths
                .map(
                  (path) =>
                      MapEntry(_friendlyOutputPathLabel(path), _safeText(path)),
                )
                .toList(growable: false),
          ),
        ),
      ],
    );
  }
}

class _ModelResultSection extends StatelessWidget {
  const _ModelResultSection({required this.run, required this.metricsAsync});

  final AiRun run;
  final AsyncValue<List<AiRunMetric>> metricsAsync;

  @override
  Widget build(BuildContext context) {
    final metrics = metricsAsync.maybeWhen(
      data: (items) => items,
      orElse: () => const <AiRunMetric>[],
    );
    final rows = _modelResultRows(run, metrics);
    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _KeyValueList(title: 'Model result', rows: rows),
        if (metrics.length > 1) ...[
          const SizedBox(height: AppSpacing.sm),
          _KeyValueList(
            title: 'Model comparison',
            rows: metrics
                .map(
                  (metric) => MapEntry(
                    _friendlyModelLabel(metric.modelName),
                    _modelMetricSummary(metric),
                  ),
                )
                .toList(growable: false),
          ),
        ],
      ],
    );
  }
}

class _ClassCountsSection extends StatelessWidget {
  const _ClassCountsSection({required this.run});

  final AiRun run;

  @override
  Widget build(BuildContext context) {
    final classRows = _countRows(run.metadata['class_counts']);
    final excludedRows = _countRows(run.metadata['excluded_classes']);
    if (classRows.isEmpty && excludedRows.isEmpty) {
      return const _KeyValueList(
        title: 'Class counts',
        emptyText: 'No class count summary recorded yet.',
        rows: [],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _KeyValueList(title: 'Class counts', rows: classRows),
        if (excludedRows.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          _KeyValueList(title: 'Excluded classes', rows: excludedRows),
        ],
      ],
    );
  }
}

class _NextStepSection extends StatelessWidget {
  const _NextStepSection({required this.run, required this.layersAsync});

  final AiRun run;
  final AsyncValue<List<AiOutputLayer>> layersAsync;

  @override
  Widget build(BuildContext context) {
    return layersAsync.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, _) => Text(
        userFacingErrorMessage(error, fallback: 'Unable to load AI layers.'),
      ),
      data: (layers) {
        final messages = <String>[
          _statusExplanation(run),
          if (_executionMode(run) != 'regional_model_eval')
            'Model metrics will appear after a regional model evaluation run.',
        ];
        if (layers.isEmpty) {
          messages.add('No published AI layers yet.');
          messages.add('AI map layers are planned for a later phase.');
        } else {
          for (final layer in layers) {
            messages.add(
              '${_friendlyLayerTypeLabel(layer.layerType)} layer: ${_friendlyLayerStatusLabel(layer.status)}.',
            );
          }
          messages.add('No viewer-facing AI layer is published in this phase.');
        }
        return _MessageList(
          title: 'Next step',
          messages: messages.map(_safeText).toList(growable: false),
        );
      },
    );
  }
}

class _AiOutputLayersSection extends StatelessWidget {
  const _AiOutputLayersSection({
    required this.run,
    required this.layersAsync,
    required this.reviewsAsync,
  });

  final AiRun run;
  final AsyncValue<List<AiOutputLayer>> layersAsync;
  final AsyncValue<List<AiReviewDecision>> reviewsAsync;

  @override
  Widget build(BuildContext context) {
    return layersAsync.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, _) => Text(
        userFacingErrorMessage(
          error,
          fallback: 'Unable to load AI output layers.',
        ),
      ),
      data: (layers) {
        final reviews = reviewsAsync.maybeWhen(
          data: (items) => items,
          orElse: () => const <AiReviewDecision>[],
        );
        final latestReview = reviews.isEmpty ? null : reviews.first;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'AI output layers',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: AppSpacing.xs),
            const _NoticeRow(
              icon: Icons.visibility_off_outlined,
              text:
                  'AI layers are not visible to viewers until a later publishing phase.',
            ),
            const SizedBox(height: AppSpacing.xs),
            if (layers.isEmpty)
              const _NoticeRow(
                icon: Icons.layers_clear_outlined,
                text: 'No AI output layers have been registered yet.',
              )
            else
              for (final layer in layers)
                _AiOutputLayerTile(
                  run: run,
                  layer: layer,
                  latestReview: latestReview,
                ),
          ],
        );
      },
    );
  }
}

class _AiOutputLayerTile extends StatelessWidget {
  const _AiOutputLayerTile({
    required this.run,
    required this.layer,
    required this.latestReview,
  });

  final AiRun run;
  final AiOutputLayer layer;
  final AiReviewDecision? latestReview;

  @override
  Widget build(BuildContext context) {
    final summaryRows = _layerSummaryRows(layer, latestReview);
    final technicalRows = _layerTechnicalRows(layer);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outline),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.layers_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_friendlyLayerTypeLabel(layer.layerType)} layer',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Text(
                          _safeText(layer.name),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  StatusChip(status: layer.status),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              _KeyValueList(title: 'Layer details', rows: summaryRows),
              if (layer.layerType == 'statistics') ...[
                const SizedBox(height: AppSpacing.sm),
                _StatisticsLayerSummary(run: run),
              ],
              if (technicalRows.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  expandedAlignment: Alignment.centerLeft,
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  title: const Text('Layer technical details'),
                  children: [
                    _KeyValueList(
                      title: 'Technical layer metadata',
                      rows: technicalRows,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatisticsLayerSummary extends StatelessWidget {
  const _StatisticsLayerSummary({required this.run});

  final AiRun run;

  @override
  Widget build(BuildContext context) {
    final includedRows = _includedClassCountRows(run);
    final excludedRows = _excludedClassCountRows(run);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _KeyValueList(
          title: 'Statistics summary',
          emptyText: 'No class statistics are registered yet.',
          rows: includedRows,
        ),
        if (excludedRows.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          _KeyValueList(title: 'Excluded classes', rows: excludedRows),
        ],
        const SizedBox(height: AppSpacing.sm),
        const _NoticeRow(
          icon: Icons.info_outline,
          text: 'Area statistics not available yet.',
        ),
        const _NoticeRow(
          icon: Icons.info_outline,
          text: 'Confidence statistics not available yet.',
        ),
      ],
    );
  }
}

class _ReviewSection extends ConsumerStatefulWidget {
  const _ReviewSection({required this.run, required this.reviewsAsync});

  final AiRun run;
  final AsyncValue<List<AiReviewDecision>> reviewsAsync;

  @override
  ConsumerState<_ReviewSection> createState() => _ReviewSectionState();
}

class _ReviewSectionState extends ConsumerState<_ReviewSection> {
  final TextEditingController _reasonController = TextEditingController();
  String? _submittingAction;
  String? _errorText;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.reviewsAsync.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, _) => Text(
        userFacingErrorMessage(
          error,
          fallback: 'Unable to load AI review decisions.',
        ),
      ),
      data: (reviews) {
        final latest = reviews.isEmpty ? null : reviews.first;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Review result',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: AppSpacing.xs),
            if (latest == null)
              const _NoticeRow(
                icon: Icons.rate_review_outlined,
                text: 'No review decision has been recorded yet.',
              )
            else
              _KeyValueList(
                title: 'Latest decision',
                rows: <MapEntry<String, String>>[
                  MapEntry(
                    'Decision',
                    _friendlyReviewDecisionLabel(latest.decision),
                  ),
                  if (latest.reason?.trim().isNotEmpty ?? false)
                    MapEntry('Reason', _safeText(latest.reason!)),
                  if (latest.decidedAt != null)
                    MapEntry('Decided', formatLebanonDate(latest.decidedAt)),
                ],
              ),
            if (widget.run.status == 'ready_for_review') ...[
              const SizedBox(height: AppSpacing.sm),
              const _NoticeRow(
                icon: Icons.visibility_off_outlined,
                text:
                    'Review decisions prepare AI results for a later publishing phase. They do not publish map layers to viewers yet.',
              ),
              const SizedBox(height: AppSpacing.sm),
              const _ReviewActionGuide(),
              const SizedBox(height: AppSpacing.sm),
              _ReviewFormArea(
                reasonController: _reasonController,
                errorText: _errorText,
                actions: _ReviewActionButtons(
                  submittingAction: _submittingAction,
                  onApprove: _isSubmitting
                      ? null
                      : () => _submitReview('approve_for_publication'),
                  onReject: _isSubmitting
                      ? null
                      : () => _submitReview('reject'),
                  onRequestMoreData: _isSubmitting
                      ? null
                      : () => _submitReview('request_more_data'),
                  onKeepDraft: _isSubmitting
                      ? null
                      : () => _submitReview('keep_draft'),
                ),
              ),
            ],
            if (reviews.length > 1) ...[
              const SizedBox(height: AppSpacing.sm),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                expandedAlignment: Alignment.centerLeft,
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                title: const Text('Review history'),
                children: [
                  for (final review in reviews)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        '${_friendlyReviewDecisionLabel(review.decision)}'
                        '${review.reason?.trim().isNotEmpty ?? false ? ': ${_safeText(review.reason!)}' : ''}',
                      ),
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  bool get _isSubmitting => _submittingAction != null;

  Future<void> _submitReview(String action) async {
    final reason = _reasonController.text.trim();
    if (action == 'reject' && reason.isEmpty) {
      setState(() => _errorText = 'Please add a reason before rejecting.');
      return;
    }
    if (action == 'request_more_data' && reason.isEmpty) {
      setState(() => _errorText = 'Please explain what data is needed.');
      return;
    }

    setState(() {
      _submittingAction = action;
      _errorText = null;
    });
    try {
      final result = await ref
          .read(aiRepositoryProvider)
          .reviewRun(runId: widget.run.id, action: action, reason: reason);
      ref.invalidate(aiRunProvider(widget.run.id));
      ref.invalidate(aiRunMetricsProvider(widget.run.id));
      ref.invalidate(aiRunLayersProvider(widget.run.id));
      ref.invalidate(aiRunLogsProvider(widget.run.id));
      ref.invalidate(aiRunReviewsProvider(widget.run.id));
      ref.invalidate(
        aiRunsProvider(AiRunsQuery(projectId: widget.run.projectId)),
      );
      if (mounted) {
        _reasonController.clear();
        AppSnackbar.showSuccess(
          context,
          result.viewerPublished
              ? 'AI review decision saved.'
              : 'AI review saved. No viewer-facing layer was published.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to save AI review decision right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _submittingAction = null);
      }
    }
  }
}

class _ReviewFormArea extends StatelessWidget {
  const _ReviewFormArea({
    required this.reasonController,
    required this.actions,
    required this.errorText,
  });

  final TextEditingController reasonController;
  final Widget actions;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 420.0;
        final formWidth = _reviewActionWidth(width);
        return SizedBox(
          width: formWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: reasonController,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: 'Review reason or comment',
                  hintText:
                      'Required for reject or request more data. Optional for approval.',
                  errorText: errorText,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              actions,
            ],
          ),
        );
      },
    );
  }
}

class _ReviewActionGuide extends StatelessWidget {
  const _ReviewActionGuide();

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodySmall;
    final mutedColor = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Action guide', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(
          'Approve accepts the result for a later publishing phase. Reject or request more data require a reason. Keep draft leaves it internal for now.',
          style: textStyle?.copyWith(color: mutedColor),
        ),
      ],
    );
  }
}

class _ReviewActionButtons extends StatelessWidget {
  const _ReviewActionButtons({
    required this.submittingAction,
    required this.onApprove,
    required this.onReject,
    required this.onRequestMoreData,
    required this.onKeepDraft,
  });

  final String? submittingAction;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;
  final VoidCallback? onRequestMoreData;
  final VoidCallback? onKeepDraft;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 420.0;
        final actionWidth = _reviewActionWidth(width);
        final showSecondaryRow = actionWidth >= 760;

        return SizedBox(
          width: actionWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Tooltip(
                message:
                    'Accept this AI result for a later publishing phase. Viewers will not see it yet.',
                child: SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: onApprove,
                    child: _buttonLabel(
                      action: 'approve_for_publication',
                      label: 'Approve for future publication',
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              if (showSecondaryRow)
                Row(
                  children: [
                    Expanded(
                      child: _reviewButton(
                        action: 'reject',
                        label: 'Reject',
                        tooltip: 'Reject this AI result. A reason is required.',
                        onPressed: onReject,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: _reviewButton(
                        action: 'request_more_data',
                        label: 'Request more data',
                        tooltip:
                            'Ask for more field or training data. A reason is required.',
                        onPressed: onRequestMoreData,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: _reviewButton(
                        action: 'keep_draft',
                        label: 'Keep draft',
                        tooltip:
                            'Keep this result internal for now. Nothing is published.',
                        onPressed: onKeepDraft,
                      ),
                    ),
                  ],
                )
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _reviewButton(
                      action: 'reject',
                      label: 'Reject',
                      tooltip: 'Reject this AI result. A reason is required.',
                      onPressed: onReject,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    _reviewButton(
                      action: 'request_more_data',
                      label: 'Request more data',
                      tooltip:
                          'Ask for more field or training data. A reason is required.',
                      onPressed: onRequestMoreData,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    _reviewButton(
                      action: 'keep_draft',
                      label: 'Keep draft',
                      tooltip:
                          'Keep this result internal for now. Nothing is published.',
                      onPressed: onKeepDraft,
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _reviewButton({
    required String action,
    required String label,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        height: 48,
        child: OutlinedButton(
          onPressed: onPressed,
          child: _buttonLabel(action: action, label: label),
        ),
      ),
    );
  }

  Widget _buttonLabel({required String action, required String label}) {
    if (submittingAction == action) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    );
  }
}

double _reviewActionWidth(double availableWidth) {
  return availableWidth < 840 ? availableWidth : 840.0;
}

class _LimitationSection extends StatelessWidget {
  const _LimitationSection({required this.run});

  final AiRun run;

  @override
  Widget build(BuildContext context) {
    final messages = _limitationMessages(run);
    if (messages.isEmpty) {
      return const SizedBox.shrink();
    }
    return _MessageList(title: 'Limitations', messages: messages);
  }
}

class _LogsSection extends StatelessWidget {
  const _LogsSection({required this.asyncValue});

  final AsyncValue<PaginatedResult<AiRunLog>> asyncValue;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      expandedAlignment: Alignment.centerLeft,
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      title: const Text('Worker logs'),
      children: [
        asyncValue.when(
          loading: () => const LinearProgressIndicator(),
          error: (error, _) => Text(
            userFacingErrorMessage(error, fallback: 'Unable to load run logs.'),
          ),
          data: (page) {
            if (page.items.isEmpty) {
              return const _KeyValueList(
                title: 'Logs',
                emptyText: 'Worker logs will appear after processing starts.',
                rows: [],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Logs', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                for (final log in page.items) _LogRow(log: log),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.log});

  final AiRunLog log;

  @override
  Widget build(BuildContext context) {
    final details = <String>[
      if (log.createdAt != null) formatLebanonDate(log.createdAt),
      if (_metadataText(log.metadata, 'step') != null)
        'Step ${_metadataText(log.metadata, 'step')}',
      if (_metadataText(log.metadata, 'duration_ms') != null)
        _formatDurationMs(_toIntValue(log.metadata['duration_ms'])),
    ].where((value) => value.trim().isNotEmpty).join(' - ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatusChip(status: log.level),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_safeText(log.message)),
                if (details.isNotEmpty)
                  Text(details, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TechnicalDetailsSection extends StatelessWidget {
  const _TechnicalDetailsSection({required this.run});

  final AiRun run;

  @override
  Widget build(BuildContext context) {
    final rows = <MapEntry<String, String>>[
      if (_metadataText(run.metadata, 'ai_pipeline_run_id') != null)
        MapEntry(
          'AI pipeline run',
          _metadataText(run.metadata, 'ai_pipeline_run_id')!,
        ),
      if (_metadataText(run.metadata, 'output_directory') != null)
        MapEntry(
          'Output directory',
          _metadataText(run.metadata, 'output_directory')!,
        ),
      if (_metadataText(run.metadata, 'pipeline_bridge_phase') != null)
        MapEntry(
          'Pipeline bridge phase',
          _metadataText(run.metadata, 'pipeline_bridge_phase')!,
        ),
      if (_metadataText(run.metadata, 'worker_phase') != null)
        MapEntry('Worker phase', _metadataText(run.metadata, 'worker_phase')!),
      if (run.metadata.isNotEmpty)
        MapEntry('Metadata keys', run.metadata.keys.toList().join(', ')),
    ];

    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      expandedAlignment: Alignment.centerLeft,
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      title: const Text('Technical metadata'),
      children: [
        _KeyValueList(
          title: 'Run metadata',
          emptyText: 'No technical metadata recorded.',
          rows: rows
              .map((row) => MapEntry(row.key, _safeText(row.value)))
              .toList(growable: false),
        ),
      ],
    );
  }
}

List<MapEntry<String, String>> _layerSummaryRows(
  AiOutputLayer layer,
  AiReviewDecision? latestReview,
) {
  final rows = <MapEntry<String, String>>[
    MapEntry('Layer name', layer.name),
    MapEntry('Layer type', _friendlyLayerTypeLabel(layer.layerType)),
    MapEntry('Status', _friendlyLayerStatusTitle(layer.status)),
    MapEntry('Viewer visibility', _layerVisibilityText(layer)),
    if (layer.description?.trim().isNotEmpty ?? false)
      MapEntry('Description', layer.description!),
    if (layer.crs?.trim().isNotEmpty ?? false) MapEntry('CRS', layer.crs!),
    if (layer.bounds.isNotEmpty)
      const MapEntry('Bounds', 'Recorded in layer metadata'),
    if (layer.createdAt != null)
      MapEntry('Created', formatLebanonDate(layer.createdAt)),
    if (layer.publishedAt != null)
      MapEntry('Published', formatLebanonDate(layer.publishedAt)),
    if (layer.publishedBy?.trim().isNotEmpty ?? false)
      MapEntry('Published by', layer.publishedBy!),
  ];

  if (latestReview != null) {
    rows.add(MapEntry('Review decision', _reviewDecisionSummary(latestReview)));
    if (latestReview.reason?.trim().isNotEmpty ?? false) {
      rows.add(MapEntry('Review reason', latestReview.reason!));
    }
  }

  return rows
      .map((row) => MapEntry(row.key, _safeText(row.value)))
      .toList(growable: false);
}

List<MapEntry<String, String>> _layerTechnicalRows(AiOutputLayer layer) {
  return <MapEntry<String, String>>[
    MapEntry('Layer id', layer.id),
    if (layer.aiRunId?.trim().isNotEmpty ?? false)
      MapEntry('Related run id', layer.aiRunId!),
    if (layer.projectId?.trim().isNotEmpty ?? false)
      MapEntry('Project id', layer.projectId!),
    if (layer.storagePath?.trim().isNotEmpty ?? false)
      MapEntry('Output/storage path', layer.storagePath!),
    if (layer.assetId?.trim().isNotEmpty ?? false)
      MapEntry('Asset id', layer.assetId!),
    if (layer.bounds.isNotEmpty) const MapEntry('Bounds metadata', 'Available'),
    if (layer.style.isNotEmpty) const MapEntry('Style metadata', 'Available'),
    if (layer.updatedAt != null)
      MapEntry('Updated', formatLebanonDate(layer.updatedAt)),
  ].map((row) => MapEntry(row.key, _safeText(row.value))).toList();
}

String _layerVisibilityText(AiOutputLayer layer) {
  if (layer.publishedAt != null || layer.status == 'published') {
    return 'Published';
  }
  return 'Not published';
}

String _reviewDecisionSummary(AiReviewDecision review) {
  final label = _friendlyReviewDecisionLabel(review.decision);
  final actor = _stringValue(review.decidedBy);
  if (actor != null) {
    return '$label by $actor';
  }
  return label;
}

List<MapEntry<String, String>> _includedClassCountRows(AiRun run) {
  final excludedLabels = _excludedClassLabels(run);
  final rows = _countRows(run.metadata['class_counts'])
      .where((row) => !excludedLabels.contains(row.key.toLowerCase()))
      .map((row) => MapEntry(row.key, row.value))
      .toList(growable: false);
  rows.sort(
    (left, right) => left.key.toLowerCase().compareTo(right.key.toLowerCase()),
  );
  return rows;
}

List<MapEntry<String, String>> _excludedClassCountRows(AiRun run) {
  return _countRows(run.metadata['excluded_classes'])
      .map((row) => MapEntry(row.key, '${row.value} below threshold'))
      .toList(growable: false);
}

Set<String> _excludedClassLabels(AiRun run) {
  return _countRows(
    run.metadata['excluded_classes'],
  ).map((row) => row.key.toLowerCase()).toSet();
}

String _executionMode(AiRun run) =>
    _metadataText(run.metadata, 'execution_mode') ?? 'not set';

List<MapEntry<String, String>> _runStatusRows(AiRun run) {
  final rows = <MapEntry<String, String>>[
    MapEntry('Status', _friendlyStatusLabel(run.status)),
    MapEntry(
      'Execution type',
      _friendlyExecutionModeLabel(_executionMode(run)),
    ),
    MapEntry('Started', _formatDate(run.startedAt)),
    MapEntry('Completed', _formatDate(run.completedAt)),
    MapEntry('Duration', _runDuration(run)),
    MapEntry('Label/class field', run.labelField ?? 'Not set'),
    MapEntry('Scope', _friendlyScopeLabel(run.scopeType)),
  ];
  if (run.regionPreset?.trim().isNotEmpty ?? false) {
    rows.add(MapEntry('Region', run.regionPreset!));
  }
  return rows.map((row) => MapEntry(row.key, _safeText(row.value))).toList();
}

String _whatHappenedMessage(String executionMode) {
  switch (executionMode) {
    case 'local_ground_truth_export':
      return 'Prepared approved project data for AI training.';
    case 'regional_feature_extraction':
      return 'Extracted satellite features for approved project samples.';
    case 'regional_model_eval':
      return 'Evaluated regional AI models using approved project data.';
    case 'dry_run':
      return 'Checked the AI pipeline without running model processing.';
    case 'mock':
      return 'Simulated worker processing for a safe app-side check.';
    default:
      return 'Recorded AI run progress for this project.';
  }
}

List<MapEntry<String, String>> _whatHappenedRows(AiRun run) {
  final mode = _executionMode(run);
  final classRows = _countRows(run.metadata['class_counts']);
  final excludedRows = _countRows(run.metadata['excluded_classes']);
  final rows = <MapEntry<String, String>>[];

  switch (mode) {
    case 'local_ground_truth_export':
      rows.addAll([
        MapEntry('Approved samples', '${run.trainingFeatureCount}'),
        MapEntry('Eligible samples', '${run.eligibleFeatureCount}'),
        if (classRows.isNotEmpty) MapEntry('Classes', '${classRows.length}'),
        MapEntry('Excluded samples', '${run.excludedFeatureCount}'),
      ]);
      break;
    case 'regional_feature_extraction':
      rows.addAll([
        MapEntry('Sample count', '${run.eligibleFeatureCount}'),
        MapEntry(
          'Satellite collection',
          _metadataText(run.metadata, 'satellite_collection') ?? 'Sentinel-2',
        ),
        MapEntry('Date range', _featureDateRange(run.metadata)),
        MapEntry('Extracted features', _featureCountText(run.metadata)),
        MapEntry('Missing/null values', _nullValueText(run.metadata)),
      ]);
      break;
    case 'regional_model_eval':
      final summary = _mapValue(run.metadata['model_metrics_summary']);
      rows.addAll([
        MapEntry('Approved samples', '${run.trainingFeatureCount}'),
        MapEntry('Eligible samples', '${run.eligibleFeatureCount}'),
        if (classRows.isNotEmpty) MapEntry('Classes', '${classRows.length}'),
        if (excludedRows.isNotEmpty)
          MapEntry('Excluded classes', '${excludedRows.length}'),
        if (_toIntValue(summary['sample_count']) != null)
          MapEntry(
            'Samples evaluated',
            '${_toIntValue(summary['sample_count'])}',
          ),
      ]);
      break;
    default:
      rows.addAll([
        MapEntry('Approved samples', '${run.trainingFeatureCount}'),
        MapEntry('Eligible samples', '${run.eligibleFeatureCount}'),
        MapEntry('Excluded samples', '${run.excludedFeatureCount}'),
      ]);
      break;
  }

  return rows
      .where((row) => row.value.trim().isNotEmpty)
      .map((row) => MapEntry(row.key, _safeText(row.value)))
      .toList(growable: false);
}

List<MapEntry<String, String>> _modelResultRows(
  AiRun run,
  List<AiRunMetric> metrics,
) {
  final rows = metrics.isNotEmpty
      ? _modelRowsFromMetricRecords(run, metrics)
      : _modelRowsFromMetadata(run);
  if (rows.isNotEmpty) {
    return rows
        .map((row) => MapEntry(row.key, _safeText(row.value)))
        .toList(growable: false);
  }
  if (_firstOutputPath(run.metadata, 'metrics') != null) {
    return const [
      MapEntry('Model metrics file', 'Available in Technical output files.'),
    ];
  }
  return const <MapEntry<String, String>>[];
}

List<MapEntry<String, String>> _modelRowsFromMetricRecords(
  AiRun run,
  List<AiRunMetric> metrics,
) {
  final bestBalanced = _maxMetric(metrics, (metric) => metric.macroF1);
  final highestAccuracy = _maxMetric(
    metrics,
    (metric) => metric.overallAccuracy,
  );
  final selectedModel = _firstString([
    run.selectedModel,
    _metadataText(run.metadata, 'selected_model'),
    _metadataText(run.metadata, 'final_model'),
    _metadataText(run.metadata, 'best_model'),
  ]);
  final selectedMetric =
      _findMetric(metrics, selectedModel) ??
      bestBalanced ??
      highestAccuracy ??
      metrics.first;

  return _compactModelRows(
    bestBalancedModel: bestBalanced?.modelName,
    highestAccuracyModel: highestAccuracy?.modelName,
    finalSelectedModel: selectedModel ?? selectedMetric.modelName,
    accuracy: selectedMetric.overallAccuracy,
    macroF1: selectedMetric.macroF1,
    weightedF1: selectedMetric.weightedF1,
  );
}

List<MapEntry<String, String>> _modelRowsFromMetadata(AiRun run) {
  final summary = _mapValue(run.metadata['model_metrics_summary']);
  if (summary.isEmpty) {
    return const <MapEntry<String, String>>[];
  }
  final models = _modelMetricMaps(summary['models']);
  final bestBalancedModel =
      _firstString([
        _stringValue(summary['best_balanced_model']),
        _stringValue(summary['best_macro_f1_model']),
        _stringValue(summary['best_model_by_macro_f1']),
        _stringValue(summary['model_chosen_by_macro_f1']),
        _stringValue(summary['best_model']),
      ]) ??
      _bestModelName(models, 'macro_f1');
  final highestAccuracyModel =
      _firstString([
        _stringValue(summary['highest_accuracy_model']),
        _stringValue(summary['best_accuracy_model']),
        _stringValue(summary['model_with_highest_accuracy']),
      ]) ??
      _bestModelName(models, 'accuracy');
  final finalSelectedModel = _firstString([
    _stringValue(summary['selected_model']),
    _stringValue(summary['final_model']),
    _stringValue(summary['final_selected_model']),
    run.selectedModel,
    bestBalancedModel,
  ]);
  final selectedMetrics =
      _modelMetricMap(models, finalSelectedModel) ??
      _modelMetricMap(models, bestBalancedModel) ??
      _modelMetricMap(models, highestAccuracyModel) ??
      summary;

  return _compactModelRows(
    bestBalancedModel: bestBalancedModel,
    highestAccuracyModel: highestAccuracyModel,
    finalSelectedModel: finalSelectedModel,
    accuracy: _toDoubleValue(selectedMetrics['accuracy']),
    macroF1: _toDoubleValue(
      selectedMetrics['macro_f1'] ?? selectedMetrics['macroF1'],
    ),
    weightedF1: _toDoubleValue(
      selectedMetrics['weighted_f1'] ?? selectedMetrics['weightedF1'],
    ),
  );
}

List<MapEntry<String, String>> _compactModelRows({
  required String? bestBalancedModel,
  required String? highestAccuracyModel,
  required String? finalSelectedModel,
  required double? accuracy,
  required double? macroF1,
  required double? weightedF1,
}) {
  return <MapEntry<String, String>>[
    if (bestBalancedModel != null)
      MapEntry('Best balanced model', _friendlyModelLabel(bestBalancedModel)),
    if (highestAccuracyModel != null)
      MapEntry(
        'Highest accuracy model',
        _friendlyModelLabel(highestAccuracyModel),
      ),
    if (finalSelectedModel != null)
      MapEntry('Final selected model', _friendlyModelLabel(finalSelectedModel)),
    if (accuracy != null) MapEntry('Accuracy', _formatMetric(accuracy)),
    if (macroF1 != null) MapEntry('Macro-F1', _formatMetric(macroF1)),
    if (weightedF1 != null) MapEntry('Weighted-F1', _formatMetric(weightedF1)),
  ];
}

String _featureDateRange(Map<String, dynamic> metadata) {
  final direct =
      _metadataText(metadata, 'date_range') ??
      _metadataText(metadata, 'satellite_date_range');
  if (direct != null) {
    return direct;
  }
  final start =
      _metadataText(metadata, 'start_date') ??
      _metadataText(metadata, 'date_start');
  final end =
      _metadataText(metadata, 'end_date') ??
      _metadataText(metadata, 'date_end');
  if (start != null || end != null) {
    return '${start ?? 'start unknown'} to ${end ?? 'end unknown'}';
  }
  return 'Configured in AI pipeline';
}

String _featureCountText(Map<String, dynamic> metadata) {
  final count =
      _toIntValue(metadata['extracted_feature_count']) ??
      _toIntValue(metadata['feature_count']) ??
      _toIntValue(metadata['column_count']);
  if (count != null) {
    return count.toString();
  }
  return 'See feature table';
}

String _nullValueText(Map<String, dynamic> metadata) {
  final count =
      _toIntValue(metadata['missing_feature_values']) ??
      _toIntValue(metadata['null_feature_values']) ??
      _toIntValue(metadata['null_value_count']);
  if (count != null) {
    return count.toString();
  }
  return 'See feature extraction summary';
}

String _friendlyExecutionModeLabel(String mode) {
  switch (mode) {
    case 'local_ground_truth_export':
      return 'Ground truth export';
    case 'regional_feature_extraction':
      return 'Regional feature extraction';
    case 'regional_model_eval':
      return 'Regional model evaluation';
    case 'dry_run':
      return 'Dry run';
    case 'mock':
      return 'Mock worker check';
    case 'not set':
      return 'Not set';
    default:
      return _titleCase(mode.replaceAll('_', ' '));
  }
}

String _friendlyStatusLabel(String status) {
  switch (status) {
    case 'ready_for_review':
      return 'Ready for review';
    case 'extracting_features':
      return 'Extracting features';
    default:
      return _titleCase(status.replaceAll('_', ' '));
  }
}

String _friendlyReviewDecisionLabel(String decision) {
  switch (decision) {
    case 'approved_for_publish':
      return 'Approved for future publication';
    case 'rejected':
      return 'Rejected';
    case 'needs_more_data':
      return 'More data requested';
    case 'keep_draft':
      return 'Kept as draft';
    case 'needs_rerun':
      return 'Rerun requested';
    case 'unpublished':
      return 'Unpublished';
    default:
      return _titleCase(decision.replaceAll('_', ' '));
  }
}

String _friendlyLayerStatusLabel(String status) {
  switch (status) {
    case 'ready_for_review':
      return 'ready for review';
    case 'approved':
      return 'approved for future publication';
    case 'rejected':
      return 'rejected';
    case 'published':
      return 'published';
    case 'unpublished':
      return 'unpublished';
    case 'draft':
      return 'draft';
    case 'failed':
      return 'failed';
    default:
      return status.replaceAll('_', ' ');
  }
}

String _friendlyLayerStatusTitle(String status) {
  switch (status) {
    case 'ready_for_review':
      return 'Ready for review';
    case 'approved':
      return 'Approved for future publication';
    case 'rejected':
      return 'Rejected';
    case 'published':
      return 'Published';
    case 'unpublished':
      return 'Not published';
    case 'draft':
      return 'Draft';
    case 'failed':
      return 'Failed';
    default:
      return _titleCase(status.replaceAll('_', ' '));
  }
}

String _friendlyLayerTypeLabel(String layerType) {
  switch (layerType) {
    case 'classification':
      return 'Classification';
    case 'confidence':
      return 'Confidence';
    case 'uncertainty':
      return 'Uncertainty';
    case 'statistics':
      return 'Statistics';
    default:
      return _titleCase(layerType.replaceAll('_', ' '));
  }
}

String _friendlyScopeLabel(String scope) {
  switch (scope) {
    case 'project':
      return 'Project';
    case 'custom_polygon':
      return 'Custom polygon';
    default:
      return _titleCase(scope.replaceAll('_', ' '));
  }
}

String _friendlyModelLabel(String model) {
  final normalized = model.trim().toLowerCase();
  switch (normalized) {
    case 'svm_rbf':
      return 'SVM RBF';
    case 'random_forest':
      return 'Random Forest';
    case 'xgboost':
      return 'XGBoost';
    default:
      return _titleCase(model.replaceAll('_', ' '));
  }
}

String _modelMetricSummary(AiRunMetric metric) {
  final parts = <String>[
    if (metric.overallAccuracy != null)
      'Accuracy ${_formatMetric(metric.overallAccuracy)}',
    if (metric.macroF1 != null) 'Macro-F1 ${_formatMetric(metric.macroF1)}',
    if (metric.weightedF1 != null)
      'Weighted-F1 ${_formatMetric(metric.weightedF1)}',
  ];
  return parts.isEmpty ? 'Metrics recorded' : parts.join(', ');
}

AiRunMetric? _maxMetric(
  List<AiRunMetric> metrics,
  double? Function(AiRunMetric metric) selector,
) {
  AiRunMetric? best;
  double? bestValue;
  for (final metric in metrics) {
    final value = selector(metric);
    if (value == null) {
      continue;
    }
    if (bestValue == null || value > bestValue) {
      best = metric;
      bestValue = value;
    }
  }
  return best;
}

AiRunMetric? _findMetric(List<AiRunMetric> metrics, String? modelName) {
  final normalized = _normalizedModelName(modelName);
  if (normalized == null) {
    return null;
  }
  for (final metric in metrics) {
    if (_normalizedModelName(metric.modelName) == normalized) {
      return metric;
    }
  }
  return null;
}

Map<String, Map<String, dynamic>> _modelMetricMaps(dynamic value) {
  final result = <String, Map<String, dynamic>>{};
  final models = _mapValue(value);
  for (final entry in models.entries) {
    final name = _stringValue(entry.key);
    final normalized = _normalizedModelName(name);
    final metrics = _mapValue(entry.value);
    if (normalized != null && metrics.isNotEmpty) {
      result[normalized] = metrics;
    }
  }
  return result;
}

Map<String, dynamic>? _modelMetricMap(
  Map<String, Map<String, dynamic>> models,
  String? modelName,
) {
  final normalized = _normalizedModelName(modelName);
  if (normalized == null) {
    return null;
  }
  return models[normalized];
}

String? _bestModelName(
  Map<String, Map<String, dynamic>> models,
  String metricKey,
) {
  String? bestName;
  double? bestValue;
  for (final entry in models.entries) {
    final value = _toDoubleValue(entry.value[metricKey]);
    if (value == null) {
      continue;
    }
    if (bestValue == null || value > bestValue) {
      bestName = entry.key;
      bestValue = value;
    }
  }
  return bestName;
}

String? _firstString(Iterable<String?> values) {
  for (final value in values) {
    final text = _stringValue(value);
    if (text != null) {
      return text;
    }
  }
  return null;
}

String? _normalizedModelName(String? value) {
  final text = _stringValue(value);
  if (text == null) {
    return null;
  }
  return text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').trim();
}

String _statusExplanation(AiRun run) {
  switch (run.status) {
    case 'ready_for_review':
      return 'Ready for review.';
    case 'failed':
      return 'This run failed. Review the failure reason and worker logs.';
    case 'draft':
      return 'Draft run record only. No worker processing has started.';
    case 'queued':
      return 'Queued for the worker.';
    case 'extracting_features':
      return 'The worker is extracting satellite features.';
    case 'training':
      return 'The worker is training regional models.';
    case 'evaluating':
      return 'The worker is evaluating model results.';
    case 'published':
      return 'Published for app users.';
    case 'cancelled':
      return 'This run was cancelled.';
    default:
      return '${_friendlyStatusLabel(run.status)}.';
  }
}

List<MapEntry<String, String>> _countRows(dynamic value) {
  final rows = <MapEntry<String, String>>[];
  final items = value is List ? value : const <dynamic>[];
  for (final item in items) {
    final map = _mapValue(item);
    final label =
        _stringValue(map['class_label']) ?? _stringValue(map['label']);
    final count =
        _toIntValue(map['sample_count']) ??
        _toIntValue(map['feature_count']) ??
        _toIntValue(map['count']);
    if (label != null && count != null) {
      rows.add(MapEntry(label, '$count samples'));
    }
  }
  return rows;
}

List<String> _limitationMessages(AiRun run) {
  final messages = <String>{};
  if (_isRegionalRun(run)) {
    messages.add('This is a regional proof-of-concept, not a national model.');
    messages.add('South Lebanon only.');
    messages.add('National AI requires wider Lebanon coverage.');
  }
  for (final value in _stringList(run.metadata['scientific_limitations'])) {
    final lower = value.toLowerCase();
    if (lower.contains('national')) {
      messages.add('National AI requires wider Lebanon coverage.');
    } else if (lower.contains('regional')) {
      messages.add(
        'This is a regional proof-of-concept, not a national model.',
      );
    }
  }
  final summary = _mapValue(run.metadata['model_metrics_summary']);
  for (final value in _stringList(summary['warnings'])) {
    final lower = value.toLowerCase();
    if (lower.contains('vineyard')) {
      messages.add(
        'Vineyards were excluded because only 12 samples are available.',
      );
    } else if (lower.contains('fruit trees') || lower.contains('broad')) {
      messages.add('Fruit Trees is a broad class.');
    } else if (lower.contains('national') || lower.contains('south')) {
      messages.add('National AI requires wider Lebanon coverage.');
    } else {
      messages.add(value);
    }
  }
  return messages.map(_safeText).toList(growable: false);
}

List<String> _outputPaths(Map<String, dynamic> metadata) {
  final paths = <String>{};
  void collect(dynamic value, [String key = '']) {
    if (value == null) {
      return;
    }
    if (value is String) {
      final normalized = value.replaceAll('\\', '/').trim();
      if (normalized.contains('outputs/')) {
        paths.add(normalized);
      }
      return;
    }
    if (value is List) {
      for (final item in value) {
        collect(item, key);
      }
      return;
    }
    if (value is Map) {
      for (final entry in value.entries) {
        collect(entry.value, entry.key.toString());
      }
    }
  }

  collect(metadata);
  return paths.toList()..sort();
}

String? _firstOutputPath(Map<String, dynamic> metadata, String contains) {
  final needle = contains.toLowerCase();
  for (final path in _outputPaths(metadata)) {
    if (path.toLowerCase().contains(needle)) {
      return path;
    }
  }
  return null;
}

String _friendlyOutputPathLabel(String path) {
  final parts = path.split('/').where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty) {
    return 'Output file';
  }
  final file = parts.last;
  if (file == 'feature_table.csv') return 'Feature table';
  if (file == 'metrics.json') return 'Metrics file';
  if (file == 'confusion_matrix.csv') return 'Confusion matrix';
  if (file == 'model_metadata.json') return 'Model metadata';
  if (file == 'classification_report.csv') return 'Classification report';
  if (file == 'feature_importance.csv') return 'Feature importance';
  if (file == 'feature_extraction_summary.json') {
    return 'Feature extraction summary';
  }
  if (file == 'ground_truth.geojson') return 'Ground truth';
  return file;
}

bool _isRegionalRun(AiRun run) {
  final executionMode = _metadataText(run.metadata, 'execution_mode') ?? '';
  return executionMode.startsWith('regional_') ||
      _stringList(
        run.metadata['scientific_limitations'],
      ).any((message) => message.toLowerCase().contains('regional'));
}

String _runDuration(AiRun run) {
  final durationMs =
      _toIntValue(run.metadata['duration_ms']) ??
      _toIntValue(
        _mapValue(run.metadata['model_metrics_summary'])['duration_ms'],
      );
  if (durationMs != null) {
    return _formatDurationMs(durationMs);
  }
  if (run.startedAt != null && run.completedAt != null) {
    return _formatDuration(run.completedAt!.difference(run.startedAt!));
  }
  return 'Unknown';
}

String _formatDurationMs(int? durationMs) {
  if (durationMs == null) {
    return '';
  }
  return _formatDuration(Duration(milliseconds: durationMs));
}

String _formatDuration(Duration duration) {
  if (duration.inMinutes >= 1) {
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${duration.inMinutes}m ${seconds}s';
  }
  if (duration.inSeconds >= 1) {
    return '${duration.inSeconds}s';
  }
  return '${duration.inMilliseconds}ms';
}

String _formatDate(DateTime? date) =>
    date == null ? 'Unknown' : formatLebanonDate(date);

String _formatMetric(double? value) =>
    value == null ? 'n/a' : value.toStringAsFixed(3);

String? _metadataText(Map<String, dynamic> metadata, String key) =>
    _stringValue(metadata[key]);

Map<String, dynamic> _mapValue(dynamic value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return const <String, dynamic>{};
}

String? _stringValue(dynamic value) {
  if (value == null) {
    return null;
  }
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

int? _toIntValue(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}

double? _toDoubleValue(dynamic value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}

List<String> _stringList(dynamic value) {
  if (value is List) {
    return value
        .map((item) => item?.toString().trim())
        .whereType<String>()
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }
  return const <String>[];
}

String _safeText(String value) {
  var text = value;
  final replacements = <RegExp>[
    RegExp(
      '-----BEGIN [^-]+PRIVATE KEY-----.*?-----END [^-]+PRIVATE KEY-----',
      caseSensitive: false,
      dotAll: true,
    ),
    RegExp(
      r'(password|secret|private[_-]?key|api[_-]?key)\s*[:=]\s*[^,\s}]+',
      caseSensitive: false,
    ),
    RegExp(r'(GEE[-_ ]?KEY[/\\][^,\s}]+)', caseSensitive: false),
  ];
  for (final pattern in replacements) {
    text = text.replaceAll(pattern, '[redacted]');
  }
  return text;
}

class _KeyValueList extends StatelessWidget {
  const _KeyValueList({
    required this.title,
    required this.rows,
    this.emptyText = 'No data available.',
  });

  final String title;
  final List<MapEntry<String, String>> rows;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        if (rows.isEmpty)
          Text(emptyText)
        else
          ...rows.map(
            (row) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: row.key),
                    const TextSpan(text: ': '),
                    TextSpan(
                      text: row.value,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                softWrap: true,
              ),
            ),
          ),
      ],
    );
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({required this.title, required this.messages});

  final String title;
  final List<String> messages;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        for (final message in messages)
          _NoticeRow(icon: Icons.info_outline, text: message),
      ],
    );
  }
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: AppSpacing.xs),
          Expanded(child: Text(text, softWrap: true)),
        ],
      ),
    );
  }
}

extension on AiProjectSettings {
  String get updatedKey =>
      '${isEnabled ? 1 : 0}:$scopeType:$minSamplesPerClass:${modelPreferences.hashCode}';
}

String _normalizedSection(String value) {
  if (value == 'settings' || value == 'runs') {
    return value;
  }
  return 'readiness';
}

String _titleCase(String value) {
  return value
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .map((word) {
        if (word.length <= 1) {
          return word.toUpperCase();
        }
        return '${word.substring(0, 1).toUpperCase()}${word.substring(1)}';
      })
      .join(' ');
}

String _formatExtent(AiSpatialExtent extent) {
  return '${extent.minLon.toStringAsFixed(4)}, ${extent.minLat.toStringAsFixed(4)} to ${extent.maxLon.toStringAsFixed(4)}, ${extent.maxLat.toStringAsFixed(4)}';
}

class _LabelFieldOption {
  const _LabelFieldOption({
    required this.key,
    required this.label,
    this.enabled = true,
    this.recommended = false,
    this.labeledFeatureCount = 0,
    this.classCount = 0,
  });

  final String key;
  final String label;
  final bool enabled;
  final bool recommended;
  final int labeledFeatureCount;
  final int classCount;
}

List<_LabelFieldOption> _labelFieldOptions(
  ProjectSummary project,
  String? current,
  List<AiLabelFieldCandidate> candidates,
) {
  final currentField = current?.trim();
  final fields = <String, AiLabelFieldCandidate?>{};

  final selectableCandidates = candidates
      .where((candidate) => candidate.usable && candidate.selectable)
      .toList(growable: false);
  if (selectableCandidates.isNotEmpty) {
    for (final candidate in selectableCandidates) {
      final key = candidate.field.trim();
      if (key.isNotEmpty) {
        fields[key] = candidate;
      }
    }
  } else {
    final fallbackKey = _schemaPreferredLabelField(project);
    for (final field in project.collectionFormSchema.fields) {
      final key = _schemaClassifierKey(field);
      if (key.isNotEmpty &&
          field.type == CollectionFieldType.select &&
          (fallbackKey == null || key == fallbackKey)) {
        fields[key] = null;
      }
    }
    if (fields.isEmpty) {
      for (final field in project.collectionFormSchema.fields) {
        final key = _schemaClassifierKey(field);
        if (key.isNotEmpty && field.type == CollectionFieldType.select) {
          fields[key] = null;
        }
      }
    }
  }

  if (candidates.isEmpty && currentField?.isNotEmpty == true) {
    fields.putIfAbsent(currentField!, () => null);
  }

  final options = fields.entries
      .map((entry) {
        final candidate = entry.value;
        final hasProbe = candidate != null;
        final enabled = !hasProbe || (candidate.usable && candidate.selectable);
        final suffix = candidate?.recommended == true
            ? 'recommended'
            : !enabled
            ? 'no labels'
            : 'available';
        return _LabelFieldOption(
          key: entry.key,
          label: '${entry.key} - $suffix',
          enabled: enabled,
          recommended: candidate?.recommended ?? false,
          labeledFeatureCount: candidate?.labeledFeatureCount ?? 0,
          classCount: candidate?.classCount ?? 0,
        );
      })
      .toList(growable: false);

  options.sort((left, right) {
    if (left.recommended != right.recommended) {
      return left.recommended ? -1 : 1;
    }
    if (left.enabled != right.enabled) {
      return left.enabled ? -1 : 1;
    }
    if (left.labeledFeatureCount != right.labeledFeatureCount) {
      return right.labeledFeatureCount.compareTo(left.labeledFeatureCount);
    }
    return left.key.compareTo(right.key);
  });

  return options;
}

String? _preferredLabelField(ProjectSummary project) {
  return _schemaPreferredLabelField(project);
}

String? _schemaPreferredLabelField(ProjectSummary project) {
  for (final field in project.collectionFormSchema.fields) {
    final key = _schemaClassifierKey(field);
    if (key.isNotEmpty &&
        field.required &&
        field.type == CollectionFieldType.select) {
      return key;
    }
  }
  for (final field in project.collectionFormSchema.fields) {
    final key = _schemaClassifierKey(field);
    if (key.isNotEmpty && field.type == CollectionFieldType.select) {
      return key;
    }
  }
  for (final field in project.collectionFormSchema.fields) {
    final key = _schemaClassifierKey(field);
    if (key.isNotEmpty) {
      return key;
    }
  }
  return null;
}

String _schemaClassifierKey(CollectionFormFieldSchema field) {
  final label = field.label.trim();
  if (_looksLikeAttributeKey(label) && label != field.key.trim()) {
    return label;
  }
  return field.key.trim();
}

bool _looksLikeAttributeKey(String value) {
  return RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(value);
}

String? _selectedLabelField(List<_LabelFieldOption> options, String? current) {
  final currentField = current?.trim();
  if (currentField?.isNotEmpty == true &&
      options.any((option) => option.key == currentField && option.enabled)) {
    return currentField;
  }
  for (final option in options) {
    if (option.recommended && option.enabled) {
      return option.key;
    }
  }
  for (final option in options) {
    if (option.enabled) {
      return option.key;
    }
  }
  return options.isEmpty ? null : options.first.key;
}

_LabelFieldOption? _optionFor(
  List<_LabelFieldOption> options,
  String? current,
) {
  final currentField = current?.trim();
  if (currentField == null || currentField.isEmpty) {
    return null;
  }
  for (final option in options) {
    if (option.key == currentField) {
      return option;
    }
  }
  return null;
}
