import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/animated_reveal.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/section_header.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../../review/domain/review_workflow.dart';
import '../widgets/draft_workflow_sheet.dart';

class ReviewQueueScreen extends ConsumerWidget {
  const ReviewQueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queueAsync = ref.watch(reviewQueueDraftsProvider);
    final session = ref.watch(authControllerProvider).session;
    final reviewerName = session?.user.fullName ?? 'Reviewer';

    return queueAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) =>
          Center(child: Text('Failed to load review queue: $error')),
      data: (items) {
        if (items.isEmpty) {
          return ListView(
            children: const [
              SectionHeader(
                title: 'Review Queue',
                subtitle: 'Admin and reviewer moderation workspace',
              ),
              SizedBox(height: 24),
              AppEmptyState(
                icon: Icons.rate_review_outlined,
                title: 'No items in queue',
                message:
                    'Submitted features awaiting moderation will appear here.',
              ),
            ],
          );
        }

        return ListView(
          children: [
            SectionHeader(
              title: 'Review Queue',
              subtitle: '${items.length} draft(s) awaiting reviewer action',
            ),
            const SizedBox(height: AppSpacing.md),
            ...List<Widget>.generate(items.length, (index) {
              final draft = items[index];
              final workflow = DraftWorkflowCodec.fromDraft(draft);
              final canStartReview =
                  draft.status == DraftWorkflowStatus.submitted;
              final canDecide =
                  draft.status == DraftWorkflowStatus.submitted ||
                  draft.status == DraftWorkflowStatus.underReview;

              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: AnimatedReveal(
                  delay: Duration(milliseconds: index * 60),
                  child: AppCard(
                    onTap: () => showDraftWorkflowSheet(context, draft: draft),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(draft.projectName),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: AppSpacing.xs),
                            child: Text(
                              '${draft.geometryType} • id ${draft.id.substring(0, 8)}',
                            ),
                          ),
                          trailing: StatusChip(status: draft.status),
                        ),
                        if (workflow.lastReviewNote != null &&
                            workflow.lastReviewNote!.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              'Latest note: ${workflow.lastReviewNote}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () =>
                                  showDraftWorkflowSheet(context, draft: draft),
                              icon: const Icon(Icons.timeline, size: 18),
                              label: const Text('Timeline'),
                            ),
                            if (canStartReview)
                              FilledButton.tonalIcon(
                                onPressed: () async {
                                  await _runAction(
                                    context,
                                    ref,
                                    action: () => ref
                                        .read(reviewWorkflowServiceProvider)
                                        .startReview(
                                          draftId: draft.id,
                                          reviewerName: reviewerName,
                                        ),
                                    success: 'Draft moved to under review.',
                                  );
                                },
                                icon: const Icon(Icons.play_arrow, size: 18),
                                label: const Text('Start Review'),
                              ),
                            if (canDecide)
                              FilledButton.icon(
                                onPressed: () async {
                                  final note = await _promptNote(
                                    context,
                                    title: 'Approval Note',
                                    hint:
                                        'Optional note for approval timeline.',
                                  );
                                  if (note == null) {
                                    return;
                                  }
                                  if (!context.mounted) {
                                    return;
                                  }
                                  await _runAction(
                                    context,
                                    ref,
                                    action: () => ref
                                        .read(reviewWorkflowServiceProvider)
                                        .approveDraft(
                                          draftId: draft.id,
                                          reviewerName: reviewerName,
                                          note: note,
                                        ),
                                    success: 'Draft approved.',
                                  );
                                },
                                icon: const Icon(Icons.check_circle, size: 18),
                                label: const Text('Approve'),
                              ),
                            if (canDecide)
                              FilledButton.tonalIcon(
                                onPressed: () async {
                                  final note = await _promptNote(
                                    context,
                                    title: 'Rejection Note',
                                    hint: 'Required reason for rejection.',
                                    requiredNote: true,
                                  );
                                  if (note == null) {
                                    return;
                                  }
                                  if (!context.mounted) {
                                    return;
                                  }
                                  await _runAction(
                                    context,
                                    ref,
                                    action: () => ref
                                        .read(reviewWorkflowServiceProvider)
                                        .rejectDraft(
                                          draftId: draft.id,
                                          reviewerName: reviewerName,
                                          note: note,
                                        ),
                                    success: 'Draft rejected and returned.',
                                  );
                                },
                                icon: const Icon(Icons.cancel, size: 18),
                                label: const Text('Reject'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}

Future<void> _runAction(
  BuildContext context,
  WidgetRef ref, {
  required Future<void> Function() action,
  required String success,
}) async {
  try {
    await action();
    ref.invalidate(localDraftFeaturesProvider);
    ref.invalidate(draftsProvider);
    ref.invalidate(reviewQueueDraftsProvider);
    if (context.mounted) {
      AppSnackbar.showSuccess(context, success);
    }
  } catch (error) {
    if (context.mounted) {
      AppSnackbar.showError(context, error.toString());
    }
  }
}

Future<String?> _promptNote(
  BuildContext context, {
  required String title,
  required String hint,
  bool requiredNote = false,
}) async {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (requiredNote && value.isEmpty) {
                return;
              }
              Navigator.of(context).pop(value);
            },
            child: const Text('Save'),
          ),
        ],
      );
    },
  );
}
