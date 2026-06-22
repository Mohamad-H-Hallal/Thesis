import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/pagination/paginated_list_controller.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/utils/lebanon_time.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_dialog_actions.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/progressive_list_section.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../../map/domain/app_tile_provider.dart';
import '../../../map/domain/lebanon_map.dart';
import '../../../map/domain/map_geometry.dart';
import '../../../exports/presentation/screens/exports_dashboard_screen.dart';
import '../../../projects/domain/project.dart';
import '../../domain/ai_models.dart';
import '../ai_model_labels.dart';
import '../ai_permissions.dart';
import '../ai_providers.dart';

class ProjectAiScreen extends ConsumerStatefulWidget {
  const ProjectAiScreen({
    required this.projectId,
    this.initialSection = 'readiness',
    this.initialRunId,
    super.key,
  });

  final String projectId;
  final String initialSection;
  final String? initialRunId;

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
                    'AI uses approved project data. AI server runs appear here with live status and review results.',
                  ),
                  const SizedBox(height: AppSpacing.md),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minWidth: constraints.maxWidth,
                          ),
                          child: SegmentedButton<String>(
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
                        ),
                      );
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
            else if (_section == 'runs')
              ProjectAiRunsSection(
                project: project,
                initialRunId: widget.initialRunId,
              ),
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
      'warning' => 'A regional run can be started, but review the limits.',
      _ => 'Resolve blockers before starting an AI run.',
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
          const SizedBox(height: AppSpacing.sm),
          _NoticeRow(
            icon: readiness.aiServer.isConnected
                ? Icons.cloud_done_outlined
                : Icons.cloud_off_outlined,
            text: _aiServerReadinessMessage(readiness.aiServer),
          ),
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
          AppButton(
            label: refreshing ? 'Refreshing...' : 'Refresh readiness',
            icon: Icons.refresh,
            isLoading: refreshing,
            onPressed: refreshing ? null : onRefresh,
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

String _aiServerReadinessMessage(AiServerReadiness aiServer) {
  if (!aiServer.configured) {
    return 'AI server URL is not configured on the backend.';
  }
  if (aiServer.isConnected) {
    return 'AI server connected.';
  }
  if (aiServer.status == 'degraded') {
    final detail = aiServer.message?.trim();
    return detail == null || detail.isEmpty
        ? 'AI server health is degraded. Refresh readiness after fixing the AI server.'
        : 'AI server health is degraded. $detail';
  }
  return 'AI server is unavailable. Start the AI server and refresh readiness.';
}

class _SeasonDateRange {
  const _SeasonDateRange({this.from, this.to});

  final DateTime? from;
  final DateTime? to;

  _SeasonDateRange copyWith({DateTime? from, DateTime? to}) {
    return _SeasonDateRange(from: from ?? this.from, to: to ?? this.to);
  }
}

class _SatelliteTimeframeState {
  _SatelliteTimeframeState({
    required this.mapYear,
    Set<String>? seasons,
    Map<String, _SeasonDateRange>? ranges,
  }) : seasons = seasons ?? <String>{'growing'},
       ranges = ranges ?? <String, _SeasonDateRange>{};

  int mapYear;
  final Set<String> seasons;
  final Map<String, _SeasonDateRange> ranges;
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
  static const List<String> _satelliteOptions = <String>[
    'sentinel2',
    'landsat',
  ];
  static const Map<String, String> _satelliteLabels = <String, String>{
    'sentinel2': 'Sentinel-2',
    'landsat': 'Landsat',
  };
  static const List<String> _seasonOptions = <String>[
    'growing',
    'dry',
    'harvest',
    'winter',
  ];
  static const Map<String, String> _seasonLabels = <String, String>{
    'growing': 'Growing',
    'dry': 'Dry',
    'harvest': 'Harvest',
    'winter': 'Winter',
  };
  static const List<String> _sentinel2Features = <String>[
    'B2',
    'B3',
    'B4',
    'B5',
    'B6',
    'B7',
    'B8',
    'B8A',
    'B11',
    'B12',
  ];
  static const List<String> _landsatFeatures = <String>[
    'SR_B2',
    'SR_B3',
    'SR_B4',
    'SR_B5',
    'SR_B6',
    'SR_B7',
  ];
  static const List<String> _sentinel2IndexFeatures = <String>[
    'NDVI',
    'EVI',
    'NDRE',
    'SAVI',
    'NDWI',
  ];
  static const List<String> _landsatIndexFeatures = <String>[
    'NDVI',
    'EVI',
    'SAVI',
    'NDWI',
  ];
  static const List<String> _staticFeatureInputs = <String>[
    'static_srtm_elevation',
    'static_srtm_slope',
    'static_srtm_aspect',
    'static_texture_pc1',
  ];
  static const List<String> _defaultSentinel2FeatureInputs = <String>[
    'B2',
    'B3',
    'B4',
    'B5',
    'B8',
    'B11',
    'B12',
    'NDVI',
    'EVI',
    'NDRE',
  ];
  static const List<String> _defaultLandsatFeatureInputs = <String>[
    'SR_B2',
    'SR_B3',
    'SR_B4',
    'SR_B5',
    'SR_B6',
    'SR_B7',
    'NDVI',
    'EVI',
    'SAVI',
    'NDWI',
  ];
  static const Map<String, List<String>> _seasonRanges = <String, List<String>>{
    'growing': <String>['03-01', '06-30'],
    'dry': <String>['06-01', '08-31'],
    'harvest': <String>['08-01', '10-31'],
    'winter': <String>['12-01', '02-28'],
  };
  static const String _textureDependencyMessage =
      'Texture feature static_texture_pc1 requires Sentinel-2 dry season and NDVI. Add a Sentinel-2 dry season/timeframe and select NDVI, or remove static_texture_pc1.';

  bool _isEnabled = false;
  String? _labelField;
  String _scopeType = 'project';
  int _aiAreaDropdownVersion = 0;
  bool _nationalScopeWarningAcknowledged = false;
  String _preferredModel = 'auto';
  Set<String> _selectedSatelliteSources = <String>{'sentinel2'};
  final Map<String, _SatelliteTimeframeState> _satelliteTimeframes =
      <String, _SatelliteTimeframeState>{};
  Set<String> _selectedFeatureInputs = Set<String>.from(
    _defaultSentinel2FeatureInputs,
  );
  Set<String> _skippedFeatureInputs = <String>{};
  Map<String, dynamic>? _customScopeGeometry;
  final TextEditingController _minSamplesController = TextEditingController();
  final TextEditingController _confidenceThresholdController =
      TextEditingController();
  final GlobalKey _featureInputsKey = GlobalKey();
  String? _initializedFor;
  bool _saving = false;

  @override
  void dispose() {
    _minSamplesController.dispose();
    _confidenceThresholdController.dispose();
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
        final minSamples =
            int.tryParse(_minSamplesController.text.trim()) ?? 50;
        final labelProbeQuery = AiReadinessQuery(
          projectId: widget.project.id,
          labelField: _labelField ?? _schemaPreferredLabelField(widget.project),
          minSamplesPerClass: minSamples,
          scopeType: _scopeType,
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
        final readiness = labelProbeAsync.asData?.value;
        final nationalScopeEligibility = readiness?.nationalScopeEligibility;
        final validationMessage = _settingsValidationMessage();
        final selectedSources = _orderedSelectedSatelliteSources();

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
                  'Settings are saved for AI server runs but do not start one.',
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
              KeyedSubtree(
                key: const ValueKey<String>('ai-area-dropdown'),
                child: DropdownButtonFormField<String>(
                  key: ValueKey<String>(
                    'ai-area-dropdown-field-$_scopeType-$_aiAreaDropdownVersion',
                  ),
                  initialValue: _scopeType,
                  decoration: const InputDecoration(labelText: 'AI area'),
                  items: [
                    const DropdownMenuItem(
                      value: 'project',
                      child: Text('Project area'),
                    ),
                    const DropdownMenuItem(
                      value: 'custom_polygon',
                      child: Text('Custom AI area'),
                    ),
                    DropdownMenuItem(
                      value: 'national',
                      enabled: false,
                      child: Text('National Lebanon (not available)'),
                    ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) => _handleAiAreaChanged(
                          value,
                          nationalScopeEligibility: nationalScopeEligibility,
                        ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              _ProjectAreaScopeSummary(
                scopeType: _scopeType,
                readiness: readiness,
                hasCustomGeometry: _customScopeGeometry != null,
              ),
              if (nationalScopeEligibility != null) ...[
                const SizedBox(height: AppSpacing.sm),
                _NationalCoverageCard(
                  eligibility: nationalScopeEligibility,
                  weakClasses:
                      readiness?.classesBelowMinimum ?? const <AiLabelCount>[],
                  minSamplesPerClass:
                      readiness?.minSamplesPerClass ??
                      int.tryParse(_minSamplesController.text.trim()) ??
                      50,
                ),
              ],
              if (_scopeType == 'custom_polygon') ...[
                const SizedBox(height: AppSpacing.sm),
                AppButton(
                  label: _customScopeGeometry == null
                      ? 'Draw AI area'
                      : 'Edit AI area',
                  icon: Icons.polyline_outlined,
                  onPressed: _saving ? null : _drawCustomScope,
                ),
                if (_customScopeGeometry != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  const _NoticeRow(
                    icon: Icons.check_circle_outline,
                    text: 'Custom AI scope polygon saved with these settings.',
                  ),
                ],
              ],
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
              TextFormField(
                controller: _confidenceThresholdController,
                enabled: !_saving,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Confidence threshold',
                  helperText:
                      'Probability scale from 0 to 1. Used as metadata/priority, not a validation filter.',
                  hintText: '0.60',
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
                  DropdownMenuItem(
                    value: 'svm',
                    child: Text('Support Vector Machine'),
                  ),
                  DropdownMenuItem(
                    value: 'gradient_boosting',
                    child: Text('Gradient Boosting'),
                  ),
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _preferredModel = value);
                        }
                      },
              ),
              if (_preferredModel == 'auto') ...[
                const SizedBox(height: AppSpacing.xs),
                const _NoticeRow(
                  icon: Icons.auto_awesome_outlined,
                  text: 'Auto selects the best model using validation metrics.',
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              Text(
                'Satellite sources',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final source in _satelliteOptions)
                    FilterChip(
                      label: Text(_satelliteLabels[source]!),
                      selected: _selectedSatelliteSources.contains(source),
                      onSelected: _saving
                          ? null
                          : (selected) => _setSatelliteSelected(
                              source,
                              selected: selected,
                            ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Each selected satellite can use different seasons and dates.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              for (final source in selectedSources) ...[
                const SizedBox(height: AppSpacing.md),
                _buildSatelliteTimeframeEditor(context, source),
              ],
              const SizedBox(height: AppSpacing.md),
              KeyedSubtree(
                key: _featureInputsKey,
                child: _FeatureInputSelector(
                  selected: _selectedFeatureInputs,
                  satelliteSources: selectedSources,
                  seasonCount: _selectedSeasonCount(),
                  options: _featureInputOptions(),
                  selectAllKeys: _selectAllFeatureInputs(),
                  dependencyNotice: _featureDependencyNotice(),
                  onSelectAll: _saving ? null : _handleSelectAllFeatureInputs,
                  onChanged: _saving ? null : _setSelectedFeatureInputs,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              const _NoticeRow(
                icon: Icons.info_outline,
                text: 'Saving settings does not run AI.',
              ),
              if (validationMessage != null) ...[
                const SizedBox(height: AppSpacing.sm),
                _NoticeRow(
                  icon: Icons.warning_amber_outlined,
                  text: validationMessage,
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              AppButton(
                label: _saving ? 'Saving...' : 'Save settings',
                icon: Icons.save_outlined,
                isLoading: _saving,
                onPressed: validationMessage == null && !_saving
                    ? _saveSettings
                    : null,
              ),
            ],
          ),
        );
      },
    );
  }

  void _initializeFromSettings(AiProjectSettings settings) {
    final key =
        '${settings.projectId}:${settings.updatedKey}:${settings.labelField}:${settings.minSamplesPerClass}:${settings.scopeType}:${settings.confidenceThreshold}';
    if (_initializedFor == key) {
      return;
    }
    _initializedFor = key;
    _isEnabled = settings.isEnabled;
    _labelField = settings.labelField ?? _preferredLabelField(widget.project);
    _scopeType = 'project';
    _nationalScopeWarningAcknowledged =
        settings.modelPreferences['national_scope_warning_acknowledged'] ==
        true;
    final storedScope = settings.scopeType.trim();
    if (storedScope == 'custom_polygon') {
      _scopeType = 'custom_polygon';
    } else if (storedScope == 'national') {
      _scopeType = 'national';
    }
    _aiAreaDropdownVersion++;
    _customScopeGeometry = settings.scopeGeometry == null
        ? null
        : Map<String, dynamic>.from(settings.scopeGeometry!);
    _preferredModel = _normalModelPreferenceForSettings(
      settings.modelPreferences['preferred_model'] as String?,
    );
    _selectedSatelliteSources = _readSatelliteSources(
      settings.modelPreferences,
    );
    _satelliteTimeframes
      ..clear()
      ..addEntries(
        _selectedSatelliteSources.map(
          (source) => MapEntry(
            source,
            _readSatelliteTimeframe(settings.modelPreferences, source),
          ),
        ),
      );
    _selectedFeatureInputs = _readFeatureInputs(settings.modelPreferences);
    if (_selectedFeatureInputs.isEmpty) {
      _selectedFeatureInputs = _expandedFeatureInputsForGroups(
        _stringSet(settings.modelPreferences['feature_groups']),
      );
    }
    if (_selectedFeatureInputs.isEmpty) {
      _selectedFeatureInputs = _defaultFeatureInputsForSelectedSatellites();
    }
    _syncFeatureInputsWithSelectedSatellites();
    _skippedFeatureInputs.clear();
    _minSamplesController.text = settings.minSamplesPerClass.toString();
    _confidenceThresholdController.text = _formatThreshold(
      settings.confidenceThreshold,
    );
  }

  Widget _buildSatelliteTimeframeEditor(BuildContext context, String source) {
    final state = _ensureSatelliteState(source);
    final yearOptions = _yearOptionsFor(source);
    if (!yearOptions.contains(state.mapYear.toString())) {
      state.mapYear = int.parse(yearOptions.first);
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _satelliteLabels[source]!,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            DropdownButtonFormField<String>(
              initialValue: state.mapYear.toString(),
              decoration: const InputDecoration(labelText: 'Map year'),
              items: yearOptions
                  .map(
                    (year) => DropdownMenuItem(value: year, child: Text(year)),
                  )
                  .toList(growable: false),
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        state.mapYear = int.parse(value);
                        _resetMissingSeasonRanges(state);
                      });
                    },
            ),
            const SizedBox(height: AppSpacing.sm),
            Text('Seasons', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final season in _seasonOptions)
                  FilterChip(
                    label: Text(_seasonLabels[season]!),
                    selected: state.seasons.contains(season),
                    onSelected: _saving
                        ? null
                        : (selected) => _setSeasonSelected(
                            source,
                            season,
                            selected: selected,
                          ),
                  ),
              ],
            ),
            for (final season in _seasonOptions.where(state.seasons.contains))
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: _buildSeasonDateFields(source, season, state),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSeasonDateFields(
    String source,
    String season,
    _SatelliteTimeframeState state,
  ) {
    final range =
        state.ranges[season] ?? _defaultRangeFor(state.mapYear, season);
    state.ranges[season] = range;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _seasonLabels[season]!,
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: AppSpacing.xs),
        LayoutBuilder(
          builder: (context, constraints) {
            final stack = constraints.maxWidth < 560;
            final fields = [
              _DateValueField(
                label: 'From date',
                value: range.from == null ? '' : _formatAiDate(range.from!),
                onTap: _saving
                    ? null
                    : () => _pickSeasonDate(
                        source: source,
                        season: season,
                        pickFromDate: true,
                      ),
              ),
              _DateValueField(
                label: 'To date',
                value: range.to == null ? '' : _formatAiDate(range.to!),
                onTap: _saving
                    ? null
                    : () => _pickSeasonDate(
                        source: source,
                        season: season,
                        pickFromDate: false,
                      ),
              ),
            ];
            if (stack) {
              return Column(
                children: [
                  fields[0],
                  const SizedBox(height: AppSpacing.sm),
                  fields[1],
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: fields[0]),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: fields[1]),
              ],
            );
          },
        ),
      ],
    );
  }

  _SatelliteTimeframeState _ensureSatelliteState(String source) {
    return _satelliteTimeframes.putIfAbsent(source, () {
      final year = int.parse(_yearOptionsFor(source).first);
      return _SatelliteTimeframeState(
        mapYear: year,
        ranges: <String, _SeasonDateRange>{
          'growing': _defaultRangeFor(year, 'growing'),
        },
      );
    });
  }

  void _setSatelliteSelected(String source, {required bool selected}) {
    setState(() {
      if (selected) {
        _selectedSatelliteSources.add(source);
        _ensureSatelliteState(source);
      } else {
        _selectedSatelliteSources.remove(source);
      }
      _syncFeatureInputsWithSelectedSatellites();
      _skippedFeatureInputs.clear();
    });
  }

  void _setSeasonSelected(
    String source,
    String season, {
    required bool selected,
  }) {
    setState(() {
      final state = _ensureSatelliteState(source);
      if (selected) {
        state.seasons.add(season);
        state.ranges.putIfAbsent(
          season,
          () => _defaultRangeFor(state.mapYear, season),
        );
      } else {
        state.seasons.remove(season);
      }
      _skippedFeatureInputs.clear();
    });
  }

  void _setSelectedFeatureInputs(Set<String> next) {
    setState(() {
      _selectedFeatureInputs = Set<String>.from(next);
      _skippedFeatureInputs.clear();
    });
  }

  void _handleSelectAllFeatureInputs() {
    final selected = _selectAllFeatureInputs();
    final available = _availableFeatureInputsForSelectedSatellites();
    setState(() {
      _selectedFeatureInputs = selected;
      _skippedFeatureInputs = available.difference(selected);
    });
  }

  void _resetMissingSeasonRanges(_SatelliteTimeframeState state) {
    for (final season in state.seasons) {
      state.ranges[season] = _defaultRangeFor(state.mapYear, season);
    }
  }

  Future<void> _pickSeasonDate({
    required String source,
    required String season,
    required bool pickFromDate,
  }) async {
    final state = _ensureSatelliteState(source);
    final current =
        state.ranges[season] ?? _defaultRangeFor(state.mapYear, season);
    final firstDate = DateTime(state.mapYear, 1, 1);
    final lastDate = DateTime(state.mapYear + 1, 12, 31);
    final currentValue = pickFromDate ? current.from : current.to;
    final picked = await showDatePicker(
      context: context,
      initialDate: currentValue ?? firstDate,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() {
      var next = pickFromDate
          ? current.copyWith(from: picked)
          : current.copyWith(to: picked);
      if (next.from != null &&
          next.to != null &&
          next.from!.isAfter(next.to!)) {
        next = pickFromDate
            ? next.copyWith(to: picked)
            : next.copyWith(from: picked);
      }
      state.ranges[season] = next;
    });
  }

  _SeasonDateRange _defaultRangeFor(int year, String season) {
    final range = _seasonRanges[season] ?? _seasonRanges['growing']!;
    final endYear = season == 'winter' ? year + 1 : year;
    return _SeasonDateRange(
      from: DateTime.parse('$year-${range[0]}'),
      to: DateTime.parse('$endYear-${range[1]}'),
    );
  }

  List<String> _yearOptionsFor(String satelliteSource) {
    final current = DateTime.now().year;
    final firstYear = satelliteSource == 'landsat' ? 2013 : 2015;
    return [for (var year = current; year >= firstYear; year -= 1) '$year'];
  }

  Set<String> _expandedFeatureInputsForGroups(Set<String> groups) {
    final features = <String>{};
    if (groups.contains('spectral_bands')) {
      for (final source in _orderedSelectedSatelliteSources()) {
        features.addAll(
          source == 'landsat' ? _landsatFeatures : _sentinel2Features,
        );
      }
    }
    if (groups.contains('vegetation_indices')) {
      for (final source in _orderedSelectedSatelliteSources()) {
        features.addAll(
          source == 'landsat' ? _landsatIndexFeatures : _sentinel2IndexFeatures,
        );
      }
    }
    if (groups.contains('topography')) {
      features.addAll(<String>[
        'static_srtm_elevation',
        'static_srtm_slope',
        'static_srtm_aspect',
      ]);
    }
    if (groups.contains('texture')) {
      features.add('static_texture_pc1');
    }
    return features;
  }

  Set<String> _featureGroupsForInputs(Set<String> rawInputs) {
    final groups = <String>{};
    if (rawInputs.any(
      (item) =>
          _sentinel2Features.contains(item) || _landsatFeatures.contains(item),
    )) {
      groups.add('spectral_bands');
    }
    if (rawInputs.any(
      (item) =>
          _sentinel2IndexFeatures.contains(item) ||
          _landsatIndexFeatures.contains(item),
    )) {
      groups.add('vegetation_indices');
    }
    if (rawInputs.any((item) => item.startsWith('static_srtm_'))) {
      groups.add('topography');
    }
    if (rawInputs.contains('static_texture_pc1')) {
      groups.add('texture');
    }
    return groups;
  }

  Set<String> _availableFeatureInputsForSelectedSatellites() {
    final features = <String>{};
    for (final source in _orderedSelectedSatelliteSources()) {
      if (source == 'landsat') {
        features
          ..addAll(_landsatFeatures)
          ..addAll(_landsatIndexFeatures);
      } else {
        features
          ..addAll(_sentinel2Features)
          ..addAll(_sentinel2IndexFeatures);
      }
    }
    features.addAll(
      _staticFeatureInputs.where(
        (feature) =>
            feature != 'static_texture_pc1' ||
            _selectedSatelliteSources.contains('sentinel2'),
      ),
    );
    return features;
  }

  Set<String> _defaultFeatureInputsForSelectedSatellites() {
    final features = <String>{};
    if (_selectedSatelliteSources.contains('sentinel2')) {
      features.addAll(_defaultSentinel2FeatureInputs);
    }
    if (_selectedSatelliteSources.contains('landsat')) {
      features.addAll(_defaultLandsatFeatureInputs);
    }
    return features;
  }

  void _syncFeatureInputsWithSelectedSatellites() {
    final available = _availableFeatureInputsForSelectedSatellites();
    _selectedFeatureInputs = _selectedFeatureInputs
        .where(available.contains)
        .toSet();
    if (_selectedFeatureInputs.isEmpty) {
      _selectedFeatureInputs = _defaultFeatureInputsForSelectedSatellites()
          .where(available.contains)
          .toSet();
    }
  }

  bool _textureRequirementsSatisfied(Set<String> inputs) {
    return _selectedSatelliteSources.contains('sentinel2') &&
        inputs.contains('NDVI') &&
        _ensureSatelliteState('sentinel2').seasons.contains('dry');
  }

  Set<String> _selectAllFeatureInputs() {
    final available = _availableFeatureInputsForSelectedSatellites();
    if (!available.contains('static_texture_pc1')) {
      return available;
    }
    if (!_textureRequirementsSatisfied(available)) {
      return Set<String>.from(available)..remove('static_texture_pc1');
    }
    return available;
  }

  String? _featureDependencyNotice() {
    if (_skippedFeatureInputs.isNotEmpty) {
      return _skippedFeatureInlineMessage(_skippedFeatureInputs);
    }
    if (_selectedFeatureInputs.contains('static_texture_pc1')) {
      final missing = <String>[];
      if (!_selectedSatelliteSources.contains('sentinel2')) {
        missing.add('Sentinel-2');
      }
      if (!_selectedFeatureInputs.contains('NDVI')) {
        missing.add('NDVI');
      }
      if (!_ensureSatelliteState('sentinel2').seasons.contains('dry')) {
        missing.add('Sentinel-2 dry season');
      }
      if (missing.isNotEmpty) {
        return 'static_texture_pc1 needs ${missing.join(', ')}. Add the missing setting or remove static_texture_pc1.';
      }
    }
    if (_selectedSatelliteSources.contains('sentinel2') &&
        !_ensureSatelliteState('sentinel2').seasons.contains('dry')) {
      return 'Select all skips static_texture_pc1 until you add a Sentinel-2 dry season/timeframe.';
    }
    return null;
  }

  String _skippedFeatureInlineMessage(Set<String> skipped) {
    if (skipped.contains('static_texture_pc1')) {
      return 'static_texture_pc1 was not selected because it requires Sentinel-2 dry season and NDVI.';
    }
    final names = skipped.toList(growable: false)..sort();
    return '${names.join(', ')} ${names.length == 1 ? 'was' : 'were'} not selected because required settings are missing.';
  }

  String _skippedFeatureSaveMessage(Set<String> skipped) {
    if (skipped.contains('static_texture_pc1')) {
      return 'AI settings saved, but 1 feature was skipped: static_texture_pc1. It requires Sentinel-2 dry season and NDVI. Add a Sentinel-2 dry season/timeframe to enable it.';
    }
    final names = skipped.toList(growable: false)..sort();
    return 'AI settings saved, but ${names.length} features were skipped: ${names.join(', ')}. Add the required settings to enable them.';
  }

  void _scrollToFeatureWarnings() {
    final context = _featureInputsKey.currentContext;
    if (context == null) {
      return;
    }
    Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      alignment: 0.08,
    );
  }

  List<_FeatureInputOption> _featureInputOptions() {
    final available = _availableFeatureInputsForSelectedSatellites();
    final recommended = _defaultFeatureInputsForSelectedSatellites();
    final options = <_FeatureInputOption>[
      if (_selectedSatelliteSources.contains('sentinel2'))
        for (final feature in _sentinel2Features)
          _FeatureInputOption(
            key: feature,
            label: feature,
            group: 'Sentinel-2 bands',
            recommended: recommended.contains(feature),
          ),
      if (_selectedSatelliteSources.contains('landsat'))
        for (final feature in _landsatFeatures)
          _FeatureInputOption(
            key: feature,
            label: feature,
            group: 'Landsat bands',
            recommended: recommended.contains(feature),
          ),
      for (final feature in <String>[
        ..._sentinel2IndexFeatures,
        for (final feature in _landsatIndexFeatures)
          if (!_sentinel2IndexFeatures.contains(feature)) feature,
      ])
        if (available.contains(feature))
          _FeatureInputOption(
            key: feature,
            label: feature,
            group: 'Vegetation indices',
            recommended: recommended.contains(feature),
          ),
      for (final feature in _staticFeatureInputs)
        _FeatureInputOption(
          key: feature,
          label: _friendlyStaticFeatureLabel(feature),
          group: feature == 'static_texture_pc1' ? 'Texture' : 'Topography',
          recommended: recommended.contains(feature),
        ),
    ];
    options.sort(_compareFeatureInputOptions);
    return options;
  }

  int _selectedSeasonCount() {
    var count = 0;
    for (final source in _orderedSelectedSatelliteSources()) {
      count += _ensureSatelliteState(source).seasons.length;
    }
    return count;
  }

  String _formatAiDate(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '${value.year}-$month-$day';
  }

  String _formatThreshold(double value) {
    final text = value.toStringAsFixed(2);
    return text
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  String? _settingsValidationMessage() {
    if (_selectedSatelliteSources.isEmpty) {
      return 'Select at least one satellite source.';
    }
    final threshold = double.tryParse(
      _confidenceThresholdController.text.trim(),
    );
    if (threshold == null || threshold < 0 || threshold > 1) {
      return 'Confidence threshold must be a number from 0 to 1.';
    }
    if (_scopeType == 'custom_polygon' && _customScopeGeometry == null) {
      return 'Draw a custom AI area before saving custom scope settings.';
    }
    if (_selectedFeatureInputs.isEmpty) {
      return 'Select at least one extracted feature.';
    }
    final dependencyMessage = _featureDependencyValidationMessage();
    if (dependencyMessage != null) {
      return dependencyMessage;
    }
    for (final source in _orderedSelectedSatelliteSources()) {
      final state = _ensureSatelliteState(source);
      if (state.seasons.isEmpty) {
        return '${_satelliteLabels[source]} needs at least one season.';
      }
      for (final season in state.seasons) {
        final range = state.ranges[season];
        if (range?.from == null || range?.to == null) {
          return '${_satelliteLabels[source]} ${_seasonLabels[season]} needs from and to dates.';
        }
        if (range!.from!.isAfter(range.to!)) {
          return '${_satelliteLabels[source]} ${_seasonLabels[season]} from date must be before to date.';
        }
      }
    }
    return null;
  }

  String? _featureDependencyValidationMessage() {
    if (_selectedFeatureInputs.contains('static_texture_pc1')) {
      if (!_selectedSatelliteSources.contains('sentinel2') ||
          !_selectedFeatureInputs.contains('NDVI') ||
          !_ensureSatelliteState('sentinel2').seasons.contains('dry')) {
        return _textureDependencyMessage;
      }
    }
    if (_selectedFeatureInputs.contains('NDRE') &&
        !_selectedSatelliteSources.contains('sentinel2')) {
      return 'NDRE requires Sentinel-2 because it uses Sentinel-2 red-edge bands.';
    }
    final hasSentinel2OnlyFeature = _selectedFeatureInputs.any(
      (feature) => _sentinel2Features.contains(feature) || feature == 'NDRE',
    );
    if (hasSentinel2OnlyFeature &&
        !_selectedSatelliteSources.contains('sentinel2')) {
      return 'Sentinel-2 bands and red-edge indices require Sentinel-2.';
    }
    final hasLandsatOnlyFeature = _selectedFeatureInputs.any(
      _landsatFeatures.contains,
    );
    if (hasLandsatOnlyFeature &&
        !_selectedSatelliteSources.contains('landsat')) {
      return 'Landsat bands require Landsat.';
    }
    return null;
  }

  void _handleAiAreaChanged(
    String? value, {
    required AiNationalScopeEligibility? nationalScopeEligibility,
  }) {
    if (value == null) {
      return;
    }
    if (value == 'national') {
      _confirmNationalScopeIfNeeded(nationalScopeEligibility);
      return;
    }
    setState(() {
      _scopeType = value;
      if (value != 'national') {
        _nationalScopeWarningAcknowledged = false;
      }
      _aiAreaDropdownVersion++;
    });
  }

  Future<void> _confirmNationalScopeIfNeeded(
    AiNationalScopeEligibility? eligibility,
  ) async {
    final score = eligibility?.coverageScore ?? 0;
    if (score >= 70 || _nationalScopeWarningAcknowledged) {
      setState(() {
        _scopeType = 'national';
        _aiAreaDropdownVersion++;
      });
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Run national classification?'),
        content: const Text(
          'Samples are not well distributed across Lebanon. You can continue, but results may be less reliable.',
        ),
        actions: [
          AppDialogActions(
            cancel: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            confirm: FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Continue'),
            ),
          ),
        ],
      ),
    );
    if (!mounted) {
      return;
    }
    if (confirmed == true) {
      setState(() {
        _scopeType = 'national';
        _nationalScopeWarningAcknowledged = true;
        _aiAreaDropdownVersion++;
      });
    } else {
      setState(() => _aiAreaDropdownVersion++);
    }
  }

  Future<void> _drawCustomScope() async {
    final polygon = await openExportAreaPicker(
      context,
      initialPolygon: _customScopeGeometry,
      title: 'Draw AI area',
      submitLabel: 'Use AI area',
    );
    if (!mounted || polygon == null) {
      return;
    }
    setState(() {
      _scopeType = 'custom_polygon';
      _customScopeGeometry = polygon;
      _aiAreaDropdownVersion++;
    });
  }

  Set<String> _stringSet(dynamic raw) {
    if (raw is List) {
      return raw
          .map((value) => value.toString().trim())
          .where((value) => value.isNotEmpty)
          .toSet();
    }
    return <String>{};
  }

  Set<String> _readFeatureInputs(Map<String, dynamic> preferences) {
    for (final key in <String>[
      'feature_inputs',
      'selected_feature_inputs',
      'selected_extracted_features',
    ]) {
      final values = _stringSet(preferences[key]);
      if (values.isNotEmpty) {
        return values;
      }
    }
    return <String>{};
  }

  Set<String> _readSatelliteSources(Map<String, dynamic> preferences) {
    final rawSources =
        preferences['satellite_sources'] ?? preferences['satelliteSources'];
    final sources = <String>{};
    if (rawSources is List) {
      for (final raw in rawSources) {
        final source = _normalizeSatelliteSource(raw);
        if (source != null) {
          sources.add(source);
        }
      }
    }
    if (sources.isEmpty) {
      final source = _normalizeSatelliteSource(
        preferences['satellite_source'] ?? preferences['satelliteSource'],
      );
      if (source != null) {
        sources.add(source);
      }
    }
    return sources.isEmpty ? <String>{'sentinel2'} : sources;
  }

  _SatelliteTimeframeState _readSatelliteTimeframe(
    Map<String, dynamic> preferences,
    String source,
  ) {
    final rawTimeframes =
        _asMap(preferences['satellite_timeframes']) ??
        _asMap(preferences['satelliteTimeframes']) ??
        const <String, dynamic>{};
    final rawForSource =
        _asMap(rawTimeframes[source]) ??
        _asMap(rawTimeframes[source == 'sentinel2' ? 'sentinel-2' : source]) ??
        const <String, dynamic>{};
    final legacyYear =
        _readYear(preferences['target_year'] ?? preferences['year']) ??
        DateTime.now().year - 1;
    final mapYear =
        _readYear(rawForSource['map_year'] ?? rawForSource['mapYear']) ??
        legacyYear;
    final legacySeason = _normalizeSeason(preferences['season']) ?? 'growing';
    final legacyRange = _defaultRangeFor(mapYear, legacySeason);
    final legacyFrom =
        _parseDate(preferences['date_from'] ?? preferences['from_date']) ??
        legacyRange.from;
    final legacyTo =
        _parseDate(preferences['date_to'] ?? preferences['to_date']) ??
        legacyRange.to;
    final state = _SatelliteTimeframeState(mapYear: mapYear);
    state.seasons.clear();
    final rawSeasons = rawForSource['seasons'] is List
        ? rawForSource['seasons'] as List
        : const <dynamic>[];
    final seasonsToRead = rawSeasons.isEmpty
        ? <dynamic>[
            <String, dynamic>{
              'season': legacySeason,
              'from_date': legacyFrom == null
                  ? null
                  : _formatAiDate(legacyFrom),
              'to_date': legacyTo == null ? null : _formatAiDate(legacyTo),
            },
          ]
        : rawSeasons;
    for (final rawSeason in seasonsToRead) {
      final record =
          _asMap(rawSeason) ?? <String, dynamic>{'season': rawSeason};
      final season = _normalizeSeason(record['season']) ?? legacySeason;
      final fallback = _defaultRangeFor(mapYear, season);
      final from =
          _parseDate(record['from_date'] ?? record['fromDate']) ??
          (season == legacySeason ? legacyFrom : null) ??
          fallback.from;
      final to =
          _parseDate(record['to_date'] ?? record['toDate']) ??
          (season == legacySeason ? legacyTo : null) ??
          fallback.to;
      state.seasons.add(season);
      state.ranges[season] = _SeasonDateRange(from: from, to: to);
    }
    if (state.seasons.isEmpty) {
      state.seasons.add('growing');
      state.ranges['growing'] = _defaultRangeFor(mapYear, 'growing');
    }
    return state;
  }

  Map<String, dynamic>? _asMap(dynamic raw) {
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    return null;
  }

  String? _normalizeSatelliteSource(dynamic raw) {
    final value = raw?.toString().trim().toLowerCase();
    return switch (value) {
      'sentinel2' || 'sentinel-2' || 'sentinel_2' || 's2' => 'sentinel2',
      'landsat' ||
      'landsat8' ||
      'landsat-8' ||
      'landsat9' ||
      'landsat-9' => 'landsat',
      _ => null,
    };
  }

  String? _normalizeSeason(dynamic raw) {
    final value = raw?.toString().trim().toLowerCase();
    return switch (value) {
      'spring' => 'growing',
      'summer' => 'dry',
      'autumn' || 'fall' => 'harvest',
      'growing' || 'dry' || 'harvest' || 'winter' => value,
      _ => null,
    };
  }

  int? _readYear(dynamic raw) {
    if (raw is int) {
      return raw;
    }
    if (raw is num) {
      return raw.toInt();
    }
    return int.tryParse(raw?.toString() ?? '');
  }

  DateTime? _parseDate(dynamic raw) {
    if (raw is DateTime) {
      return raw;
    }
    final value = raw?.toString().trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return DateTime.tryParse(value);
  }

  List<String> _orderedSelectedSatelliteSources() {
    return [
      for (final source in _satelliteOptions)
        if (_selectedSatelliteSources.contains(source)) source,
    ];
  }

  Map<String, dynamic> _satelliteTimeframesPayload() {
    return <String, dynamic>{
      for (final source in _orderedSelectedSatelliteSources())
        source: <String, dynamic>{
          'map_year': _ensureSatelliteState(source).mapYear,
          'seasons': [
            for (final season in _seasonOptions.where(
              _ensureSatelliteState(source).seasons.contains,
            ))
              <String, dynamic>{
                'season': season,
                'from_date': _formatAiDate(
                  _ensureSatelliteState(source).ranges[season]!.from!,
                ),
                'to_date': _formatAiDate(
                  _ensureSatelliteState(source).ranges[season]!.to!,
                ),
              },
          ],
        },
    };
  }

  Future<void> _saveSettings() async {
    final validationMessage = _settingsValidationMessage();
    if (validationMessage != null) {
      AppSnackbar.showError(context, validationMessage);
      return;
    }
    final parsedMinSamples = int.tryParse(_minSamplesController.text.trim());
    final minSamples = (parsedMinSamples ?? 50).clamp(1, 10000).toInt();
    final confidenceThreshold =
        double.tryParse(_confidenceThresholdController.text.trim()) ?? 0.6;
    final sources = _orderedSelectedSatelliteSources();
    final timeframes = _satelliteTimeframesPayload();
    _syncFeatureInputsWithSelectedSatellites();
    final skippedFeatureInputs = Set<String>.from(_skippedFeatureInputs);
    final selectedFeatureInputs = _selectedFeatureInputs.toList(growable: false)
      ..sort();
    final featureGroups = _featureGroupsForInputs(
      _selectedFeatureInputs,
    ).toList(growable: false)..sort();
    final primarySource = sources.first;
    final primaryFrame = timeframes[primarySource] as Map<String, dynamic>;
    final primarySeasons = primaryFrame['seasons'] as List<dynamic>;
    final primarySeason = primarySeasons.first as Map<String, dynamic>;
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
              scopeGeometry: _scopeType == 'custom_polygon'
                  ? _customScopeGeometry
                  : null,
              minSamplesPerClass: minSamples,
              confidenceThreshold: confidenceThreshold,
              modelPreferences: <String, dynamic>{
                'preferred_model': _preferredModel,
                'satellite_sources': sources,
                'satellite_timeframes': timeframes,
                'satellite_source': primarySource,
                'target_year': primaryFrame['map_year'],
                'season': primarySeason['season'],
                'date_from': primarySeason['from_date'],
                'date_to': primarySeason['to_date'],
                'feature_groups': featureGroups,
                'feature_inputs': selectedFeatureInputs,
                'selected_feature_inputs': selectedFeatureInputs,
                'selected_extracted_features': selectedFeatureInputs,
                if (_scopeType == 'national')
                  'national_scope_warning_acknowledged':
                      _nationalScopeWarningAcknowledged,
              },
            ),
          );
      bumpWorkflowRefresh(ref);
      if (mounted) {
        if (skippedFeatureInputs.isNotEmpty) {
          AppSnackbar.showWarning(
            context,
            _skippedFeatureSaveMessage(skippedFeatureInputs),
            actionLabel: 'View warning',
            onAction: _scrollToFeatureWarnings,
          );
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _scrollToFeatureWarnings();
            }
          });
        } else {
          AppSnackbar.showSuccess(context, 'AI settings saved successfully.');
        }
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

