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
                        '${_formatValue(run.status)} - ${run.labelField ?? 'No label'} - ${run.eligibleFeatureCount} eligible',
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
                    'Run details',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                StatusChip(status: run.status),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (_isRegionalRun(run)) ...[
              const _NoticeRow(
                icon: Icons.travel_explore_outlined,
                text:
                    'This is a regional proof-of-concept, not a national model.',
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            _KeyValueList(title: 'Summary', rows: _runSummaryRows(run)),
            if (run.failureReason?.trim().isNotEmpty ?? false) ...[
              const SizedBox(height: AppSpacing.md),
              _NoticeRow(
                icon: Icons.error_outline,
                text: 'Failure reason: ${_safeText(run.failureReason!)}',
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            _OutputPathsSection(paths: _outputPaths(run.metadata)),
            const SizedBox(height: AppSpacing.md),
            _MetricsSection(run: run, asyncValue: metricsAsync),
            const SizedBox(height: AppSpacing.md),
            _ClassCountsSection(run: run),
            const SizedBox(height: AppSpacing.md),
            _LayerSection(asyncValue: layersAsync),
            const SizedBox(height: AppSpacing.md),
            _LimitationSection(run: run),
            const SizedBox(height: AppSpacing.md),
            _LogsSection(asyncValue: logsAsync),
            const SizedBox(height: AppSpacing.sm),
            _TechnicalDetailsSection(run: run),
          ],
        ),
      ),
    );
  }
}

class _OutputPathsSection extends StatelessWidget {
  const _OutputPathsSection({required this.paths});

  final List<String> paths;

  @override
  Widget build(BuildContext context) {
    return _KeyValueList(
      title: 'Output paths',
      emptyText: 'No output paths recorded yet.',
      rows: paths
          .map((path) => MapEntry(_outputPathLabel(path), _safeText(path)))
          .toList(growable: false),
    );
  }
}

class _MetricsSection extends StatelessWidget {
  const _MetricsSection({required this.run, required this.asyncValue});

  final AiRun run;
  final AsyncValue<List<AiRunMetric>> asyncValue;

  @override
  Widget build(BuildContext context) {
    return asyncValue.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, _) => Text(
        userFacingErrorMessage(error, fallback: 'Unable to load AI metrics.'),
      ),
      data: (metrics) {
        final rows = _metricRows(run, metrics);
        if (rows.isEmpty) {
          return const _KeyValueList(
            title: 'Model metrics',
            emptyText:
                'Model metrics will appear after a regional model evaluation run.',
            rows: [],
          );
        }
        return _KeyValueList(title: 'Model metrics', rows: rows);
      },
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

class _LayerSection extends StatelessWidget {
  const _LayerSection({required this.asyncValue});

  final AsyncValue<List<AiOutputLayer>> asyncValue;

