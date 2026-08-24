import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/utils/lebanon_time.dart';
import '../../../../core/widgets/app_action_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_dialog_controller_host.dart';
import '../../../../core/widgets/app_dialog_actions.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../exports/presentation/export_file_actions.dart';
import '../../domain/legal_models.dart';
import '../legal_providers.dart';

class PrivacyCenterScreen extends ConsumerStatefulWidget {
  const PrivacyCenterScreen({super.key});

  @override
  ConsumerState<PrivacyCenterScreen> createState() =>
      _PrivacyCenterScreenState();
}

class _PrivacyCenterScreenState extends ConsumerState<PrivacyCenterScreen> {
  static const int _pageSize = 10;

  int _dataExportsPage = 0;
  int _privacyRequestsPage = 0;
  int _contentReportsPage = 0;

  Future<void> _requestWithPassword(
    BuildContext context,
    WidgetRef ref,
    PrivacyRequestType type,
  ) async {
    final password = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AppDialogControllerHost(
        initialValues: const [''],
        builder: (dialogContext, controllers) => AlertDialog(
          title: const Text('Get my data'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: AppTextField(
              label: 'Current password',
              controller: controllers.single,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
            ),
          ),
          actions: [
            AppDialogActions(
              cancel: TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              confirm: FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(controllers.single.text),
                child: const Text('Send'),
              ),
            ),
          ],
        ),
      ),
    );
    if (password == null || !context.mounted) {
      return;
    }
    if (password.isEmpty) {
      AppSnackbar.showError(context, 'Enter your current password.');
      return;
    }
    try {
      await ref
          .read(legalRepositoryProvider)
          .createPrivacyRequest(type: type, currentPassword: password);
      ref.invalidate(privacyRequestsProvider);
      if (context.mounted) {
        setState(() => _dataExportsPage = 0);
        AppSnackbar.showSuccess(context, 'Privacy request submitted.');
      }
    } catch (error) {
      if (context.mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to submit the request.',
          ),
        );
      }
    }
  }

  Future<void> _requestCorrection(BuildContext context, WidgetRef ref) async {
    final requestedValue = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AppDialogControllerHost(
        initialValues: const [''],
        builder: (dialogContext, controllers) {
          return AlertDialog(
            title: const Text('Correct my data'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: AppTextField(
                label: 'Correct full name',
                controller: controllers.single,
                maxLength: 200,
              ),
            ),
            actions: [
              AppDialogActions(
                cancel: TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                confirm: FilledButton(
                  onPressed: () => Navigator.of(
                    dialogContext,
                  ).pop(controllers.single.text.trim()),
                  child: const Text('Send'),
                ),
              ),
            ],
          );
        },
      ),
    );
    if (requestedValue == null || !context.mounted) {
      return;
    }
    if (requestedValue.isEmpty) {
      AppSnackbar.showError(context, 'Enter the correct full name.');
      return;
    }
    try {
      await ref
          .read(legalRepositoryProvider)
          .createPrivacyRequest(
            type: PrivacyRequestType.correction,
            details: <String, dynamic>{
              'field': 'full_name',
              'requested_value': requestedValue,
            },
          );
      ref.invalidate(privacyRequestsProvider);
      if (context.mounted) {
        setState(() => _privacyRequestsPage = 0);
        AppSnackbar.showSuccess(context, 'Correction request submitted.');
      }
    } catch (error) {
      if (context.mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to submit the request.',
          ),
        );
      }
    }
  }

  Future<void> _cancelRequest(
    BuildContext context,
    WidgetRef ref,
    PrivacyRequestRecord request,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Cancel ${request.type.label.toLowerCase()} request?'),
        content: const Text('This cancels only this request.'),
        actions: [
          AppDialogActions(
            cancel: TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const AppDialogActionLabel('Keep'),
            ),
            confirm: FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const AppDialogActionLabel('Cancel'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await ref.read(legalRepositoryProvider).cancelPrivacyRequest(request.id);
      ref.invalidate(privacyRequestsProvider);
      if (context.mounted) {
        setState(() {
          if (request.type == PrivacyRequestType.accessExport) {
            _dataExportsPage = 0;
          } else {
            _privacyRequestsPage = 0;
          }
        });
        AppSnackbar.showSuccess(context, 'Privacy request cancelled.');
      }
    } catch (error) {
      if (context.mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(
            error,
            fallback: 'Unable to cancel the request.',
          ),
        );
      }
    }
  }

  Future<void> _downloadExport(
    BuildContext context,
    WidgetRef ref,
    PrivacyRequestRecord request,
  ) async {
    final password = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AppDialogControllerHost(
        initialValues: const [''],
        builder: (dialogContext, controllers) => AlertDialog(
          title: const Text('Download my data'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: AppTextField(
              label: 'Current password',
              controller: controllers.single,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
            ),
          ),
          actions: [
            AppDialogActions(
              cancel: TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              confirm: FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(controllers.single.text),
                child: const Text('Download'),
              ),
            ),
          ],
        ),
      ),
    );
    if (password == null || !context.mounted) return;
    if (password.isEmpty) {
      AppSnackbar.showError(context, 'Enter your current password.');
      return;
    }
    try {
      final path = await ref
          .read(legalRepositoryProvider)
          .downloadPersonalDataExport(
            requestId: request.id,
            currentPassword: password,
          );
      if (context.mounted) {
        if (path.isNotEmpty) {
          ref.invalidate(personalDataExportLocalPathProvider(request.id));
        }
        AppSnackbar.showSuccess(
          context,
          path.isEmpty
              ? 'Report downloaded by the browser.'
              : 'Report downloaded. You can show its folder, share it, or download it again.',
        );
      }
    } catch (error) {
      if (context.mounted) {
        AppSnackbar.showError(
          context,
          userFacingErrorMessage(error, fallback: 'Unable to download export.'),
        );
      }
    }
  }

  Future<void> _revealDownloadedExport(String path) async {
    if (kIsWeb) {
      AppSnackbar.showError(
        context,
        'Use the browser downloads list to locate this report.',
      );
      return;
    }
    if (!await File(path).exists()) {
      if (!mounted) return;
      AppSnackbar.showError(
        context,
        'The downloaded report is no longer available on this device.',
      );
      return;
    }
    try {
      await ExportFileActions.revealFile(path);
    } on PlatformException catch (error) {
      if (!mounted) return;
      AppSnackbar.showError(
        context,
        error.message?.trim().isNotEmpty == true
            ? error.message!
            : 'This device could not show the report folder.',
      );
    }
  }

  Future<void> _shareDownloadedExport(String path) async {
    if (kIsWeb) {
      AppSnackbar.showError(
        context,
        'Use the browser downloads list to share this report.',
      );
      return;
    }
    if (!await File(path).exists()) {
      if (!mounted) return;
      AppSnackbar.showError(
        context,
        'The downloaded report is no longer available on this device.',
      );
      return;
    }
    try {
      await ExportFileActions.shareFile(
        path: path,
        subject: 'TerraLeb personal data report',
        text: 'My TerraLeb personal data report.',
      );
    } on PlatformException catch (error) {
      if (!mounted) return;
      AppSnackbar.showError(
        context,
        error.message?.trim().isNotEmpty == true
            ? error.message!
            : 'This device could not open the share sheet.',
      );
    }
  }

  Widget _buildExportRequestCard(
    BuildContext context,
    WidgetRef ref,
    PrivacyRequestRecord item,
  ) {
    final localPath = ref
        .watch(personalDataExportLocalPathProvider(item.id))
        .asData
        ?.value
        ?.trim();
    final hasLocalFile = localPath?.isNotEmpty == true;
    return _PrivacyRequestCard(
      request: item,
      title: 'Personal data export',
      onCancel: item.canCancel
          ? () => _cancelRequest(context, ref, item)
          : null,
      onDownload: item.canDownload
          ? () => _downloadExport(context, ref, item)
          : null,
      onReveal: hasLocalFile ? () => _revealDownloadedExport(localPath!) : null,
      onShare: hasLocalFile ? () => _shareDownloadedExport(localPath!) : null,
    );
  }

  int _pageFor(int requestedPage, int itemCount) {
    if (itemCount == 0) return 0;
    final lastPage = (itemCount - 1) ~/ _pageSize;
    return requestedPage.clamp(0, lastPage);
  }

  List<T> _itemsForPage<T>(List<T> items, int page) =>
      items.skip(page * _pageSize).take(_pageSize).toList(growable: false);

  Widget _paginationControls({
    required String sectionKey,
    required int page,
    required int itemCount,
    required ValueChanged<int> onPageChanged,
  }) {
    final pageCount = (itemCount + _pageSize - 1) ~/ _pageSize;
    if (pageCount <= 1) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Page ${page + 1} of $pageCount',
            key: ValueKey('$sectionKey-page-label'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.xs),
          AppActionButtons(
            fillRows: true,
            children: [
              OutlinedButton.icon(
                key: ValueKey('$sectionKey-previous-page'),
                onPressed: page > 0 ? () => onPageChanged(page - 1) : null,
                icon: const Icon(Icons.chevron_left),
                label: const Text('Previous'),
              ),
              OutlinedButton.icon(
                key: ValueKey('$sectionKey-next-page'),
                onPressed: page + 1 < pageCount
                    ? () => onPageChanged(page + 1)
                    : null,
                icon: const Icon(Icons.chevron_right),
                label: const Text('Next'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).session?.user;
    if (user?.isSuperAdmin == true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Privacy & data')),
        body: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: const [_LegalInformationCard()],
        ),
      );
    }

    final requests = ref.watch(privacyRequestsProvider);
    final reports = ref.watch(myContentReportsProvider);
    PrivacyRequestRecord? activeExportRequest;
    PrivacyRequestRecord? activeCorrectionRequest;
    for (final request
        in requests.asData?.value ?? const <PrivacyRequestRecord>[]) {
      if (!request.isActive) {
        continue;
      }
      if (request.type == PrivacyRequestType.accessExport) {
        activeExportRequest ??= request;
      } else if (request.type == PrivacyRequestType.correction) {
        activeCorrectionRequest ??= request;
      }
    }
    final canRequestExport =
        requests.asData != null && activeExportRequest == null;
    final canRequestCorrection =
        requests.asData != null && activeCorrectionRequest == null;
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy & data')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your data',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: AppSpacing.md),
                AppActionButtons(
                  fillRows: true,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: activeExportRequest?.canCancel == true
                          ? () => _cancelRequest(
                              context,
                              ref,
                              activeExportRequest!,
                            )
                          : canRequestExport
                          ? () => _requestWithPassword(
                              context,
                              ref,
                              PrivacyRequestType.accessExport,
                            )
                          : null,
                      icon: Icon(
                        activeExportRequest?.canCancel == true
                            ? Icons.close
                            : Icons.download_outlined,
                      ),
                      label: Text(
                        activeExportRequest?.canCancel == true
                            ? 'Cancel data request'
                            : activeExportRequest != null
                            ? 'Data request ${activeExportRequest.status.replaceAll('_', ' ')}'
                            : 'Get my data',
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: activeCorrectionRequest?.canCancel == true
                          ? () => _cancelRequest(
                              context,
                              ref,
                              activeCorrectionRequest!,
                            )
                          : canRequestCorrection
                          ? () => _requestCorrection(context, ref)
                          : null,
                      icon: Icon(
                        activeCorrectionRequest?.canCancel == true
                            ? Icons.close
                            : Icons.edit_note,
                      ),
                      label: Text(
                        activeCorrectionRequest?.canCancel == true
                            ? 'Cancel correction request'
                            : activeCorrectionRequest != null
                            ? 'Correction ${activeCorrectionRequest.status.replaceAll('_', ' ')}'
                            : 'Correct my data',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          const _LegalInformationCard(),
          const SizedBox(height: AppSpacing.md),
          requests.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => AppCard(
              child: Column(
                children: [
                  Text(error.toString()),
                  TextButton(
                    onPressed: () => ref.invalidate(privacyRequestsProvider),
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
            data: (items) {
              final sorted = [...items]
                ..sort(
                  (left, right) =>
                      right.requestedAt.compareTo(left.requestedAt),
                );
              final exports = sorted
                  .where((item) => item.type == PrivacyRequestType.accessExport)
                  .toList(growable: false);
              final otherRequests = sorted
                  .where((item) => item.type != PrivacyRequestType.accessExport)
                  .toList(growable: false);
              final exportsPage = _pageFor(_dataExportsPage, exports.length);
              final requestsPage = _pageFor(
                _privacyRequestsPage,
                otherRequests.length,
              );
              final visibleExports = _itemsForPage(exports, exportsPage);
              final visibleRequests = _itemsForPage(
                otherRequests,
                requestsPage,
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Your data exports',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (exports.isEmpty)
                    const _PrivacyEmptyCard(
                      icon: Icons.download_done_outlined,
                      message: 'No data exports requested.',
                    )
                  else
                    for (final item in visibleExports)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: _buildExportRequestCard(context, ref, item),
                      ),
                  _paginationControls(
                    sectionKey: 'data-exports',
                    page: exportsPage,
                    itemCount: exports.length,
                    onPageChanged: (page) =>
                        setState(() => _dataExportsPage = page),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'Your requests',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (otherRequests.isEmpty)
                    const _PrivacyEmptyCard(
                      icon: Icons.fact_check_outlined,
                      message: 'No privacy requests submitted.',
                    )
                  else
                    for (final item in visibleRequests)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: _PrivacyRequestCard(
                          request: item,
                          onCancel: item.canCancel
                              ? () => _cancelRequest(context, ref, item)
                              : null,
                        ),
                      ),
                  _paginationControls(
                    sectionKey: 'privacy-requests',
                    page: requestsPage,
                    itemCount: otherRequests.length,
                    onPageChanged: (page) =>
                        setState(() => _privacyRequestsPage = page),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Your content reports',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: AppSpacing.sm),
          reports.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => AppCard(
              child: Text(
                userFacingErrorMessage(
                  error,
                  fallback: 'Unable to load content reports.',
                ),
              ),
            ),
            data: (items) {
              final sorted = [...items]
                ..sort(
                  (left, right) => right.createdAt.compareTo(left.createdAt),
                );
              if (sorted.isEmpty) {
                return const _PrivacyEmptyCard(
                  icon: Icons.flag_outlined,
                  message: 'No content reports submitted.',
                );
              }
              final reportsPage = _pageFor(_contentReportsPage, sorted.length);
              final visibleReports = _itemsForPage(sorted, reportsPage);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final item in visibleReports)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: AppCard(
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(item.reasonCode.replaceAll('_', ' ')),
                          subtitle: Text(
                            '${item.projectTitle ?? item.entityType.replaceAll('_', ' ')} · '
                            '${item.status.replaceAll('_', ' ')}'
                            '${item.userMessage?.isNotEmpty == true ? '\n${item.userMessage}' : ''}',
                          ),
                        ),
                      ),
                    ),
                  _paginationControls(
                    sectionKey: 'content-reports',
                    page: reportsPage,
                    itemCount: sorted.length,
                    onPageChanged: (page) =>
                        setState(() => _contentReportsPage = page),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PrivacyEmptyCard extends StatelessWidget {
  const _PrivacyEmptyCard({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: double.infinity,
      child: AppCard(
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(icon, color: colors.onSurfaceVariant, size: 21),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrivacyRequestCard extends StatelessWidget {
  const _PrivacyRequestCard({
    required this.request,
    this.title,
    this.onCancel,
    this.onDownload,
    this.onReveal,
    this.onShare,
  });

  final PrivacyRequestRecord request;
  final String? title;
  final VoidCallback? onCancel;
  final VoidCallback? onDownload;
  final VoidCallback? onReveal;
  final VoidCallback? onShare;

  String get _statusLabel => request.status
      .split('_')
      .map(
        (word) => word.isEmpty
            ? word
            : '${word.substring(0, 1).toUpperCase()}${word.substring(1)}',
      )
      .join(' ');

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isOpen = request.isActive;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                isOpen ? Icons.schedule_outlined : Icons.task_alt,
                color: isOpen ? colors.primary : colors.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  title ?? request.type.label,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: isOpen
                      ? colors.primaryContainer
                      : colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _statusLabel,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: isOpen
                        ? colors.onPrimaryContainer
                        : colors.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Submitted ${formatLebanonDate(request.requestedAt)}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
          if (request.canDownload && request.exportExpiresAt != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Available until ${formatLebanonDate(request.exportExpiresAt!)}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
          if (request.userMessage?.trim().isNotEmpty == true) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(request.userMessage!.trim()),
          ],
          if (onCancel != null ||
              onDownload != null ||
              onReveal != null ||
              onShare != null) ...[
            const SizedBox(height: AppSpacing.md),
            AppActionButtons(
              fillRows: true,
              children: [
                if (onCancel != null)
                  OutlinedButton.icon(
                    onPressed: onCancel,
                    icon: const Icon(Icons.close),
                    label: const Text('Cancel request'),
                  ),
                if (onDownload != null)
                  FilledButton.icon(
                    onPressed: onDownload,
                    icon: const Icon(Icons.download_outlined),
                    label: Text(
                      onReveal != null ? 'Download again' : 'Download report',
                    ),
                  ),
                if (onReveal != null)
                  OutlinedButton.icon(
                    onPressed: onReveal,
                    icon: const Icon(Icons.folder_open_outlined),
                    label: const Text('Show in folder'),
                  ),
                if (onShare != null)
                  OutlinedButton.icon(
                    onPressed: onShare,
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('Share'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _LegalInformationCard extends StatelessWidget {
  const _LegalInformationCard();

  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Legal information',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        for (final entry in const <String, String>{
          'privacy': 'Privacy Notice',
          'terms': 'Terms of Use',
          'acceptable-use': 'Acceptable Use',
          'important-notices': 'Important GIS & AI Notices',
          'account-deletion': 'Account deletion information',
          'subprocessors': 'Subprocessors',
          'open-source': 'Open-source & data notices',
        }.entries)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            visualDensity: VisualDensity.compact,
            title: Text(entry.value),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.legalDocument(entry.key)),
          ),
      ],
    ),
  );
}
