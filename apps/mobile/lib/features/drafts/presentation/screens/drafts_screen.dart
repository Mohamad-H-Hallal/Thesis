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
import '../../../auth/domain/auth_models.dart';
import '../../../review/domain/review_workflow.dart';
import '../../../review/presentation/widgets/draft_workflow_sheet.dart';

class DraftsScreen extends ConsumerWidget {
  const DraftsScreen({required this.showSubmittedOnly, super.key});

  final bool showSubmittedOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draftsAsync = ref.watch(localDraftFeaturesProvider);
    final authSession = ref.watch(authControllerProvider).session;

    return draftsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(child: Text('Failed to load drafts: $error')),
      data: (items) {
        final visible = items
            .where((item) {
              return showSubmittedOnly
                  ? DraftWorkflowStatus.isSubmissionTrack(item.status)
                  : DraftWorkflowStatus.isDraftTrack(item.status);
            })
            .toList(growable: false);

        if (visible.isEmpty) {
          return AppEmptyState(
            icon: showSubmittedOnly
                ? Icons.upload_file_outlined
                : Icons.inbox_outlined,
            title: showSubmittedOnly ? 'No submissions yet' : 'No drafts yet',
            message: showSubmittedOnly
                ? 'Submitted features will appear here after sending for review.'
                : 'Create your first feature draft from the map workspace.',
          );
        }

        return ListView(
          children: [
            SectionHeader(
              title: showSubmittedOnly ? 'My Submissions' : 'My Drafts',
              subtitle: showSubmittedOnly
                  ? 'Track submitted features through admin review decisions.'
                  : 'Continue editing drafts and submit them for review.',
            ),
            const SizedBox(height: AppSpacing.md),
            ...List<Widget>.generate(visible.length, (index) {
              final draft = visible[index];
              final workflow = DraftWorkflowCodec.fromDraft(draft);
              final reviewNote = workflow.lastReviewNote;
              final canSubmit =
                  !showSubmittedOnly &&
                  authSession?.user.role == UserRole.contributor &&
                  (draft.status == DraftWorkflowStatus.draft ||
                      draft.status == DraftWorkflowStatus.rejected);

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
                              '${draft.geometryType} - updated ${draft.toDraftItem().lastEdited}',
                            ),
                          ),
                          trailing: StatusChip(status: draft.status),
                        ),
                        if (reviewNote != null &&
                            reviewNote.trim().isNotEmpty &&
                            draft.status == DraftWorkflowStatus.rejected)
                          Padding(
                            padding: const EdgeInsets.only(
                              top: 2,
                              bottom: AppSpacing.xs,
                            ),
                            child: Text(
                              'Admin review note: $reviewNote',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        Row(
                          children: [
                            TextButton.icon(
                              onPressed: () =>
                                  showDraftWorkflowSheet(context, draft: draft),
                              icon: const Icon(Icons.timeline, size: 18),
                              label: const Text('Timeline'),
                            ),
                            const Spacer(),
                            if (canSubmit)
                              FilledButton.icon(
                                onPressed: () async {
                                  final userName =
                                      authSession?.user.fullName ??
                                      'Contributor';
                                  try {
                                    await ref
                                        .read(reviewWorkflowServiceProvider)
                                        .submitDraft(
                                          draftId: draft.id,
                                          actorName: userName,
                                        );
                                    ref.invalidate(localDraftFeaturesProvider);
                                    ref.invalidate(draftsProvider);
                                    ref.invalidate(reviewQueueDraftsProvider);
                                    if (context.mounted) {
                                      AppSnackbar.showSuccess(
                                        context,
                                        'Draft submitted to review queue.',
                                      );
                                    }
                                  } catch (error) {
                                    if (context.mounted) {
                                      AppSnackbar.showError(
                                        context,
                                        error.toString(),
                                      );
                                    }
                                  }
                                },
                                icon: const Icon(Icons.upload_file, size: 18),
                                label: const Text('Submit'),
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
