import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/config/app_env.dart';
import '../../../../core/constants/design_tokens.dart';
import '../../../../core/network/api_error_message.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/router/route_paths.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/progressive_list_section.dart';
import '../../domain/admin_models.dart';

class CategoriesScreen extends ConsumerStatefulWidget {
  const CategoriesScreen({super.key});

  @override
  ConsumerState<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends ConsumerState<CategoriesScreen> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<ProjectCategorySummary> _applyQuery(
    List<ProjectCategorySummary> categories,
  ) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      return categories;
    }

    return categories
        .where((category) {
          return category.name.toLowerCase().contains(query) ||
              (category.description?.toLowerCase().contains(query) ?? false);
        })
        .toList(growable: false);
  }

  String? _previewUrl(String? iconUrl) {
    final raw = iconUrl?.trim() ?? '';
    if (raw.isEmpty) {
      return null;
    }
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return raw;
    }
    return '${AppEnv.apiBaseUrl}$raw';
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(projectCategoriesProvider);

    return categoriesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => AppEmptyState(
        icon: Icons.error_outline,
        title: 'Categories unavailable',
        message: userFacingErrorMessage(
          error,
          fallback: 'Unable to load categories right now. Please try again.',
        ),
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(projectCategoriesProvider),
      ),
      data: (categories) {
        final filtered = _applyQuery(categories);
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(projectCategoriesProvider),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: () => context.push(AppRoutes.categoryCreate),
                  icon: const Icon(Icons.add),
                  label: const Text('Create'),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: AppCard(
                  child: SearchBar(
                    controller: _searchController,
                    hintText: 'Search category name or description',
                    leading: const Icon(Icons.search),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
              Text(
                '${filtered.length} categor${filtered.length == 1 ? 'y' : 'ies'}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.sm),
              if (filtered.isEmpty)
                AppEmptyState(
                  icon: Icons.category_outlined,
                  title: categories.isEmpty
                      ? 'No categories yet'
                      : 'No categories match',
                  message: categories.isEmpty
                      ? 'Create your first category before provisioning projects from mobile.'
                      : 'Try a different search term or clear the active category filter.',
                  actionLabel: categories.isEmpty ? 'Create category' : null,
                  onAction: categories.isEmpty
                      ? () => context.push(AppRoutes.categoryCreate)
                      : null,
                )
              else
                ProgressiveListSection<ProjectCategorySummary>(
                  items: filtered,
                  resetKey: Object.hash(
                    _searchController.text,
                    filtered.length,
                  ),
                  itemBuilder: (context, category, _) => AppCard(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final iconPreview = _previewUrl(category.iconUrl);
                        final summary = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              category.name,
                              style: Theme.of(context).textTheme.titleMedium,
                              softWrap: true,
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            if (category.description?.trim().isNotEmpty == true)
                              Text(category.description!, softWrap: true),
                          ],
                        );

                        final editAction = IconButton(
                          tooltip: 'Edit category',
                          onPressed: () =>
                              context.push(AppRoutes.categoryEdit(category.id)),
                          icon: const Icon(Icons.edit_outlined),
                        );
                        final avatar = CircleAvatar(
                          radius: 28,
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          backgroundImage: iconPreview != null
                              ? NetworkImage(iconPreview)
                              : null,
                          child: iconPreview == null
                              ? const Icon(Icons.category_outlined)
                              : null,
                        );

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                avatar,
                                const SizedBox(width: AppSpacing.sm),
                                Expanded(child: summary),
                                if (constraints.maxWidth >= 360) editAction,
                              ],
                            ),
                            if (constraints.maxWidth < 360)
                              Align(
                                alignment: Alignment.centerRight,
                                child: editAction,
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