  @override
  Widget build(BuildContext context) {
    return asyncValue.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, _) => Text(
        userFacingErrorMessage(error, fallback: 'Unable to load AI layers.'),
      ),
      data: (layers) {
        if (layers.isEmpty) {
          return const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _KeyValueList(
                title: 'AI output layers',
                emptyText: 'No published AI layers yet.',
                rows: [],
              ),
              SizedBox(height: AppSpacing.xs),
              _NoticeRow(
                icon: Icons.layers_outlined,
                text: 'AI map layers are planned for the next phase.',
              ),
            ],
          );
        }
        return _KeyValueList(
          title: 'AI output layers',
          rows: layers
              .map(
                (layer) => MapEntry(
                  layer.name,
                  '${_formatValue(layer.layerType)} - ${_formatValue(layer.status)}',
                ),
              )
              .toList(growable: false),
        );
      },
    );
  }
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
    return asyncValue.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, _) => Text(
        userFacingErrorMessage(error, fallback: 'Unable to load run logs.'),
      ),
      data: (page) {
        if (page.items.isEmpty) {
          return const _KeyValueList(
            title: 'Logs',
            emptyText: 'No logs yet.',
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
      title: const Text('Technical details'),
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

List<MapEntry<String, String>> _runSummaryRows(AiRun run) {
  final executionMode = _metadataText(run.metadata, 'execution_mode');
  return [
    MapEntry('Status', _formatValue(run.status)),
    MapEntry('Execution mode', _formatValue(executionMode ?? 'not set')),
    MapEntry('Label field', run.labelField ?? 'Not set'),
    MapEntry('Scope', _formatValue(run.scopeType)),
    if (run.regionPreset?.trim().isNotEmpty ?? false)
      MapEntry('Region preset', run.regionPreset!),
    MapEntry('Training features', '${run.trainingFeatureCount}'),
    MapEntry('Eligible features', '${run.eligibleFeatureCount}'),
    MapEntry('Excluded features', '${run.excludedFeatureCount}'),
    MapEntry('Selected model', run.selectedModel ?? 'Not selected'),
    MapEntry('Duration', _runDuration(run)),
    MapEntry('Created', _formatDate(run.createdAt)),
    MapEntry('Started', _formatDate(run.startedAt)),
    MapEntry('Completed', _formatDate(run.completedAt)),
  ];
}

List<MapEntry<String, String>> _metricRows(
  AiRun run,
  List<AiRunMetric> metrics,
) {
  final summary = _mapValue(run.metadata['model_metrics_summary']);
  final rows = <MapEntry<String, String>>[];
  final bestModel = _stringValue(summary['best_model']);
  if (bestModel != null) {
    rows.add(MapEntry('Best model', _formatValue(bestModel)));
  }
  final sampleCount = _toIntValue(summary['sample_count']);
  if (sampleCount != null) {
    rows.add(MapEntry('Samples evaluated', sampleCount.toString()));
  }
  final trainCount = _toIntValue(summary['train_count']);
  final testCount = _toIntValue(summary['test_count']);
  if (trainCount != null || testCount != null) {
    rows.add(
      MapEntry(
        'Train/test split',
        '${trainCount ?? 'unknown'} / ${testCount ?? 'unknown'}',
      ),
    );
  }
  final droppedNullRows = _toIntValue(summary['dropped_null_rows']);
  if (droppedNullRows != null) {
    rows.add(MapEntry('Dropped null rows', droppedNullRows.toString()));
  }
  final modelRows = _modelMetricRows(summary['models']);
  if (modelRows.isNotEmpty) {
    rows.addAll(modelRows);
  }
  if (rows.isEmpty && metrics.isNotEmpty) {
    for (final metric in metrics) {
      rows.add(
        MapEntry(
          metric.modelName,
          [
            if (metric.overallAccuracy != null)
              'accuracy ${_formatMetric(metric.overallAccuracy)}',
            if (metric.macroF1 != null)
              'macro-F1 ${_formatMetric(metric.macroF1)}',
            if (metric.weightedF1 != null)
              'weighted-F1 ${_formatMetric(metric.weightedF1)}',
          ].join(', '),
        ),
      );
    }
  }
  final confusionPath = _firstOutputPath(run.metadata, 'confusion_matrix');
  if (confusionPath != null) {
    rows.add(MapEntry('Confusion matrix', confusionPath));
  }
  final importancePath = _firstOutputPath(run.metadata, 'feature_importance');
  if (importancePath != null) {
    rows.add(MapEntry('Feature importance', importancePath));
  }
  return rows
      .map((row) => MapEntry(row.key, _safeText(row.value)))
      .toList(growable: false);
}

List<MapEntry<String, String>> _modelMetricRows(dynamic value) {
  final models = _mapValue(value);
  final rows = <MapEntry<String, String>>[];
  for (final entry in models.entries) {
    final metrics = _mapValue(entry.value);
    final values = <String>[
      if (_toDoubleValue(metrics['accuracy']) != null)
        'accuracy ${_formatMetric(_toDoubleValue(metrics['accuracy']))}',
      if (_toDoubleValue(metrics['macro_f1']) != null)
        'macro-F1 ${_formatMetric(_toDoubleValue(metrics['macro_f1']))}',
      if (_toDoubleValue(metrics['weighted_f1']) != null)
        'weighted-F1 ${_formatMetric(_toDoubleValue(metrics['weighted_f1']))}',
    ];
    if (values.isNotEmpty) {
      rows.add(MapEntry(_formatValue(entry.key), values.join(', ')));
    }
  }
  return rows;
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
    messages.add(
      'Regional proof-of-concept only. Do not use as a national model.',
    );
  }
  for (final value in _stringList(run.metadata['scientific_limitations'])) {
    messages.add(value);
  }
  final summary = _mapValue(run.metadata['model_metrics_summary']);
  for (final value in _stringList(summary['warnings'])) {
    messages.add(value);
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

String _outputPathLabel(String path) {
  final parts = path.split('/').where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty) {
    return 'Output';
  }
  final file = parts.last;
  if (file == 'feature_table.csv') return 'Feature table';
  if (file == 'metrics.json') return 'Metrics';
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

String _formatValue(String value) => value.replaceAll('_', ' ');

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
