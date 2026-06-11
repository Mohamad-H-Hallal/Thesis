import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/pagination/paginated_list_controller.dart';
import '../../../../core/pagination/paginated_result.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/utils/lebanon_time.dart';
import '../../../../core/widgets/app_card.dart';
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
  static const List<String> _indexFeatures = <String>[
    'NDVI',
    'EVI',
    'NDRE',
    'SAVI',
    'NDWI',
  ];
  static const Set<String> _recommendedFeatures = <String>{
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
  };
  static const Map<String, List<String>> _seasonRanges = <String, List<String>>{
    'growing': <String>['03-01', '05-31'],
    'dry': <String>['06-01', '08-31'],
    'harvest': <String>['09-01', '11-30'],
    'winter': <String>['12-01', '02-28'],
  };

  bool _isEnabled = false;
  String? _labelField;
  String _scopeType = 'project';
  int _aiAreaDropdownVersion = 0;
  bool _nationalModeEnabled = false;
  String _preferredModel = 'auto';
  String _satelliteSource = 'sentinel2';
  String _targetYear = '2025';
  String _season = 'growing';
  Set<String> _selectedFeatureInputs = Set<String>.from(_recommendedFeatures);
  Map<String, dynamic>? _customScopeGeometry;
  final TextEditingController _minSamplesController = TextEditingController();
  final TextEditingController _dateFromController = TextEditingController();
  final TextEditingController _dateToController = TextEditingController();
  String? _initializedFor;
  bool _saving = false;

  @override
  void dispose() {
    _minSamplesController.dispose();
    _dateFromController.dispose();
    _dateToController.dispose();
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
        final nationalReadiness = labelProbeAsync.asData?.value;
        final nationalScopeEligible =
            nationalReadiness?.nationalScopeEligibility.eligible ?? false;
        final nationalScopeEnabled =
            nationalScopeEligible &&
            (_nationalModeEnabled ||
                (nationalReadiness?.nationalScopeEnabled ?? false));
        if (_scopeType == 'national' && !nationalScopeEnabled) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _scopeType != 'national') {
              return;
            }
            setState(() {
              _scopeType = 'project';
              _nationalModeEnabled = false;
              _aiAreaDropdownVersion++;
            });
          });
        }
        final nationalOptionLabel = nationalScopeEnabled
            ? 'National Lebanon'
            : nationalScopeEligible
            ? 'National Lebanon - ready'
            : 'National Lebanon - locked';

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
                      child: Text(nationalOptionLabel),
                    ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) => _handleAiAreaChanged(
                          value,
                          nationalScopeEligible: nationalScopeEligible,
                          nationalScopeEnabled: nationalScopeEnabled,
                          settings: settings,
                        ),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                _scopeType == 'custom_polygon'
                    ? 'Custom AI area uses approved project samples inside the polygon you draw.'
                    : 'Project area uses approved samples from this project. National Lebanon requires representative samples across Lebanon.',
              ),
              if (_scopeType == 'custom_polygon') ...[
                const SizedBox(height: AppSpacing.sm),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : _drawCustomScope,
                    icon: const Icon(Icons.polyline_outlined),
                    label: Text(
                      _customScopeGeometry == null
                          ? 'Draw AI area'
                          : 'Edit AI area',
                    ),
                  ),
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
              DropdownButtonFormField<String>(
                initialValue: _satelliteSource,
                decoration: const InputDecoration(
                  labelText: 'Satellite source',
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'sentinel2',
                    child: Text('Sentinel-2'),
                  ),
                  DropdownMenuItem(value: 'landsat', child: Text('Landsat')),
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() {
                            _satelliteSource = value;
                            final years = _yearOptionsFor(value);
                            if (!years.contains(_targetYear)) {
                              _targetYear = years.first;
                            }
                            _applySeasonDates();
                            _selectedFeatureInputs = _selectedFeatureInputs
                                .where(
                                  _availableFeaturesForSatellite(
                                    value,
                                  ).contains,
                                )
                                .toSet();
                            if (_selectedFeatureInputs.isEmpty) {
                              _selectedFeatureInputs = Set<String>.from(
                                _recommendedFeaturesForSatellite(value),
                              );
                            }
                          });
                        }
                      },
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                _satelliteSource == 'sentinel2'
                    ? 'Sentinel-2 imagery is available from 2015 onward.'
                    : 'Landsat 8/9 imagery is available from 2013 onward.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _targetYear,
                      decoration: const InputDecoration(labelText: 'Map year'),
                      items: _yearOptions()
                          .map(
                            (year) => DropdownMenuItem(
                              value: year,
                              child: Text(year),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: _saving
                          ? null
                          : (value) {
                              if (value != null) {
                                setState(() {
                                  _targetYear = value;
                                  _applySeasonDates();
                                });
                              }
                            },
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _season,
                      decoration: const InputDecoration(labelText: 'Season'),
                      items: const [
                        DropdownMenuItem(
                          value: 'growing',
                          child: Text('Growing'),
                        ),
                        DropdownMenuItem(value: 'dry', child: Text('Dry')),
                        DropdownMenuItem(
                          value: 'harvest',
                          child: Text('Harvest'),
                        ),
                        DropdownMenuItem(
                          value: 'winter',
                          child: Text('Winter'),
                        ),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) {
                              if (value != null) {
                                setState(() {
                                  _season = value;
                                  _applySeasonDates();
                                });
                              }
                            },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _dateFromController,
                enabled: !_saving,
                readOnly: true,
                onTap: _saving ? null : () => _pickDate(_dateFromController),
                decoration: const InputDecoration(
                  labelText: 'From date',
                  hintText: 'Season start',
                  suffixIcon: Icon(Icons.calendar_month_outlined),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextFormField(
                controller: _dateToController,
                enabled: !_saving,
                readOnly: true,
                onTap: _saving ? null : () => _pickDate(_dateToController),
                decoration: const InputDecoration(
                  labelText: 'To date',
                  hintText: 'Season end',
                  suffixIcon: Icon(Icons.calendar_month_outlined),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Dates are limited to the selected season window.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.md),
              _FeatureInputSelector(
                selected: _selectedFeatureInputs,
                availableFeatures: _availableFeaturesForSatellite(
                  _satelliteSource,
                ),
                recommended: _recommendedFeaturesForSatellite(_satelliteSource),
                recommendationNote: _featureRecommendationNote(widget.project),
                onChanged: _saving
                    ? null
                    : (next) => setState(() => _selectedFeatureInputs = next),
              ),
              const SizedBox(height: AppSpacing.md),
              const _NoticeRow(
                icon: Icons.info_outline,
                text:
                    'Saving settings does not run AI. Vegetation indices are recommended for agricultural projects.',
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
    _nationalModeEnabled =
        settings.modelPreferences['national_scope_enabled'] == true;
    final storedScope = settings.scopeType.trim();
    if (storedScope == 'custom_polygon') {
      _scopeType = 'custom_polygon';
    } else if (storedScope == 'national' && _nationalModeEnabled) {
      _scopeType = 'national';
    }
    _aiAreaDropdownVersion++;
    _customScopeGeometry = settings.scopeGeometry == null
        ? null
        : Map<String, dynamic>.from(settings.scopeGeometry!);
    _preferredModel =
        settings.modelPreferences['preferred_model'] as String? ?? 'auto';
    final satellite =
        settings.modelPreferences['satellite_source'] as String? ?? 'sentinel2';
    _satelliteSource = satellite == 'landsat' ? 'landsat' : 'sentinel2';
    final storedYear =
        '${settings.modelPreferences['target_year'] ?? DateTime.now().year - 1}';
    final years = _yearOptions();
    _targetYear = years.contains(storedYear) ? storedYear : years.first;
    final storedSeason =
        settings.modelPreferences['season'] as String? ?? 'growing';
    _season = _seasonRanges.containsKey(storedSeason)
        ? storedSeason
        : 'growing';
    _selectedFeatureInputs = _stringSet(
      settings.modelPreferences['feature_inputs'],
    );
    if (_selectedFeatureInputs.isEmpty) {
      _selectedFeatureInputs = Set<String>.from(
        _recommendedFeaturesForSatellite(_satelliteSource),
      );
    } else {
      final available = _availableFeaturesForSatellite(_satelliteSource);
      _selectedFeatureInputs = _selectedFeatureInputs
          .where(available.contains)
          .toSet();
    }
    _minSamplesController.text = settings.minSamplesPerClass.toString();
    _dateFromController.text =
        settings.modelPreferences['date_from'] as String? ?? '';
    _dateToController.text =
        settings.modelPreferences['date_to'] as String? ?? '';
    if (_dateFromController.text.trim().isEmpty ||
        _dateToController.text.trim().isEmpty ||
        !_datesWithinSeason()) {
      _applySeasonDates();
    }
  }

  List<String> _yearOptions() {
    return _yearOptionsFor(_satelliteSource);
  }

  List<String> _yearOptionsFor(String satelliteSource) {
    final current = DateTime.now().year;
    final firstYear = satelliteSource == 'landsat' ? 2013 : 2015;
    return [for (var year = current; year >= firstYear; year -= 1) '$year'];
  }

  List<String> _availableFeaturesForSatellite(String satelliteSource) {
    return <String>[
      if (satelliteSource == 'landsat')
        ..._landsatFeatures
      else
        ..._sentinel2Features,
      ..._indexFeatures,
    ];
  }

  Set<String> _recommendedFeaturesForSatellite(String satelliteSource) {
    if (satelliteSource == 'landsat') {
      return const <String>{
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
      };
    }
    return _recommendedFeatures;
  }

  String _featureRecommendationNote(ProjectSummary project) {
    final text = [
      project.category,
      project.name,
      project.description,
      project.objectives ?? '',
    ].join(' ').toLowerCase();
    if (text.contains('agric') ||
        text.contains('tree') ||
        text.contains('crop') ||
        text.contains('fruit') ||
        text.contains('olive') ||
        text.contains('vegetation')) {
      return 'Recommended for agricultural classification: visible/red-edge/NIR/SWIR bands plus NDVI, EVI, and NDRE/SAVI to separate crop vigor and tree canopy differences.';
    }
    return 'Recommended features are based on the selected satellite source and common land-cover signals. Adjust them if the project objective needs fewer or different inputs.';
  }

  void _applySeasonDates() {
    final range = _seasonDateRange();
    _dateFromController.text = _formatAiDate(range.start);
    _dateToController.text = _formatAiDate(range.end);
  }

  bool _datesWithinSeason() {
    final from = DateTime.tryParse(_dateFromController.text.trim());
    final to = DateTime.tryParse(_dateToController.text.trim());
    if (from == null || to == null || from.isAfter(to)) {
      return false;
    }
    final range = _seasonDateRange();
    return !from.isBefore(range.start) && !to.isAfter(range.end);
  }

  DateTimeRange _seasonDateRange() {
    final range = _seasonRanges[_season] ?? _seasonRanges['growing']!;
    final startYear = int.tryParse(_targetYear) ?? DateTime.now().year;
    final endYear = _season == 'winter' ? startYear + 1 : startYear;
    return DateTimeRange(
      start: DateTime.parse('$startYear-${range[0]}'),
      end: DateTime.parse('$endYear-${range[1]}'),
    );
  }

  String _formatAiDate(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '${value.year}-$month-$day';
  }

  Future<void> _pickDate(TextEditingController controller) async {
    final range = _seasonDateRange();
    final firstDate = range.start;
    final lastDate = range.end;
    final parsed = DateTime.tryParse(controller.text.trim());
    final initialDate =
        parsed != null &&
            !parsed.isBefore(firstDate) &&
            !parsed.isAfter(lastDate)
        ? parsed
        : firstDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (picked == null) {
      return;
    }
    setState(() {
      controller.text = _formatAiDate(picked);
      final from = DateTime.tryParse(_dateFromController.text.trim());
      final to = DateTime.tryParse(_dateToController.text.trim());
      if (from != null && to != null && from.isAfter(to)) {
        if (identical(controller, _dateFromController)) {
          _dateToController.text = _formatAiDate(picked);
        } else {
          _dateFromController.text = _formatAiDate(picked);
        }
      }
    });
  }

  void _handleAiAreaChanged(
    String? value, {
    required bool nationalScopeEligible,
    required bool nationalScopeEnabled,
    required AiProjectSettings settings,
  }) {
    if (value == null) {
      return;
    }
    if (value == 'national') {
      if (nationalScopeEnabled) {
        setState(() {
          _scopeType = 'national';
          _aiAreaDropdownVersion++;
        });
        return;
      }
      setState(() {
        if (_scopeType == 'national') {
          _scopeType = 'project';
        }
        _aiAreaDropdownVersion++;
      });
      if (nationalScopeEligible) {
        _showEnableNationalModeDialog(settings);
      } else {
        _showNationalScopeLockedDialog();
      }
      return;
    }
    setState(() {
      _scopeType = value;
      _aiAreaDropdownVersion++;
    });
  }

  Future<void> _showNationalScopeLockedDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('National Lebanon is locked'),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'National AI can be enabled only when the project has enough reliable training data across Lebanon and the AI pipeline can process a national prediction area.',
              ),
              SizedBox(height: AppSpacing.sm),
              Text('1. National mode is enabled for this project.'),
              Text('2. Lebanon boundary is configured for AI prediction.'),
              Text(
                '3. Approved training samples cover multiple Lebanese regions and environmental conditions.',
              ),
              Text(
                '4. Every class has enough approved samples: minimum 50, recommended 100+.',
              ),
              Text(
                '5. All samples used for training have valid and consistent labels.',
              ),
              Text(
                '6. No class or region is dangerously underrepresented, or the warning is reviewed.',
              ),
              Text(
                '7. The AI pipeline supports the selected satellite, dates, features, and national boundary.',
              ),
              Text(
                '8. A validation/review plan exists before national results are published.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _showEnableNationalModeDialog(AiProjectSettings settings) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enable national mode'),
        content: const Text(
          'National readiness requirements are met. Enable National Lebanon as an AI area option for future runs?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Enable national mode'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _enableNationalMode(settings);
    }
  }

  Future<void> _enableNationalMode(AiProjectSettings settings) async {
    setState(() => _saving = true);
    try {
      await ref
          .read(aiRepositoryProvider)
          .saveSettings(
            projectId: widget.project.id,
            settings: AiProjectSettings(
              id: settings.id,
              projectId: widget.project.id,
              isEnabled: settings.isEnabled,
              labelField: settings.labelField,
              scopeType: _scopeType == 'national' ? 'project' : _scopeType,
              scopeGeometry: _scopeType == 'custom_polygon'
                  ? _customScopeGeometry
                  : null,
              minSamplesPerClass: settings.minSamplesPerClass,
              modelPreferences: <String, dynamic>{
                ...settings.modelPreferences,
                'national_scope_enabled': true,
              },
              persisted: settings.persisted,
            ),
          );
      ref
        ..invalidate(aiSettingsProvider(widget.project.id))
        ..invalidate(aiReadinessProvider);
      if (mounted) {
        setState(() {
          _nationalModeEnabled = true;
          _aiAreaDropdownVersion++;
        });
        AppSnackbar.showSuccess(
          context,
          'National mode enabled. Select National Lebanon when preparing a run.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to enable national mode right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
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

  Future<void> _saveSettings() async {
    final minSamples =
        int.tryParse(_minSamplesController.text.trim())?.clamp(1, 10000) ?? 50;
    if (_scopeType == 'custom_polygon' && _customScopeGeometry == null) {
      AppSnackbar.showError(context, 'Draw a custom AI area before saving.');
      return;
    }
    if (_scopeType == 'national' && !_nationalModeEnabled) {
      AppSnackbar.showError(
        context,
        'Enable national mode before selecting National Lebanon.',
      );
      return;
    }
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
              modelPreferences: <String, dynamic>{
                'preferred_model': _preferredModel,
                'satellite_source': _satelliteSource,
                'target_year': int.tryParse(_targetYear) ?? DateTime.now().year,
                'season': _season,
                'date_from': _dateFromController.text.trim(),
                'date_to': _dateToController.text.trim(),
                'feature_inputs': (_selectedFeatureInputs.toList(
                  growable: false,
                )..sort()),
                'recommended_feature_inputs': (_recommendedFeaturesForSatellite(
                  _satelliteSource,
                ).toList(growable: false)..sort()),
                'national_scope_enabled': _nationalModeEnabled,
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

class _FeatureInputSelector extends StatelessWidget {
  const _FeatureInputSelector({
    required this.selected,
    required this.availableFeatures,
    required this.recommended,
    required this.recommendationNote,
    required this.onChanged,
  });

  final Set<String> selected;
  final List<String> availableFeatures;
  final Set<String> recommended;
  final String recommendationNote;
  final ValueChanged<Set<String>>? onChanged;

  @override
  Widget build(BuildContext context) {
    final allFeatures = availableFeatures;
    final allSelected =
        allFeatures.isNotEmpty &&
        allFeatures.every((feature) => selected.contains(feature));
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
            TextButton.icon(
              onPressed: onChanged == null
                  ? null
                  : () => onChanged!(
                      allSelected
                          ? Set<String>.from(recommended)
                          : allFeatures.toSet(),
                    ),
              icon: Icon(
                allSelected
                    ? Icons.recommend_outlined
                    : Icons.select_all_outlined,
              ),
              label: Text(allSelected ? 'Use recommended' : 'Select all'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        _NoticeRow(icon: Icons.eco_outlined, text: recommendationNote),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final feature in allFeatures)
              FilterChip(
                label: Text(
                  recommended.contains(feature) ? '$feature *' : feature,
                ),
                selected: selected.contains(feature),
                onSelected: onChanged == null
                    ? null
                    : (value) {
                        final next = Set<String>.from(selected);
                        if (value) {
                          next.add(feature);
                        } else {
                          next.remove(feature);
                        }
                        onChanged!(next);
                      },
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text('* recommended', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
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
                        ? () => _prepareAiRun(settings)
                        : null,
                    icon: _creatingDraft
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.note_add_outlined),
                    label: Text(
                      _creatingDraft ? 'Preparing...' : 'Prepare AI run',
                    ),
                  );
                },
              ),
              const SizedBox(height: AppSpacing.xs),
              const Text(
                'Creates a reviewable AI run configuration. Phase Q will connect saved settings to the Python pipeline.',
              ),
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
                    'Prepare a run when settings and readiness are ready to review.',
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

  Future<void> _prepareAiRun(AiProjectSettings settings) async {
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
          'AI run prepared. No worker command was started.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to prepare AI run right now.',
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
            _RunDetailSectionCard(
              title: 'Run summary',
              trailing: StatusChip(status: run.status),
              child: _RunStatusSection(run: run),
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
              title: 'Output layers',
              child: _AiOutputLayersSection(
                run: run,
                layersAsync: layersAsync,
                reviewsAsync: reviewsAsync,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            _RunDetailSectionCard(
              title: 'Review and publishing',
              child: _ReviewSection(run: run, reviewsAsync: reviewsAsync),
            ),
            const SizedBox(height: AppSpacing.md),
            _RunDetailSectionCard(
              title: 'Technical details',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _DetailedRunResultsSection(
                    run: run,
                    metricsAsync: metricsAsync,
                    layersAsync: layersAsync,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  _OutputPathsSection(paths: _outputPaths(run.metadata)),
                  const SizedBox(height: AppSpacing.sm),
                  _LogsSection(asyncValue: logsAsync),
                  const SizedBox(height: AppSpacing.sm),
                  _TechnicalDetailsSection(run: run),
                ],
              ),
            ),
          ],
        ),
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
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

class _RunStatusSection extends StatelessWidget {
  const _RunStatusSection({required this.run});

  final AiRun run;

  @override
  Widget build(BuildContext context) {
    return _KeyValueList(title: 'Run status', rows: _runStatusRows(run));
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
        const SizedBox(height: AppSpacing.sm),
        _KeyValueList(
          title: 'Execution support',
          rows: _runExecutionSupportRows(run),
        ),
      ],
    );
  }
}

class _DetailedRunResultsSection extends StatelessWidget {
  const _DetailedRunResultsSection({
    required this.run,
    required this.metricsAsync,
    required this.layersAsync,
  });

  final AiRun run;
  final AsyncValue<List<AiRunMetric>> metricsAsync;
  final AsyncValue<List<AiOutputLayer>> layersAsync;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      expandedAlignment: Alignment.centerLeft,
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      title: const Text('Detailed run results'),
      children: [
        _WhatHappenedSection(run: run, metricsAsync: metricsAsync),
        const SizedBox(height: AppSpacing.md),
        _LimitationSection(run: run),
        const SizedBox(height: AppSpacing.md),
        _NextStepSection(run: run, layersAsync: layersAsync),
      ],
    );
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
            if (layer.layerType == 'statistics') {
              messages.add('Statistics summary is available for review.');
            } else {
              messages.add(
                '${_friendlyLayerTypeLabel(layer.layerType)} layer: ${_friendlyLayerStatusLabel(layer.status)}.',
              );
            }
          }
          if (layers.any((layer) => layer.status == 'published')) {
            messages.add(
              'Published AI layers are visible as read-only Project Map overlays.',
            );
          } else {
            messages.add('No viewer-facing AI layer is published yet.');
          }
        }
        return _MessageList(
          title: 'Next step',
          messages: messages.map(_safeText).toList(growable: false),
        );
      },
    );
  }
}

class _AiOutputLayersSection extends ConsumerWidget {
  const _AiOutputLayersSection({
    required this.run,
    required this.layersAsync,
    required this.reviewsAsync,
  });

  final AiRun run;
  final AsyncValue<List<AiOutputLayer>> layersAsync;
  final AsyncValue<List<AiReviewDecision>> reviewsAsync;

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
        final reviews = reviewsAsync.maybeWhen(
          data: (items) => items,
          orElse: () => const <AiReviewDecision>[],
        );
        final latestReview = reviews.isEmpty ? null : reviews.first;
        final previewLayers = layers
            .where(_isPreviewableAiLayer)
            .toList(growable: false);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _NoticeRow(
              icon: Icons.visibility_off_outlined,
              text:
                  'Project Map shows published map layers only. Statistics stay as reports.',
            ),
            const SizedBox(height: AppSpacing.xs),
            if (layers.isEmpty)
              const _NoticeRow(
                icon: Icons.layers_clear_outlined,
                text: 'No AI output layers have been registered yet.',
              )
            else
              _LayerStatusSummary(layers: layers),
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
            if (layers.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              ExpansionTile(
                key: PageStorageKey<String>('ai-layer-details-${run.id}'),
                maintainState: true,
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                expandedAlignment: Alignment.centerLeft,
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                title: const Text('Layer details'),
                children: [
                  for (final layer in layers)
                    _AiOutputLayerTile(
                      run: run,
                      layer: layer,
                      latestReview: latestReview,
                      onPublish: _canPublishAiLayer(layer)
                          ? () => _publishLayer(context, ref, run, layer)
                          : null,
                      onUnpublish: _canUnpublishAiLayer(layer)
                          ? () => _unpublishLayer(context, ref, run, layer)
                          : null,
                    ),
                ],
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
    ref.invalidate(aiRunLogsProvider(run.id));
    ref.invalidate(aiRunReviewsProvider(run.id));
    if (refreshRun) {
      ref.invalidate(aiRunProvider(run.id));
    }
    ref.invalidate(publishedAiLayersProvider(run.projectId));
  }
}

bool _isPreviewableAiLayer(AiOutputLayer layer) {
  const types = {'classification', 'confidence', 'uncertainty'};
  const statuses = {'draft', 'ready_for_review', 'approved', 'published'};
  return types.contains(layer.layerType) && statuses.contains(layer.status);
}

bool _canPublishAiLayer(AiOutputLayer layer) {
  const types = {'classification', 'confidence', 'uncertainty'};
  return types.contains(layer.layerType) && layer.status == 'approved';
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
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    layer.layerType == 'statistics'
                        ? 'Statistics: Report summary'
                        : '${_friendlyLayerTypeLabel(layer.layerType)}: '
                              '${_friendlyLayerStatusTitle(layer.status)}',
                  ),
                ),
                Text(
                  layer.layerType == 'statistics'
                      ? 'Not a map overlay'
                      : _layerVisibilityText(layer),
                  style: Theme.of(context).textTheme.bodySmall,
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
    required this.latestReview,
    this.onPublish,
    this.onUnpublish,
  });

  final AiRun run;
  final AiOutputLayer layer;
  final AiReviewDecision? latestReview;
  final VoidCallback? onPublish;
  final VoidCallback? onUnpublish;

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
                const SizedBox(height: AppSpacing.sm),
                const _NoticeRow(
                  icon: Icons.summarize_outlined,
                  text:
                      'Statistics are review/report summaries. They are not published as map overlays.',
                ),
              ],
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
  bool _showConfidence = false;
  bool _showUncertainty = false;
  bool _panelExpanded = false;
  String? _selectedFeatureKey;
  _AiPreviewFeature? _selectedFeatureOverride;
  String? _featureViewportBounds;
  double? _featureViewportZoom;
  DateTime? _suppressProgrammaticViewportRefreshUntil;
  final Map<String, AiLayerFeatureCollection> _lastLayerCollections =
      <String, AiLayerFeatureCollection>{};

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
      if (_showConfidence) 'confidence',
      if (_showUncertainty) 'uncertainty',
    };
    final activeLayers = previewLayers
        .where((layer) => activeLayerTypes.contains(layer.layerType))
        .toList(growable: false);

    final collections = <AiLayerFeatureCollection>[];
    final errors = <String>[];
    var loading = false;
    for (final layer in activeLayers) {
      final cachedCollection = _lastLayerCollections[layer.id];
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
              _lastLayerCollections[layer.id] = collection;
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
    final loadSummary = _AiPreviewLoadSummary.fromCollections(collections);
    final hasStatisticsLayer = layers.any(
      (layer) => layer.layerType == 'statistics',
    );
    final featureListLayer = _primaryPreviewFeatureListLayer(previewLayers);

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
              showConfidence: _showConfidence,
              showUncertainty: _showUncertainty,
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
                    showConfidence: _showConfidence,
                    showUncertainty: _showUncertainty,
                    expanded: _panelExpanded,
                    loading: loading,
                    errors: errors,
                    hasStatisticsLayer: hasStatisticsLayer,
                    onExpandedChanged: (value) {
                      setState(() => _panelExpanded = value);
                    },
                    onClassificationChanged: (value) {
                      setState(() => _showClassification = value);
                    },
                    onConfidenceChanged: (value) {
                      setState(() => _showConfidence = value);
                    },
                    onUncertaintyChanged: (value) {
                      setState(() => _showUncertainty = value);
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
    );
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
  });

  final int totalFeatureCount;
  final int visibleFeatureCount;
  final int returnedFeatureCount;
  final bool capped;
  final bool optimizedPreview;
  final String geometryMode;
  final int? cap;

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
    );
  }
}

