import '../../../core/pagination/paginated_result.dart';
import 'ai_models.dart';

abstract class AiRepository {
  Future<AiReadinessResult> fetchReadiness({
    required String projectId,
    String? labelField,
    int? minSamplesPerClass,
    String? scopeType,
  });

  Future<AiProjectSettings> fetchSettings({required String projectId});

  Future<AiProjectSettings> saveSettings({
    required String projectId,
    required AiProjectSettings settings,
  });

  Future<PaginatedResult<AiRun>> fetchRunsPage({
    required String projectId,
    String? status,
    int page = 1,
    int limit = 20,
  });

  Future<AiRun> createRun({
    required String projectId,
    required String status,
    String? labelField,
    String? scopeType,
    int? minSamplesPerClass,
  });

  Future<AiRun> fetchRun({required String runId});

  Future<List<AiRunMetric>> fetchRunMetrics({required String runId});

  Future<List<AiOutputLayer>> fetchRunLayers({required String runId});

  Future<PaginatedResult<AiRunLog>> fetchRunLogsPage({
    required String runId,
    int page = 1,
    int limit = 20,
  });

  Future<List<AiReviewDecision>> fetchRunReviews({required String runId});

  Future<AiRunReviewResult> reviewRun({
    required String runId,
    required String action,
    String? reason,
  });
}
