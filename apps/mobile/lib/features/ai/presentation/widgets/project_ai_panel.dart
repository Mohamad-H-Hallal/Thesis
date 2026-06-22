import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/utils/lebanon_time.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../domain/ai_models.dart';
import '../ai_providers.dart';
import '../../../projects/domain/project.dart';

class ProjectAiPanel extends ConsumerWidget {
  const ProjectAiPanel({required this.project, super.key});

  final ProjectSummary project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(aiSettingsProvider(project.id));
    final settings = settingsAsync.asData?.value;
    final error = settingsAsync.asError?.error;
    final runsAsync = ref.watch(aiProjectRunsProvider(project.id));
    final publishedLayersAsync = ref.watch(
      publishedAiLayersProvider(project.id),
    );
    final readinessAsync = settings == null
        ? null
        : ref.watch(
            aiReadinessProvider(
              AiReadinessQuery(
                projectId: project.id,
                labelField: settings.labelField,
                minSamplesPerClass: settings.minSamplesPerClass,
                scopeType: settings.scopeType,
              ),
            ),
          );
    final readiness = readinessAsync?.asData?.value;
    final runs = runsAsync.asData?.value ?? const <AiRun>[];
    final activeRun = _activeRunFrom(runs);
    final runsError = runsAsync.asError?.error;
    final isCheckingRuns = runsAsync.isLoading && runs.isEmpty;
    final publishedLayer = _firstClassificationLayer(
      publishedLayersAsync.asData?.value ?? const <AiOutputLayer>[],
    );
    final publishedRunId = publishedLayer?.aiRunId?.trim() ?? '';
    final showPublishedRunAction = publishedRunId.isNotEmpty;
    final aiServerText = readiness == null
        ? 'AI server not checked'
        : readiness.aiServer.isConnected
        ? 'AI server connected'
        : readiness.aiServer.configured
        ? 'AI server unavailable'
        : 'AI server URL missing';
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Icon(
                    Icons.psychology_outlined,
                    size: 18,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AI',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      settings?.isEnabled == true
                          ? 'AI is enabled for this project.'
                          : 'AI is not enabled for this project.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (settings != null)
                StatusChip(status: settings.isEnabled ? 'active' : 'draft'),
            ],
          ),
          if (settings != null) ...[
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  label: Text(
                    settings.labelField?.isNotEmpty == true
                        ? 'Label ${settings.labelField}'
                        : 'No label field',
                  ),
                ),
                Chip(
                  label: Text('AI area ${_formatValue(settings.scopeType)}'),
                ),
                Chip(label: Text('Min ${settings.minSamplesPerClass}/class')),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            _InlineNotice(
              icon: readiness?.aiServer.isConnected == true
                  ? Icons.cloud_done_outlined
                  : Icons.cloud_off_outlined,
              text: aiServerText,
            ),
            const SizedBox(height: AppSpacing.sm),
            if (publishedLayer == null)
              const _InlineNotice(
                icon: Icons.layers_clear_outlined,
                text:
                    'No AI layer is published yet. Start an AI run and publish its result when it is ready.',
              )
            else
              _AiPanelRows(
                title: 'Published AI layer',
                rows: [
                  MapEntry('Layer', 'Current project AI classification result'),
                  if (publishedRunId.isNotEmpty)
                    MapEntry('Run', _runTitleFromId(publishedRunId)),
                  if (publishedLayer.publishedAt != null)
                    MapEntry(
                      'Published',
                      formatLebanonDate(publishedLayer.publishedAt),
                    ),
                  MapEntry(
                    'Predictions',
                    '${publishedLayer.predictionCount > 0 ? publishedLayer.predictionCount : publishedLayer.runPredictionCount}',
                  ),
                ],
              ),
            if (activeRun != null) ...[
              const SizedBox(height: AppSpacing.sm),
              _AiPanelRows(
                title: 'Active run',
                rows: [
                  MapEntry('Run', _runTitle(activeRun)),
                  MapEntry('Status', _formatValue(activeRun.status)),
                  if (activeRun.stage?.trim().isNotEmpty == true)
                    MapEntry('Stage', _formatValue(activeRun.stage!)),
                  if (activeRun.progress > 0)
                    MapEntry(
                      'Progress',
                      '${(activeRun.progress * 100).round()}%',
                    ),
                ],
              ),
            ] else if (isCheckingRuns) ...[
              const SizedBox(height: AppSpacing.sm),
              const _InlineNotice(
                icon: Icons.sync_outlined,
                text: 'Checking active AI runs...',
              ),
            ] else if (runsError != null) ...[
              const SizedBox(height: AppSpacing.sm),
              _InlineNotice(
                icon: Icons.error_outline,
                text: userFacingErrorMessage(
                  runsError,
                  fallback: 'Unable to check active AI runs right now.',
                ),
              ),
            ],
          ],
          if (error != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              userFacingErrorMessage(
                error,
                fallback: 'AI settings are unavailable right now.',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          AppButtonRow(
            stackBelowWidth: 680,
            children: [
              AppButton(
                label: 'AI Settings',
                icon: Icons.tune_outlined,
                onPressed: () => context.push(
                  AppRoutes.projectAi(project.id, section: 'settings'),
                ),
              ),
              if (showPublishedRunAction)
                AppButton(
                  label: 'Open Published Run',
                  icon: Icons.manage_search_outlined,
                  variant: AppButtonVariant.outlined,
                  onPressed: () => context.push(
                    AppRoutes.projectAi(
                      project.id,
                      section: 'runs',
                      runId: publishedRunId,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: AppSpacing.xs),
        Expanded(child: Text(text, softWrap: true)),
      ],
    );
  }
}

class _AiPanelRows extends StatelessWidget {
  const _AiPanelRows({required this.title, required this.rows});

  final String title;
  final List<MapEntry<String, String>> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text('${row.key}: ${row.value}'),
          ),
      ],
    );
  }
}

String _formatValue(String value) => value.replaceAll('_', ' ');

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

String _runTitle(AiRun run) =>
    'Run ${run.id.length <= 8 ? run.id : run.id.substring(0, 8)}';

String _runTitleFromId(String runId) =>
    'Run ${runId.length <= 8 ? runId : runId.substring(0, 8)}';