class _DateValueField extends StatelessWidget {
  const _DateValueField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: const Icon(Icons.calendar_month_outlined),
          enabled: onTap != null,
        ),
        child: Text(value.isEmpty ? 'Select date' : value),
      ),
    );
  }
}

class _ProjectAreaScopeSummary extends StatelessWidget {
  const _ProjectAreaScopeSummary({
    required this.scopeType,
    required this.readiness,
    required this.hasCustomGeometry,
  });

  final String scopeType;
  final AiReadinessResult? readiness;
  final bool hasCustomGeometry;

  @override
  Widget build(BuildContext context) {
    final extent = readiness?.spatialExtent;
    final title = switch (scopeType) {
      'custom_polygon' =>
        hasCustomGeometry ? 'Custom AI area' : 'Custom AI area not configured',
      'national' => 'National Lebanon',
      _ =>
        extent == null
            ? 'Project area scope not configured'
            : 'Project feature extent (rectangular fallback)',
    };
    final text = switch (scopeType) {
      'custom_polygon' =>
        hasCustomGeometry
            ? 'AI runs will clip imagery, training samples, and predictions to the saved custom polygon.'
            : 'Project area scope is not configured. AI runs need an AOI to clip imagery and generate predictions.',
      'national' =>
        'National Lebanon is not available in the current AI pipeline.',
      _ =>
        extent == null
            ? 'Project area scope is not configured. AI runs need an AOI to clip imagery and generate predictions.'
            : 'The backend will use the bounding rectangle around approved project features and training samples: ${_formatExtent(extent)}. This is not a drawn project boundary; if samples are spread out, the AI may classify a larger area. Draw a Custom AI area to limit the run.',
    };
    final isFallbackExtent =
        scopeType != 'custom_polygon' &&
        scopeType != 'national' &&
        extent != null;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: _NoticeRow(
          icon: (extent == null && scopeType != 'national') || isFallbackExtent
              ? Icons.warning_amber_outlined
              : Icons.travel_explore_outlined,
          text: '$title. $text',
        ),
      ),
    );
  }
}

