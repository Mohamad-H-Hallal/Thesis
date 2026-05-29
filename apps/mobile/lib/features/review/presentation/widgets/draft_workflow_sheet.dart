import 'package:flutter/material.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/offline/local_models.dart';
import '../../../../core/utils/lebanon_time.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../domain/review_workflow.dart';

Future<void> showDraftWorkflowSheet(
  BuildContext context, {
  required LocalDraftFeature draft,
}) {
  final snapshot = DraftWorkflowCodec.fromDraft(draft);

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.65,
        minChildSize: 0.45,
        maxChildSize: 0.9,
        builder: (context, controller) {
          final bottomInset =
              MediaQuery.viewPaddingOf(context).bottom + AppSpacing.lg;
          return ListView(
            controller: controller,
            padding: EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              bottomInset,
            ),
            children: [
              Text(
                draft.projectName,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              Row(children: [StatusChip(status: snapshot.status)]),
              const SizedBox(height: 14),
              Text(
                'Workflow Timeline',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (snapshot.timeline.isEmpty)
                const Text('No timeline events yet.')
              else
                ...snapshot.timeline.reversed.map(
                  (event) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                event.label,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              Text(
                                _formatDate(event.at),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Actor: ${event.actor}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (event.note != null &&
                              event.note!.trim().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                event.note!,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
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
    },
  );
}

String _formatDate(DateTime dateTime) {
  return formatLebanonDateTime(dateTime);
}
