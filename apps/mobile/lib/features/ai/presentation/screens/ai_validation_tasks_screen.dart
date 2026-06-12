import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../auth/domain/auth_models.dart';
import '../../domain/ai_models.dart';
import '../ai_providers.dart';
import '../widgets/ai_validation_widgets.dart';

class AiValidationTasksScreen extends ConsumerStatefulWidget {
  const AiValidationTasksScreen({super.key});

  @override
  ConsumerState<AiValidationTasksScreen> createState() =>
      _AiValidationTasksScreenState();
}

class _AiValidationTasksScreenState
    extends ConsumerState<AiValidationTasksScreen> {
  String? _statusFilter;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authControllerProvider).session;
    final user = session?.user;
    if (user == null || user.role != UserRole.contributor) {
      return const AppEmptyState(
        icon: Icons.lock_outline,
        title: 'AI validation restricted',
        message: 'Only project contributors can open AI validation tasks.',
      );
    }

    final query = AiPredictionValidationTasksQuery(status: _statusFilter);
    final tasksAsync = ref.watch(myAiValidationTasksProvider(query));

    return ListView(
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      children: [
        const SectionHeader(title: 'AI Validation'),
        const SizedBox(height: AppSpacing.sm),
        const Text(
          'Review available project AI prediction validation tasks before they become trusted training evidence.',
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('All'),
              selected: _statusFilter == null,
              onSelected: (_) => setState(() => _statusFilter = null),
            ),
            for (final status in const <String>[
              'open',
              'assigned',
              'submitted',
              'accepted',
              'rejected',
            ])
              ChoiceChip(
                label: Text(_statusLabel(status)),
                selected: _statusFilter == status,
                onSelected: (_) => setState(() => _statusFilter = status),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        tasksAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => AppEmptyState(
            icon: Icons.error_outline,
            title: 'AI validation unavailable',
            message: userFacingErrorMessage(
              error,
              fallback: 'Unable to load AI validation tasks.',
            ),
            actionLabel: 'Retry',
            onAction: () => ref.invalidate(myAiValidationTasksProvider(query)),
          ),
          data: (result) {
            if (result.tasks.isEmpty) {
              return const AppEmptyState(
                icon: Icons.assignment_turned_in_outlined,
                title: 'No AI validation tasks',
                message:
                    'Available project AI prediction validation tasks will appear here.',
              );
            }
            return Column(
              children: [
                for (final task in result.tasks) ...[
                  AiValidationTaskCard(
                    task: task,
                    showProjectName: true,
                    onViewDetails: () => openAiValidationTaskDetails(
                      context,
                      task,
                      onSubmit: task.canSubmit
                          ? () => _openSubmitDialog(task)
                          : null,
                    ),
                    onOpenMap: () => openAiValidationTaskMap(context, task),
                    onSubmit: task.canSubmit
                        ? () => _openSubmitDialog(task)
                        : null,
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
              ],
            );
          },
        ),
      ],
    );
  }

  Future<void> _openSubmitDialog(AiPredictionValidationTask task) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AiValidationSubmissionDialog(task: task),
    );
  }
}

String _statusLabel(String status) {
  switch (status) {
    case 'in_progress':
      return 'In progress';
    default:
      final words = status.replaceAll('_', ' ').split(RegExp(r'\s+'));
      return words
          .where((word) => word.isNotEmpty)
          .map(
            (word) => word.length == 1
                ? word.toUpperCase()
                : '${word.substring(0, 1).toUpperCase()}${word.substring(1)}',
          )
          .join(' ');
  }
}
