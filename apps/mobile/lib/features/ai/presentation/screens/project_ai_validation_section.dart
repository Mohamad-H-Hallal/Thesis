import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../projects/domain/project.dart';
import '../../domain/ai_models.dart';
import '../ai_providers.dart';
import '../widgets/ai_validation_widgets.dart';

class ProjectAiValidationSection extends ConsumerStatefulWidget {
  const ProjectAiValidationSection({required this.project, super.key});

  final ProjectSummary project;

  @override
  ConsumerState<ProjectAiValidationSection> createState() =>
      _ProjectAiValidationSectionState();
}

class _ProjectAiValidationSectionState
    extends ConsumerState<ProjectAiValidationSection> {
  String? _statusFilter;
  bool _generating = false;

  @override
  Widget build(BuildContext context) {
    final query = AiPredictionValidationTasksQuery(
      projectId: widget.project.id,
      status: _statusFilter,
    );
    final tasksAsync = ref.watch(projectAiValidationTasksProvider(query));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(title: 'AI Prediction Validation'),
              const SizedBox(height: AppSpacing.sm),
              const Text(
                'Create and review field validation tasks for all AI prediction features. Confidence is shown as metadata, not a validation filter.',
              ),
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: _generating ? null : _generateTasks,
                  icon: _generating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.playlist_add_check_outlined),
                  label: Text(
                    _generating
                        ? 'Generating tasks...'
                        : 'Generate validation tasks',
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Accepted validations can become AI-approved project map features for future training.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        tasksAsync.when(
          loading: () =>
              const AppCard(child: Center(child: CircularProgressIndicator())),
          error: (error, _) => AppEmptyState(
            icon: Icons.error_outline,
            title: 'Validation tasks unavailable',
            message: userFacingErrorMessage(
              error,
              fallback: 'Unable to load AI validation tasks right now.',
            ),
            actionLabel: 'Retry',
            onAction: () =>
                ref.invalidate(projectAiValidationTasksProvider(query)),
          ),
          data: (tasks) => _ProjectAiValidationTasksView(
            tasks: tasks,
            statusFilter: _statusFilter,
            onStatusFilterChanged: (status) {
              setState(() => _statusFilter = status);
            },
          ),
        ),
      ],
    );
  }

  Future<void> _generateTasks() async {
    setState(() => _generating = true);
    try {
      final result = await ref
          .read(aiRepositoryProvider)
          .generateValidationTasks(projectId: widget.project.id);
      bumpRealtimeScope(ref, RealtimeScope('ai', widget.project.id));
      ref.invalidate(
        projectAiValidationTasksProvider(
          AiPredictionValidationTasksQuery(projectId: widget.project.id),
        ),
      );
      if (!mounted) {
        return;
      }
      AppSnackbar.showSuccess(
        context,
        'Created ${result.createdCount} validation tasks; skipped ${result.existingActiveCount} existing tasks.',
      );
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to generate validation tasks.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _generating = false);
      }
    }
  }
}

class _ProjectAiValidationTasksView extends StatelessWidget {
  const _ProjectAiValidationTasksView({
    required this.tasks,
    required this.statusFilter,
    required this.onStatusFilterChanged,
  });

  final AiPredictionValidationTaskList tasks;
  final String? statusFilter;
  final ValueChanged<String?> onStatusFilterChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Validation counts',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.sm),
              AiValidationStatusCounts(counts: tasks.statusCounts),
              const SizedBox(height: AppSpacing.md),
              _StatusFilterChips(
                selectedStatus: statusFilter,
                onChanged: onStatusFilterChanged,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (tasks.tasks.isEmpty)
          const AppEmptyState(
            icon: Icons.rule_folder_outlined,
            title: 'No validation tasks',
            message:
                'Generate validation tasks or change the current status filter.',
          )
        else
          for (final task in tasks.tasks) ...[
            AiValidationTaskCard(
              task: task,
              onViewDetails: () => openAiValidationTaskDetails(
                context,
                task,
                onAccept: task.canReview
                    ? () => showDialog<void>(
                        context: context,
                        builder: (_) => AiValidationReviewDialog(
                          task: task,
                          decision: 'accepted',
                        ),
                      )
                    : null,
                onReject: task.canReview
                    ? () => showDialog<void>(
                        context: context,
                        builder: (_) => AiValidationReviewDialog(
                          task: task,
                          decision: 'rejected',
                        ),
                      )
                    : null,
              ),
              onOpenMap: () => openAiValidationTaskMap(context, task),
              onAssign: _assignable(task)
                  ? () => showDialog<void>(
                      context: context,
                      builder: (_) => AiValidationAssignDialog(task: task),
                    )
                  : null,
              onAccept: task.canReview
                  ? () => showDialog<void>(
                      context: context,
                      builder: (_) => AiValidationReviewDialog(
                        task: task,
                        decision: 'accepted',
                      ),
                    )
                  : null,
              onReject: task.canReview
                  ? () => showDialog<void>(
                      context: context,
                      builder: (_) => AiValidationReviewDialog(
                        task: task,
                        decision: 'rejected',
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
      ],
    );
  }

  bool _assignable(AiPredictionValidationTask task) {
    return const {'open', 'assigned', 'in_progress'}.contains(task.status);
  }
}

class _StatusFilterChips extends StatelessWidget {
  const _StatusFilterChips({
    required this.selectedStatus,
    required this.onChanged,
  });

  final String? selectedStatus;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          ChoiceChip(
            label: const Text('All'),
            selected: selectedStatus == null,
            onSelected: (_) => onChanged(null),
          ),
          const SizedBox(width: AppSpacing.xs),
          for (final status in aiPredictionValidationTaskStatuses) ...[
            ChoiceChip(
              label: Text(_statusLabel(status)),
              selected: selectedStatus == status,
              onSelected: (_) => onChanged(status),
            ),
            const SizedBox(width: AppSpacing.xs),
          ],
        ],
      ),
    );
  }

  String _statusLabel(String status) {
    return status
        .split('_')
        .map(
          (part) => part.isEmpty
              ? part
              : '${part[0].toUpperCase()}${part.substring(1)}',
        )
        .join(' ');
  }
}
