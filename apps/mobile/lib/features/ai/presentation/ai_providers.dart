import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/pagination/paginated_result.dart';
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
