import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/pagination/paginated_list_controller.dart';
import '../../../core/providers/providers.dart';
import '../../map/domain/map_feature.dart';
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

final importDetailsProvider = FutureProvider.autoDispose
    .family<GisImportDetails, String>((ref, importId) async {
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

typedef ImportMapData =
    ({
      List<ImportedFeature> stagedFeatures,
      List<MapFeatureSummary> approvedProjectFeatures,
    });

final importMapDataProvider =
    FutureProvider.autoDispose.family<ImportMapData, ImportMapQuery>((
      ref,
      query,
    ) async {
      ref.watch(workflowRefreshTickProvider);
      final importsRepository = ref.read(importsRepositoryProvider);
      final mapRepository = ref.read(mapRepositoryProvider);
      const pageLimit = 200;

      final stagedFeatures = <ImportedFeature>[];
      var stagedPage = 1;
      var stagedHasMore = true;
      while (stagedHasMore) {
        final result = await importsRepository.fetchImportFeaturesPage(
          importId: query.importId,
          page: stagedPage,
          limit: pageLimit,
        );
        stagedFeatures.addAll(result.items);
        stagedHasMore = result.hasMore;
        stagedPage += 1;
      }

      final approvedProjectFeatures = <MapFeatureSummary>[];
      var approvedPage = 1;
      var approvedHasMore = true;
      while (approvedHasMore) {
        final result = await mapRepository.fetchProjectFeaturesPage(
          projectId: query.projectId,
          status: 'approved',
          page: approvedPage,
          limit: pageLimit,
        );
        approvedProjectFeatures.addAll(result.items);
        approvedHasMore = result.hasMore;
        approvedPage += 1;
      }

      return (
        stagedFeatures: stagedFeatures,
        approvedProjectFeatures: approvedProjectFeatures,
      );
    });
