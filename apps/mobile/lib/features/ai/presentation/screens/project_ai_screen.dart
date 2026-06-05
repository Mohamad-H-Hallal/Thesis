import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
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
                    'AI uses approved project data. Worker execution is not connected yet.',
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
                subtitle: const Text('Worker execution is not connected yet.'),
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
                'View AI run records. Worker execution is not connected yet.',
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
          'Draft AI run record created. Worker not connected yet.',
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
            _KeyValueList(
              title: 'Summary',
              rows: [
                MapEntry('Label field', run.labelField ?? 'Not set'),
                MapEntry('Scope', _formatValue(run.scopeType)),
                MapEntry('Training features', '${run.trainingFeatureCount}'),
                MapEntry('Eligible features', '${run.eligibleFeatureCount}'),
                MapEntry('Selected model', run.selectedModel ?? 'Not selected'),
                MapEntry(
                  'Created',
                  run.createdAt == null
                      ? 'Unknown'
                      : formatLebanonDate(run.createdAt),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _AsyncCountSection(
              title: 'Metrics',
              emptyText: 'No metrics yet. The worker is not connected.',
              asyncValue: metricsAsync,
              labelFor: (metric) => metric.modelName,
            ),
            const SizedBox(height: AppSpacing.md),
            _AsyncCountSection(
              title: 'AI output layers',
              emptyText: 'No AI layers yet. Nothing is published to viewers.',
              asyncValue: layersAsync,
              labelFor: (layer) => layer.name,
            ),
            const SizedBox(height: AppSpacing.md),
            logsAsync.when(
              loading: () => const LinearProgressIndicator(),
              error: (error, _) => Text(
                userFacingErrorMessage(
                  error,
                  fallback: 'Unable to load run logs.',
                ),
              ),
              data: (page) => _KeyValueList(
                title: 'Logs',
                emptyText: 'No logs yet.',
                rows: page.items
                    .map((log) => MapEntry(log.level, log.message))
                    .toList(growable: false),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AsyncCountSection<T> extends StatelessWidget {
  const _AsyncCountSection({
    required this.title,
    required this.emptyText,
    required this.asyncValue,
    required this.labelFor,
  });

  final String title;
  final String emptyText;
  final AsyncValue<List<T>> asyncValue;
  final String Function(T item) labelFor;

  @override
  Widget build(BuildContext context) {
    return asyncValue.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, _) => Text(
        userFacingErrorMessage(error, fallback: 'Unable to load $title.'),
      ),
      data: (items) => _KeyValueList(
        title: title,
        emptyText: emptyText,
        rows: items
            .map((item) => MapEntry(labelFor(item), 'available'))
            .toList(growable: false),
      ),
    );
  }
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