class _AiPreviewLayerToggles extends StatelessWidget {
  const _AiPreviewLayerToggles({
    required this.layers,
    required this.showClassification,
    required this.showConfidence,
    required this.showUncertainty,
    required this.onClassificationChanged,
    required this.onConfidenceChanged,
    required this.onUncertaintyChanged,
  });

  final List<AiOutputLayer> layers;
  final bool showClassification;
  final bool showConfidence;
  final bool showUncertainty;
  final ValueChanged<bool> onClassificationChanged;
  final ValueChanged<bool> onConfidenceChanged;
  final ValueChanged<bool> onUncertaintyChanged;

  @override
  Widget build(BuildContext context) {
    final hasClassification = layers.any(
      (layer) => layer.layerType == 'classification',
    );
    final hasConfidence = layers.any(
      (layer) => layer.layerType == 'confidence',
    );
    final hasUncertainty = layers.any(
      (layer) => layer.layerType == 'uncertainty',
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
        FilterChip(
          selected: showConfidence && hasConfidence,
          avatar: const _LegendSwatch(color: Color(0xFF0288D1)),
          label: const Text('Confidence'),
          onSelected: hasConfidence ? onConfidenceChanged : null,
        ),
        FilterChip(
          selected: showUncertainty && hasUncertainty,
          avatar: const _LegendSwatch(color: Color(0xFFE65100)),
          label: const Text('Uncertainty'),
          onSelected: hasUncertainty ? onUncertaintyChanged : null,
        ),
      ],
    );
  }
}

