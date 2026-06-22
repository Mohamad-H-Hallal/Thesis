import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/config/app_env.dart';
import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/utils/lebanon_time.dart';
import '../../../../core/widgets/app_action_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/status_chip.dart';
import '../../../projects/domain/project.dart';
import '../../domain/ai_models.dart';
import '../../domain/ai_repository.dart';
import '../ai_model_labels.dart';
import '../ai_providers.dart';

class AiValidationStatusCounts extends StatelessWidget {
  const AiValidationStatusCounts({required this.counts, super.key});

  final Map<String, int> counts;

  @override
  Widget build(BuildContext context) {
    final statuses = const <String>[
      'open',
      'submitted',
      'accepted',
      'rejected',
      'cancelled',
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final status in statuses)
          Chip(
            avatar: Icon(_taskStatusIcon(status), size: 18),
            label: Text('${_taskStatusLabel(status)} ${counts[status] ?? 0}'),
          ),
      ],
    );
  }
}

class AiValidationTaskCard extends ConsumerWidget {
  const AiValidationTaskCard({
    required this.task,
    this.showProjectName = false,
    this.onViewDetails,
    this.onOpenMap,
    this.onSubmit,
    this.onAssign,
    this.onAccept,
    this.onReject,
    super.key,
  });

  final AiPredictionValidationTask task;
  final bool showProjectName;
  final VoidCallback? onViewDetails;
  final VoidCallback? onOpenMap;
  final VoidCallback? onSubmit;
  final VoidCallback? onAssign;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectAsync = showProjectName
        ? ref.watch(projectByIdProvider(task.projectId))
        : const AsyncValue<ProjectSummary?>.data(null);
    final projectName = projectAsync.asData?.value?.name;
    final prediction = task.prediction;
    final submitted = task.latestSubmission;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.rule_folder_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      prediction.predictedClass?.trim().isNotEmpty == true
                          ? prediction.predictedClass!.trim()
                          : 'AI prediction',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      projectName?.trim().isNotEmpty == true
                          ? projectName!.trim()
                          : 'Project ${_shortId(task.projectId)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              StatusChip(status: task.status),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          const _NoticeLine(
            icon: Icons.info_outline,
            text:
                'AI validation task. Confidence is metadata and does not block review.',
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(label: Text('Confidence ${_score(prediction.confidence)}')),
              Chip(
                label: Text(
                  'Uncertainty ${_score(prediction.uncertaintyScore)}',
                ),
              ),
              Chip(
                label: Text(
                  prediction.modelName?.trim().isNotEmpty == true
                      ? formatModelName(prediction.modelName)
                      : 'Model n/a',
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            task.assignedUser != null
                ? 'Assigned to ${task.assignedUser!.displayName}'
                : 'Open to project contributors',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (submitted != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Submitted result: ${aiValidationResultLabel(submitted.result)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          AppActionButtons(
            maxColumns: 3,
            fillRows: true,
            compactBreakpoint: 520,
            children: [
              OutlinedButton.icon(
                onPressed: onViewDetails,
                icon: const Icon(Icons.info_outline),
                label: const Text('View details'),
              ),
              OutlinedButton.icon(
                onPressed: onOpenMap,
                icon: const Icon(Icons.map_outlined),
                label: const Text('Open on map'),
              ),
              if (onSubmit != null)
                FilledButton.icon(
                  onPressed: onSubmit,
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('Submit validation'),
                ),
              if (onAssign != null)
                FilledButton.tonalIcon(
                  onPressed: onAssign,
                  icon: const Icon(Icons.assignment_ind_outlined),
                  label: const Text('Assign'),
                ),
              if (onAccept != null)
                FilledButton.icon(
                  onPressed: onAccept,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Accept'),
                ),
              if (onReject != null)
                OutlinedButton.icon(
                  onPressed: onReject,
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('Reject'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class AiValidationTaskDetailsSheet extends StatelessWidget {
  const AiValidationTaskDetailsSheet({
    required this.task,
    this.onOpenMap,
    this.onSubmit,
    this.onAccept,
    this.onReject,
    super.key,
  });

  final AiPredictionValidationTask task;
  final VoidCallback? onOpenMap;
  final VoidCallback? onSubmit;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;

  @override
  Widget build(BuildContext context) {
    final bottomInset =
        MediaQuery.viewPaddingOf(context).bottom + AppSpacing.lg;
    final prediction = task.prediction;
    final submission = task.latestSubmission;
    final submissionPhotos = submission == null
        ? const <String>[]
        : aiEvidencePhotoMediaIds(submission.evidence);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          bottomInset,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      'AI validation task',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  StatusChip(status: task.status),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              const _NoticeLine(
                icon: Icons.info_outline,
                text:
                    'This validation will be reviewed before it becomes trusted AI feedback.',
              ),
              const SizedBox(height: AppSpacing.md),
              _DetailRows(
                title: 'Prediction',
                rows: [
                  MapEntry(
                    'Predicted class',
                    prediction.predictedClass ?? 'Not recorded',
                  ),
                  MapEntry('Confidence', _score(prediction.confidence)),
                  MapEntry('Uncertainty', _score(prediction.uncertaintyScore)),
                  MapEntry('Model', formatModelName(prediction.modelName)),
                  MapEntry('Source', prediction.source),
                  MapEntry(
                    'Layer',
                    prediction.layer == null
                        ? 'Not recorded'
                        : '${prediction.layer!.name} (${prediction.layer!.layerType})',
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              _DetailRows(
                title: 'Assignment',
                rows: [
                  MapEntry('Status', _taskStatusLabel(task.status)),
                  MapEntry(
                    'Assigned user',
                    task.assignedUser?.displayName ??
                        'Open to project contributors',
                  ),
                  if (task.createdAt != null)
                    MapEntry('Created', formatLebanonDate(task.createdAt!)),
                  if (task.reviewDecision != null)
                    MapEntry(
                      'Review decision',
                      _taskStatusLabel(task.reviewDecision!),
                    ),
                  if (task.reviewReason != null)
                    MapEntry('Review reason', task.reviewReason!),
                ],
              ),
              if (submission != null) ...[
                const SizedBox(height: AppSpacing.md),
                _DetailRows(
                  title: 'Submitted evidence',
                  rows: [
                    MapEntry(
                      'Result',
                      aiValidationResultLabel(submission.result),
                    ),
                    if (submission.correctedClass != null)
                      MapEntry('Corrected class', submission.correctedClass!),
                    if (submission.note != null)
                      MapEntry('Note', submission.note!),
                    if (submission.linkedFeatureId != null)
                      MapEntry('Linked feature', submission.linkedFeatureId!),
                    if (submission.createdAt != null)
                      MapEntry(
                        'Submitted',
                        formatLebanonDate(submission.createdAt!),
                      ),
                  ],
                ),
                if (submissionPhotos.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _EvidencePhotoPreviewGrid(mediaIds: submissionPhotos),
                ],
              ],
              const SizedBox(height: AppSpacing.md),
              AppActionButtons(
                maxColumns: 2,
                fillRows: true,
                compactBreakpoint: 520,
                children: [
                  OutlinedButton.icon(
                    onPressed: onOpenMap,
                    icon: const Icon(Icons.map_outlined),
                    label: const Text('Open on map'),
                  ),
                  if (onSubmit != null)
                    FilledButton.icon(
                      onPressed: onSubmit,
                      icon: const Icon(Icons.fact_check_outlined),
                      label: const Text('Submit validation'),
                    ),
                  if (onAccept != null)
                    FilledButton.icon(
                      onPressed: onAccept,
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('Accept validation'),
                    ),
                  if (onReject != null)
                    OutlinedButton.icon(
                      onPressed: onReject,
                      icon: const Icon(Icons.cancel_outlined),
                      label: const Text('Reject validation'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AiValidationSubmissionDialog extends ConsumerStatefulWidget {
  const AiValidationSubmissionDialog({required this.task, super.key});

  final AiPredictionValidationTask task;

  @override
  ConsumerState<AiValidationSubmissionDialog> createState() =>
      _AiValidationSubmissionDialogState();
}

class _AiValidationSubmissionDialogState
    extends ConsumerState<AiValidationSubmissionDialog> {
  final TextEditingController _noteController = TextEditingController();
  final ImagePicker _imagePicker = ImagePicker();
  final List<AiValidationPhotoUpload> _photos = <AiValidationPhotoUpload>[];
  String _result = 'correct';
  String? _correctedClass;
  bool _submitting = false;
  String? _errorText;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final runAsync = ref.watch(aiRunProvider(widget.task.aiRunId));
    final run = runAsync.asData?.value;
    final eligibleClasses = eligibleAiValidationClasses(widget.task, run);
    if (_correctedClass != null && !eligibleClasses.contains(_correctedClass)) {
      _correctedClass = null;
    }

    return AlertDialog(
      title: const Text('Submit AI validation'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _NoticeLine(
                icon: Icons.info_outline,
                text:
                    'This validation will be reviewed before it becomes trusted AI feedback.',
              ),
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<String>(
                initialValue: _result,
                decoration: const InputDecoration(labelText: 'Result'),
                items: const [
                  DropdownMenuItem(value: 'correct', child: Text('Correct')),
                  DropdownMenuItem(
                    value: 'wrong_class',
                    child: Text('Wrong class'),
                  ),
                  DropdownMenuItem(
                    value: 'not_target_class',
                    child: Text('Not target class'),
                  ),
                  DropdownMenuItem(value: 'unsure', child: Text('Unsure')),
                ],
                onChanged: _submitting
                    ? null
                    : (value) {
                        setState(() {
                          _result = value ?? 'correct';
                          if (_result != 'wrong_class') {
                            _correctedClass = null;
                          }
                          _errorText = null;
                        });
                      },
              ),
              if (_result == 'wrong_class') ...[
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<String>(
                  initialValue: _correctedClass,
                  decoration: const InputDecoration(
                    labelText: 'Corrected class',
                  ),
                  items: eligibleClasses
                      .map(
                        (label) => DropdownMenuItem<String>(
                          value: label,
                          child: Text(label),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: _submitting
                      ? null
                      : (value) {
                          setState(() {
                            _correctedClass = value;
                            _errorText = null;
                          });
                        },
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _noteController,
                minLines: 3,
                maxLines: 5,
                enabled: !_submitting,
                decoration: const InputDecoration(
                  labelText: 'Note / evidence',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Validation photos (optional)',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  SizedBox(
                    width: 180,
                    child: OutlinedButton.icon(
                      onPressed: _submitting
                          ? null
                          : () => _pickPhoto(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Add photo'),
                    ),
                  ),
                  SizedBox(
                    width: 180,
                    child: OutlinedButton.icon(
                      onPressed: _submitting
                          ? null
                          : () => _pickPhoto(ImageSource.camera),
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('Take photo'),
                    ),
                  ),
                ],
              ),
              if (_photos.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final photo in _photos)
                      InputChip(
                        avatar: const Icon(Icons.image_outlined, size: 18),
                        label: Text(photo.fileName),
                        onDeleted: _submitting
                            ? null
                            : () => setState(() => _photos.remove(photo)),
                      ),
                  ],
                ),
              ],
              if (_errorText != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  _errorText!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _submitting ? null : _submit,
          icon: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.fact_check_outlined),
          label: Text(_submitting ? 'Submitting...' : 'Submit'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final note = _noteController.text.trim();
    if (note.isEmpty) {
      setState(() => _errorText = 'Note/evidence is required.');
      return;
    }
    if (_result == 'wrong_class' &&
        (_correctedClass == null || _correctedClass!.trim().isEmpty)) {
      setState(() => _errorText = 'Corrected class is required.');
      return;
    }

    setState(() {
      _submitting = true;
      _errorText = null;
    });

    try {
      final photoMediaIds = _photos.isEmpty
          ? const <String>[]
          : await ref
                .read(aiRepositoryProvider)
                .uploadPredictionValidationPhotos(
                  projectId: widget.task.projectId,
                  predictionId: widget.task.aiPredictionFeatureId,
                  photos: _photos,
                );
      await ref
          .read(aiRepositoryProvider)
          .submitValidationTask(
            taskId: widget.task.id,
            result: _result,
            correctedClass: _result == 'wrong_class' ? _correctedClass : null,
            note: note,
            evidence: <String, dynamic>{
              'text': note,
              if (photoMediaIds.isNotEmpty) 'photo_media_ids': photoMediaIds,
              'ui_phase': 'mobile_phase_s2',
            },
          );
      bumpWorkflowRefresh(ref);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop();
      AppSnackbar.showSuccess(context, 'AI validation submitted for review.');
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorText = userFacingErrorMessage(
            error,
            fallback: 'Unable to submit this AI validation task.',
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _pickPhoto(ImageSource source) async {
    try {
      final image = await _imagePicker.pickImage(
        source: source,
        maxWidth: 2200,
        imageQuality: 86,
      );
      if (image == null) {
        return;
      }
      final bytes = await image.readAsBytes();
      if (!mounted) {
        return;
      }
      setState(() {
        _photos.add(
          AiValidationPhotoUpload(
            fileName: image.name.isEmpty ? 'validation-photo.jpg' : image.name,
            bytes: bytes,
          ),
        );
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorText = userFacingErrorMessage(
            error,
            fallback: 'Unable to attach this photo.',
          );
        });
      }
    }
  }
}

class AiValidationReviewDialog extends ConsumerStatefulWidget {
  const AiValidationReviewDialog({
    required this.task,
    required this.decision,
    super.key,
  });

  final AiPredictionValidationTask task;
  final String decision;

  @override
  ConsumerState<AiValidationReviewDialog> createState() =>
      _AiValidationReviewDialogState();
}

class _AiValidationReviewDialogState
    extends ConsumerState<AiValidationReviewDialog> {
  final TextEditingController _reasonController = TextEditingController();
  bool _submitting = false;
  String? _errorText;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rejecting = widget.decision == 'rejected';
    return AlertDialog(
      title: Text(rejecting ? 'Reject validation' : 'Accept validation'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              rejecting
                  ? 'Rejected validation keeps the AI prediction separate and evidence unaccepted.'
                  : 'Accepted validation can create an AI-approved project map feature and mark it for future training use.',
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _reasonController,
              minLines: 3,
              maxLines: 5,
              enabled: !_submitting,
              decoration: InputDecoration(
                labelText: rejecting
                    ? 'Rejection reason'
                    : 'Review note (optional)',
                alignLabelWithHint: true,
              ),
            ),
            if (_errorText != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                _errorText!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _submitting ? null : _review,
          icon: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(rejecting ? Icons.cancel_outlined : Icons.check),
          label: Text(_submitting ? 'Saving...' : 'Save review'),
        ),
      ],
    );
  }

  Future<void> _review() async {
    final reason = _reasonController.text.trim();
    if (widget.decision == 'rejected' && reason.isEmpty) {
      setState(() => _errorText = 'Reject reason is required.');
      return;
    }

    setState(() {
      _submitting = true;
      _errorText = null;
    });

    try {
      await ref
          .read(aiRepositoryProvider)
          .reviewValidationTask(
            taskId: widget.task.id,
            decision: widget.decision,
            reason: reason.isEmpty ? null : reason,
            submissionId: widget.task.latestSubmission?.id,
          );
      bumpWorkflowRefresh(ref);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop();
      AppSnackbar.showSuccess(context, 'AI validation review saved.');
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorText = userFacingErrorMessage(
            error,
            fallback: 'Unable to save this AI validation review.',
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }
}

class AiValidationAssignDialog extends ConsumerStatefulWidget {
  const AiValidationAssignDialog({required this.task, super.key});

  final AiPredictionValidationTask task;

  @override
  ConsumerState<AiValidationAssignDialog> createState() =>
      _AiValidationAssignDialogState();
}

class _AiValidationAssignDialogState
    extends ConsumerState<AiValidationAssignDialog> {
  final TextEditingController _assigneeController = TextEditingController();
  bool _submitting = false;
  String? _errorText;

  @override
  void dispose() {
    _assigneeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Assign validation task'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Assign to an approved contributor on this project.'),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _assigneeController,
              enabled: !_submitting,
              decoration: const InputDecoration(
                labelText: 'Contributor user id',
              ),
            ),
            if (_errorText != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                _errorText!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _submitting ? null : _assign,
          icon: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.assignment_ind_outlined),
          label: Text(_submitting ? 'Assigning...' : 'Assign'),
        ),
      ],
    );
  }

  Future<void> _assign() async {
    final assignee = _assigneeController.text.trim();
    if (assignee.isEmpty) {
      setState(() => _errorText = 'Contributor user id is required.');
      return;
    }

    setState(() {
      _submitting = true;
      _errorText = null;
    });

    try {
      await ref
          .read(aiRepositoryProvider)
          .assignValidationTask(taskId: widget.task.id, assignedTo: assignee);
      bumpWorkflowRefresh(ref);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop();
      AppSnackbar.showSuccess(context, 'AI validation task assigned.');
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorText = userFacingErrorMessage(
            error,
            fallback: 'Unable to assign this AI validation task.',
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }
}

void openAiValidationTaskDetails(
  BuildContext context,
  AiPredictionValidationTask task, {
  VoidCallback? onSubmit,
  VoidCallback? onAccept,
  VoidCallback? onReject,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => AiValidationTaskDetailsSheet(
      task: task,
      onOpenMap: () => openAiValidationTaskMap(context, task),
      onSubmit: onSubmit,
      onAccept: onAccept,
      onReject: onReject,
    ),
  );
}

void openAiValidationTaskMap(
  BuildContext context,
  AiPredictionValidationTask task,
) {
  context.push(
    AppRoutes.mapForProject(
      task.projectId,
      featureId: task.id,
      focusSource: AppRoutes.focusSourceAiValidationTask,
    ),
  );
}

String aiValidationResultLabel(String value) {
  switch (value) {
    case 'correct':
      return 'Correct';
    case 'wrong_class':
      return 'Wrong class';
    case 'not_target_class':
      return 'Not target class';
    case 'unsure':
      return 'Unsure';
    default:
      return value.replaceAll('_', ' ');
  }
}

const aiUnclassifiedClassLabel = 'Unclassified';

List<String> eligibleAiValidationClasses(
  AiPredictionValidationTask task,
  AiRun? run,
) {
  final labels = <String>{};
  _collectAiClassLabels(task.metadata, labels);
  _collectAiClassLabels(task.prediction.metadata, labels);
  if (run != null) {
    _collectAiClassLabels(run.metadata, labels);
  }
  _addAiClassLabel(labels, task.prediction.predictedClass);

  return _sortedAiClassesWithUnclassified(labels);
}

List<String> eligibleAiPredictionFeatureClasses(
  AiPredictionFeatureDetails details,
) {
  final labels = <String>{};
  _collectAiClassLabels(details.prediction.metadata, labels);
  _collectAiClassLabels(details.run, labels);
  _addAiClassLabel(labels, details.prediction.predictedClass);
  return _sortedAiClassesWithUnclassified(labels);
}

List<String> aiEvidencePhotoMediaIds(Map<String, dynamic> evidence) {
  final values = evidence['photo_media_ids'] ?? evidence['photos'];
  if (values is List) {
    return values
        .map((item) => item?.toString().trim())
        .whereType<String>()
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }
  return const <String>[];
}

class _EvidencePhotoPreviewGrid extends StatelessWidget {
  const _EvidencePhotoPreviewGrid({required this.mediaIds});

  final List<String> mediaIds;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final mediaId in mediaIds)
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 76,
              height: 76,
              child: Image.network(
                _evidencePhotoUrl(mediaId),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                  child: const Icon(Icons.image_not_supported_outlined),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

String _evidencePhotoUrl(String mediaId) {
  final trimmed = mediaId.trim();
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return trimmed;
  }
  final baseUri = Uri.parse(AppEnv.apiBaseUrl);
  final origin = baseUri.replace(path: '', query: null, fragment: null);
  final relative = trimmed.startsWith('/') ? trimmed : '/$trimmed';
  return '${origin.toString().replaceAll(RegExp(r'/$'), '')}$relative';
}

void _addAiClassLabel(Set<String> labels, Object? value) {
  final text = value?.toString().trim();
  if (text != null && text.isNotEmpty) {
    labels.add(text);
  }
}

void _addAiClassArray(Set<String> labels, Object? value) {
  if (value is! List) {
    return;
  }
  for (final item in value) {
    if (item is String) {
      _addAiClassLabel(labels, item);
    } else if (item is Map) {
      _addAiClassLabel(labels, item['class_label']);
      _addAiClassLabel(labels, item['label']);
      _addAiClassLabel(labels, item['class']);
      _addAiClassLabel(labels, item['predicted_class']);
    }
  }
}

void _collectAiClassLabels(Map<String, dynamic> metadata, Set<String> labels) {
  _addAiClassArray(labels, metadata['class_labels']);
  _addAiClassArray(labels, metadata['eligible_classes']);
  _addAiClassArray(labels, metadata['trained_classes']);
  _addAiClassArray(labels, metadata['classes']);
  _addAiClassArray(labels, metadata['class_counts']);
  _addAiClassArray(labels, metadata['label_counts']);
  final summary = metadata['model_metrics_summary'];
  if (summary is Map) {
    _addAiClassArray(labels, summary['classes']);
  }
}

List<String> _sortedAiClassesWithUnclassified(Set<String> labels) {
  final sorted =
      labels
          .where(
            (label) =>
                label.trim().isNotEmpty &&
                label.trim().toLowerCase() !=
                    aiUnclassifiedClassLabel.toLowerCase(),
          )
          .toList(growable: false)
        ..sort();
  return <String>[...sorted, aiUnclassifiedClassLabel];
}

String _taskStatusLabel(String status) {
  switch (status) {
    case 'in_progress':
      return 'In progress';
    case 'ready_for_review':
      return 'Ready for review';
    default:
      final words = status.replaceAll('_', ' ').trim().split(RegExp(r'\s+'));
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

IconData _taskStatusIcon(String status) {
  switch (status) {
    case 'open':
      return Icons.radio_button_unchecked;
    case 'assigned':
      return Icons.assignment_ind_outlined;
    case 'in_progress':
      return Icons.pending_actions_outlined;
    case 'submitted':
      return Icons.mark_email_read_outlined;
    case 'accepted':
      return Icons.check_circle_outline;
    case 'rejected':
      return Icons.cancel_outlined;
    case 'cancelled':
      return Icons.block_outlined;
    default:
      return Icons.info_outline;
  }
}

String _score(double? value) {
  if (value == null) {
    return 'n/a';
  }
  return '${(value * 100).clamp(0, 100).toStringAsFixed(1)}%';
}

String _shortId(String id) => id.length <= 8 ? id : id.substring(0, 8);

class _NoticeLine extends StatelessWidget {
  const _NoticeLine({required this.icon, required this.text});

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

class _DetailRows extends StatelessWidget {
  const _DetailRows({required this.title, required this.rows});

  final String title;
  final List<MapEntry<String, String>> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${row.key}: '),
                  TextSpan(
                    text: row.value,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              softWrap: true,
            ),
          ),
      ],
    );
  }
}
