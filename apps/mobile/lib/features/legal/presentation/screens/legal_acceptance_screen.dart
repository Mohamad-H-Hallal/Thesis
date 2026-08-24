import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_snackbar.dart';
import '../../domain/legal_models.dart';
import '../legal_providers.dart';

class LegalAcceptanceScreen extends ConsumerStatefulWidget {
  const LegalAcceptanceScreen({super.key});

  @override
  ConsumerState<LegalAcceptanceScreen> createState() =>
      _LegalAcceptanceScreenState();
}

class _LegalAcceptanceScreenState extends ConsumerState<LegalAcceptanceScreen> {
  bool _affirmed = false;
  bool _submitting = false;

  @override
  Widget build(BuildContext context) {
    final statusAsync = ref.watch(legalAcceptanceStatusProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Updated Terms'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: _submitting
                ? null
                : () => ref.read(authControllerProvider.notifier).logout(),
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: statusAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: AppCard(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 42),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    userFacingErrorMessage(
                      error,
                      fallback:
                          'The current Terms could not be verified. Try again while connected.',
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  FilledButton.tonal(
                    onPressed: () =>
                        ref.invalidate(legalAcceptanceStatusProvider),
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          ),
        ),
        data: (status) {
          if (!status.required) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              ref
                  .read(authControllerProvider.notifier)
                  .markLegalAcceptanceCurrent();
              context.go(AppRoutes.app);
            });
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Review a material Terms update',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    const Text(
                      'Your affirmative acceptance is required because these versions are classified as material updates. Viewing the Privacy Notice is not consent, and optional AI training, public publication, or marketing choices are not included here.',
                    ),
                    const SizedBox(height: AppSpacing.md),
                    for (final document in status.missingDocuments)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.description_outlined),
                        title: Text(document.title),
                        subtitle: Text('Version ${document.version}'),
                        trailing: const Icon(Icons.open_in_new),
                        onTap: () => context.push(
                          AppRoutes.legalDocument(document.slug),
                        ),
                      ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.privacy_tip_outlined),
                      title: const Text('Privacy Notice'),
                      subtitle: const Text('Notice only, not bundled consent'),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () =>
                          context.push(AppRoutes.legalDocument('privacy')),
                    ),
                    CheckboxListTile(
                      key: const Key('renewed-legal-acceptance'),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _affirmed,
                      onChanged: _submitting
                          ? null
                          : (value) => setState(() {
                              _affirmed = value ?? false;
                            }),
                      title: const Text(
                        'I have reviewed and accept the current Terms of Use and Acceptable Use Policy.',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    FilledButton(
                      key: const Key('accept-renewed-legal-documents'),
                      onPressed: !_affirmed || _submitting
                          ? null
                          : () => _accept(status.missingDocuments),
                      child: Text(
                        _submitting ? 'Recording...' : 'Accept and continue',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _accept(List<LegalDocument> documents) async {
    setState(() => _submitting = true);
    try {
      await ref.read(legalRepositoryProvider).acceptCurrentDocuments(documents);
      if (!mounted) return;
      ref.read(authControllerProvider.notifier).markLegalAcceptanceCurrent();
      ref.invalidate(legalAcceptanceStatusProvider);
      context.go(AppRoutes.app);
    } catch (error) {
      if (!mounted) return;
      setState(() => _submitting = false);
      AppSnackbar.showError(
        context,
        userFacingErrorMessage(
          error,
          fallback: 'Unable to record acceptance. Try again while connected.',
        ),
      );
    }
  }
}
