import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/status_chip.dart';
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
                      'Configure AI settings and prepared runs.',
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
          const _InlineNotice(
            icon: Icons.info_outline,
            text:
                'Worker execution is controlled from backend commands; this panel does not start AI.',
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: () => context.push(
              AppRoutes.projectAi(project.id, section: 'readiness'),
            ),
            icon: const Icon(Icons.tune_outlined),
            label: const Text('AI settings'),
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

String _formatValue(String value) => value.replaceAll('_', ' ');