class _FeatureInputSelector extends StatelessWidget {
  const _FeatureInputSelector({
    required this.selected,
    required this.satelliteSources,
    required this.seasonCount,
    required this.options,
    required this.selectAllKeys,
    required this.dependencyNotice,
    required this.onSelectAll,
    required this.onChanged,
  });

  final Set<String> selected;
  final List<String> satelliteSources;
  final int seasonCount;
  final List<_FeatureInputOption> options;
  final Set<String> selectAllKeys;
  final String? dependencyNotice;
  final VoidCallback? onSelectAll;
  final ValueChanged<Set<String>>? onChanged;

  @override
  Widget build(BuildContext context) {
    final recommendedKeys = options
        .where((option) => option.recommended)
        .map((option) => option.key)
        .toSet();
    final optionKeys = options.map((option) => option.key).toSet();
    final selectableKeys = selectAllKeys.where(optionKeys.contains).toSet();
    final allSelected =
        selectableKeys.isNotEmpty && selectableKeys.every(selected.contains);
    final groupedOptions = <String, List<_FeatureInputOption>>{};
    for (final option in options) {
      groupedOptions.putIfAbsent(option.group, () => <_FeatureInputOption>[]);
      groupedOptions[option.group]!.add(option);
    }
    final groups = groupedOptions.keys.toList(growable: false)
      ..sort((left, right) {
        final rankCompare = _featureInputGroupRank(
          left,
        ).compareTo(_featureInputGroupRank(right));
        if (rankCompare != 0) {
          return rankCompare;
        }
        return left.compareTo(right);
      });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Extracted features',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            IconButton(
              tooltip: 'Feature requirements',
              icon: const Icon(Icons.info_outline),
              onPressed: () => _showFeatureRequirementsSheet(context),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        _NoticeRow(
          icon: Icons.satellite_alt_outlined,
          text:
              'Choose the exact feature inputs used for training and prediction. Satellite features come from ${satelliteSources.map(_friendlySatelliteLabel).join(', ')} and selected seasons.',
        ),
        if (seasonCount > 1) ...[
          const SizedBox(height: AppSpacing.xs),
          const _NoticeRow(
            icon: Icons.timeline_outlined,
            text: 'Seasonal composites capture crop phenology.',
          ),
        ],
        if (dependencyNotice != null) ...[
          const SizedBox(height: AppSpacing.xs),
          _NoticeRow(
            icon: Icons.warning_amber_outlined,
            text: dependencyNotice!,
          ),
        ],
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          children: [
            ActionChip(
              avatar: const Icon(Icons.auto_awesome_outlined, size: 18),
              label: const Text('Select recommended'),
              onPressed: onChanged == null
                  ? null
                  : () => onChanged!(
                      recommendedKeys.isEmpty
                          ? selected
                          : Set<String>.from(recommendedKeys),
                    ),
            ),
            ActionChip(
              avatar: Icon(
                allSelected
                    ? Icons.deselect_outlined
                    : Icons.select_all_outlined,
                size: 18,
              ),
              label: Text(allSelected ? 'Unselect all' : 'Select all'),
              onPressed: onChanged == null || selectableKeys.isEmpty
                  ? null
                  : allSelected
                  ? () => onChanged!(<String>{})
                  : onSelectAll,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        for (var groupIndex = 0; groupIndex < groups.length; groupIndex += 1)
          _FeatureInputGroup(
            group: groups[groupIndex],
            options: groupedOptions[groups[groupIndex]]!,
            selected: selected,
            onChanged: onChanged,
            topSpacing: groupIndex == 0 ? 0 : AppSpacing.md,
          ),
      ],
    );
  }
}

void _showFeatureRequirementsSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        child: ListView(
          shrinkWrap: true,
          children: const [
            Text(
              'Feature requirements',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: AppSpacing.sm),
            _FeatureRequirementRow(
              title: 'Spectral bands',
              text:
                  'Sentinel-2: B2 (Blue), B3 (Green), B4 (Red), B5/B6/B7 (Red-edge), B8/B8A (Near Infrared), B11/B12 (Shortwave Infrared). Landsat: SR_B2 (Blue), SR_B3 (Green), SR_B4 (Red), SR_B5 (Near Infrared), SR_B6/SR_B7 (Shortwave Infrared).',
            ),
            _FeatureRequirementRow(
              title: 'Vegetation indices',
              text:
                  'NDVI (vegetation greenness), EVI (dense canopy greenness), SAVI (soil-adjusted greenness), and NDWI (water/moisture signal) require a valid Sentinel-2 or Landsat season.',
            ),
            _FeatureRequirementRow(
              title: 'Red-edge indices',
              text:
                  'NDRE (chlorophyll/red-edge signal) requires Sentinel-2 because Landsat does not provide Sentinel-2 red-edge bands.',
            ),
            _FeatureRequirementRow(
              title: 'Texture features',
              text:
                  'static_texture_pc1 (orchard texture pattern) requires Sentinel-2, NDVI, and a Sentinel-2 dry season/timeframe.',
            ),
            _FeatureRequirementRow(
              title: 'Topography',
              text:
                  'static_srtm_elevation (elevation), static_srtm_slope (slope), and static_srtm_aspect (aspect) come from terrain data and can be used with any satellite source.',
            ),
            _FeatureRequirementRow(
              title: 'Seasonal features',
              text:
                  'Seasonal composites use the selected source and timeframe keys: growing, dry, harvest, and winter. Each selected season needs a from date and to date.',
            ),
          ],
        ),
      ),
    ),
  );
}

class _FeatureRequirementRow extends StatelessWidget {
  const _FeatureRequirementRow({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(text),
        ],
      ),
    );
  }
}

class _FeatureInputGroup extends StatelessWidget {
  const _FeatureInputGroup({
    required this.group,
    required this.options,
    required this.selected,
    required this.onChanged,
    required this.topSpacing,
  });

  final String group;
  final List<_FeatureInputOption> options;
  final Set<String> selected;
  final ValueChanged<Set<String>>? onChanged;
  final double topSpacing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: topSpacing),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            group,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.xs),
          LayoutBuilder(
            builder: (context, constraints) {
              final columnCount = constraints.maxWidth >= 900
                  ? 3
                  : constraints.maxWidth >= 620
                  ? 2
                  : 1;
              final totalSpacing = AppSpacing.sm * (columnCount - 1);
              final itemWidth =
                  (constraints.maxWidth - totalSpacing) / columnCount;
              return Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final option in options)
                    SizedBox(
                      width: itemWidth,
                      child: CheckboxListTile(
                        value: selected.contains(option.key),
                        onChanged: onChanged == null
                            ? null
                            : (value) {
                                final next = Set<String>.from(selected);
                                if (value == true) {
                                  next.add(option.key);
                                } else {
                                  next.remove(option.key);
                                }
                                onChanged!(next);
                              },
                        secondary: Icon(option.icon),
                        title: Text(option.title),
                        subtitle: option.recommended
                            ? const Text('Recommended')
                            : null,
                        controlAffinity: ListTileControlAffinity.trailing,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                        ),
                        shape: RoundedRectangleBorder(
                          side: BorderSide(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _FeatureInputOption {
  const _FeatureInputOption({
    required this.key,
    required this.label,
    required this.group,
    required this.recommended,
  });

  final String key;
  final String label;
  final String group;
  final bool recommended;

  String get title => label;

  IconData get icon {
    if (group.contains('Landsat') || group.contains('Sentinel')) {
      return Icons.blur_on_outlined;
    }
    if (group == 'Vegetation indices') {
      return Icons.eco_outlined;
    }
    if (group == 'Topography') {
      return Icons.terrain_outlined;
    }
    return Icons.grain_outlined;
  }
}

int _featureInputGroupRank(String group) {
  return switch (group) {
    'Sentinel-2 bands' => 0,
    'Landsat bands' => 1,
    'Vegetation indices' => 2,
    'Topography' => 3,
    'Texture' => 4,
    _ => 100,
  };
}

int _compareFeatureInputOptions(
  _FeatureInputOption left,
  _FeatureInputOption right,
) {
  final groupCompare = _featureInputGroupRank(
    left.group,
  ).compareTo(_featureInputGroupRank(right.group));
  if (groupCompare != 0) {
    return groupCompare;
  }
  if (left.recommended != right.recommended) {
    return left.recommended ? -1 : 1;
  }
  return left.key.compareTo(right.key);
}

class ProjectAiRunsSection extends ConsumerStatefulWidget {
  const ProjectAiRunsSection({
    required this.project,
    this.initialRunId,
    super.key,
  });

  final ProjectSummary project;
  final String? initialRunId;

  @override
  ConsumerState<ProjectAiRunsSection> createState() =>
      _ProjectAiRunsSectionState();
}

class _ProjectAiRunsSectionState extends ConsumerState<ProjectAiRunsSection> {
  String? _selectedRunId;
  String? _lastAutoScrolledRunId;
  bool _startingRun = false;
  final Map<String, GlobalKey> _runKeys = <String, GlobalKey>{};
  final Map<String, AiRun> _runOverrides = <String, AiRun>{};

  @override
  void initState() {
    super.initState();
    _selectedRunId = _cleanRunId(widget.initialRunId);
  }

  @override
  void didUpdateWidget(covariant ProjectAiRunsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextRunId = _cleanRunId(widget.initialRunId);
    if (nextRunId != _cleanRunId(oldWidget.initialRunId)) {
      _selectedRunId = nextRunId;
      _scrollToRun(nextRunId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(aiSettingsProvider(widget.project.id));
    final runsAsync = ref.watch(aiProjectRunsProvider(widget.project.id));
    final publishedLayersAsync = ref.watch(
      publishedAiLayersProvider(widget.project.id),
    );
    final visibleRuns = _runsWithOverrides(runsAsync.asData?.value);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(title: 'AI Runs'),
              const SizedBox(height: AppSpacing.sm),
              const Text('View AI server run status and results.'),
              const SizedBox(height: AppSpacing.md),
              settingsAsync.when(
                loading: () => const LinearProgressIndicator(),
                error: (error, _) => Text(
                  userFacingErrorMessage(
                    error,
                    fallback: 'Unable to load AI run settings.',
                  ),
                ),
                data: (settings) {
                  final readinessQuery = AiReadinessQuery(
                    projectId: widget.project.id,
                    labelField: settings.labelField,
                    minSamplesPerClass: settings.minSamplesPerClass,
                    scopeType: settings.scopeType,
                  );
                  final readinessAsync = ref.watch(
                    aiReadinessProvider(readinessQuery),
                  );
                  final readiness = readinessAsync.asData?.value;
                  final runItems = runsAsync.asData?.value;
                  final runListReady =
                      runItems != null || _runOverrides.isNotEmpty;
                  final activeRun = runListReady
                      ? _activeRunFrom(visibleRuns)
                      : null;
                  final canStartRun =
                      !_startingRun &&
                      runListReady &&
                      activeRun == null &&
                      settings.isEnabled &&
                      (settings.labelField?.trim().isNotEmpty ?? false) &&
                      readiness != null &&
                      !readiness.isNotReady &&
                      readiness.aiServer.isConnected;
                  final startHelp = !runListReady
                      ? 'Checking active AI runs before starting.'
                      : activeRun != null
                      ? 'An AI run is already active for this project.'
                      : readinessAsync.when(
                          loading: () => 'Checking readiness before starting.',
                          error: (error, _) => userFacingErrorMessage(
                            error,
                            fallback:
                                'Unable to check readiness before starting.',
                          ),
                          data: (value) => value.aiServer.isConnected
                              ? 'Starts an AI run through the backend AI server.'
                              : _aiServerReadinessMessage(value.aiServer),
                        );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppButton(
                        label: _startingRun ? 'Starting...' : 'Start AI run',
                        icon: Icons.play_arrow_outlined,
                        isLoading: _startingRun,
                        onPressed: canStartRun
                            ? () => _startAiRun(settings)
                            : null,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(startHelp),
                      const SizedBox(height: AppSpacing.md),
                      publishedLayersAsync.when(
                        loading: () => const LinearProgressIndicator(),
                        error: (error, _) => _NoticeRow(
                          icon: Icons.error_outline,
                          text: userFacingErrorMessage(
                            error,
                            fallback:
                                'Unable to load the current published AI layer.',
                          ),
                        ),
                        data: (layers) => _PublishedRunTopSummary(
                          layer: _firstClassificationLayer(layers),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        runsAsync.when(
          loading: () => visibleRuns.isEmpty
              ? const AppCard(child: Center(child: CircularProgressIndicator()))
              : _buildRunsList(visibleRuns),
          error: (error, _) => AppEmptyState(
            icon: Icons.error_outline,
            title: 'AI runs unavailable',
            message: userFacingErrorMessage(
              error,
              fallback: 'Unable to load AI runs right now.',
            ),
            actionLabel: 'Retry',
            onAction: () =>
                ref.invalidate(aiProjectRunsProvider(widget.project.id)),
          ),
          data: (_) {
            if (visibleRuns.isEmpty) {
              return const AppCard(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.history_outlined),
                  title: Text('No AI run records yet'),
                  subtitle: Text(
                    'Start a run when settings and readiness are ready.',
                  ),
                ),
              );
            }
            return _buildRunsList(visibleRuns);
          },
        ),
      ],
    );
  }

  Widget _buildRunsList(List<AiRun> runs) {
    _scrollToRun(_selectedRunId);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final run in runs) ...[
            KeyedSubtree(
              key: _runKey(run.id),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.manage_history_outlined),
                    title: Text(_runDisplayTitle(run)),
                    subtitle: Text(
                      [
                        _friendlyStatusLabel(run.status),
                        '${_runPredictionCount(run)} predictions',
                        run.labelField ?? 'No label',
                      ].join(' - '),
                    ),
                    trailing: StatusChip(status: run.status),
                    onTap: () => _toggleRun(run.id),
                  ),
                  if (run.failureReason?.trim().isNotEmpty ?? false)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: Text('Failure: ${run.failureReason}'),
                    ),
                  if (_selectedRunId == run.id) ...[
                    const SizedBox(height: AppSpacing.sm),
                    _AiRunDetailCard(
                      runId: run.id,
                      initialRun: run,
                      onRunUpdated: _upsertLocalRun,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                ],
              ),
            ),
            if (run != runs.last) const Divider(height: 1),
          ],
        ],
      ),
    );
  }

  GlobalKey _runKey(String runId) {
    return _runKeys.putIfAbsent(runId, GlobalKey.new);
  }

  void _toggleRun(String runId) {
    final willOpen = _selectedRunId != runId;
    setState(() => _selectedRunId = willOpen ? runId : null);
    if (willOpen) {
      _scrollToRun(runId, force: true);
    }
  }

  void _scrollToRun(String? runId, {bool force = false}) {
    if (runId == null) {
      return;
    }
    if (!force && _lastAutoScrolledRunId == runId) {
      return;
    }
    if (!force) {
      _lastAutoScrolledRunId = runId;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _runKeys[runId]?.currentContext;
      if (context == null || !mounted) {
        return;
      }
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        alignment: 0.05,
      );
    });
  }

  Future<void> _startAiRun(AiProjectSettings settings) async {
    setState(() => _startingRun = true);
    try {
      final run = await ref
          .read(aiRepositoryProvider)
          .createRun(
            projectId: widget.project.id,
            status: 'starting',
            labelField: settings.labelField,
            scopeType: settings.scopeType,
            minSamplesPerClass: settings.minSamplesPerClass,
            executionMode: 'regional_full_review_artifacts',
          );
      _selectedRunId = run.id;
      _upsertLocalRun(run);
      if (mounted) {
        AppSnackbar.showSuccess(context, 'AI run started.');
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to start AI run right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _startingRun = false);
      }
    }
  }

  List<AiRun> _runsWithOverrides(List<AiRun>? baseRuns) {
    final byId = <String, AiRun>{};
    for (final run in baseRuns ?? const <AiRun>[]) {
      byId[run.id] = run;
    }
    for (final run in _runOverrides.values) {
      final existing = byId[run.id];
      byId[run.id] = existing == null ? run : _preferNewestRun(existing, run);
    }
    final runs = byId.values.toList(growable: false);
    runs.sort(_compareRunsNewestFirst);
    return runs;
  }

  void _upsertLocalRun(AiRun run) {
    setState(() {
      _runOverrides[run.id] = run;
    });
    ref.invalidate(aiProjectRunsProvider(run.projectId));
    ref.invalidate(aiRunsProvider);
  }
}

String? _cleanRunId(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

int _compareRunsNewestFirst(AiRun left, AiRun right) {
  final leftDate = left.createdAt ?? left.startedAt ?? left.updatedAt;
  final rightDate = right.createdAt ?? right.startedAt ?? right.updatedAt;
  if (leftDate != null && rightDate != null) {
    final dateCompare = rightDate.compareTo(leftDate);
    if (dateCompare != 0) {
      return dateCompare;
    }
  } else if (leftDate != null) {
    return -1;
  } else if (rightDate != null) {
    return 1;
  }
  return left.id.compareTo(right.id);
}

AiRun _preferNewestRun(AiRun preferred, AiRun fallback) {
  if (preferred.id != fallback.id) {
    return fallback;
  }
  final preferredDate =
      preferred.updatedAt ??
      preferred.callbackReceivedAt ??
      preferred.completedAt ??
      preferred.startedAt ??
      preferred.createdAt;
  final fallbackDate =
      fallback.updatedAt ??
      fallback.callbackReceivedAt ??
      fallback.completedAt ??
      fallback.startedAt ??
      fallback.createdAt;
  if (preferredDate != null && fallbackDate != null) {
    return preferredDate.isBefore(fallbackDate) ? fallback : preferred;
  }
  if (fallbackDate != null && preferredDate == null) {
    return fallback;
  }
  return preferred;
}

class _PublishedRunTopSummary extends StatelessWidget {
  const _PublishedRunTopSummary({required this.layer});

  final AiOutputLayer? layer;

  @override
  Widget build(BuildContext context) {
    final publishedLayer = layer;
    final runId = publishedLayer?.aiRunId?.trim() ?? '';
    if (publishedLayer == null || runId.isEmpty) {
      return const _NoticeRow(
        icon: Icons.layers_clear_outlined,
        text: 'No AI layer is currently published.',
      );
    }

    final predictionCount = publishedLayer.predictionCount > 0
        ? publishedLayer.predictionCount
        : publishedLayer.runPredictionCount;
    final runLabel = _publishedRunDisplayLabel(publishedLayer);
    final rows = <MapEntry<String, String>>[
      MapEntry('Published Run', runLabel),
      MapEntry('Prediction Count', '$predictionCount'),
      MapEntry(
        'Published At',
        publishedLayer.publishedAt == null
            ? 'Not recorded'
            : formatLebanonDate(publishedLayer.publishedAt!),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Current Published AI Layer',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: AppSpacing.xs),
        for (final row in rows)
          Padding(
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
      ],
    );
  }
}

String _publishedRunDisplayLabel(AiOutputLayer layer) {
  final runId = layer.aiRunId?.trim() ?? '';
  final displayName = layer.runDisplayName?.trim();
  if (displayName != null && displayName.isNotEmpty) {
    final lower = displayName.toLowerCase();
    if (lower.startsWith('run ')) {
      return displayName;
    }
    if (displayName == runId || _looksLikeUuid(displayName)) {
      return 'Run ${_shortId(displayName)}';
    }
  }
  return 'Run ${_shortId(runId)}';
}

bool _looksLikeUuid(String value) {
  return RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  ).hasMatch(value.trim());
}

class _AiRunDetailCard extends ConsumerStatefulWidget {
  const _AiRunDetailCard({
    required this.runId,
    required this.initialRun,
    required this.onRunUpdated,
  });

  final String runId;
  final AiRun initialRun;
  final ValueChanged<AiRun> onRunUpdated;

  @override
  ConsumerState<_AiRunDetailCard> createState() => _AiRunDetailCardState();
}

class _AiRunDetailCardState extends ConsumerState<_AiRunDetailCard> {
  AiRun? _localRun;

  @override
  void didUpdateWidget(covariant _AiRunDetailCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runId != widget.runId) {
      _localRun = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final runAsync = ref.watch(aiRunProvider(widget.runId));
    final metricsAsync = ref.watch(aiRunMetricsProvider(widget.runId));
    final layersAsync = ref.watch(aiRunLayersProvider(widget.runId));

    return runAsync.when(
      loading: () => _buildDetails(
        run: _localRun ?? widget.initialRun,
        metricsAsync: metricsAsync,
        layersAsync: layersAsync,
      ),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'AI run unavailable',
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to load this AI run right now.',
        ),
      ),
      data: (run) {
        return _buildDetails(
          run: _localRun ?? _preferNewestRun(widget.initialRun, run),
          metricsAsync: metricsAsync,
          layersAsync: layersAsync,
        );
      },
    );
  }

  Widget _buildDetails({
    required AiRun run,
    required AsyncValue<List<AiRunMetric>> metricsAsync,
    required AsyncValue<List<AiOutputLayer>> layersAsync,
  }) {
    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpacing.md,
        right: AppSpacing.md,
        bottom: AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RunDetailSectionCard(
            title: 'Run summary',
            trailing: StatusChip(status: run.status),
            child: _RunStatusSection(run: run),
          ),
          const SizedBox(height: AppSpacing.md),
          _RunActionBar(
            run: run,
            onRunUpdated: (updated) {
              setState(() => _localRun = updated);
              widget.onRunUpdated(updated);
            },
          ),
          if (run.failureReason?.trim().isNotEmpty ?? false) ...[
            const SizedBox(height: AppSpacing.md),
            _RunDetailSectionCard(
              title: 'Failure reason',
              child: _NoticeRow(
                icon: Icons.error_outline,
                text: _safeText(run.failureReason!),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          _RunDetailSectionCard(
            title: 'Model summary',
            child: _ModelResultSection(run: run, metricsAsync: metricsAsync),
          ),
          const SizedBox(height: AppSpacing.md),
          _RunDetailSectionCard(
            title: 'Run configuration',
            child: _AiRunSettingsSection(run: run),
          ),
          const SizedBox(height: AppSpacing.md),
          _RunDetailSectionCard(
            title: 'Output Layer',
            child: _AiOutputLayersSection(run: run, layersAsync: layersAsync),
          ),
          const SizedBox(height: AppSpacing.md),
          _RunDetailSectionCard(
            title: 'Validation summary',
            child: _RunValidationSummary(run: run),
          ),
          const SizedBox(height: AppSpacing.md),
          _RunDetailSectionCard(
            title: 'Retraining recommendation',
            child: _RetrainRecommendationSection(run: run),
          ),
          const SizedBox(height: AppSpacing.md),
          _RunDetailSectionCard(
            title: 'AI output files',
            child: _OutputPathsSection(run: run),
          ),
        ],
      ),
    );
  }
}

