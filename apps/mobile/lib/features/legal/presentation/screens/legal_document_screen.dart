import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/widgets/app_card.dart';
import '../legal_providers.dart';

class LegalDocumentScreen extends ConsumerWidget {
  const LegalDocumentScreen({required this.slug, super.key});

  final String slug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final documentAsync = ref.watch(legalDocumentProvider(slug));
    return Scaffold(
      appBar: AppBar(title: const Text('Legal information')),
      body: documentAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.policy_outlined, size: 48),
                const SizedBox(height: AppSpacing.sm),
                Text(error.toString(), textAlign: TextAlign.center),
                const SizedBox(height: AppSpacing.sm),
                FilledButton.tonal(
                  onPressed: () => ref.invalidate(legalDocumentProvider(slug)),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
        data: (document) => SelectionArea(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              if (document.isDraft) ...[
                AppCard(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      const Expanded(
                        child: Text(
                          'Legal-review draft. This document is not approved for public production.',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              Text(
                document.title,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Version ${document.version} · ${document.locale}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(document.summary),
              for (final section in document.sections) ...[
                const SizedBox(height: AppSpacing.lg),
                Text(
                  section.heading,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                for (final paragraph in section.paragraphs) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(paragraph),
                ],
                for (final bullet in section.bullets) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('•  '),
                      Expanded(child: Text(bullet)),
                    ],
                  ),
                ],
              ],
              if (slug == 'open-source') ...[
                const SizedBox(height: AppSpacing.lg),
                FilledButton.tonalIcon(
                  onPressed: () => showLicensePage(
                    context: context,
                    applicationName: 'TerraLeb',
                  ),
                  icon: const Icon(Icons.code),
                  label: const Text('View bundled software licenses'),
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
            ],
          ),
        ),
      ),
    );
  }
}
