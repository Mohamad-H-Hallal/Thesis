import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_action_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../auth/domain/auth_models.dart';
import '../../domain/ai_models.dart';
import '../ai_providers.dart';
import '../widgets/ai_uncertainty_task_widgets.dart';

class AiValidationTasksScreen extends ConsumerStatefulWidget {
  const AiValidationTasksScreen({super.key});

  @override
  ConsumerState<AiValidationTasksScreen> createState() =>
      _AiValidationTasksScreenState();
}

class _AiValidationTasksScreenState
    extends ConsumerState<AiValidationTasksScreen> {
  String? _selectedStatus;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authControllerProvider).session;
    if (session?.user.role != UserRole.contributor) {
      return const AppEmptyState(
        icon: Icons.lock_outline,
        title: 'AI validation unavailable',
        message: 'Assigned AI validation tasks are available to contributors.',
      );
    }

    final query = AiUncertaintyTasksQuery(status: _selectedStatus);
    final tasksAsync = ref.watch(myAiValidationTasksProvider(query));

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(myAiValidationTasksProvider(query));
        await ref.read(myAiValidationTasksProvider(query).future);
      },
      child: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          const SectionHeader(
            title: 'AI Validation Tasks',
            subtitle:
                'Validate assigned uncertainty areas through normal feature submission and review.',
          ),
          const SizedBox(height: AppSpacing.md),
          const AppCard(child: AiUncertaintyTaskWarning()),
          const SizedBox(height: AppSpacing.md),
          AppCard(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('All'),
                  selected: _selectedStatus == null,
                  onSelected: (_) => setState(() => _selectedStatus = null),
                ),
                for (final status in const [
                  'assigned',
                  'in_progress',
                  'in_review',
                  'validated',
                  'rejected',
                ])
                  ChoiceChip(
                    label: Text(aiUncertaintyStatusLabel(status)),
                    selected: _selectedStatus == status,
                    onSelected: (_) => setState(() => _selectedStatus = status),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          tasksAsync.when(
            loading: () => const AppCard(
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => AppEmptyState(
              icon: Icons.error_outline,
              title: 'AI validation tasks unavailable',
              message: userFacingErrorMessage(
                error,
                fallback: 'Unable to load assigned AI validation tasks.',
              ),
              actionLabel: 'Retry',
              onAction: () =>
                  ref.invalidate(myAiValidationTasksProvider(query)),
            ),
            data: (page) {
              if (page.items.isEmpty) {
                return const AppEmptyState(
                  icon: Icons.assignment_turned_in_outlined,
                  title: 'No assigned AI validation tasks',
                  message:
                      'Tasks assigned by an admin will appear here for field validation.',
                );
              }

              return Column(
                children: [
                  for (final task in page.items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.md),
                      child: _ContributorAiValidationTaskCard(
                        task: task,
                        onOpenMap: () => context.push(
                          AppRoutes.mapForAiValidationTask(
                            task.projectId,
                            task.id,
                          ),
                        ),
                        onSubmit: _canSubmit(task)
                            ? () => showAiUncertaintySubmitDialog(
                                context,
                                task: task,
                                onSubmitted: () => ref.invalidate(
                                  myAiValidationTasksProvider(query),
                                ),
                              )
                            : null,
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

  bool _canSubmit(AiUncertaintyArea task) {
    return task.status == 'assigned' || task.status == 'in_progress';
  }
}

class _ContributorAiValidationTaskCard extends StatelessWidget {
  const _ContributorAiValidationTaskCard({
    required this.task,
    required this.onOpenMap,
    this.onSubmit,
  });

  final AiUncertaintyArea task;
  final VoidCallback onOpenMap;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    final projectName = task.projectName?.trim();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.fact_check_outlined),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      aiUncertaintyClassLabel(task),
                      style: Theme.of(context).textTheme.titleMedium,
                      softWrap: true,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      projectName == null || projectName.isEmpty
                          ? 'Task ${aiUncertaintyCompactId(task.id)}'
                          : '$projectName - task ${aiUncertaintyCompactId(task.id)}',
                      style: Theme.of(context).textTheme.bodySmall,
                      softWrap: true,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          AiUncertaintyMetricPills(task: task),
          const SizedBox(height: AppSpacing.sm),
          const AiUncertaintyTaskWarning(),
          if (task.validatedFeatureId?.trim().isNotEmpty ?? false) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Linked feature: ${task.validatedFeatureId}',
              style: Theme.of(context).textTheme.bodySmall,
              softWrap: true,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          AppActionButtons(
            maxColumns: 2,
            fillRows: true,
            children: [
              OutlinedButton.icon(
                onPressed: onOpenMap,
                icon: const Icon(Icons.map_outlined),
                label: const Text('Open on map'),
              ),
              FilledButton.icon(
                onPressed: onSubmit,
                icon: const Icon(Icons.link_outlined),
                label: const Text('Submit/link validation'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
