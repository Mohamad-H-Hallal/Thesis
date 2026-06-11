import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/pagination/paginated_result.dart';
import '../../../core/pagination/paginated_list_controller.dart';
import '../../../core/providers/providers.dart';
import '../data/api_ai_repository.dart';
import '../domain/ai_models.dart';
import '../domain/ai_repository.dart';

final aiRepositoryProvider = Provider<AiRepository>((ref) {
  return ApiAiRepository(ref.watch(apiClientProvider));
});

final aiSettingsProvider = FutureProvider.family<AiProjectSettings, String>((
  ref,
  projectId,
) async {
  ref.watch(workflowRefreshTickProvider);
  return ref.read(aiRepositoryProvider).fetchSettings(projectId: projectId);
});

final aiReadinessProvider =
    FutureProvider.family<AiReadinessResult, AiReadinessQuery>((
      ref,
      query,
    ) async {
      ref.watch(workflowRefreshTickProvider);
      return ref
          .read(aiRepositoryProvider)
          .fetchReadiness(
            projectId: query.projectId,
            labelField: query.labelField,
            minSamplesPerClass: query.minSamplesPerClass,
            scopeType: query.scopeType,
          );
    });

final aiRunsProvider =
    FutureProvider.family<PaginatedResult<AiRun>, AiRunsQuery>((
      ref,
      query,
    ) async {
      ref.watch(workflowRefreshTickProvider);
      return ref
          .read(aiRepositoryProvider)
          .fetchRunsPage(
            projectId: query.projectId,
            status: query.status,
            page: query.page,
            limit: query.limit,
          );
    });

final aiRunProvider = FutureProvider.family<AiRun, String>((ref, runId) async {
  ref.watch(workflowRefreshTickProvider);
  return ref.read(aiRepositoryProvider).fetchRun(runId: runId);
});

final aiRunMetricsProvider = FutureProvider.family<List<AiRunMetric>, String>((
  ref,
  runId,
) async {
  ref.watch(workflowRefreshTickProvider);
  return ref.read(aiRepositoryProvider).fetchRunMetrics(runId: runId);
});

final aiRunLayersProvider = FutureProvider.family<List<AiOutputLayer>, String>((
  ref,
  runId,
) async {
  ref.watch(workflowRefreshTickProvider);
  return ref.read(aiRepositoryProvider).fetchRunLayers(runId: runId);
});

final publishedAiLayersProvider =
    FutureProvider.family<List<AiOutputLayer>, String>((ref, projectId) async {
      ref.watch(workflowRefreshTickProvider);
      if (projectId.trim().isEmpty) {
        return const <AiOutputLayer>[];
      }
      return ref
          .read(aiRepositoryProvider)
          .fetchPublishedProjectLayers(projectId: projectId);
    });

final aiLayerFeaturesProvider =
    FutureProvider.family<AiLayerFeatureCollection, AiLayerFeaturesQuery>((
      ref,
      query,
    ) async {
      return ref
          .read(aiRepositoryProvider)
          .fetchLayerFeatures(
            layerId: query.layerId,
            detail: query.detail,
            geometry: query.geometry,
            bounds: query.bounds,
            zoom: query.zoom,
            limit: query.limit,
            page: query.page,
            search: query.search,
            classLabel: query.classLabel,
            featureId: query.featureId,
          );
    });

final paginatedAiLayerFeatureBrowserProvider = StateNotifierProvider.autoDispose
    .family<
      PaginatedListController<AiLayerFeature>,
      AsyncValue<PaginatedListState<AiLayerFeature>>,
      AiLayerFeatureBrowserQuery
    >((ref, query) {
      return PaginatedListController<AiLayerFeature>(
        loadPage: ({required page, required limit}) async {
          final collection = await ref
              .read(aiRepositoryProvider)
              .fetchLayerFeatures(
                layerId: query.layerId,
                detail: 'overview',
                geometry: 'simplified',
                page: page,
                limit: limit,
                zoom: 14,
                search: query.search,
                classLabel: query.classLabel,
              );
          return PaginatedResult<AiLayerFeature>(
            items: collection.features,
            page: page,
            limit: limit,
            total: collection.matchingFeatureCount,
            hasMore: page * limit < collection.matchingFeatureCount,
          );
        },
      );
    });

final aiRunLogsProvider =
    FutureProvider.family<PaginatedResult<AiRunLog>, String>((
      ref,
      runId,
    ) async {
      ref.watch(workflowRefreshTickProvider);
      return ref.read(aiRepositoryProvider).fetchRunLogsPage(runId: runId);
    });

final aiRunReviewsProvider =
    FutureProvider.family<List<AiReviewDecision>, String>((ref, runId) async {
      ref.watch(workflowRefreshTickProvider);
      return ref.read(aiRepositoryProvider).fetchRunReviews(runId: runId);
    });
