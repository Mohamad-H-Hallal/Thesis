import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/section_header.dart';

class CategoriesScreen extends ConsumerWidget {
  const CategoriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categoriesAsync = ref.watch(projectCategoriesProvider);

    return categoriesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Categories unavailable',
        message: '$error',
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(projectCategoriesProvider),
      ),
      data: (categories) {
        return ListView(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Expanded(
                  child: SectionHeader(
                    title: 'Categories',
                    subtitle:
                        'Define the ministry project categories used for project provisioning.',
                  ),
                ),
                FilledButton.icon(
                  onPressed: () => context.push(AppRoutes.categoryCreate),
                  icon: const Icon(Icons.add),
                  label: const Text('Create'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (categories.isEmpty)
              AppEmptyState(
                icon: Icons.category_outlined,
                title: 'No categories yet',
                message:
                    'Create your first category before provisioning projects from mobile.',
                actionLabel: 'Create category',
                onAction: () => context.push(AppRoutes.categoryCreate),
              )
            else
              ...categories.map(
                (category) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: AppCard(
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const CircleAvatar(
                        child: Icon(Icons.category_outlined),
                      ),
                      title: Text(category.name),
                      subtitle: Text(
                        category.description?.trim().isNotEmpty == true
                            ? category.description!
                            : 'No description provided.',
                      ),
                      trailing: IconButton(
                        tooltip: 'Edit category',
                        onPressed: () =>
                            context.push(AppRoutes.categoryEdit(category.id)),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
