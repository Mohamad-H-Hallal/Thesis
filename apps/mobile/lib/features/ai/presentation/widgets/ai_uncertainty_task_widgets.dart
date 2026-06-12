import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_dialog_actions.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../domain/ai_models.dart';
import '../ai_providers.dart';

String aiUncertaintyStatusLabel(String status) {
  switch (status.trim().toLowerCase()) {
    case 'open':
      return 'Open';
    case 'assigned':
      return 'Assigned';
    case 'in_progress':
      return 'In progress';
    case 'in_review':
      return 'In review';
    case 'validated':
      return 'Validated';
    case 'rejected':
      return 'Rejected';
    case 'cancelled':
      return 'Cancelled';
    case 'dismissed':
      return 'Dismissed';
    default:
      return status.trim().replaceAll('_', ' ');
  }
}

String aiUncertaintyClassLabel(AiUncertaintyArea task) {
  final value = task.suggestedClass?.trim();
  if (value == null || value.isEmpty) {
    return 'Unknown class';
  }
  return value
      .split(RegExp(r'\s+|_+'))
      .where((word) => word.isNotEmpty)
      .map((word) {
        if (word.length == 1) {
          return word.toUpperCase();
        }
        return '${word.substring(0, 1).toUpperCase()}${word.substring(1)}';
      })
      .join(' ');
}

String aiUncertaintyPercentLabel(double? value) {
  if (value == null || !value.isFinite) {
    return 'Unknown';
  }
  final normalized = value > 1 ? value / 100 : value;
  return '${(normalized.clamp(0, 1) * 100).round()}%';
}

String aiUncertaintyCompactId(String id) {
  final trimmed = id.trim();
  if (trimmed.length <= 8) {
    return trimmed;
  }
  return trimmed.substring(0, 8);
}

class AiUncertaintyTaskWarning extends StatelessWidget {
  const AiUncertaintyTaskWarning({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.42),
        borderRadius: AppRadii.sm,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: const Padding(
        padding: EdgeInsets.all(AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, size: 20),
            SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                'AI validation task, not official field data. Submit or link a normal feature for review before it can become official.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AiUncertaintyMetricPills extends StatelessWidget {
  const AiUncertaintyMetricPills({
    required this.task,
    this.includeStatus = true,
    super.key,
  });

  final AiUncertaintyArea task;
  final bool includeStatus;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        Chip(
          avatar: const Icon(Icons.category_outlined, size: 18),
          label: Text(aiUncertaintyClassLabel(task)),
        ),
        Chip(
          avatar: const Icon(Icons.report_problem_outlined, size: 18),
          label: Text(
            'Uncertainty ${aiUncertaintyPercentLabel(task.uncertaintyScore)}',
          ),
        ),
        Chip(
          avatar: const Icon(Icons.speed_outlined, size: 18),
          label: Text(
            'Confidence ${aiUncertaintyPercentLabel(task.confidenceScore)}',
          ),
        ),
        if (includeStatus) StatusChip(status: task.status),
      ],
    );
  }
}

Future<void> showAiUncertaintySubmitDialog(
  BuildContext context, {
  required AiUncertaintyArea task,
  VoidCallback? onSubmitted,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) =>
        _AiUncertaintySubmitDialog(task: task, onSubmitted: onSubmitted),
  );
}

class _AiUncertaintySubmitDialog extends ConsumerStatefulWidget {
  const _AiUncertaintySubmitDialog({required this.task, this.onSubmitted});

  final AiUncertaintyArea task;
  final VoidCallback? onSubmitted;

  @override
  ConsumerState<_AiUncertaintySubmitDialog> createState() =>
      _AiUncertaintySubmitDialogState();
}

class _AiUncertaintySubmitDialogState
    extends ConsumerState<_AiUncertaintySubmitDialog> {
  final _featureIdController = TextEditingController();
  final _notesController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _submitting = false;

  @override
  void dispose() {
    _featureIdController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Submit validation'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AiUncertaintyTaskWarning(),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Link a draft or pending normal feature collected for this task.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                label: 'Validated feature ID',
                controller: _featureIdController,
                textInputAction: TextInputAction.next,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Enter the normal feature ID to link.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              AppTextField(
                label: 'Notes',
                controller: _notesController,
                minLines: 2,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
              ),
            ],
          ),
        ),
      ),
      actions: [
        AppDialogActions(
          cancel: TextButton(
            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          confirm: FilledButton.icon(
            onPressed: _submitting ? null : _submit,
            icon: _submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send_outlined),
            label: Text(_submitting ? 'Submitting...' : 'Submit'),
          ),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() => _submitting = true);
    try {
      await ref
          .read(aiRepositoryProvider)
          .submitUncertaintyValidation(
            id: widget.task.id,
            validatedFeatureId: _featureIdController.text.trim(),
            notes: _notesController.text,
          );
      bumpWorkflowRefresh(ref);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop();
      widget.onSubmitted?.call();
      AppSnackbar.showSuccess(
        context,
        'AI validation linked to normal feature review.',
      );
    } catch (error) {
      if (mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to submit this AI validation task right now.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }
}