class _AiPreviewLegend extends StatelessWidget {
  const _AiPreviewLegend({
    required this.showClassification,
    required this.showConfidence,
    required this.showUncertainty,
  });

  final bool showClassification;
  final bool showConfidence;
  final bool showUncertainty;

  @override
  Widget build(BuildContext context) {
    final entries = <(Color, String)>[
      if (showClassification) ...[
        (const Color(0xFF2E7D32), 'Olives'),
        (const Color(0xFFF9A825), 'Citrus fruit trees'),
        (const Color(0xFF7B1FA2), 'Fruit trees'),
      ],
      if (showConfidence) (const Color(0xFF0288D1), 'Confidence'),
      if (showUncertainty) (const Color(0xFFE65100), 'Uncertainty'),
    ];
    if (entries.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Legend', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        LayoutBuilder(
          builder: (context, constraints) {
            final maxItemWidth = constraints.maxWidth < 360
                ? constraints.maxWidth
                : 190.0;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in entries)
                  _AiPreviewLegendItem(
                    color: entry.$1,
                    label: entry.$2,
                    maxWidth: maxItemWidth,
                  ),
              ],
            );
          },
        ),
        if (showUncertainty) ...[
          const SizedBox(height: AppSpacing.xs),
          const _NoticeRow(
            icon: Icons.info_outline,
            text: 'Uncertain areas are candidates for future field validation.',
          ),
        ],
      ],
    );
  }
}