class _RunDetailSectionCard extends StatelessWidget {
  const _RunDetailSectionCard({
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: AppSpacing.sm),
                  trailing!,
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            child,
          ],
        ),
      ),
    );
  }
}

class _RunActionBar extends ConsumerStatefulWidget {
  const _RunActionBar({required this.run, required this.onRunUpdated});

  final AiRun run;
  final ValueChanged<AiRun> onRunUpdated;

  @override
  ConsumerState<_RunActionBar> createState() => _RunActionBarState();
}

class _RunActionBarState extends ConsumerState<_RunActionBar> {
  bool _refreshing = false;
  bool _cancelling = false;
  bool _resuming = false;

  @override
  Widget build(BuildContext context) {
    final actions = <Widget>[
      AppButton(
        label: _refreshing ? 'Checking...' : 'Check status',
        icon: Icons.refresh_outlined,
        isLoading: _refreshing,
        variant: AppButtonVariant.outlined,
        onPressed: _cancelling || _resuming ? null : _refreshRunStatus,
      ),
      if (widget.run.canCancel)
        AppButton(
          label: _cancelling ? 'Cancelling...' : 'Cancel run',
          icon: Icons.cancel_outlined,
          isLoading: _cancelling,
          variant: AppButtonVariant.outlined,
          onPressed: _refreshing || _resuming ? null : _cancelRun,
        ),
      if (widget.run.canResume)
        AppButton(
          label: _resuming ? 'Resuming...' : 'Resume run',
          icon: Icons.replay_outlined,
          isLoading: _resuming,
          onPressed: _refreshing || _cancelling ? null : _resumeRun,
        ),
    ];
    return AppButtonRow(stackBelowWidth: 640, children: actions);
  }

