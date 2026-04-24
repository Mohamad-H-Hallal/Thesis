import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/pagination/paginated_list_controller.dart';
import '../../../core/providers/providers.dart';
import '../domain/import_models.dart';

final importJobsProvider =
    FutureProvider.family<List<GisImportJob>, GisImportListQuery>((
      ref,
      query,
    ) async {
      ref.watch(workflowRefreshTickProvider);
      return ref
          .read(importsRepositoryProvider)
          .fetchImports(status: query.status, projectId: query.projectId);
    });

final importDetailsProvider = FutureProvider.family<GisImportDetails, String>((
  ref,
  importId,
) async {
  ref.watch(workflowRefreshTickProvider);
  return ref.read(importsRepositoryProvider).fetchImportDetails(importId);
});

final paginatedImportJobsProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<GisImportJob>,
      AsyncValue<PaginatedListState<GisImportJob>>,
      GisImportListQuery
    >((ref, query) {
      ref.watch(workflowRefreshTickProvider);
      return PaginatedListController<GisImportJob>(
        loadPage: ({required page, required limit}) {
          return ref
              .read(importsRepositoryProvider)
              .fetchImportsPage(
                status: query.status,
                projectId: query.projectId,
                categoryId: query.categoryId,
                page: page,
                limit: limit,
              );
        },
      );
    });

final paginatedImportFeaturesProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<ImportedFeature>,
      AsyncValue<PaginatedListState<ImportedFeature>>,
      ImportedFeatureListQuery
    >((ref, query) {
      ref.watch(workflowRefreshTickProvider);
      return PaginatedListController<ImportedFeature>(
        loadPage: ({required page, required limit}) {
          return ref
              .read(importsRepositoryProvider)
              .fetchImportFeaturesPage(
                importId: query.importId,
                status: query.status,
                issue: query.issue,
                page: page,
                limit: limit,
              );
        },
      );
    });