class _AiPreviewLegendItem extends StatelessWidget {
  const _AiPreviewLegendItem({
    required this.color,
    required this.label,
    required this.maxWidth,
  });

  final Color color;
  final String label;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _LegendSwatch(color: color),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AiPreviewControlPanel extends StatelessWidget {
  const _AiPreviewControlPanel({
    required this.title,
    required this.layers,
    required this.loadSummary,
    required this.showClassification,
    required this.showConfidence,
    required this.showUncertainty,
    required this.expanded,
    required this.loading,
    required this.errors,
    required this.hasStatisticsLayer,
    required this.onExpandedChanged,
    required this.onClassificationChanged,
    required this.onConfidenceChanged,
    required this.onUncertaintyChanged,
  });

  final String title;
  final List<AiOutputLayer> layers;
  final _AiPreviewLoadSummary? loadSummary;
  final bool showClassification;
  final bool showConfidence;
  final bool showUncertainty;
  final bool expanded;
  final bool loading;
  final List<String> errors;
  final bool hasStatisticsLayer;
  final ValueChanged<bool> onExpandedChanged;
  final ValueChanged<bool> onClassificationChanged;
  final ValueChanged<bool> onConfidenceChanged;
  final ValueChanged<bool> onUncertaintyChanged;

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
                                      label:
                                          'Total AI features: ${loadSummary!.totalFeatureCount}',
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
                      showConfidence: showConfidence,
                      showUncertainty: showUncertainty,
                      onClassificationChanged: onClassificationChanged,
                      onConfidenceChanged: onConfidenceChanged,
                      onUncertaintyChanged: onUncertaintyChanged,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    _AiPreviewLegend(
                      showClassification: showClassification,
                      showConfidence: showConfidence,
                      showUncertainty: showUncertainty,
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
                    if (hasStatisticsLayer) ...[
                      const SizedBox(height: AppSpacing.xs),
                      const _NoticeRow(
                        icon: Icons.query_stats_outlined,
                        text: 'Statistics are summarized in Run Details.',
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
    required this.showConfidence,
    required this.showUncertainty,
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
  final bool showConfidence;
  final bool showUncertainty;
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
    return (item.layer.layerType == 'classification' && showClassification) ||
        (item.layer.layerType == 'confidence' && showConfidence) ||
        (item.layer.layerType == 'uncertainty' && showUncertainty);
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
    final source = _aiFeatureText(feature, const ['source']);
    final area = _aiFeatureText(feature, const ['area_ha', 'area']);
    final layerLabel = _friendlyLayerTypeLabel(previewFeature.layer.layerType);
    final title = isAggregate
        ? 'AI overview group'
        : className == null
        ? 'AI prediction'
        : _friendlyClassLabel(className);
    final rows = <MapEntry<String, String>>[
      if (isAggregate)
        MapEntry(
          'Group size',
          '${_aggregateAiFeatureCount(feature) ?? 1} AI features',
        ),
      if (className != null)
        MapEntry(
          isAggregate ? 'Dominant class' : 'Predicted class',
          _friendlyClassLabel(className),
        ),
      if (confidence != null)
        MapEntry('Confidence', _formatConfidence(confidence)),
      if (model != null) MapEntry('Model', _friendlyModelLabel(model)),
      MapEntry('Layer', layerLabel),
      MapEntry(
        'Run id',
        _safeText(_aiFeatureText(feature, const ['run_id']) ?? run.id),
      ),
      if (source != null) MapEntry('Source', _safeText(source)),
      if (area != null) MapEntry('Area', _safeText(area)),
    ];
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
              StatusChip(status: 'ready_for_review'),
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
          Wrap(
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
          const SizedBox(height: AppSpacing.md),
          _KeyValueList(title: 'Details', rows: rows),
          const SizedBox(height: AppSpacing.sm),
          const _NoticeRow(
            icon: Icons.info_outline,
            text: 'Regional proof-of-concept. Not a national model.',
          ),
        ],
      ),
    );
  }
}

class _AiFeatureListSheet extends ConsumerStatefulWidget {
  const _AiFeatureListSheet({
    required this.layer,
    required this.onFeatureSelected,
  });