  Future<void> _refreshRunStatus() async {
    setState(() => _refreshing = true);
    try {
      final updated = await ref
          .read(aiRepositoryProvider)
          .fetchRunStatus(
            projectId: widget.run.projectId,
            runId: widget.run.id,
          );
      widget.onRunUpdated(updated);
      _refreshRunDetailProviders(updated);
      if (mounted) {
        AppSnackbar.showSuccess(context, 'AI run status refreshed.');
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to refresh this AI run right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _cancelRun() async {
    if (!widget.run.canCancel) {
      AppSnackbar.showInfo(context, 'This AI run is not active.');
      return;
    }
    setState(() => _cancelling = true);
    try {
      final updated = await ref
          .read(aiRepositoryProvider)
          .cancelRun(projectId: widget.run.projectId, runId: widget.run.id);
      widget.onRunUpdated(updated);
      _refreshRunDetailProviders(updated);
      if (mounted) {
        AppSnackbar.showSuccess(context, 'Cancellation requested.');
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to cancel this AI run right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _cancelling = false);
      }
    }
  }

  Future<void> _resumeRun() async {
    if (!widget.run.canResume) {
      AppSnackbar.showInfo(context, 'This AI run cannot be resumed.');
      return;
    }
    setState(() => _resuming = true);
    try {
      final updated = await ref
          .read(aiRepositoryProvider)
          .resumeRun(projectId: widget.run.projectId, runId: widget.run.id);
      widget.onRunUpdated(updated);
      _refreshRunDetailProviders(updated);
      if (mounted) {
        AppSnackbar.showSuccess(context, 'Resume requested.');
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to resume this AI run right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _resuming = false);
      }
    }
  }

  void _refreshRunDetailProviders(AiRun run) {
    ref.invalidate(aiRunProvider(run.id));
    ref.invalidate(aiProjectRunsProvider(run.projectId));
    ref.invalidate(aiRunsProvider);
    ref.invalidate(aiRunMetricsProvider(run.id));
    ref.invalidate(aiRunLayersProvider(run.id));
    ref.invalidate(
      aiRunValidationSummaryProvider((projectId: run.projectId, runId: run.id)),
    );
    ref.invalidate(aiRunLogsProvider(run.id));
    ref.invalidate(aiRunReviewsProvider(run.id));
    ref.invalidate(publishedAiLayersProvider(run.projectId));
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

class _RetrainRecommendationSection extends ConsumerWidget {
  const _RetrainRecommendationSection({required this.run});

  final AiRun run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<AiRetrainRecommendation>(
      future: ref
          .read(aiRepositoryProvider)
          .fetchRetrainRecommendation(projectId: run.projectId, runId: run.id),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const LinearProgressIndicator();
        }
        if (snapshot.hasError) {
          return Text(
            userFacingErrorMessage(
              snapshot.error ?? 'Retraining recommendation unavailable.',
              fallback: 'Unable to check retraining recommendation right now.',
            ),
          );
        }
        final recommendation = snapshot.data;
        if (recommendation == null) {
          return const Text('No retraining recommendation returned.');
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StatusChip(
              status: recommendation.shouldRetrain ? 'ready' : 'not_ready',
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(_safeText(recommendation.reason)),
            if (recommendation.signals.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              _KeyValueList(
                title: 'Signals',
                rows: recommendation.signals.entries
                    .map((entry) => MapEntry(entry.key, '${entry.value}'))
                    .toList(growable: false),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _AiRunSettingsSection extends StatelessWidget {
  const _AiRunSettingsSection({required this.run});

  final AiRun run;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _KeyValueList(title: 'Imagery', rows: _runImageryRows(run)),
        const SizedBox(height: AppSpacing.sm),
        _KeyValueList(
          title: 'Training samples',
          rows: _runTrainingSampleRows(run),
        ),
        const SizedBox(height: AppSpacing.sm),
        _KeyValueList(
          title: 'Prediction area',
          rows: _runPredictionAreaRows(run),
        ),
        const SizedBox(height: AppSpacing.sm),
        _KeyValueList(
          title: 'Extracted features',
          rows: _runExtractedFeatureRows(run),
        ),
        const SizedBox(height: AppSpacing.sm),
        _KeyValueList(title: 'Model', rows: _runModelConfigRows(run)),
      ],
    );
  }
}

class _OutputPathsSection extends StatelessWidget {
  const _OutputPathsSection({required this.run});

  final AiRun run;

  @override
  Widget build(BuildContext context) {
    final paths = _outputPathsForRun(run);
    final rows = paths
        .map(
          (path) => MapEntry(_friendlyOutputPathLabel(path), _safeText(path)),
        )
        .toList(growable: false);

    return ExpansionTile(
      key: PageStorageKey<String>('technical-output-files-${run.id}'),
      maintainState: true,
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      expandedAlignment: Alignment.centerLeft,
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      title: const Text('Technical output files'),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _NoticeRow(
              icon: Icons.folder_copy_outlined,
              text: paths.isEmpty
                  ? 'No technical output files were reported for this run.'
                  : 'AI server output files reported for this run.',
            ),
            const SizedBox(height: AppSpacing.sm),
            _KeyValueList(
              title: 'Output files',
              emptyText:
                  'No prediction GeoJSON, raster, metrics, feature table, or run log paths were reported.',
              rows: rows,
            ),
            const SizedBox(height: AppSpacing.sm),
            _KeyValueList(
              title: 'Prediction registration',
              rows: [
                MapEntry(
                  'Prediction features inserted',
                  '${_runPredictionCount(run)}',
                ),
                if (run.counts.isNotEmpty)
                  MapEntry('Count fields', run.counts.keys.join(', ')),
              ],
            ),
          ],
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
        const SizedBox(height: AppSpacing.sm),
        _ConfusionMatrixSection(metrics: metrics),
        const SizedBox(height: AppSpacing.sm),
        _FeatureImportanceSection(metrics: metrics),
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

class _ConfusionMatrixSection extends StatefulWidget {
  const _ConfusionMatrixSection({required this.metrics});

  final List<AiRunMetric> metrics;

  @override
  State<_ConfusionMatrixSection> createState() =>
      _ConfusionMatrixSectionState();
}

class _ConfusionMatrixSectionState extends State<_ConfusionMatrixSection> {
  late final ScrollController _horizontalController;

  @override
  void initState() {
    super.initState();
    _horizontalController = ScrollController();
  }

  @override
  void dispose() {
    _horizontalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matrix = _firstConfusionMatrix(widget.metrics);
    if (matrix.rows.isEmpty || matrix.predictedLabels.isEmpty) {
      return const _NoticeRow(
        icon: Icons.grid_off_outlined,
        text: 'No confusion matrix was generated for this run.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Confusion matrix', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        Scrollbar(
          controller: _horizontalController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _horizontalController,
            scrollDirection: Axis.horizontal,
            primary: false,
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: DataTable(
                columnSpacing: 18,
                columns: [
                  const DataColumn(label: Text('Actual \\ Predicted')),
                  for (final label in matrix.predictedLabels)
                    DataColumn(label: Text(label)),
                  const DataColumn(label: Text('Total')),
                ],
                rows: [
                  for (final row in matrix.rows)
                    DataRow(
                      cells: [
                        DataCell(Text(row.actualLabel)),
                        for (final label in matrix.predictedLabels)
                          DataCell(Text((row.values[label] ?? 0).toString())),
                        DataCell(Text(row.total.toString())),
                      ],
                    ),
                  if (matrix.columnTotals.isNotEmpty)
                    DataRow(
                      cells: [
                        const DataCell(Text('Total')),
                        for (final label in matrix.predictedLabels)
                          DataCell(
                            Text((matrix.columnTotals[label] ?? 0).toString()),
                          ),
                        DataCell(Text(matrix.grandTotal.toString())),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _FeatureImportanceSection extends StatelessWidget {
  const _FeatureImportanceSection({required this.metrics});

  final List<AiRunMetric> metrics;

  @override
  Widget build(BuildContext context) {
    final rows = _firstFeatureImportance(metrics);
    if (rows.isEmpty) {
      return const _NoticeRow(
        icon: Icons.bar_chart_outlined,
        text: 'No feature importance data was generated for this run.',
      );
    }
    final maxImportance = rows
        .map((row) => row.importance)
        .fold<double>(0, (max, value) => value > max ? value : max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Feature importance',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: AppSpacing.xs),
        for (final row in rows.take(20))
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final progress = maxImportance <= 0
                    ? 0.0
                    : (row.importance / maxImportance).clamp(0, 1).toDouble();
                final valueText = Text(
                  row.importance.toStringAsFixed(4),
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.bodySmall,
                );
                if (constraints.maxWidth < 520) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.feature,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: LinearProgressIndicator(value: progress),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          SizedBox(width: 64, child: valueText),
                        ],
                      ),
                    ],
                  );
                }
                final contentWidth = constraints.maxWidth
                    .clamp(340.0, 560.0)
                    .toDouble();
                final labelWidth = constraints.maxWidth < 680 ? 136.0 : 156.0;
                return ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: contentWidth),
                  child: Row(
                    children: [
                      SizedBox(
                        width: labelWidth,
                        child: Text(
                          row.feature,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 2,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(child: LinearProgressIndicator(value: progress)),
                      const SizedBox(width: AppSpacing.sm),
                      SizedBox(width: 68, child: valueText),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _ConfusionMatrixData {
  const _ConfusionMatrixData({
    required this.predictedLabels,
    required this.rows,
    required this.columnTotals,
    required this.grandTotal,
  });

  final List<String> predictedLabels;
  final List<_ConfusionMatrixRow> rows;
  final Map<String, int> columnTotals;
  final int grandTotal;
}

class _ConfusionMatrixRow {
  const _ConfusionMatrixRow({
    required this.actualLabel,
    required this.values,
    required this.total,
  });

  final String actualLabel;
  final Map<String, int> values;
  final int total;
}

class _FeatureImportanceRow {
  const _FeatureImportanceRow({
    required this.feature,
    required this.importance,
  });

  final String feature;
  final double importance;
}

_ConfusionMatrixData _firstConfusionMatrix(List<AiRunMetric> metrics) {
  for (final metric in metrics) {
    final parsed = _parseConfusionMatrix(metric.confusionMatrix);
    if (parsed.rows.isNotEmpty) {
      return parsed;
    }
  }
  return const _ConfusionMatrixData(
    predictedLabels: <String>[],
    rows: <_ConfusionMatrixRow>[],
    columnTotals: <String, int>{},
    grandTotal: 0,
  );
}

_ConfusionMatrixData _parseConfusionMatrix(Object? raw) {
  final rowsSource = raw is Map
      ? (raw['rows'] ?? raw['matrix'] ?? raw['data'])
      : raw;
  if (rowsSource is! List) {
    return const _ConfusionMatrixData(
      predictedLabels: <String>[],
      rows: <_ConfusionMatrixRow>[],
      columnTotals: <String, int>{},
      grandTotal: 0,
    );
  }
  final predictedLabels = <String>{};
  final rows = <_ConfusionMatrixRow>[];
  for (final rawRow in rowsSource) {
    if (rawRow is! Map) {
      continue;
    }
    final row = Map<String, dynamic>.from(rawRow);
    final actual =
        row['actual']?.toString() ??
        row['actual_class']?.toString() ??
        row['label']?.toString() ??
        '';
    if (actual.trim().isEmpty) {
      continue;
    }
    final values = <String, int>{};
    for (final entry in row.entries) {
      final key = entry.key;
      if (const {'actual', 'actual_class', 'label', 'total'}.contains(key)) {
        continue;
      }
      final count = _intFrom(entry.value);
      if (count == null) {
        continue;
      }
      predictedLabels.add(key);
      values[key] = count;
    }
    rows.add(
      _ConfusionMatrixRow(
        actualLabel: actual,
        values: values,
        total:
            _intFrom(row['total']) ??
            values.values.fold<int>(0, (sum, value) => sum + value),
      ),
    );
  }
  final sortedLabels = predictedLabels.toList()..sort();
  final totals = <String, int>{
    for (final label in sortedLabels)
      label: rows.fold<int>(0, (sum, row) => sum + (row.values[label] ?? 0)),
  };
  return _ConfusionMatrixData(
    predictedLabels: sortedLabels,
    rows: rows,
    columnTotals: totals,
    grandTotal: totals.values.fold<int>(0, (sum, value) => sum + value),
  );
}

List<_FeatureImportanceRow> _firstFeatureImportance(List<AiRunMetric> metrics) {
  for (final metric in metrics) {
    final rows = _parseFeatureImportance(metric.featureImportance);
    if (rows.isNotEmpty) {
      return rows;
    }
  }
  return const <_FeatureImportanceRow>[];
}

List<_FeatureImportanceRow> _parseFeatureImportance(Object? raw) {
  final rowsSource = raw is Map
      ? (raw['rows'] ?? raw['features'] ?? raw['data'])
      : raw;
  if (rowsSource is! List) {
    return const <_FeatureImportanceRow>[];
  }
  final rows = <_FeatureImportanceRow>[];
  for (final rawRow in rowsSource) {
    if (rawRow is! Map) {
      continue;
    }
    final row = Map<String, dynamic>.from(rawRow);
    final feature =
        row['feature']?.toString() ??
        row['feature_name']?.toString() ??
        row['name']?.toString() ??
        '';
    final importance = _doubleFrom(
      row['importance'] ?? row['score'] ?? row['value'],
    );
    if (feature.trim().isEmpty || importance == null) {
      continue;
    }
    rows.add(_FeatureImportanceRow(feature: feature, importance: importance));
  }
  rows.sort((a, b) => b.importance.compareTo(a.importance));
  return rows;
}

int? _intFrom(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  return int.tryParse(value?.toString() ?? '');
}

double? _doubleFrom(Object? value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '');
}

String _friendlyMetadataKey(String key) => key
    .split(RegExp(r'[_\s-]+'))
    .where((part) => part.isNotEmpty)
    .map((part) => part[0].toUpperCase() + part.substring(1))
    .join(' ');

class _RunValidationSummary extends ConsumerWidget {
  const _RunValidationSummary({required this.run});

  final AiRun run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(
      aiRunValidationSummaryProvider((projectId: run.projectId, runId: run.id)),
    );

    return summaryAsync.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, _) => Text(
        userFacingErrorMessage(
          error,
          fallback: 'Unable to load AI validation summary.',
        ),
      ),
      data: (summary) {
        if (summary.totalAiFeatures == 0) {
          return const _NoticeRow(
            icon: Icons.rule_folder_outlined,
            text: 'No AI prediction features are linked to this run yet.',
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _KeyValueList(
              title: 'AI prediction validation',
              rows: <MapEntry<String, String>>[
                MapEntry('Total AI features', '${summary.totalAiFeatures}'),
                MapEntry('Published features', '${summary.publishedFeatures}'),
                MapEntry(
                  'Contributor validations',
                  '${summary.contributorValidationsSubmitted}',
                ),
                MapEntry(
                  'Features with contributor validation',
                  '${summary.featuresValidatedByContributor}',
                ),
                MapEntry(
                  'Admin approved/promoted',
                  '${summary.adminApprovedPromoted}',
                ),
                MapEntry('Rejected', '${summary.rejected}'),
                MapEntry('Pending', '${summary.pending}'),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            const _NoticeRow(
              icon: Icons.info_outline,
              text:
                  'This is one AI classification layer. Confidence is an attribute and does not block validation.',
            ),
            if (summary.confidenceDistribution.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              _KeyValueList(
                title: 'Confidence distribution',
                rows: summary.confidenceDistribution.entries
                    .map(
                      (entry) => MapEntry(
                        _friendlyMetadataKey(entry.key),
                        '${entry.value}',
                      ),
                    )
                    .toList(growable: false),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _AiOutputLayersSection extends ConsumerWidget {
  const _AiOutputLayersSection({required this.run, required this.layersAsync});

  final AiRun run;
  final AsyncValue<List<AiOutputLayer>> layersAsync;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return layersAsync.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, _) => Text(
        userFacingErrorMessage(
          error,
          fallback: 'Unable to load AI output layers.',
        ),
      ),
      data: (layers) {
        final visibleLayers = layers
            .where((layer) => layer.layerType == 'classification')
            .toList(growable: false);
        final previewLayers = visibleLayers
            .where(_isPreviewableAiLayer)
            .toList(growable: false);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _NoticeRow(
              icon: Icons.visibility_off_outlined,
              text: 'Project Map shows published AI map layers only.',
            ),
            const SizedBox(height: AppSpacing.xs),
            if (visibleLayers.isEmpty)
              const _NoticeRow(
                icon: Icons.layers_clear_outlined,
                text: 'No AI classification layer has been registered yet.',
              )
            else
              _LayerStatusSummary(layers: visibleLayers),
            if (previewLayers.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              const _NoticeRow(
                icon: Icons.admin_panel_settings_outlined,
                text: 'Preview is protected super-admin review only.',
              ),
              const SizedBox(height: AppSpacing.sm),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('Preview map'),
                  onPressed: () => context.push(
                    AppRoutes.projectAiPreview(run.projectId, run.id),
                  ),
                ),
              ),
            ],
            if (visibleLayers.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              for (final layer in visibleLayers)
                _AiOutputLayerTile(
                  run: run,
                  layer: layer,
                  onPublish: _canPublishAiLayer(layer)
                      ? () => _publishLayer(context, ref, run, layer)
                      : null,
                  onUnpublish: _canUnpublishAiLayer(layer)
                      ? () => _unpublishLayer(context, ref, run, layer)
                      : null,
                ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _publishLayer(
    BuildContext context,
    WidgetRef ref,
    AiRun run,
    AiOutputLayer layer,
  ) async {
    try {
      await ref.read(aiRepositoryProvider).publishLayer(layerId: layer.id);
      if (!context.mounted) {
        return;
      }
      AppSnackbar.showSuccess(
        context,
        'AI layer published as a read-only map overlay.',
      );
      _refreshLayerReviewState(ref, run, refreshRun: false);
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      AppSnackbar.showError(
        context,
        userFacingErrorMessage(
          error,
          fallback: 'Unable to publish this AI layer.',
        ),
      );
    }
  }

  Future<void> _unpublishLayer(
    BuildContext context,
    WidgetRef ref,
    AiRun run,
    AiOutputLayer layer,
  ) async {
    try {
      await ref.read(aiRepositoryProvider).unpublishLayer(layerId: layer.id);
      if (!context.mounted) {
        return;
      }
      AppSnackbar.showSuccess(context, 'AI layer unpublished.');
      _refreshLayerReviewState(ref, run, refreshRun: false);
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      AppSnackbar.showError(
        context,
        userFacingErrorMessage(
          error,
          fallback: 'Unable to unpublish this AI layer.',
        ),
      );
    }
  }

  void _refreshLayerReviewState(
    WidgetRef ref,
    AiRun run, {
    bool refreshRun = true,
  }) {
    ref.invalidate(aiRunLayersProvider(run.id));
    if (refreshRun) {
      ref.invalidate(aiRunProvider(run.id));
    }
    ref.invalidate(publishedAiLayersProvider(run.projectId));
  }
}

bool _isPreviewableAiLayer(AiOutputLayer layer) {
  const statuses = {'draft', 'ready_for_review', 'approved', 'published'};
  return layer.layerType == 'classification' && statuses.contains(layer.status);
}

bool _canPublishAiLayer(AiOutputLayer layer) {
  return layer.layerType == 'classification' &&
      (layer.status == 'approved' || layer.status == 'ready_for_review');
}

bool _canUnpublishAiLayer(AiOutputLayer layer) =>
    layer.status == 'published' && _isPreviewableAiLayer(layer);

AiOutputLayer? _primaryPreviewFeatureListLayer(List<AiOutputLayer> layers) {
  for (final layer in layers) {
    if (layer.layerType == 'classification') {
      return layer;
    }
  }
  return layers.isEmpty ? null : layers.first;
}

class _LayerStatusSummary extends StatelessWidget {
  const _LayerStatusSummary({required this.layers});

  final List<AiOutputLayer> layers;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final layer in layers)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('${_friendlyLayerTypeLabel(layer.layerType)} layer'),
                Text(
                  _friendlyLayerStatusTitle(layer.status),
                  style: Theme.of(context).textTheme.bodySmall,
                  softWrap: true,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _AiOutputLayerTile extends StatelessWidget {
  const _AiOutputLayerTile({
    required this.run,
    required this.layer,
    this.onPublish,
    this.onUnpublish,
  });

  final AiRun run;
  final AiOutputLayer layer;
  final VoidCallback? onPublish;
  final VoidCallback? onUnpublish;

  @override
  Widget build(BuildContext context) {
    final summaryRows = _layerSummaryRows(layer, run);
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
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: StatusChip(status: layer.status),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    Icons.layers_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      '${_friendlyLayerTypeLabel(layer.layerType)} layer',
                      style: Theme.of(context).textTheme.titleSmall,
                      softWrap: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              _KeyValueList(title: 'Layer details', rows: summaryRows),
              if (onPublish != null || onUnpublish != null) ...[
                const SizedBox(height: AppSpacing.sm),
                const _NoticeRow(
                  icon: Icons.info_outline,
                  text:
                      'Publishing makes this AI layer visible as a read-only Project Map overlay.',
                ),
                const SizedBox(height: AppSpacing.xs),
                if (onPublish != null)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: onPublish,
                      icon: const Icon(Icons.public_outlined),
                      label: const Text('Publish'),
                    ),
                  ),
                if (onUnpublish != null)
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: onUnpublish,
                      icon: const Icon(Icons.visibility_off_outlined),
                      label: const Text('Unpublish'),
                    ),
                  ),
              ],
              if (technicalRows.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                ExpansionTile(
                  key: PageStorageKey<String>('ai-layer-technical-${layer.id}'),
                  maintainState: true,
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

class ProjectAiPreviewMapScreen extends ConsumerStatefulWidget {
  const ProjectAiPreviewMapScreen({
    required this.projectId,
    required this.runId,
    super.key,
  });

  final String projectId;
  final String runId;

  @override
  ConsumerState<ProjectAiPreviewMapScreen> createState() =>
      _ProjectAiPreviewMapScreenState();
}

class _ProjectAiPreviewMapScreenState
    extends ConsumerState<ProjectAiPreviewMapScreen> {
  final MapController _mapController = MapController();
  final LayerHitNotifier<_AiPreviewFeature> _previewPolygonHitNotifier =
      ValueNotifier(null);
  final LayerHitNotifier<_AiPreviewFeature> _previewPolylineHitNotifier =
      ValueNotifier(null);

  MapCamera? _latestCamera;
  Timer? _viewportFeatureRefreshTimer;
  LebanonBasemapStyle _basemapStyle = LebanonBasemapStyle.street;
  bool _showClassification = true;
  bool _panelExpanded = false;
  String? _selectedClassFilter;
  String? _selectedFeatureKey;
  _AiPreviewFeature? _selectedFeatureOverride;
  String? _featureViewportBounds;
  double? _featureViewportZoom;
  DateTime? _suppressProgrammaticViewportRefreshUntil;
  final Map<String, AiLayerFeatureCollection> _lastLayerCollections =
      <String, AiLayerFeatureCollection>{};
  final Set<String> _knownPreviewClasses = <String>{};

  @override
  void initState() {
    super.initState();
    final initialZoom = _aiPreviewZoomBucket(
      LebanonMapConfig.fullscreenInitialZoom,
    );
    _featureViewportBounds = _aiLayerBoundsQuery(
      LebanonMapConfig.bounds,
      initialZoom,
    );
    _featureViewportZoom = initialZoom;
  }

  @override
  void dispose() {
    _viewportFeatureRefreshTimer?.cancel();
    _previewPolygonHitNotifier.dispose();
    _previewPolylineHitNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authControllerProvider).session;
    if (session?.user.isProtectedSuperAdmin != true) {
      return const AppEmptyState(
        icon: Icons.lock_outline,
        title: 'AI preview restricted',
        message: 'Only the protected super-admin can preview AI layers.',
      );
    }

    final runAsync = ref.watch(aiRunProvider(widget.runId));
    final layersAsync = ref.watch(aiRunLayersProvider(widget.runId));

    return runAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'AI run unavailable',
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to load this AI run.',
        ),
      ),
      data: (run) => layersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => AppEmptyState(
          icon: Icons.error_outline,
          title: 'AI layers unavailable',
          message: userFacingErrorMessage(
            error,
            fallback: 'Unable to load AI output layers.',
          ),
        ),
        data: (layers) => _buildPreview(run, layers),
      ),
    );
  }

  Widget _buildPreview(AiRun run, List<AiOutputLayer> layers) {
    final previewLayers = layers.where(_isPreviewableAiLayer).toList();
    final activeLayerTypes = <String>{
      if (_showClassification) 'classification',
    };
    final activeLayers = previewLayers
        .where((layer) => activeLayerTypes.contains(layer.layerType))
        .toList(growable: false);

    final collections = <AiLayerFeatureCollection>[];
    final summaryCollections = <AiLayerFeatureCollection>[];
    final errors = <String>[];
    var loading = false;
    for (final layer in activeLayers) {
      final cacheKey = _previewCollectionCacheKey(layer.id);
      final summaryCacheKey = _previewSummaryCacheKey(layer.id);
      final cachedCollection = _lastLayerCollections[cacheKey];
      final cachedSummaryCollection = _lastLayerCollections[summaryCacheKey];
      ref
          .watch(aiLayerFeaturesProvider(_summaryQuery(layer.id)))
          .when<void>(
            loading: () {
              loading = true;
              if (cachedSummaryCollection != null) {
                summaryCollections.add(cachedSummaryCollection);
              }
            },
            error: (error, _) {
              errors.add(
                '${_friendlyLayerTypeLabel(layer.layerType)} summary: '
                '${userFacingErrorMessage(error, fallback: 'Unable to load layer summary.')}',
              );
              if (cachedSummaryCollection != null) {
                summaryCollections.add(cachedSummaryCollection);
              }
            },
            data: (collection) {
              _lastLayerCollections[summaryCacheKey] = collection;
              summaryCollections.add(collection);
            },
          );
      ref
          .watch(aiLayerFeaturesProvider(_featureQuery(layer.id)))
          .when<void>(
            loading: () {
              loading = true;
              if (cachedCollection != null) {
                collections.add(cachedCollection);
              }
            },
            error: (error, _) {
              errors.add(
                '${_friendlyLayerTypeLabel(layer.layerType)}: '
                '${userFacingErrorMessage(error, fallback: 'Unable to load layer features.')}',
              );
              if (cachedCollection != null) {
                collections.add(cachedCollection);
              }
            },
            data: (collection) {
              _lastLayerCollections[cacheKey] = collection;
              collections.add(collection);
            },
          );
    }

    final features = <_AiPreviewFeature>[
      for (final collection in collections)
        for (final feature in collection.features)
          _AiPreviewFeature(layer: collection.layer, feature: feature),
    ];
    final selectedOverride = _selectedFeatureOverride;
    if (selectedOverride != null &&
        activeLayerTypes.contains(selectedOverride.layer.layerType) &&
        !features.any((item) => item.key == selectedOverride.key)) {
      features.add(selectedOverride);
    }
    final loadSummary = _AiPreviewLoadSummary.fromCollections(
      summaryCollections,
    );
    final featureListLayer = _primaryPreviewFeatureListLayer(previewLayers);
    final classOptions = _previewClassOptions(<AiLayerFeatureCollection>[
      ...summaryCollections,
      ...collections,
    ], features);

    return ClipRRect(
      borderRadius: AppRadii.lg,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Stack(
          children: [
            _AiPreviewMap(
              mapController: _mapController,
              basemapStyle: _basemapStyle,
              run: run,
              features: features,
              polygonHitNotifier: _previewPolygonHitNotifier,
              polylineHitNotifier: _previewPolylineHitNotifier,
              showClassification: _showClassification,
              selectedFeatureKey: _selectedFeatureKey,
              onFeatureSelected: (feature) =>
                  _handlePreviewFeatureSelected(run, feature),
              onPositionChanged: _handleMapPositionChanged,
            ),
            Positioned(
              left: 12,
              top: 12,
              right: 12,
              child: Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: double.infinity,
                  child: _AiPreviewControlPanel(
                    title: _previewPanelTitle(run),
                    layers: previewLayers,
                    loadSummary: loadSummary,
                    showClassification: _showClassification,
                    expanded: _panelExpanded,
                    loading: loading,
                    errors: errors,
                    classOptions: classOptions,
                    selectedClass: _selectedClassFilter,
                    onExpandedChanged: (value) {
                      setState(() => _panelExpanded = value);
                    },
                    onClassificationChanged: (value) {
                      setState(() {
                        _showClassification = value;
                        if (!value) {
                          _selectedClassFilter = null;
                        }
                      });
                    },
                    onClassFilterChanged: (value) {
                      setState(() {
                        _selectedClassFilter = value;
                        _selectedFeatureKey = null;
                        _selectedFeatureOverride = null;
                      });
                    },
                  ),
                ),
              ),
            ),
            Positioned(
              right: 14,
              bottom: 18,
              child: _AiPreviewMapControls(
                basemapStyle: _basemapStyle,
                featureCount: loadSummary?.totalFeatureCount ?? features.length,
                onOpenFeatures: featureListLayer == null
                    ? null
                    : () => _openFeatureList(run, featureListLayer),
                onFitWorkspace: _fitWorkspace,
                onZoomIn: () => _zoomBy(1),
                onZoomOut: () => _zoomBy(-1),
                onToggleBasemap: () {
                  setState(() {
                    _basemapStyle = _basemapStyle == LebanonBasemapStyle.street
                        ? LebanonBasemapStyle.satellite
                        : LebanonBasemapStyle.street;
                  });
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  AiLayerFeaturesQuery _featureQuery(String layerId) {
    final zoom = _featureViewportZoom;
    final geometry = _aiPreviewGeometryMode(zoom);
    return AiLayerFeaturesQuery(
      layerId: layerId,
      detail: geometry == 'full' ? 'full' : 'overview',
      geometry: geometry,
      bounds: _featureViewportBounds,
      zoom: zoom,
      classLabel: _selectedClassFilter,
    );
  }

  AiLayerFeaturesQuery _summaryQuery(String layerId) {
    return AiLayerFeaturesQuery(
      layerId: layerId,
      detail: 'overview',
      geometry: 'aggregate',
      limit: 1,
      page: 1,
      classLabel: _selectedClassFilter,
    );
  }

  String _previewCollectionCacheKey(String layerId) {
    return [
      layerId,
      _selectedClassFilter ?? 'all',
      _featureViewportBounds ?? 'global',
      _featureViewportZoom?.toStringAsFixed(2) ?? 'zoom',
    ].join('|');
  }

  String _previewSummaryCacheKey(String layerId) {
    return [layerId, _selectedClassFilter ?? 'all', 'summary'].join('|');
  }

  List<String> _previewClassOptions(
    List<AiLayerFeatureCollection> collections,
    List<_AiPreviewFeature> features,
  ) {
    final discovered = <String>{
      for (final collection in collections)
        ...collection.classCounts.keys.where(
          (value) => value.trim().isNotEmpty,
        ),
      for (final item in features)
        if (_aiFeatureClass(item.feature)?.trim().isNotEmpty ?? false)
          _aiFeatureClass(item.feature)!.trim(),
    };
    if (discovered.any((value) => !_knownPreviewClasses.contains(value))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        setState(() => _knownPreviewClasses.addAll(discovered));
      });
    }
    final classes = <String>{..._knownPreviewClasses, ...discovered}.toList();
    classes.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return classes;
  }

  void _handleMapPositionChanged(MapCamera camera, bool hasGesture) {
    _latestCamera = camera;
    final suppressUntil = _suppressProgrammaticViewportRefreshUntil;
    if (!hasGesture &&
        suppressUntil != null &&
        DateTime.now().isBefore(suppressUntil)) {
      return;
    }
    if (suppressUntil != null && DateTime.now().isAfter(suppressUntil)) {
      _suppressProgrammaticViewportRefreshUntil = null;
    }
    _scheduleFeatureViewportRefresh();
  }

  void _scheduleFeatureViewportRefresh() {
    _scheduleFeatureViewportRefreshAfter();
  }

  void _scheduleFeatureViewportRefreshAfter({
    Duration delay = const Duration(milliseconds: 350),
    bool force = false,
  }) {
    _viewportFeatureRefreshTimer?.cancel();
    _viewportFeatureRefreshTimer = Timer(delay, () {
      if (!mounted) {
        return;
      }
      final camera = _currentAiPreviewCamera();
      if (camera == null) {
        return;
      }
      final nextZoom = _aiPreviewZoomBucket(camera.zoom);
      final nextBounds = _aiLayerBoundsQuery(
        _paddedAiViewportBounds(camera.visibleBounds, nextZoom),
        nextZoom,
      );
      if (nextBounds == _featureViewportBounds &&
          nextZoom == _featureViewportZoom &&
          !force) {
        return;
      }
      setState(() {
        _featureViewportBounds = nextBounds;
        _featureViewportZoom = nextZoom;
      });
    });
  }

  MapCamera? _currentAiPreviewCamera() {
    final latest = _latestCamera;
    if (latest != null) {
      return latest;
    }
    try {
      return _mapController.camera;
    } catch (_) {
      return null;
    }
  }

  void _fitWorkspace() {
    _runMapAction(
      () => _mapController.fitCamera(LebanonMapConfig.fullscreenFit),
    );
  }

  void _zoomBy(double delta) {
    MapCamera camera;
    try {
      camera = _latestCamera ?? _mapController.camera;
    } catch (_) {
      return;
    }
    final zoom = (camera.zoom + delta)
        .clamp(
          LebanonMapConfig.fullscreenMinZoom,
          LebanonMapConfig.fullscreenMaxZoom,
        )
        .toDouble();
    _runMapAction(() => _mapController.move(camera.center, zoom));
  }

  void _runMapAction(VoidCallback action) {
    try {
      action();
    } catch (_) {
      // The controller can briefly be unavailable while FlutterMap mounts.
    }
  }

  void _selectPreviewFeature(
    AiRun run,
    _AiPreviewFeature item, {
    required bool showDetails,
  }) {
    _focusPreviewFeature(item);
    if (showDetails) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _openFeatureDetails(run, item);
        }
      });
    }
  }

  void _handlePreviewFeatureSelected(AiRun run, _AiPreviewFeature item) {
    if (_isAggregateAiFeature(item.feature)) {
      _drillIntoPreviewAggregate(item);
      return;
    }
    _selectPreviewFeature(run, item, showDetails: true);
  }

  void _drillIntoPreviewAggregate(_AiPreviewFeature item) {
    final center = geometryPointsCenter(geometryPoints(item.feature.geometry));
    if (center == null) {
      return;
    }
    _runMapAction(() {
      final currentZoom = _latestCamera?.zoom ?? _featureViewportZoom ?? 9;
      final nextZoom = (currentZoom + 2.5)
          .clamp(11.5, LebanonMapConfig.fullscreenMaxZoom)
          .toDouble();
      _suppressProgrammaticViewportRefreshUntil = DateTime.now().add(
        const Duration(milliseconds: 500),
      );
      _mapController.move(center, nextZoom);
      setState(() {
        _selectedFeatureKey = null;
        _selectedFeatureOverride = null;
      });
      _scheduleFeatureViewportRefreshAfter(
        delay: const Duration(milliseconds: 650),
        force: true,
      );
    });
  }

  void _focusPreviewFeature(_AiPreviewFeature item) {
    final points = geometryPoints(item.feature.geometry);
    setState(() {
      _selectedFeatureKey = item.key;
      if (!_isAggregateAiFeature(item.feature)) {
        _selectedFeatureOverride = item;
      }
      if (points.isNotEmpty && !_isAggregateAiFeature(item.feature)) {
        final targetBounds = LatLngBounds.fromPoints(points);
        _featureViewportZoom = 14;
        _featureViewportBounds = _aiLayerBoundsQuery(
          _expandedAiBounds(targetBounds, 0.02),
          _featureViewportZoom!,
        );
      }
    });
    if (points.isEmpty) {
      return;
    }
    _runMapAction(() {
      _suppressProgrammaticViewportRefreshUntil = DateTime.now().add(
        const Duration(milliseconds: 900),
      );
      if (points.length > 1 &&
          !geometryPointsCollapseToSingleLocation(points)) {
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(points),
            padding: const EdgeInsets.all(76),
            maxZoom: 16,
          ),
        );
        return;
      }
      final center = geometryPointsCenter(points);
      if (center != null) {
        _mapController.move(center, 16);
      }
      _scheduleFeatureViewportRefreshAfter(
        delay: const Duration(milliseconds: 900),
        force: true,
      );
    });
  }

  void _openFeatureDetails(AiRun run, _AiPreviewFeature item) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) =>
          _AiFeatureDetailsSheet(run: run, previewFeature: item),
    );
  }

  void _openFeatureList(AiRun run, AiOutputLayer layer) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _AiFeatureListSheet(
        layer: layer,
        selectedClass: _selectedClassFilter,
        onClassFilterChanged: (value) {
          if (!mounted) {
            return;
          }
          setState(() {
            _selectedClassFilter = value;
            _selectedFeatureKey = null;
            _selectedFeatureOverride = null;
          });
        },
        onFeatureSelected: (feature) {
          Navigator.of(context).pop();
          unawaited(_selectFullPreviewFeatureFromList(run, feature));
        },
      ),
    );
  }

  Future<void> _selectFullPreviewFeatureFromList(
    AiRun run,
    _AiPreviewFeature item,
  ) async {
    if (_isAggregateAiFeature(item.feature)) {
      _drillIntoPreviewAggregate(item);
      return;
    }
    try {
      final collection = await ref
          .read(aiRepositoryProvider)
          .fetchLayerFeatures(
            layerId: item.layer.id,
            detail: 'full',
            geometry: 'full',
            page: 1,
            limit: 1,
            featureId: item.feature.id,
          );
      if (!mounted) {
        return;
      }
      final feature = collection.features.isEmpty
          ? item.feature
          : collection.features.first;
      final fullItem = _AiPreviewFeature(
        layer: collection.features.isEmpty ? item.layer : collection.layer,
        feature: feature,
      );
      _selectPreviewFeature(run, fullItem, showDetails: true);
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnackbar.showError(
        context,
        userFacingErrorMessage(
          error,
          fallback: 'Unable to open this AI feature right now.',
        ),
      );
      _selectPreviewFeature(run, item, showDetails: true);
    }
  }
}

String _previewPanelTitle(AiRun run) {
  final shortId = run.id.length <= 8 ? run.id : run.id.substring(0, 8);
  return 'Run $shortId preview';
}

String _aiLayerBoundsQuery(LatLngBounds bounds, double zoom) {
  final cell = _aiPreviewBoundsCellSize(zoom);
  double snapDown(double value) => (value / cell).floorToDouble() * cell;
  double snapUp(double value) => (value / cell).ceilToDouble() * cell;
  String normalize(double value) => value.toStringAsFixed(4);
  return [
    normalize(snapDown(bounds.southWest.longitude)),
    normalize(snapDown(bounds.southWest.latitude)),
    normalize(snapUp(bounds.northEast.longitude)),
    normalize(snapUp(bounds.northEast.latitude)),
  ].join(',');
}

LatLngBounds _expandedAiBounds(LatLngBounds bounds, double paddingDegrees) {
  final southWest = bounds.southWest;
  final northEast = bounds.northEast;
  return LatLngBounds(
    LatLng(
      southWest.latitude - paddingDegrees,
      southWest.longitude - paddingDegrees,
    ),
    LatLng(
      northEast.latitude + paddingDegrees,
      northEast.longitude + paddingDegrees,
    ),
  );
}

LatLngBounds _paddedAiViewportBounds(LatLngBounds bounds, double zoomBucket) {
  final southWest = bounds.southWest;
  final northEast = bounds.northEast;
  final latSpan = (northEast.latitude - southWest.latitude).abs();
  final lonSpan = (northEast.longitude - southWest.longitude).abs();
  final scalePadding = zoomBucket >= 14
      ? 0.45
      : zoomBucket >= 12
      ? 0.35
      : 0.25;
  final minPadding = zoomBucket >= 14
      ? 0.006
      : zoomBucket >= 12
      ? 0.015
      : 0.04;
  final latPadding = (latSpan * scalePadding)
      .clamp(minPadding, zoomBucket >= 14 ? 0.08 : 0.18)
      .toDouble();
  final lonPadding = (lonSpan * scalePadding)
      .clamp(minPadding, zoomBucket >= 14 ? 0.08 : 0.18)
      .toDouble();

  return LatLngBounds(
    LatLng(southWest.latitude - latPadding, southWest.longitude - lonPadding),
    LatLng(northEast.latitude + latPadding, northEast.longitude + lonPadding),
  );
}

double _aiPreviewZoomBucket(double zoom) {
  if (zoom < 8) {
    return 7;
  }
  if (zoom < 10) {
    return 9;
  }
  if (zoom < 12) {
    return 11;
  }
  if (zoom < 14) {
    return 13;
  }
  return (zoom * 2).roundToDouble() / 2;
}

double _aiPreviewBoundsCellSize(double zoomBucket) {
  if (zoomBucket < 8) {
    return 0.25;
  }
  if (zoomBucket < 10) {
    return 0.12;
  }
  if (zoomBucket < 12) {
    return 0.06;
  }
  if (zoomBucket < 14) {
    return 0.025;
  }
  return 0.01;
}

String _aiPreviewGeometryMode(double? zoom) {
  final value = zoom ?? LebanonMapConfig.fullscreenInitialZoom;
  if (value >= 14) {
    return 'full';
  }
  if (value < 11) {
    return 'aggregate';
  }
  return 'simplified';
}

class _AiPreviewLoadSummary {
  const _AiPreviewLoadSummary({
    required this.totalFeatureCount,
    required this.visibleFeatureCount,
    required this.returnedFeatureCount,
    required this.capped,
    required this.optimizedPreview,
    required this.geometryMode,
    this.cap,
    this.totalAreaHectares,
  });

  final int totalFeatureCount;
  final int visibleFeatureCount;
  final int returnedFeatureCount;
  final bool capped;
  final bool optimizedPreview;
  final String geometryMode;
  final int? cap;
  final double? totalAreaHectares;

  static _AiPreviewLoadSummary? fromCollections(
    List<AiLayerFeatureCollection> collections,
  ) {
    if (collections.isEmpty) {
      return null;
    }
    final primary = collections.firstWhere(
      (collection) => collection.layer.layerType == 'classification',
      orElse: () => collections.first,
    );
    return _AiPreviewLoadSummary(
      totalFeatureCount: primary.featureCount,
      visibleFeatureCount: primary.matchingFeatureCount,
      returnedFeatureCount: primary.returnedFeatureCount,
      capped: primary.capped,
      cap: primary.cap,
      optimizedPreview: primary.optimizedPreview,
      geometryMode: primary.geometryMode,
      totalAreaHectares: primary.totalAreaHectares,
    );
  }
}

class _AiPreviewLayerToggles extends StatelessWidget {
  const _AiPreviewLayerToggles({
    required this.layers,
    required this.showClassification,
    required this.onClassificationChanged,
  });

  final List<AiOutputLayer> layers;
  final bool showClassification;
  final ValueChanged<bool> onClassificationChanged;

  @override
  Widget build(BuildContext context) {
    final hasClassification = layers.any(
      (layer) => layer.layerType == 'classification',
    );
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: [
        FilterChip(
          selected: showClassification && hasClassification,
          avatar: const _LegendSwatch(color: Color(0xFF2E7D32)),
          label: const Text('Classification'),
          onSelected: hasClassification ? onClassificationChanged : null,
        ),
      ],
    );
  }
}

class _AiPreviewClassFilter extends StatelessWidget {
  const _AiPreviewClassFilter({
    required this.showClassification,
    required this.classOptions,
    required this.selectedClass,
    required this.onSelectedClassChanged,
  });

  final bool showClassification;
  final List<String> classOptions;
  final String? selectedClass;
  final ValueChanged<String?> onSelectedClassChanged;

  @override
  Widget build(BuildContext context) {
    if (!showClassification) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Legend and class filter',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilterChip(
              selected: selectedClass == null,
              avatar: const Icon(Icons.layers_outlined, size: 18),
              label: const Text('All'),
              onSelected: (_) => onSelectedClassChanged(null),
            ),
            for (final className in classOptions)
              FilterChip(
                selected: selectedClass == className,
                avatar: _LegendSwatch(color: _classificationColor(className)),
                label: Text(
                  _friendlyClassLabel(className),
                  overflow: TextOverflow.ellipsis,
                ),
                onSelected: (selected) =>
                    onSelectedClassChanged(selected ? className : null),
              ),
          ],
        ),
        if (classOptions.isEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          const _NoticeRow(
            icon: Icons.info_outline,
            text: 'Class filters appear after AI predictions load.',
          ),
        ],
      ],
    );
  }
}

class _AiPreviewControlPanel extends StatelessWidget {
  const _AiPreviewControlPanel({
    required this.title,
    required this.layers,
    required this.loadSummary,
    required this.showClassification,
    required this.expanded,
    required this.loading,
    required this.errors,
    required this.classOptions,
    required this.selectedClass,
    required this.onExpandedChanged,
    required this.onClassificationChanged,
    required this.onClassFilterChanged,
  });

  final String title;
  final List<AiOutputLayer> layers;
  final _AiPreviewLoadSummary? loadSummary;
  final bool showClassification;
  final bool expanded;
  final bool loading;
  final List<String> errors;
  final List<String> classOptions;
  final String? selectedClass;
  final ValueChanged<bool> onExpandedChanged;
  final ValueChanged<bool> onClassificationChanged;
  final ValueChanged<String?> onClassFilterChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: Material(
        elevation: 0,
        color: scheme.surface.withValues(alpha: 0.93),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.38),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final actionRailWidth = constraints.maxWidth >= 370 ? 104.0 : 48.0;
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 11, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  height: 1.15,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  const _MapInfoPill(
                                    icon: Icons.visibility_off_outlined,
                                    label: 'Not published',
                                  ),
                                  const _MapInfoPill(
                                    icon: Icons.rule_folder_outlined,
                                    label: 'Review only',
                                  ),
                                  if (loadSummary != null)
                                    _MapInfoPill(
                                      icon: Icons.layers_outlined,
                                      label: selectedClass == null
                                          ? 'AI features: ${loadSummary!.totalFeatureCount}'
                                          : '${_friendlyClassLabel(selectedClass!)}: ${loadSummary!.totalFeatureCount}',
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: actionRailWidth),
                        child: Align(
                          alignment: Alignment.topRight,
                          child: Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              _MapPanelIconButton(
                                tooltip: expanded
                                    ? 'Collapse AI layers'
                                    : 'Show AI layers',
                                icon: expanded
                                    ? Icons.keyboard_arrow_up_rounded
                                    : Icons.tune_rounded,
                                onPressed: () => onExpandedChanged(!expanded),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (expanded) ...[
                    const SizedBox(height: AppSpacing.sm),
                    _AiPreviewLayerToggles(
                      layers: layers,
                      showClassification: showClassification,
                      onClassificationChanged: onClassificationChanged,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    _AiPreviewClassFilter(
                      showClassification: showClassification,
                      classOptions: classOptions,
                      selectedClass: selectedClass,
                      onSelectedClassChanged: onClassFilterChanged,
                    ),
                    if (loading) ...[
                      const SizedBox(height: AppSpacing.sm),
                      const LinearProgressIndicator(),
                    ],
                    for (final error in errors)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.xs),
                        child: _NoticeRow(
                          icon: Icons.error_outline,
                          text: error,
                        ),
                      ),
                    if (layers.isEmpty) ...[
                      const SizedBox(height: AppSpacing.xs),
                      const _NoticeRow(
                        icon: Icons.layers_clear_outlined,
                        text: 'No preview layers are registered for this run.',
                      ),
                    ],
                    const SizedBox(height: AppSpacing.xs),
                    const _NoticeRow(
                      icon: Icons.info_outline,
                      text: 'AI predictions remain separate from field data.',
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _AiPreviewMapControls extends StatelessWidget {
  const _AiPreviewMapControls({
    required this.basemapStyle,
    required this.featureCount,
    required this.onOpenFeatures,
    required this.onFitWorkspace,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onToggleBasemap,
  });

  final LebanonBasemapStyle basemapStyle;
  final int featureCount;
  final VoidCallback? onOpenFeatures;
  final VoidCallback onFitWorkspace;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onToggleBasemap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _MapFloatingActionButton(
          tooltip: 'Browse AI features',
          onPressed: onOpenFeatures,
          badgeLabel: featureCount > 0 ? '$featureCount' : null,
          child: const Icon(Icons.layers_outlined, size: 20),
        ),
        const SizedBox(height: 12),
        Material(
          elevation: 6,
          color: scheme.surface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _AiGroupedMapRailButton(
                tooltip: basemapStyle == LebanonBasemapStyle.street
                    ? 'Switch to satellite'
                    : 'Switch to street map',
                onPressed: onToggleBasemap,
                icon: Icon(
                  basemapStyle == LebanonBasemapStyle.street
                      ? Icons.satellite_alt_outlined
                      : Icons.map_outlined,
                ),
                isTop: true,
              ),
              _AiGroupedMapRailButton(
                tooltip: 'Fit Lebanon workspace',
                onPressed: onFitWorkspace,
                icon: const Icon(Icons.center_focus_strong_outlined),
              ),
              _AiGroupedMapRailButton(
                tooltip: 'Zoom in',
                onPressed: onZoomIn,
                icon: const Icon(Icons.add),
              ),
              _AiGroupedMapRailButton(
                tooltip: 'Zoom out',
                onPressed: onZoomOut,
                icon: const Icon(Icons.remove),
                isBottom: true,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AiGroupedMapRailButton extends StatelessWidget {
  const _AiGroupedMapRailButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.isTop = false,
    this.isBottom = false,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Widget icon;
  final bool isTop;
  final bool isBottom;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.vertical(
      top: isTop ? const Radius.circular(18) : Radius.zero,
      bottom: isBottom ? const Radius.circular(18) : Radius.zero,
    );
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: radius,
        onTap: onPressed,
        child: SizedBox(width: 44, height: 44, child: Center(child: icon)),
      ),
    );
  }
}

class _MapFloatingActionButton extends StatelessWidget {
  const _MapFloatingActionButton({
    required this.tooltip,
    required this.onPressed,
    required this.child,
    this.badgeLabel,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Widget child;
  final String? badgeLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        elevation: 6,
        color: scheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onPressed,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Center(child: child),
                if (badgeLabel != null)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1.5,
                        ),
                        child: Text(
                          badgeLabel!,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: scheme.onPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MapPanelIconButton extends StatelessWidget {
  const _MapPanelIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: scheme.primaryContainer.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onPressed,
          child: SizedBox(width: 40, height: 40, child: Icon(icon, size: 20)),
        ),
      ),
    );
  }
}

class _MapInfoPill extends StatelessWidget {
  const _MapInfoPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: scheme.primary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AiPreviewMap extends StatelessWidget {
  const _AiPreviewMap({
    required this.mapController,
    required this.basemapStyle,
    required this.run,
    required this.features,
    required this.polygonHitNotifier,
    required this.polylineHitNotifier,
    required this.showClassification,
    required this.selectedFeatureKey,
    required this.onFeatureSelected,
    required this.onPositionChanged,
  });

  final MapController mapController;
  final LebanonBasemapStyle basemapStyle;
  final AiRun run;
  final List<_AiPreviewFeature> features;
  final LayerHitNotifier<_AiPreviewFeature> polygonHitNotifier;
  final LayerHitNotifier<_AiPreviewFeature> polylineHitNotifier;
  final bool showClassification;
  final String? selectedFeatureKey;
  final ValueChanged<_AiPreviewFeature> onFeatureSelected;
  final void Function(MapCamera camera, bool hasGesture) onPositionChanged;

  @override
  Widget build(BuildContext context) {
    final center = LebanonMapConfig.center;
    final labelOverlayUrl = LebanonMapConfig.referenceLabelUrlTemplate(
      basemapStyle,
    );
    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        initialCenter: center,
        initialZoom: LebanonMapConfig.fullscreenInitialZoom,
        initialCameraFit: LebanonMapConfig.fullscreenFit,
        minZoom: LebanonMapConfig.fullscreenMinZoom,
        maxZoom: LebanonMapConfig.fullscreenMaxZoom,
        cameraConstraint: CameraConstraint.containCenter(
          bounds: LebanonMapConfig.bounds,
        ),
        onPositionChanged: onPositionChanged,
      ),
      children: [
        if (LebanonMapConfig.shouldRenderTileLayers)
          TileLayer(
            key: ValueKey<String>('ai_preview_basemap_${basemapStyle.name}'),
            urlTemplate: LebanonMapConfig.basemapUrlTemplate(basemapStyle),
            tileProvider: appNetworkTileProvider(),
            tileDisplay: const TileDisplay.fadeIn(
              duration: Duration(milliseconds: 180),
              startOpacity: 0,
              reloadStartOpacity: 0,
            ),
            panBuffer: 2,
            keepBuffer: 3,
            userAgentPackageName: 'lb.gov.gis_collector',
          ),
        if (LebanonMapConfig.shouldRenderTileLayers && labelOverlayUrl != null)
          TileLayer(
            key: ValueKey<String>(
              'ai_preview_label_overlay_${basemapStyle.name}',
            ),
            urlTemplate: labelOverlayUrl,
            tileProvider: appNetworkTileProvider(),
            tileDisplay: const TileDisplay.fadeIn(
              duration: Duration(milliseconds: 220),
              startOpacity: 0,
              reloadStartOpacity: 0,
            ),
            panBuffer: 2,
            keepBuffer: 3,
            userAgentPackageName: 'lb.gov.gis_collector',
          ),
        _polygonLayer(),
        _polylineLayer(),
        MarkerLayer(markers: _markers(context)),
      ],
    );
  }

  Widget _polygonLayer() {
    final layer = PolygonLayer<_AiPreviewFeature>(
      polygons: _polygons(),
      hitNotifier: polygonHitNotifier,
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      hitTestBehavior: HitTestBehavior.deferToChild,
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTap: () => _handleGeometryLayerHit(polygonHitNotifier),
        child: layer,
      ),
    );
  }

  Widget _polylineLayer() {
    final layer = PolylineLayer<_AiPreviewFeature>(
      polylines: _polylines(),
      hitNotifier: polylineHitNotifier,
      minimumHitbox: 12,
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      hitTestBehavior: HitTestBehavior.deferToChild,
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTap: () => _handleGeometryLayerHit(polylineHitNotifier),
        child: layer,
      ),
    );
  }

  void _handleGeometryLayerHit(LayerHitNotifier<_AiPreviewFeature> notifier) {
    final hits = notifier.value?.hitValues;
    if (hits == null || hits.isEmpty) {
      return;
    }
    final feature = _preferredHitFeature(hits);
    if (feature != null) {
      onFeatureSelected(feature);
    }
  }

  _AiPreviewFeature? _preferredHitFeature(List<_AiPreviewFeature> hits) {
    final visibleHits = hits
        .where(_isVisible)
        .where((item) {
          return !_isAggregateAiFeature(item.feature);
        })
        .toList(growable: false);
    if (visibleHits.isEmpty) {
      return null;
    }
    if (visibleHits.length == 1) {
      return visibleHits.first;
    }
    visibleHits.sort((a, b) {
      final aArea = _aiFeatureApproxArea(a.feature);
      final bArea = _aiFeatureApproxArea(b.feature);
      return aArea.compareTo(bArea);
    });
    return visibleHits.first;
  }

  List<Polygon<_AiPreviewFeature>> _polygons() {
    final polygons = <Polygon<_AiPreviewFeature>>[];
    for (final item in features) {
      if (!_isVisible(item)) {
        continue;
      }
      if (!isPolygonGeometry(item.feature.geometry)) {
        continue;
      }
      final selected = item.key == selectedFeatureKey;
      final style = _aiFeatureStyle(item);
      for (final points in polygonGeometrySegments(item.feature.geometry)) {
        if (!isValidPolygonRing(points)) {
          continue;
        }
        polygons.add(
          Polygon<_AiPreviewFeature>(
            points: points,
            borderStrokeWidth: selected ? 4.2 : style.borderWidth,
            borderColor: selected ? Colors.black87 : style.borderColor,
            color: style.fillColor,
            hitValue: item,
          ),
        );
      }
    }
    return polygons;
  }

  List<Polyline<_AiPreviewFeature>> _polylines() {
    final lines = <Polyline<_AiPreviewFeature>>[];
    for (final item in features) {
      if (!_isVisible(item)) {
        continue;
      }
      if (!isLineGeometry(item.feature.geometry)) {
        continue;
      }
      final selected = item.key == selectedFeatureKey;
      final style = _aiFeatureStyle(item);
      for (final points in lineGeometrySegments(item.feature.geometry)) {
        if (points.isEmpty) {
          continue;
        }
        lines.add(
          Polyline<_AiPreviewFeature>(
            points: points,
            strokeWidth: selected ? 4.0 : 3.0,
            color: selected ? Colors.black87 : style.borderColor,
            hitValue: item,
          ),
        );
      }
    }
    return lines;
  }

  List<Marker> _markers(BuildContext context) {
    final markers = <Marker>[];
    for (final item in features) {
      if (!_isVisible(item)) {
        continue;
      }
      if (!isPointGeometry(item.feature.geometry)) {
        continue;
      }
      final style = _aiFeatureStyle(item);
      final selected = item.key == selectedFeatureKey;
      final aggregate = _isAggregateAiFeature(item.feature);
      for (final point in pointGeometryPoints(item.feature.geometry)) {
        markers.add(
          Marker(
            point: point,
            width: aggregate ? 30 : 26,
            height: aggregate ? 30 : 26,
            child: GestureDetector(
              key: ValueKey<String>('ai-preview-feature-${item.key}'),
              behavior: HitTestBehavior.translucent,
              onTap: () => onFeatureSelected(item),
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: style.borderColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? Colors.black87 : Colors.white,
                      width: selected ? 2.4 : 1.8,
                    ),
                  ),
                  child: SizedBox(
                    width: aggregate ? 17 : 15,
                    height: aggregate ? 17 : 15,
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }
    return markers;
  }

  bool _isVisible(_AiPreviewFeature item) {
    return item.layer.layerType == 'classification' && showClassification;
  }
}

class _AiFeatureDetailsSheet extends StatelessWidget {
  const _AiFeatureDetailsSheet({
    required this.run,
    required this.previewFeature,
  });

  final AiRun run;
  final _AiPreviewFeature previewFeature;

  @override
  Widget build(BuildContext context) {
    final feature = previewFeature.feature;
    final isAggregate = _isAggregateAiFeature(feature);
    final className = _aiFeatureClass(feature);
    final confidence = _aiFeatureConfidence(feature);
    final model = _aiFeatureText(feature, const ['model_name', 'model']);
    final areaHa = _aiFeatureText(feature, const ['area_ha']);
    final areaM2 = _aiFeatureText(feature, const [
      'processed_area_m2',
      'area_m2',
      'area',
    ]);
    final geometryQuality = _aiFeatureText(feature, const ['geometry_quality']);
    final processingMethod = _aiFeatureText(feature, const [
      'processing_method',
    ]);
    final sourceResolution = _aiFeatureText(feature, const [
      'source_resolution_m',
    ]);
    final threshold = _aiFeatureText(feature, const ['confidence_threshold']);
    final reviewStatus =
        _aiFeatureText(feature, const [
          'admin_validation_status',
          'validation_status',
          'ai_validation_status',
          'status',
          'review_status',
        ]) ??
        'ready_for_review';
    final correctedClass = _aiFeatureText(feature, const [
      'corrected_class',
      'approved_class',
      'validated_class',
    ]);
    final layerLabel = _friendlyLayerTypeLabel(previewFeature.layer.layerType);
    final title = isAggregate
        ? 'AI overview group'
        : className == null
        ? 'AI prediction'
        : _friendlyClassLabel(className);
    final attributes = <String, Object?>{
      if (isAggregate)
        'group_size': '${_aggregateAiFeatureCount(feature) ?? 1} AI features',
      isAggregate ? 'dominant_class' : 'predicted_class': className == null
          ? 'Not available'
          : _friendlyClassLabel(className),
      'confidence': confidence == null
          ? 'Not available'
          : _formatConfidence(confidence),
      'review_status': _friendlyStatusLabel(reviewStatus),
      if (correctedClass != null)
        'corrected_class': _friendlyClassLabel(correctedClass),
      if (model != null) 'model': _friendlyModelLabel(model),
      if (areaHa != null) 'area': '${_safeText(areaHa)} ha',
      if (areaM2 != null) 'area_m2': '${_safeText(areaM2)} m2',
      'geometry_type': feature.geometry['type']?.toString() ?? 'Not available',
      if (geometryQuality != null)
        'geometry_quality': _friendlyStatusLabel(geometryQuality),
      'layer': layerLabel,
      if (sourceResolution != null)
        'source_resolution': '${_safeText(sourceResolution)} m',
      if (processingMethod != null)
        'processing': _friendlyProcessingMethod(processingMethod),
      if (threshold != null) 'confidence_threshold': _safeText(threshold),
      'output_note':
          'AI-derived polygon, post-processed from satellite classification.',
    };
    final bottomInset =
        MediaQuery.viewPaddingOf(context).bottom + AppSpacing.lg;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.60,
      minChildSize: 0.32,
      maxChildSize: 0.90,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          bottomInset,
        ),
        children: [
          Center(
            child: Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(
                      '$layerLabel layer - review only',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              StatusChip(status: reviewStatus),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          const _NoticeRow(
            icon: Icons.warning_amber_outlined,
            text: 'AI prediction for review, not approved field data.',
          ),
          if (isAggregate) ...[
            const SizedBox(height: AppSpacing.xs),
            const _NoticeRow(
              icon: Icons.grid_view_outlined,
              text: 'Overview group. Zoom in for detailed geometry.',
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          _DetailSection(
            title: 'Prediction details',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (className != null)
                  _MapInfoPill(
                    icon: Icons.category_outlined,
                    label: _friendlyClassLabel(className),
                  ),
                if (confidence != null)
                  _MapInfoPill(
                    icon: Icons.speed_outlined,
                    label: 'Confidence ${_formatConfidence(confidence)}',
                  ),
                _MapInfoPill(icon: Icons.layers_outlined, label: layerLabel),
              ],
            ),
          ),
          _DetailSection(
            title: 'Attributes',
            child: _FeatureAttributesGrid(attributes: attributes),
          ),
          const _DetailSection(
            title: 'Data status',
            child: _NoticeRow(
              icon: Icons.info_outline,
              text:
                  'This is one AI classification layer. Confidence is metadata.',
            ),
          ),
        ],
      ),
    );
  }
}

class _AiFeatureListSheet extends ConsumerStatefulWidget {
  const _AiFeatureListSheet({
    required this.layer,
    required this.selectedClass,
    required this.onClassFilterChanged,
    required this.onFeatureSelected,
  });

  final AiOutputLayer layer;
  final String? selectedClass;
  final ValueChanged<String?> onClassFilterChanged;
  final ValueChanged<_AiPreviewFeature> onFeatureSelected;

  @override
  ConsumerState<_AiFeatureListSheet> createState() =>
      _AiFeatureListSheetState();
}

class _AiFeatureListSheetState extends ConsumerState<_AiFeatureListSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String? _selectedClass;
  bool _showFilters = false;

  @override
  void initState() {
    super.initState();
    _selectedClass = widget.selectedClass;
  }

  @override
  void didUpdateWidget(covariant _AiFeatureListSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedClass != oldWidget.selectedClass &&
        widget.selectedClass != _selectedClass) {
      _selectedClass = widget.selectedClass;
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final browserQuery = AiLayerFeatureBrowserQuery(
      layerId: widget.layer.id,
      search: _query.trim().isEmpty ? null : _query.trim(),
      classLabel: _selectedClass,
    );
    final featuresAsync = ref.watch(
      paginatedAiLayerFeatureBrowserProvider(browserQuery),
    );
    final featuresController = ref.read(
      paginatedAiLayerFeatureBrowserProvider(browserQuery).notifier,
    );
    final featureState =
        featuresAsync.valueOrNull ??
        const PaginatedListState<AiLayerFeature>.initial();
    final displayedFeatures = featureState.items;
    final summaryAsync = ref.watch(
      aiLayerFeaturesProvider(
        AiLayerFeaturesQuery(
          layerId: widget.layer.id,
          detail: 'overview',
          geometry: 'simplified',
          page: 1,
          limit: 1,
          zoom: 14,
        ),
      ),
    );
    final summary = summaryAsync.valueOrNull;
    final classes = _aiFeatureBrowserClasses(summary, displayedFeatures);
    final displayedTotal = featureState.total > 0
        ? featureState.total
        : (browserQuery.search == null && browserQuery.classLabel == null
              ? summary?.featureCount ?? 0
              : 0);
    final classLocked = widget.selectedClass != null;

    final bottomInset =
        MediaQuery.viewPaddingOf(context).bottom + AppSpacing.lg;
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.68,
        minChildSize: 0.36,
        maxChildSize: 0.92,
        builder: (context, controller) {
          return ListView(
            controller: controller,
            padding: EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
              bottomInset,
            ),
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Padding(
                padding: EdgeInsets.zero,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'AI features',
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    Text(
                      _aiFeatureListLabel(
                        shownCount: displayedFeatures.length,
                        totalCount: displayedTotal,
                        hasFilter:
                            browserQuery.search != null ||
                            browserQuery.classLabel != null,
                      ),
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'These are AI predictions for review, not approved field data.',
                      style: theme.textTheme.bodySmall,
                    ),
                    if (classLocked) ...[
                      const SizedBox(height: AppSpacing.xs),
                      _NoticeRow(
                        icon: Icons.lock_outline,
                        text:
                            'Class filter locked to ${_friendlyClassLabel(widget.selectedClass!)}.',
                      ),
                    ],
                    const SizedBox(height: AppSpacing.sm),
                    TextField(
                      controller: _searchController,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search),
                        hintText: 'Search AI features',
                        suffixIcon: _query.trim().isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear search',
                                onPressed: () {
                                  setState(() {
                                    _searchController.clear();
                                    _query = '';
                                  });
                                },
                                icon: const Icon(Icons.clear),
                              ),
                      ),
                      onChanged: (value) => setState(() => _query = value),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    TextButton.icon(
                      onPressed: () =>
                          setState(() => _showFilters = !_showFilters),
                      icon: Icon(
                        _showFilters
                            ? Icons.filter_alt_off_outlined
                            : Icons.filter_alt_outlined,
                      ),
                      label: Text(_showFilters ? 'Hide' : 'Filter'),
                    ),
                    if (_showFilters) ...[
                      const SizedBox(height: AppSpacing.sm),
                      if (classLocked)
                        _NoticeRow(
                          icon: Icons.lock_outline,
                          text:
                              'Locked to ${_friendlyClassLabel(widget.selectedClass!)} from the map filter. Clear the map class filter to browse all classes.',
                        )
                      else if (classes.isEmpty)
                        const _NoticeRow(
                          icon: Icons.filter_alt_off_outlined,
                          text: 'No classes available.',
                        )
                      else
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              ChoiceChip(
                                label: const Text('All'),
                                selected: _selectedClass == null,
                                onSelected: (_) {
                                  setState(() => _selectedClass = null);
                                  widget.onClassFilterChanged(null);
                                },
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              for (final className in classes) ...[
                                ChoiceChip(
                                  label: Text(_friendlyClassLabel(className)),
                                  selected: _selectedClass == className,
                                  onSelected: (_) {
                                    setState(() => _selectedClass = className);
                                    widget.onClassFilterChanged(className);
                                  },
                                ),
                                const SizedBox(width: AppSpacing.xs),
                              ],
                            ],
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              if (featuresAsync.isLoading && displayedFeatures.isEmpty)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(AppSpacing.lg),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (featuresAsync.hasError && displayedFeatures.isEmpty)
                AppEmptyState(
                  icon: Icons.error_outline,
                  title: 'AI features unavailable',
                  message: userFacingErrorMessage(
                    featuresAsync.asError?.error ??
                        StateError(
                          'AI features failed without an error payload.',
                        ),
                    fallback: 'Unable to load AI features right now.',
                  ),
                  actionLabel: 'Retry',
                  onAction: featuresController.refresh,
                )
              else if (displayedFeatures.isEmpty)
                const AppEmptyState(
                  icon: Icons.layers_clear_outlined,
                  title: 'No AI features match these filters',
                  message: 'Try a different class or search term.',
                )
              else
                ProgressiveListSection<AiLayerFeature>(
                  items: displayedFeatures,
                  resetKey: browserQuery,
                  hasMore: featureState.hasMore,
                  isLoadingMore: featureState.isLoadingMore,
                  onLoadMore: featuresController.loadMore,
                  gridMinItemWidth: 360,
                  itemBuilder: (context, feature, _) {
                    final item = _AiPreviewFeature(
                      layer: widget.layer,
                      feature: feature,
                    );
                    return _AiFeatureListCard(
                      item: item,
                      onTap: () => widget.onFeatureSelected(item),
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class _AiFeatureListCard extends StatelessWidget {
  const _AiFeatureListCard({required this.item, required this.onTap});

  final _AiPreviewFeature item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final feature = item.feature;
    final className = _aiFeatureClass(feature);
    final confidence = _aiFeatureConfidence(feature);
    final model = _aiFeatureText(feature, const ['model_name', 'model']);
    final layerLabel = _friendlyLayerTypeLabel(item.layer.layerType);
    final title = className == null
        ? '$layerLabel output'
        : _friendlyClassLabel(className);
    final subtitle = [
      layerLabel,
      if (confidence != null) 'Confidence ${_formatConfidence(confidence)}',
      if (model != null) _friendlyModelLabel(model),
    ].join(' - ');

    return AppCard(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 12,
            height: 12,
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              color: _aiFeatureStyle(item).borderColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall,
                  softWrap: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _aiFeatureListLabel({
  required int shownCount,
  required int totalCount,
  required bool hasFilter,
}) {
  final totalLabel = totalCount <= 0 ? 'matching AI features' : '$totalCount';
  if (hasFilter) {
    return 'Showing $shownCount of $totalLabel matching AI feature(s)';
  }
  return 'Showing $shownCount of $totalLabel AI review feature(s)';
}

List<String> _aiFeatureBrowserClasses(
  AiLayerFeatureCollection? summary,
  List<AiLayerFeature> fallbackFeatures,
) {
  final classes = <String>{
    ...?summary?.classCounts.keys.where((value) => value.trim().isNotEmpty),
    ...fallbackFeatures.map(_aiFeatureClass).whereType<String>(),
  }.toList();
  classes.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return classes;
}

class _AiPreviewFeature {
  const _AiPreviewFeature({required this.layer, required this.feature});

  final AiOutputLayer layer;
  final AiLayerFeature feature;

  String get key => '${layer.id}:${feature.id}';
}

class _AiFeatureStyle {
  const _AiFeatureStyle({
    required this.fillColor,
    required this.borderColor,
    required this.borderWidth,
  });

  final Color fillColor;
  final Color borderColor;
  final double borderWidth;
}

class _LegendSwatch extends StatelessWidget {
  const _LegendSwatch({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
      child: const SizedBox(width: 14, height: 14),
    );
  }
}

_AiFeatureStyle _aiFeatureStyle(_AiPreviewFeature item) {
  switch (item.layer.layerType) {
    case 'classification':
    default:
      final color = _classificationColor(_aiFeatureClass(item.feature));
      return _AiFeatureStyle(
        fillColor: color.withValues(alpha: 0.20),
        borderColor: color,
        borderWidth: 2,
      );
  }
}

Color _classificationColor(String? label) {
  final normalized = label?.trim().toLowerCase() ?? '';
  if (normalized.contains('citrus')) {
    return const Color(0xFFF9A825);
  }
  if (normalized.contains('fruit')) {
    return const Color(0xFF7B1FA2);
  }
  if (normalized.contains('olive')) {
    return const Color(0xFF2E7D32);
  }
  return const Color(0xFF455A64);
}

String _friendlyClassLabel(String label) {
  final normalized = label.trim();
  if (normalized.isEmpty) {
    return 'Unlabeled';
  }
  return _titleCase(normalized.replaceAll('_', ' '));
}

String? _aiFeatureClass(AiLayerFeature feature) {
  return _aiFeatureText(feature, const [
    'predicted_class',
    'dominant_class',
    'class_label',
    'label',
    'L4_descr',
  ]);
}

bool _isAggregateAiFeature(AiLayerFeature feature) {
  final aggregate = feature.properties['aggregate'];
  if (aggregate is bool) {
    return aggregate;
  }
  return _stringValue(feature.properties['preview_geometry']) == 'aggregate' ||
      _stringValue(feature.properties['preview_kind']) == 'aggregate';
}

int? _aggregateAiFeatureCount(AiLayerFeature feature) {
  final value = feature.properties['aggregate_count'];
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

double _aiFeatureApproxArea(AiLayerFeature feature) {
  final storedArea = _aiFeatureAreaValue(feature);
  if (storedArea != null) {
    return storedArea;
  }
  final points = geometryPoints(feature.geometry);
  if (points.isEmpty) {
    return double.infinity;
  }
  var minLat = double.infinity;
  var minLon = double.infinity;
  var maxLat = -double.infinity;
  var maxLon = -double.infinity;
  for (final point in points) {
    if (point.latitude < minLat) minLat = point.latitude;
    if (point.longitude < minLon) minLon = point.longitude;
    if (point.latitude > maxLat) maxLat = point.latitude;
    if (point.longitude > maxLon) maxLon = point.longitude;
  }
  final bboxArea = (maxLat - minLat).abs() * (maxLon - minLon).abs();
  return bboxArea.isFinite ? bboxArea : double.infinity;
}

double? _aiFeatureAreaValue(AiLayerFeature feature) {
  for (final key in const <String>['area_ha', 'area']) {
    final value = feature.properties[key];
    if (value is num && value.isFinite) {
      return value.toDouble().abs();
    }
    if (value is String) {
      final parsed = double.tryParse(value);
      if (parsed != null && parsed.isFinite) {
        return parsed.abs();
      }
    }
  }
  return null;
}

double? _aiFeatureConfidence(AiLayerFeature feature) {
  for (final key in const [
    'confidence',
    'confidence_score',
    'probability',
    'max_probability',
  ]) {
    final value = _toDoubleValue(feature.properties[key]);
    if (value != null) {
      return value;
    }
  }
  return null;
}

String? _aiFeatureText(AiLayerFeature feature, List<String> keys) {
  for (final key in keys) {
    final text = _stringValue(feature.properties[key]);
    if (text != null) {
      return text;
    }
  }
  return null;
}

String _formatConfidence(double value) {
  if (value >= 0 && value <= 1) {
    return '${(value * 100).toStringAsFixed(1)}%';
  }
  return value.toStringAsFixed(2);
}

List<MapEntry<String, String>> _layerSummaryRows(
  AiOutputLayer layer,
  AiRun run,
) {
  final modelName = _firstString([
    run.selectedModel,
    _metadataText(run.metadata, 'selected_model'),
    _metadataText(run.metadata, 'final_model'),
    _metadataText(run.metadata, 'model_name'),
  ]);
  final rows = <MapEntry<String, String>>[
    MapEntry('Layer type', _friendlyLayerTypeLabel(layer.layerType)),
    MapEntry('Status', _friendlyLayerStatusTitle(layer.status)),
    MapEntry('Run', _shortId(run.id)),
    if (run.createdAt != null) MapEntry('Run date', _formatDate(run.createdAt)),
    if (modelName != null) MapEntry('Model', _friendlyModelLabel(modelName)),
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

String _executionMode(AiRun run) =>
    _metadataText(run.metadata, 'execution_mode') ?? 'not set';

AiRun? _activeRunFrom(List<AiRun> runs) {
  for (final run in runs) {
    if (run.isActive) {
      return run;
    }
  }
  return null;
}

AiOutputLayer? _firstClassificationLayer(List<AiOutputLayer> layers) {
  for (final layer in layers) {
    if (layer.layerType == 'classification') {
      return layer;
    }
  }
  return null;
}

String _runDisplayTitle(AiRun run) {
  return 'Run ${_shortId(run.id)}';
}

int _runPredictionCount(AiRun run) {
  return run.predictionCount > 0
      ? run.predictionCount
      : _toIntValue(
              run.counts['predictions_inserted'] ??
                  run.counts['prediction_count'] ??
                  run.counts['features_inserted'] ??
                  run.metadata['prediction_count'],
            ) ??
            0;
}

List<MapEntry<String, String>> _runStatusRows(AiRun run) {
  final rows = <MapEntry<String, String>>[
    MapEntry('Run name', _runDisplayTitle(run)),
    MapEntry('Status', _friendlyStatusLabel(run.status)),
    if (run.stage?.trim().isNotEmpty ?? false)
      MapEntry('Stage', _friendlyStatusLabel(run.stage!)),
    if (run.progress > 0) MapEntry('Progress', _formatMetric(run.progress)),
    if (run.message?.trim().isNotEmpty ?? false)
      MapEntry('Message', run.message!),
    MapEntry(
      'Execution mode',
      _friendlyExecutionModeLabel(_executionMode(run)),
    ),
    MapEntry('Label field', run.labelField ?? 'Not set'),
    MapEntry('Prediction features', '${_runPredictionCount(run)}'),
    MapEntry('Created', _formatDate(run.createdAt)),
    MapEntry('AI area', _friendlyScopeLabel(run.scopeType)),
    MapEntry('Duration', _runDuration(run)),
  ];
  if (run.regionPreset?.trim().isNotEmpty ?? false) {
    rows.add(MapEntry('Region', run.regionPreset!));
  }
  if (run.callbackReceivedAt != null) {
    rows.add(MapEntry('Last callback', _formatDate(run.callbackReceivedAt)));
  }
  return rows.map((row) => MapEntry(row.key, _safeText(row.value))).toList();
}

const String _notRecordedForRun = 'Not recorded for this run';

Map<String, dynamic> _runSettingsSnapshot(AiRun run) =>
    _mapValue(run.metadata['ai_settings']);

String _recordedOrMissing(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return _notRecordedForRun;
  }
  return trimmed;
}

String? _runAreaTypeValue(AiRun run, String key) {
  final settings = _runSettingsSnapshot(run);
  return _firstString([
    _metadataText(run.metadata, key),
    _stringValue(settings[key]),
    if (key == 'training_samples_area_type' || key == 'prediction_area_type')
      _areaTypeFromLegacyScope(_stringValue(settings['scope_type'])),
    _areaTypeFromLegacyScope(run.scopeType),
  ]);
}

String? _areaTypeFromLegacyScope(String? value) {
  switch (value) {
    case 'project':
    case 'project_area':
      return 'project_area';
    case 'custom_polygon':
    case 'custom_ai_area':
      return 'custom_ai_area';
    case 'national':
    case 'national_lebanon':
      return 'national_lebanon';
    default:
      return null;
  }
}

List<MapEntry<String, String>> _runImageryRows(AiRun run) {
  final settings = _runSettingsSnapshot(run);
  final sources = _stringList(settings['satellite_sources']);
  final timeframes = _mapValue(settings['satellite_timeframes']);
  if (sources.isNotEmpty && timeframes.isNotEmpty) {
    return <MapEntry<String, String>>[
          MapEntry(
            'Satellite sources',
            sources.map((source) => _friendlySatelliteLabel(source)).join(', '),
          ),
          for (final source in sources)
            MapEntry(
              _friendlySatelliteLabel(source),
              _satelliteTimeframeSummary(_mapValue(timeframes[source])),
            ),
        ]
        .map((row) => MapEntry(row.key, _safeText(row.value)))
        .toList(growable: false);
  }
  final dateFrom = _stringValue(settings['date_from']);
  final dateTo = _stringValue(settings['date_to']);
  return <MapEntry<String, String>>[
    MapEntry(
      'Satellite source',
      settings.containsKey('satellite_source')
          ? _friendlySatelliteLabel(_stringValue(settings['satellite_source']))
          : _notRecordedForRun,
    ),
    MapEntry('Year', _recordedOrMissing(_stringValue(settings['target_year']))),
    MapEntry(
      'Season',
      settings.containsKey('season')
          ? _friendlySeasonLabel(_stringValue(settings['season']) ?? '')
          : _notRecordedForRun,
    ),
    MapEntry(
      'Date range',
      dateFrom == null && dateTo == null
          ? _notRecordedForRun
          : '${dateFrom ?? _notRecordedForRun} to ${dateTo ?? _notRecordedForRun}',
    ),
  ].map((row) => MapEntry(row.key, _safeText(row.value))).toList(growable: false);
}

String _satelliteTimeframeSummary(Map<String, dynamic> timeframe) {
  if (timeframe.isEmpty) {
    return _notRecordedForRun;
  }
  final year = _stringValue(timeframe['map_year'] ?? timeframe['mapYear']);
  final seasons = timeframe['seasons'];
  if (seasons is! List || seasons.isEmpty) {
    return year == null ? _notRecordedForRun : 'Year $year';
  }
  final parts = <String>[
    if (year != null) 'Year $year',
    for (final rawSeason in seasons)
      if (rawSeason is Map)
        _seasonTimeframeSummary(Map<String, dynamic>.from(rawSeason)),
  ].where((part) => part.trim().isNotEmpty).toList(growable: false);
  return parts.isEmpty ? _notRecordedForRun : parts.join('; ');
}

String _seasonTimeframeSummary(Map<String, dynamic> season) {
  final label = _friendlySeasonLabel(_stringValue(season['season']) ?? '');
  final from = _stringValue(season['from_date'] ?? season['fromDate']);
  final to = _stringValue(season['to_date'] ?? season['toDate']);
  if (from == null && to == null) {
    return label;
  }
  return '$label $from to $to';
}

List<MapEntry<String, String>> _runTrainingSampleRows(AiRun run) {
  final areaType = _runAreaTypeValue(run, 'training_samples_area_type');
  final classRows = _countRows(run.metadata['class_counts']);
  final selectedClasses = _stringList(run.metadata['selected_classes']);
  return <MapEntry<String, String>>[
        MapEntry('Label field', run.labelField ?? _notRecordedForRun),
        MapEntry('Area used', _friendlyScopeLabel(areaType ?? '')),
        MapEntry(
          'Approved samples',
          run.trainingFeatureCount > 0
              ? '${run.trainingFeatureCount}'
              : _notRecordedForRun,
        ),
        MapEntry(
          'Eligible samples',
          run.eligibleFeatureCount > 0
              ? '${run.eligibleFeatureCount}'
              : _notRecordedForRun,
        ),
        MapEntry(
          'Selected classes',
          classRows.isNotEmpty
              ? classRows.map((row) => row.key).join(', ')
              : selectedClasses.isEmpty
              ? _notRecordedForRun
              : selectedClasses.join(', '),
        ),
      ]
      .map((row) => MapEntry(row.key, _safeText(row.value)))
      .toList(growable: false);
}

List<MapEntry<String, String>> _runPredictionAreaRows(AiRun run) {
  final areaType = _runAreaTypeValue(run, 'prediction_area_type');
  final nationalEligibility = _mapValue(
    run.metadata['national_scope_eligibility'],
  );
  final customSummary = _mapValue(
    _runSettingsSnapshot(run)['custom_polygon_summary'],
  );
  final isNational = areaType == 'national_lebanon';
  return <MapEntry<String, String>>[
        MapEntry('Prediction area', _friendlyScopeLabel(areaType ?? '')),
        if (customSummary.isNotEmpty)
          MapEntry(
            'Custom AI area',
            customSummary['saved_for_run'] == true
                ? 'Saved for run'
                : 'Recorded for run',
          ),
        if (isNational || nationalEligibility.isNotEmpty)
          MapEntry('National Lebanon', _nationalLebanonStatusForRun(run)),
      ]
      .map((row) => MapEntry(row.key, _safeText(row.value)))
      .toList(growable: false);
}

List<MapEntry<String, String>> _runExtractedFeatureRows(AiRun run) {
  final settings = _runSettingsSnapshot(run);
  final featureInputs = _firstStringList([
    settings['feature_inputs'],
    settings['selected_feature_inputs'],
    settings['selected_extracted_features'],
  ]);
  final featureGroups = _stringList(settings['feature_groups']);
  return <MapEntry<String, String>>[
        MapEntry(
          'Selected features',
          featureInputs.isEmpty ? _notRecordedForRun : featureInputs.join(', '),
        ),
        if (featureInputs.isNotEmpty)
          MapEntry('Feature count', featureInputs.length.toString())
        else if (featureGroups.isNotEmpty)
          MapEntry(
            'Legacy groups',
            featureGroups.map(_friendlyFeatureGroupLabel).join(', '),
          ),
      ]
      .map((row) => MapEntry(row.key, _safeText(row.value)))
      .toList(growable: false);
}

List<MapEntry<String, String>> _runModelConfigRows(AiRun run) {
  final settings = _runSettingsSnapshot(run);
  final actualModel = _firstString([
    run.selectedModel,
    _metadataText(run.metadata, 'classification_model'),
    _metadataText(run.metadata, 'selected_model'),
    _metadataText(run.metadata, 'final_model'),
  ]);
  return <MapEntry<String, String>>[
        MapEntry(
          'Preferred model requested',
          settings.containsKey('preferred_model')
              ? _friendlyModelLabel(
                  _stringValue(settings['preferred_model']) ?? '',
                )
              : _notRecordedForRun,
        ),
        MapEntry(
          'Actual model used',
          actualModel == null
              ? _notRecordedForRun
              : _friendlyModelLabel(actualModel),
        ),
        MapEntry(
          'Confidence threshold',
          _stringValue(settings['confidence_threshold']) ??
              _stringValue(run.metadata['confidence_threshold']) ??
              _notRecordedForRun,
        ),
        MapEntry(
          'Best balanced model',
          _friendlyModelOrMissing(
            _firstString([
              _metadataText(run.metadata, 'metrics_best_macro_f1_model'),
              _metadataText(run.metadata, 'best_macro_f1_model'),
              _metadataText(run.metadata, 'best_balanced_model'),
            ]),
          ),
        ),
        MapEntry(
          'Highest accuracy model',
          _friendlyModelOrMissing(
            _firstString([
              _metadataText(run.metadata, 'highest_accuracy_model'),
              _metadataText(run.metadata, 'best_accuracy_model'),
            ]),
          ),
        ),
      ]
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
  final explanation = _modelSelectionExplanation(run, metrics);
  final enrichedRows = <MapEntry<String, String>>[
    ...rows,
    if (explanation != null) MapEntry('Selection rationale', explanation),
  ];
  if (enrichedRows.isNotEmpty) {
    return enrichedRows
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

String? _modelSelectionExplanation(AiRun run, List<AiRunMetric> metrics) {
  final metadataSelection = _mapValue(run.metadata['model_selection']);
  final summary = _mapValue(run.metadata['model_metrics_summary']);
  final summarySelection = _mapValue(summary['model_selection']);
  final fromRun = _firstString([
    _stringValue(metadataSelection['selection_explanation']),
    _stringValue(metadataSelection['explanation']),
    _stringValue(run.metadata['selection_explanation']),
    _stringValue(summarySelection['selection_explanation']),
    _stringValue(summarySelection['explanation']),
    _stringValue(summary['selection_explanation']),
  ]);
  if (fromRun != null) {
    return fromRun;
  }
  for (final metric in metrics) {
    final metricSelection = _mapValue(
      metric.metrics['model_selection'] ?? metric.metrics['selection'],
    );
    final explanation = _firstString([
      _stringValue(metricSelection['selection_explanation']),
      _stringValue(metricSelection['explanation']),
      _stringValue(metric.metrics['selection_explanation']),
    ]);
    if (explanation != null) {
      return explanation;
    }
  }
  return null;
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

String _friendlyExecutionModeLabel(String mode) {
  switch (mode) {
    case 'local_ground_truth_export':
      return 'Ground truth export';
    case 'regional_feature_extraction':
      return 'Regional feature extraction';
    case 'regional_model_eval':
      return 'Regional model evaluation';
    case 'regional_classification':
      return 'Regional review prediction';
    case 'regional_vectorization_artifacts':
      return 'Regional prediction store';
    case 'regional_full_review_artifacts':
      return 'Full regional review run';
    case 'dry_run':
      return 'Pipeline test run';
    case 'mock':
      return 'Mock AI server check';
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

String _friendlyLayerStatusTitle(String status) {
  switch (status) {
    case 'ready_for_review':
      return 'Ready for review';
    case 'approved':
      return 'Approved';
    case 'rejected':
      return 'Rejected';
    case 'published':
      return 'Published';
    case 'unpublished':
      return 'Draft';
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
    default:
      return _titleCase(layerType.replaceAll('_', ' '));
  }
}

String _friendlyProcessingMethod(String value) {
  switch (value) {
    case 'confidence_mask_dissolve_makevalid_simplify_preserve_topology':
      return 'Confidence mask, dissolve, geometry repair, and simplification';
    case 'confidence_mask_dissolve_makevalid_simplify_preserve_topology_chaikin':
      return 'Confidence mask, dissolve, geometry repair, simplification, and smoothing';
    default:
      return _titleCase(value.replaceAll('_', ' '));
  }
}

String _friendlyScopeLabel(String scope) {
  switch (scope) {
    case 'project':
    case 'project_area':
      return 'Project feature extent';
    case 'custom_polygon':
    case 'custom_ai_area':
      return 'Custom AI area';
    case 'national':
    case 'national_lebanon':
      return 'National Lebanon';
    case '':
      return _notRecordedForRun;
    default:
      return _titleCase(scope.replaceAll('_', ' '));
  }
}

String _nationalLebanonStatusForRun(AiRun run) {
  final eligibility = _mapValue(run.metadata['national_scope_eligibility']);
  final coverage = _mapValue(eligibility['coverage']);
  final score = _toIntValue(coverage['score']);
  if (run.scopeType == 'national') {
    return score == null
        ? 'Static Lebanon boundary'
        : 'Coverage score $score / 100';
  }
  return score == null ? 'Not selected' : 'Available, score $score / 100';
}

String _friendlySatelliteLabel(String? value) {
  switch (value) {
    case 'sentinel2':
      return 'Sentinel-2';
    case 'landsat':
      return 'Landsat';
    case null:
      return 'Not set';
    default:
      return _titleCase(value.replaceAll('_', ' '));
  }
}

String _friendlyFeatureGroupLabel(String value) {
  switch (value) {
    case 'spectral_bands':
      return 'Spectral bands';
    case 'vegetation_indices':
      return 'Vegetation indices';
    case 'topography':
      return 'Topography';
    case 'texture':
      return 'Texture';
    case 'seasonal_phenology':
      return 'Seasonal composites';
    default:
      return _titleCase(value.replaceAll('_', ' '));
  }
}

String _friendlyStaticFeatureLabel(String value) {
  switch (value) {
    case 'static_srtm_elevation':
      return 'SRTM elevation';
    case 'static_srtm_slope':
      return 'SRTM slope';
    case 'static_srtm_aspect':
      return 'SRTM aspect';
    case 'static_texture_pc1':
      return 'Texture PC1';
    default:
      return _titleCase(value.replaceAll('_', ' '));
  }
}

String _friendlySeasonLabel(String value) {
  switch (value) {
    case 'growing':
      return 'Growing season';
    case 'spring':
      return 'Spring';
    case 'summer':
      return 'Summer';
    case 'autumn':
      return 'Autumn';
    case 'winter':
      return 'Winter';
    case 'custom':
      return 'Custom';
    default:
      return _titleCase(value.replaceAll('_', ' '));
  }
}

String _friendlyModelOrMissing(String? model) =>
    model == null ? _notRecordedForRun : _friendlyModelLabel(model);

String _friendlyModelLabel(String model) {
  return formatModelName(model);
}

String _normalModelPreferenceForSettings(String? value) {
  switch (value?.trim().toLowerCase()) {
    case 'random_forest':
    case 'rf':
      return 'random_forest';
    case 'svm':
    case 'svm_rbf':
      return 'svm';
    case 'gradient_boosting':
    case 'gb':
      return 'gradient_boosting';
    case 'xgboost':
    case 'xgb':
      return 'auto';
    case 'auto':
      return 'auto';
    default:
      return 'auto';
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

List<String> _outputPaths(Map<String, dynamic> metadata) {
  final paths = <String>{};
  void collect(dynamic value, [String key = '']) {
    if (value == null) {
      return;
    }
    if (value is String) {
      final normalized = value.replaceAll('\\', '/').trim();
      final lower = normalized.toLowerCase();
      final keyLower = key.toLowerCase();
      final looksLikeArtifact =
          keyLower.contains('path') ||
          keyLower.contains('file') ||
          lower.endsWith('.geojson') ||
          lower.endsWith('.json') ||
          lower.endsWith('.csv') ||
          lower.endsWith('.tif') ||
          lower.endsWith('.tiff') ||
          lower.endsWith('.log');
      if (normalized.contains('outputs/') || looksLikeArtifact) {
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

List<String> _outputPathsForRun(AiRun run) {
  final paths = <String>{
    ..._outputPaths(run.metadata),
    ..._outputPaths(run.artifacts),
  };
  return paths.where((path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.geojson') ||
        lower.endsWith('.json') ||
        lower.endsWith('.csv') ||
        lower.endsWith('.tif') ||
        lower.endsWith('.tiff') ||
        lower.endsWith('.log') ||
        lower.contains('classification') ||
        lower.contains('training_features') ||
        lower.contains('feature_importance') ||
        lower.contains('confusion_matrix');
  }).toList()..sort();
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
  if (file.startsWith('training_features')) return 'Training features';
  if (file == 'ai_classification_review.geojson') {
    return 'Prediction GeoJSON';
  }
  if (file.endsWith('.geojson')) return 'Vector output';
  if (file.endsWith('.tif') || file.endsWith('.tiff')) {
    return 'Classification raster';
  }
  if (file == 'run.log') return 'Run log file';
  if (file == 'run_config.json') return 'Run configuration file';
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

String _shortId(String id) {
  final trimmed = id.trim();
  if (trimmed.length <= 8) {
    return trimmed;
  }
  return trimmed.substring(0, 8);
}

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

List<String> _firstStringList(List<dynamic> values) {
  for (final value in values) {
    final items = _stringList(value);
    if (items.isNotEmpty) {
      return items;
    }
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

String _labelizeAttributeKey(String key) {
  return key
      .replaceAll('_', ' ')
      .split(' ')
      .where((part) => part.isNotEmpty)
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');
}

String _formatAttributeValue(Object? value) {
  if (value == null) {
    return 'Not available';
  }
  if (value is List) {
    return value.map(_formatAttributeValue).join(', ');
  }
  if (value is Map) {
    return value.entries
        .map((entry) => '${entry.key}: ${_formatAttributeValue(entry.value)}')
        .join(', ');
  }
  final text = value.toString().trim();
  return text.isEmpty ? 'Not available' : _safeText(text);
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

class _DetailSection extends StatelessWidget {
  const _DetailSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.sm),
            child,
          ],
        ),
      ),
    );
  }
}

class _FeatureAttributesGrid extends StatelessWidget {
  const _FeatureAttributesGrid({required this.attributes});

  final Map<String, Object?> attributes;

  @override
  Widget build(BuildContext context) {
    final entries = attributes.entries
        .where((entry) => entry.value != null)
        .toList(growable: false);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 520 ? 2 : 1;
        final itemWidth = columns == 1
            ? constraints.maxWidth
            : (constraints.maxWidth - 12) / 2;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final entry in entries)
              SizedBox(
                width: itemWidth,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).colorScheme.outlineVariant.withValues(alpha: 0.36),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _labelizeAttributeKey(entry.key),
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                          softWrap: true,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatAttributeValue(entry.value),
                          style: Theme.of(context).textTheme.bodyMedium,
                          softWrap: true,
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

class _NationalCoverageCard extends StatelessWidget {
  const _NationalCoverageCard({
    required this.eligibility,
    required this.weakClasses,
    required this.minSamplesPerClass,
  });

  final AiNationalScopeEligibility eligibility;
  final List<AiLabelCount> weakClasses;
  final int minSamplesPerClass;

  @override
  Widget build(BuildContext context) {
    final coverage = eligibility.coverage;
    final score = _toIntValue(coverage['score']) ?? eligibility.coverageScore;
    final rating = _coverageRatingLabel(
      coverage['rating']?.toString() ?? eligibility.coverageRating,
    );
    final governoratesCovered =
        _toIntValue(coverage['governorates_covered']) ?? 0;
    final totalGovernorates = _toIntValue(coverage['total_governorates']) ?? 8;
    final gridCellsCovered = _toIntValue(coverage['grid_cells_covered']) ?? 0;
    final totalGridCells = _toIntValue(coverage['total_grid_cells']) ?? 20;
    final usableClasses = _toIntValue(coverage['usable_class_count']) ?? 0;
    final weakClassCount =
        _toIntValue(coverage['weak_class_count']) ?? weakClasses.length;
    final elevationMeasured = coverage['elevation_measured'] == true;
    final elevationBands = coverage['elevation_bands'] is List
        ? (coverage['elevation_bands'] as List)
              .map((value) => value.toString())
              .where((value) => value.trim().isNotEmpty)
              .join(', ')
        : '';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'National Coverage',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 2),
            Text(
              'Checks how well approved samples are spread across Lebanon.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            _NationalCoverageRow(
              icon: Icons.map_outlined,
              label: 'Governorates covered',
              value: '$governoratesCovered / $totalGovernorates',
              rating: coverage['governorate_rating']?.toString(),
            ),
            _NationalCoverageRow(
              icon: Icons.grid_view_outlined,
              label: 'Spatial spread',
              value: '$gridCellsCovered / $totalGridCells grid cells',
              rating: coverage['grid_rating']?.toString(),
            ),
            _NationalCoverageRow(
              icon: Icons.category_outlined,
              label: 'Class coverage',
              value: '$usableClasses usable classes, $weakClassCount weak',
              rating: coverage['class_rating']?.toString(),
            ),
            if (elevationMeasured)
              _NationalCoverageRow(
                icon: Icons.terrain_outlined,
                label: 'Topography',
                value: elevationBands.isEmpty ? 'Measured' : elevationBands,
                rating: 'good',
              ),
            const SizedBox(height: AppSpacing.xs),
            _NationalCoverageRow(
              icon: Icons.speed_outlined,
              label: 'Overall coverage',
              value: '$rating ($score / 100)',
              rating: coverage['rating']?.toString(),
            ),
            if (weakClasses.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              _NoticeRow(
                icon: Icons.info_outline,
                text:
                    'Classes with fewer than $minSamplesPerClass samples will be skipped.',
              ),
            ],
            if (score < 70) ...[
              const SizedBox(height: AppSpacing.xs),
              const _NoticeRow(
                icon: Icons.warning_amber_outlined,
                text: 'Run allowed, but national results may be unreliable.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NationalCoverageRow extends StatelessWidget {
  const _NationalCoverageRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.rating,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? rating;

  @override
  Widget build(BuildContext context) {
    final normalized = rating?.trim().toLowerCase();
    final color = switch (normalized) {
      'good' => Colors.green.shade700,
      'limited' => Colors.orange.shade700,
      'weak' => Theme.of(context).colorScheme.error,
      _ => Theme.of(context).colorScheme.primary,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$label: ',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(text: value),
                ],
              ),
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }
}

String _coverageRatingLabel(String rating) {
  switch (rating.trim().toLowerCase()) {
    case 'good':
      return 'Good';
    case 'limited':
      return 'Limited';
    case 'weak':
    default:
      return 'Weak';
  }
}

extension on AiProjectSettings {
  String get updatedKey =>
      '${isEnabled ? 1 : 0}:$scopeType:$minSamplesPerClass:$confidenceThreshold:${modelPreferences.hashCode}';
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
