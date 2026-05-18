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
    final categoriesQuery = ProjectCategoriesQuery(
      query: _searchController.text.trim().isEmpty
          ? null
          : _searchController.text.trim(),
    );
    final categoriesAsync = ref.watch(
      paginatedProjectCategoriesProvider(categoriesQuery),
    );
    final categoriesController = ref.read(
      paginatedProjectCategoriesProvider(categoriesQuery).notifier,
    );

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
        onAction: categoriesController.load,
      ),
      data: (categoriesState) {
        final filtered = categoriesState.items;
        return RefreshIndicator(
          onRefresh: categoriesController.refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: AppCard(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final createButton = FilledButton.icon(
                        onPressed: () => context.push(AppRoutes.categoryCreate),
                        icon: const Icon(Icons.add),
                        label: const Text('Create'),
                      );
                      final searchBar = SearchBar(
                        controller: _searchController,
                        hintText: 'Search category name or description',
                        leading: const Icon(Icons.search),
                        onChanged: (_) => setState(() {}),
                      );

                      if (constraints.maxWidth < 560) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            searchBar,
                            const SizedBox(height: AppSpacing.sm),
                            SizedBox(
                              width: double.infinity,
                              child: createButton,
                            ),
                          ],
                        );
                      }

                      return Row(
                        children: [
                          Expanded(child: searchBar),
                          const SizedBox(width: AppSpacing.sm),
                          SizedBox(width: 180, child: createButton),
                        ],
                      );
                    },
                  ),
                ),
              ),
              Text(
                '${categoriesState.total} categor${categoriesState.total == 1 ? 'y' : 'ies'}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.sm),
              if (filtered.isEmpty)
                AppEmptyState(
                  icon: Icons.category_outlined,
                  title: categoriesState.total == 0
                      ? 'No categories yet'
                      : 'No categories match',
                  message: categoriesState.total == 0
                      ? 'Create your first category before provisioning projects from mobile.'
                      : 'Try a different search term or clear the active category filter.',
                  actionLabel: categoriesState.total == 0
                      ? 'Create category'
                      : null,
                  onAction: categoriesState.total == 0
                      ? () => context.push(AppRoutes.categoryCreate)
                      : null,
                )
              else
                ProgressiveListSection<ProjectCategorySummary>(
                  items: filtered,
                  resetKey: Object.hash(
                    _searchController.text,
                    categoriesState.total,
                  ),
                  hasMore: categoriesState.hasMore,
                  isLoadingMore: categoriesState.isLoadingMore,
                  onLoadMore: categoriesController.loadMore,
                  gridMinItemWidth: 380,
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