  final AiOutputLayer layer;
  final ValueChanged<_AiPreviewFeature> onFeatureSelected;

  @override
  ConsumerState<_AiFeatureListSheet> createState() =>
      _AiFeatureListSheetState();
}

class _AiFeatureListSheetState extends ConsumerState<_AiFeatureListSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String? _selectedClass;

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
                    if (classes.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.sm),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            ChoiceChip(
                              label: const Text('All'),
                              selected: _selectedClass == null,
                              onSelected: (_) {
                                setState(() => _selectedClass = null);
                              },
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            for (final className in classes) ...[
                              ChoiceChip(
                                label: Text(_friendlyClassLabel(className)),
                                selected: _selectedClass == className,
                                onSelected: (_) {
                                  setState(() => _selectedClass = className);
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
        ? '$layerLabel artifact'
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
    case 'confidence':
      final confidence = _aiFeatureConfidence(item.feature);
      final alpha = confidence == null
          ? 0.22
          : (0.12 + confidence.clamp(0, 1).toDouble() * 0.32);
      return _AiFeatureStyle(
        fillColor: const Color(0xFF0288D1).withValues(alpha: alpha),
        borderColor: const Color(0xFF01579B),
        borderWidth: 2,
      );
    case 'uncertainty':
      return _AiFeatureStyle(
        fillColor: const Color(0xFFE65100).withValues(alpha: 0.24),
        borderColor: const Color(0xFFBF360C),
        borderWidth: 2.4,
      );
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
                    'Review decisions prepare AI results for a separate publishing step. They do not publish map layers by themselves.',
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
          'Approve accepts the result for publishing review. Reject or request more data require a reason. Keep draft leaves it internal for now.',
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
                    'Accept this AI result for the separate publish step. Viewers will not see it from this decision alone.',
                child: SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: onApprove,
                    child: _buttonLabel(
                      action: 'approve_for_publication',
                      label: 'Approve',
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
                        label: 'Request data',
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
                      label: 'Request data',
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
    MapEntry(
      layer.layerType == 'statistics' ? 'Usage' : 'Viewer visibility',
      _layerVisibilityText(layer),
    ),
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
  if (layer.layerType == 'statistics') {
    return 'Review/report summary only';
  }
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
      'Execution mode',
      _friendlyExecutionModeLabel(_executionMode(run)),
    ),
    MapEntry('Label field', run.labelField ?? 'Not set'),
    MapEntry('Created', _formatDate(run.createdAt)),
    MapEntry('AI area', _friendlyScopeLabel(run.scopeType)),
    MapEntry('Duration', _runDuration(run)),
  ];
  if (run.regionPreset?.trim().isNotEmpty ?? false) {
    rows.add(MapEntry('Region', run.regionPreset!));
  }
  return rows.map((row) => MapEntry(row.key, _safeText(row.value))).toList();
}

const String _notRecordedForRun = 'Not recorded for this run';

Map<String, dynamic> _runSettingsSnapshot(AiRun run) =>
    _mapValue(run.metadata['ai_settings']);

Map<String, dynamic> _pipelineSupportSnapshot(AiRun run) =>
    _mapValue(run.metadata['pipeline_execution_support']);

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

String _runSupportState(
  AiRun run,
  String setting, {
  String fallback = 'Saved for run',
}) {
  final support = _pipelineSupportSnapshot(run);
  final effective = _stringList(support['effective_pipeline_settings']);
  final pending = _stringList(support['pending_pipeline_settings']);
  if (effective.contains(setting)) {
    return 'Effective now';
  }
  if (pending.contains(setting)) {
    return 'Pipeline support pending';
  }
  if (support.isEmpty) {
    return _notRecordedForRun;
  }
  return fallback;
}

List<MapEntry<String, String>> _runImageryRows(AiRun run) {
  final settings = _runSettingsSnapshot(run);
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

List<MapEntry<String, String>> _runTrainingSampleRows(AiRun run) {
  final areaType = _runAreaTypeValue(run, 'training_samples_area_type');
  final classRows = _countRows(run.metadata['class_counts']);
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
          classRows.isEmpty
              ? _notRecordedForRun
              : classRows.map((row) => row.key).join(', '),
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
        MapEntry('Pipeline use', _runSupportState(run, 'prediction_area_type')),
        if (customSummary.isNotEmpty)
          MapEntry(
            'Custom AI area',
            customSummary['saved_for_run'] == true
                ? 'Saved for run'
                : 'Recorded for run',
          ),
        if (isNational || nationalEligibility.isNotEmpty)
          MapEntry(
            'National Lebanon',
            nationalEligibility['eligible'] == true
                ? 'Eligible'
                : 'Locked / requirements unmet',
          ),
      ]
      .map((row) => MapEntry(row.key, _safeText(row.value)))
      .toList(growable: false);
}

List<MapEntry<String, String>> _runExtractedFeatureRows(AiRun run) {
  final settings = _runSettingsSnapshot(run);
  final featureInputs = _stringList(settings['feature_inputs']);
  return <MapEntry<String, String>>[
        MapEntry(
          'Selected features',
          featureInputs.isEmpty
              ? _notRecordedForRun
              : '${featureInputs.length} selected: ${featureInputs.join(', ')}',
        ),
        MapEntry('Pipeline use', _runSupportState(run, 'feature_inputs')),
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

List<MapEntry<String, String>> _runExecutionSupportRows(AiRun run) {
  final support = _pipelineSupportSnapshot(run);
  final pending = _stringList(support['pending_pipeline_settings']);
  final effective = _stringList(support['effective_pipeline_settings']);
  return <MapEntry<String, String>>[
        MapEntry(
          'Settings',
          support['settings_saved_for_run'] == true
              ? 'Saved for run'
              : _notRecordedForRun,
        ),
        MapEntry(
          'Training samples area',
          effective.contains('training_samples_area_type') ||
                  effective.contains('scope_type')
              ? 'Effective now'
              : _runSupportState(run, 'training_samples_area_type'),
        ),
        MapEntry(
          'Prediction area',
          pending.contains('prediction_area_type') ||
                  pending.contains('scope_type')
              ? 'Pipeline support pending'
              : _runSupportState(run, 'prediction_area_type'),
        ),
        if (pending.isNotEmpty)
          MapEntry(
            'Pipeline support pending',
            pending.map(_friendlyPendingPipelineSetting).join(', '),
          ),
        if (effective.isNotEmpty)
          MapEntry(
            'Effective now',
            effective.map(_friendlyPendingPipelineSetting).join(', '),
          ),
        if (_mapValue(run.metadata['national_scope_eligibility']).isNotEmpty)
          MapEntry('National Lebanon', 'Locked / requirements unmet'),
      ]
      .map((row) => MapEntry(row.key, _safeText(row.value)))
      .toList(growable: false);
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
    case 'project_area':
      return 'Project area';
    case 'custom_polygon':
    case 'custom_ai_area':
      return 'Custom AI area';
    case 'national':
    case 'national_lebanon':
      return 'National Lebanon - locked';
    case '':
      return _notRecordedForRun;
    default:
      return _titleCase(scope.replaceAll('_', ' '));
  }
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

String _friendlyPendingPipelineSetting(String value) {
  switch (value) {
    case 'satellite_source':
      return 'satellite';
    case 'date_range':
      return 'date range';
    case 'feature_inputs':
      return 'selected features';
    case 'custom_area':
      return 'custom AI area';
    case 'training_samples_area_type':
      return 'training samples area';
    case 'prediction_area_type':
      return 'prediction area';
    case 'project_bounds':
      return 'project bounds';
    case 'label_field':
      return 'label field';
    case 'execution_mode':
      return 'execution mode';
    case 'scope_type':
      return 'AI area';
    default:
      return value.replaceAll('_', ' ');
  }
}

String _friendlyModelOrMissing(String? model) =>
    model == null ? _notRecordedForRun : _friendlyModelLabel(model);

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
      return 'AI run prepared. No worker processing has started.';
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
