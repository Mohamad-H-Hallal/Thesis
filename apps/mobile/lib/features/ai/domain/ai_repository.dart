import '../../../core/pagination/paginated_result.dart';
import 'ai_models.dart';

class AiValidationPhotoUpload {
  const AiValidationPhotoUpload({required this.fileName, required this.bytes});

  final String fileName;
  final List<int> bytes;
}

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
    String? executionMode,
  });

  Future<AiRun> fetchRun({required String runId});

  Future<AiRun> fetchRunStatus({
    required String projectId,
    required String runId,
  });

  Future<AiRun> cancelRun({required String projectId, required String runId});

  Future<AiRun> resumeRun({required String projectId, required String runId});

  Future<AiRetrainRecommendation> fetchRetrainRecommendation({
    required String projectId,
    String? runId,
  });

  Future<List<AiRunMetric>> fetchRunMetrics({required String runId});

  Future<List<AiOutputLayer>> fetchRunLayers({required String runId});

  Future<List<AiOutputLayer>> fetchPublishedProjectLayers({
    required String projectId,
  });

  Future<AiLayerFeatureCollection> fetchLayerFeatures({
    required String layerId,
    String detail = 'overview',
    String geometry = 'simplified',
    String? bounds,
    double? zoom,
    int? limit,
    int? page,
    String? search,
    String? classLabel,
    String? featureId,
  });

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

  Future<AiOutputLayer> publishLayer({required String layerId});

  Future<AiOutputLayer> unpublishLayer({required String layerId});

  Future<AiRun> publishRun({required String projectId, required String runId});

  Future<AiRun> unpublishRun({
    required String projectId,
    required String runId,
  });

  Future<AiRunPredictionValidationSummary> fetchRunValidationSummary({
    required String projectId,
    required String runId,
  });

  Future<AiPredictionFeatureDetails> fetchPredictionDetails({
    required String projectId,
    required String runId,
    required String predictionId,
  });

  Future<AiPredictionFeatureDetails> submitPredictionValidation({
    required String projectId,
    required String predictionId,
    required String validationResult,
    String? correctedClass,
    String? note,
    List<String> photoMediaIds = const <String>[],
    Map<String, dynamic>? gpsLocation,
    double? gpsAccuracyM,
  });

  Future<List<String>> uploadPredictionValidationPhotos({
    required String projectId,
    required String predictionId,
    required List<AiValidationPhotoUpload> photos,
  });

  Future<List<AiPredictionFeatureValidation>> fetchPredictionValidations({
    required String projectId,
    required String predictionId,
  });

  Future<AiPredictionFeatureDetails> reviewPredictionFeature({
    required String projectId,
    required String predictionId,
    required String approvalStatus,
    String? approvedClass,
    String? adminNote,
  });

  Future<AiPredictionValidationTaskList> fetchMyValidationTasks({
    String? status,
    String? aiRunId,
    int page = 1,
    int limit = 50,
  });

  Future<AiPredictionValidationTaskList> fetchProjectValidationTasks({
    required String projectId,
    String? status,
    String? assignedTo,
    String? aiRunId,
    int page = 1,
    int limit = 50,
  });

  Future<AiPredictionValidationGenerateResult> generateValidationTasks({
    required String projectId,
    String? aiRunId,
    String? aiOutputLayerId,
    String? aiPredictionFeatureId,
    double? confidenceThreshold,
    int? limit,
    int? priority,
  });

  Future<AiPredictionValidationTask> fetchValidationTask({
    required String taskId,
  });

  Future<AiPredictionValidationTask> assignValidationTask({
    required String taskId,
    required String assignedTo,
  });

  Future<AiPredictionValidationTask> updateValidationTaskStatus({
    required String taskId,
    required String status,
  });

  Future<AiPredictionValidationTask> submitValidationTask({
    required String taskId,
    required String result,
    String? correctedClass,
    required String note,
    Map<String, dynamic> evidence = const <String, dynamic>{},
    String? linkedFeatureId,
  });

  Future<AiPredictionValidationTask> reviewValidationTask({
    required String taskId,
    required String decision,
    String? reason,
    String? submissionId,
  });
}
