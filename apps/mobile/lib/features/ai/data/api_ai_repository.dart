import 'package:dio/dio.dart';

import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_error_message.dart';
import '../../../core/pagination/paginated_result.dart';
import '../domain/ai_models.dart';
import '../domain/ai_repository.dart';

class ApiAiRepository implements AiRepository {
  ApiAiRepository(this._apiClient);

  final ApiClient _apiClient;

  String get _projectsBasePath => '${AppEnv.apiVersionPrefix}/projects';
  String get _aiBasePath => '${AppEnv.apiVersionPrefix}/ai';
  String get _meBasePath => '${AppEnv.apiVersionPrefix}/me';

  @override
  Future<AiReadinessResult> fetchReadiness({
    required String projectId,
    String? labelField,
    int? minSamplesPerClass,
    String? scopeType,
  }) async {
    final queryParameters = <String, dynamic>{};
    final normalizedLabelField = _nonEmpty(labelField);
    final normalizedScopeType = _nonEmpty(scopeType);
    if (normalizedLabelField != null) {
      queryParameters['label_field'] = normalizedLabelField;
    }
    if (minSamplesPerClass != null) {
      queryParameters['min_samples_per_class'] = minSamplesPerClass;
    }
    if (normalizedScopeType != null) {
      queryParameters['scope_type'] = normalizedScopeType;
    }

    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/readiness',
        queryParameters: queryParameters,
      );
      final payload = response.data ?? const <String, dynamic>{};
      final data = _toMap(payload['data']);
      return AiReadinessResult.fromResponse(data);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to check AI readiness right now.',
      );
    }
  }

  @override
  Future<AiProjectSettings> fetchSettings({required String projectId}) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/settings',
      );
      final payload = response.data ?? const <String, dynamic>{};
      return AiProjectSettings.fromMap(
        _toMap(payload['data']),
        projectId: projectId,
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load AI settings right now.',
      );
    }
  }

  @override
  Future<AiProjectSettings> saveSettings({
    required String projectId,
    required AiProjectSettings settings,
  }) async {
    try {
      final response = await _apiClient.dio.patch<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/settings',
        data: settings.toRequestBody(),
      );
      final payload = response.data ?? const <String, dynamic>{};
      return AiProjectSettings.fromMap(
        _toMap(payload['data']),
        projectId: projectId,
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to save AI settings right now.',
      );
    }
  }

  @override
  Future<void> saveGovernance({
    required String projectId,
    required bool trainingDataUseAuthorized,
    String? trainingAuthorityBasis,
    String? trainingApprovalReference,
    required bool publicationAuthorized,
    String? publicationAuthorityBasis,
    String? publicationApprovalReference,
  }) async {
    try {
      await _apiClient.dio.put<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/governance',
        data: <String, dynamic>{
          'training_data_use_authorized': trainingDataUseAuthorized,
          'training_authority_basis': trainingAuthorityBasis,
          'training_approval_reference': trainingApprovalReference,
          'publication_authorized': publicationAuthorized,
          'publication_authority_basis': publicationAuthorityBasis,
          'publication_approval_reference': publicationApprovalReference,
        },
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to save AI authority records right now.',
      );
    }
  }

  @override
  Future<PaginatedResult<AiRun>> fetchRunsPage({
    required String projectId,
    String? status,
    int page = 1,
    int limit = 20,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/runs',
        queryParameters: <String, dynamic>{
          'page': page,
          'limit': limit,
          if (status?.trim().isNotEmpty ?? false) 'status': status!.trim(),
        },
      );
      final payload = response.data ?? const <String, dynamic>{};
      final rows = (payload['data'] as List? ?? const <dynamic>[]);
      final items = rows
          .whereType<Map>()
          .map((row) => AiRun.fromMap(Map<String, dynamic>.from(row)))
          .toList(growable: false);
      final pagination = _toMap(payload['pagination']);
      final total = _toInt(pagination['total']) ?? items.length;
      final effectivePage = _toInt(pagination['page']) ?? page;
      final effectiveLimit = _toInt(pagination['limit']) ?? limit;
      return PaginatedResult<AiRun>(
        items: items,
        page: effectivePage,
        limit: effectiveLimit,
        total: total,
        hasMore:
            (pagination['has_more'] as bool?) ??
            ((effectivePage * effectiveLimit) < total && items.isNotEmpty),
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load AI runs right now.',
      );
    }
  }

  @override
  Future<AiRun> createRun({
    required String projectId,
    required String status,
    String? labelField,
    String? scopeType,
    int? minSamplesPerClass,
    String? executionMode,
  }) async {
    final data = <String, dynamic>{'status': status};
    final normalizedLabelField = _nonEmpty(labelField);
    final normalizedScopeType = _nonEmpty(scopeType);
    final normalizedExecutionMode = _nonEmpty(executionMode);
    if (normalizedLabelField != null) {
      data['label_field'] = normalizedLabelField;
    }
    if (normalizedScopeType != null) {
      data['scope_type'] = normalizedScopeType;
    }
    if (normalizedExecutionMode != null) {
      data['execution_mode'] = normalizedExecutionMode;
    }
    if (minSamplesPerClass != null) {
      data['min_samples_per_class'] = minSamplesPerClass;
    }

    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/runs',
        data: data,
      );
      final payload = response.data ?? const <String, dynamic>{};
      return AiRun.fromMap(_toMap(payload['data']));
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to create the AI run record right now.',
      );
    }
  }

  @override
  Future<AiRun> fetchRun({required String runId}) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_aiBasePath/runs/$runId',
      );
      final payload = response.data ?? const <String, dynamic>{};
      return AiRun.fromMap(_toMap(payload['data']));
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load the AI run right now.',
      );
    }
  }

  @override
  Future<AiRun> fetchRunStatus({
    required String projectId,
    required String runId,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/runs/$runId/status',
      );
      final payload = response.data ?? const <String, dynamic>{};
      return AiRun.fromMap(_toMap(payload['data']));
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to refresh the AI run status right now.',
      );
    }
  }

  @override
  Future<AiRun> cancelRun({
    required String projectId,
    required String runId,
  }) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/runs/$runId/cancel',
      );
      final payload = response.data ?? const <String, dynamic>{};
      return AiRun.fromMap(_toMap(payload['data']));
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to cancel the AI run right now.',
      );
    }
  }

  @override
  Future<AiRun> resumeRun({
    required String projectId,
    required String runId,
  }) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/runs/$runId/resume',
      );
      final payload = response.data ?? const <String, dynamic>{};
      return AiRun.fromMap(_toMap(payload['data']));
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to resume the AI run right now.',
      );
    }
  }

  @override
  Future<AiRetrainRecommendation> fetchRetrainRecommendation({
    required String projectId,
    String? runId,
  }) async {
    final path = runId?.trim().isNotEmpty ?? false
        ? '$_projectsBasePath/$projectId/ai/runs/${runId!.trim()}/retrain-check'
        : '$_projectsBasePath/$projectId/ai/retrain-check';
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(path);
      final payload = response.data ?? const <String, dynamic>{};
      return AiRetrainRecommendation.fromMap(_toMap(payload['data']));
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to check retraining recommendation right now.',
      );
    }
  }

  @override
  Future<List<AiRunMetric>> fetchRunMetrics({required String runId}) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_aiBasePath/runs/$runId/metrics',
      );
      return _rows(
        response.data,
      ).map((row) => AiRunMetric.fromMap(row)).toList(growable: false);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load AI metrics right now.',
      );
    }
  }

  @override
  Future<List<AiOutputLayer>> fetchRunLayers({required String runId}) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_aiBasePath/runs/$runId/layers',
      );
      return _rows(
        response.data,
      ).map((row) => AiOutputLayer.fromMap(row)).toList(growable: false);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load AI layers right now.',
      );
    }
  }

  @override
  Future<List<AiOutputLayer>> fetchPublishedProjectLayers({
    required String projectId,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/published-layers',
      );
      return _rows(
        response.data,
      ).map((row) => AiOutputLayer.fromMap(row)).toList(growable: false);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load published AI layers right now.',
      );
    }
  }

  @override
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
  }) async {
    try {
      final boundsValue = bounds?.trim();
      final queryParameters = <String, dynamic>{
        'detail': detail,
        'geometry': geometry,
      };
      if (boundsValue != null && boundsValue.isNotEmpty) {
        queryParameters['bounds'] = boundsValue;
      }
      if (zoom != null) {
        queryParameters['zoom'] = zoom.toStringAsFixed(2);
      }
      if (limit != null) {
        queryParameters['limit'] = limit;
      }
      if (page != null) {
        queryParameters['page'] = page;
      }
      final searchValue = search?.trim();
      if (searchValue != null && searchValue.isNotEmpty) {
        queryParameters['q'] = searchValue;
      }
      final classValue = classLabel?.trim();
      if (classValue != null && classValue.isNotEmpty) {
        queryParameters['class_label'] = classValue;
      }
      final featureIdValue = featureId?.trim();
      if (featureIdValue != null && featureIdValue.isNotEmpty) {
        queryParameters['feature_id'] = featureIdValue;
      }
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_aiBasePath/layers/$layerId/predictions',
        queryParameters: queryParameters,
      );
      final payload = response.data ?? const <String, dynamic>{};
      return AiLayerFeatureCollection.fromResponse(_toMap(payload['data']));
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load AI layer preview features right now.',
      );
    }
  }

  @override
  Future<PaginatedResult<AiRunLog>> fetchRunLogsPage({
    required String runId,
    int page = 1,
    int limit = 20,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_aiBasePath/runs/$runId/logs',
        queryParameters: <String, dynamic>{'page': page, 'limit': limit},
      );
      final payload = response.data ?? const <String, dynamic>{};
      final items = _rows(
        payload,
      ).map((row) => AiRunLog.fromMap(row)).toList(growable: false);
      final pagination = _toMap(payload['pagination']);
      final total = _toInt(pagination['total']) ?? items.length;
      final effectivePage = _toInt(pagination['page']) ?? page;
      final effectiveLimit = _toInt(pagination['limit']) ?? limit;
      return PaginatedResult<AiRunLog>(
        items: items,
        page: effectivePage,
        limit: effectiveLimit,
        total: total,
        hasMore:
            (pagination['has_more'] as bool?) ??
            ((effectivePage * effectiveLimit) < total && items.isNotEmpty),
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load AI run logs right now.',
      );
    }
  }

  @override
  Future<List<AiReviewDecision>> fetchRunReviews({
    required String runId,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_aiBasePath/runs/$runId/reviews',
      );
      return _rows(
        response.data,
      ).map((row) => AiReviewDecision.fromMap(row)).toList(growable: false);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load AI review decisions right now.',
      );
    }
  }

  @override
  Future<AiRunReviewResult> reviewRun({
    required String runId,
    required String action,
    String? reason,
  }) async {
    final data = <String, dynamic>{'action': action};
    final normalizedReason = _nonEmpty(reason);
    if (normalizedReason != null) {
      data['reason'] = normalizedReason;
    }

    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_aiBasePath/runs/$runId/review',
        data: data,
      );
      final payload = response.data ?? const <String, dynamic>{};
      return AiRunReviewResult.fromResponse(_toMap(payload['data']));
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to save AI review decision right now.',
      );
    }
  }

  @override
  Future<AiOutputLayer> publishLayer({required String layerId}) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_aiBasePath/layers/$layerId/publish',
      );
      final payload = response.data ?? const <String, dynamic>{};
      return AiOutputLayer.fromMap(_toMap(payload['data']));
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to publish this AI layer right now.',
      );
    }
  }

  @override
  Future<AiOutputLayer> unpublishLayer({required String layerId}) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_aiBasePath/layers/$layerId/unpublish',
      );
      final payload = response.data ?? const <String, dynamic>{};
      return AiOutputLayer.fromMap(_toMap(payload['data']));
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to unpublish this AI layer right now.',
      );
    }
  }

  @override
  Future<AiRun> publishRun({
    required String projectId,
    required String runId,
  }) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/runs/$runId/publish',
      );
      final payload = response.data ?? const <String, dynamic>{};
      return AiRun.fromMap(_toMap(_toMap(payload['data'])['run']));
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to publish this AI run right now.',
      );
    }
  }

  @override
  Future<AiRun> unpublishRun({
    required String projectId,
    required String runId,
  }) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/runs/$runId/unpublish',
      );
      final payload = response.data ?? const <String, dynamic>{};
      return AiRun.fromMap(_toMap(_toMap(payload['data'])['run']));
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to unpublish this AI run right now.',
      );
    }
  }

  @override
  Future<AiRunPredictionValidationSummary> fetchRunValidationSummary({
    required String projectId,
    required String runId,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/runs/$runId/validation-summary',
      );
      final payload = response.data ?? const <String, dynamic>{};
      return AiRunPredictionValidationSummary.fromMap(_toMap(payload['data']));
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load AI validation summary right now.',
      );
    }
  }

  @override
  Future<AiPredictionFeatureDetails> fetchPredictionDetails({
    required String projectId,
    required String runId,
    required String predictionId,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/runs/$runId/predictions/$predictionId',
      );
      final payload = response.data ?? const <String, dynamic>{};
      return AiPredictionFeatureDetails.fromMap(_toMap(payload['data']));
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load this AI prediction right now.',
      );
    }
  }

  @override
  Future<AiPredictionFeatureDetails> submitPredictionValidation({
    required String projectId,
    required String predictionId,
    required String validationResult,
    String? correctedClass,
    String? note,
    List<String> photoMediaIds = const <String>[],
    Map<String, dynamic>? gpsLocation,
    double? gpsAccuracyM,
  }) async {
    final normalizedCorrectedClass = _nonEmpty(correctedClass);
    final normalizedNote = _nonEmpty(note);
    final data = <String, dynamic>{'validation_result': validationResult};
    if (normalizedCorrectedClass != null) {
      data['corrected_class'] = normalizedCorrectedClass;
    }
    if (normalizedNote != null) {
      data['note'] = normalizedNote;
    }
    if (photoMediaIds.isNotEmpty) {
      data['photo_media_ids'] = photoMediaIds;
    }
    if (gpsLocation != null) {
      data['gps_location'] = gpsLocation;
    }
    if (gpsAccuracyM != null) {
      data['gps_accuracy_m'] = gpsAccuracyM;
    }
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/predictions/$predictionId/validations',
        data: data,
      );
      final payload = response.data ?? const <String, dynamic>{};
      return AiPredictionFeatureDetails.fromMap(_toMap(payload['data']));
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to submit this AI validation right now.',
      );
    }
  }

  @override
  Future<List<String>> uploadPredictionValidationPhotos({
    required String projectId,
    required String predictionId,
    required List<AiValidationPhotoUpload> photos,
  }) async {
    if (photos.isEmpty) {
      return const <String>[];
    }

    try {
      final files = await Future.wait(
        photos.map(
          (photo) async => MultipartFile.fromBytes(
            photo.bytes,
            filename: photo.fileName.trim().isEmpty
                ? 'validation-photo.jpg'
                : photo.fileName.trim(),
          ),
        ),
      );
      final formData = FormData.fromMap(<String, dynamic>{'photos': files});
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/predictions/$predictionId/validation-photos',
        data: formData,
        options: Options(
          headers: <String, dynamic>{'Content-Type': 'multipart/form-data'},
        ),
      );
      final payload = _toMap(response.data?['data']);
      final ids = _stringsFromList(payload['photo_media_ids']);
      if (ids.isNotEmpty) {
        return ids;
      }
      final photosPayload = payload['photos'];
      if (photosPayload is List) {
        return photosPayload
            .map((item) {
              final map = _toMap(item);
              return _nonEmpty(
                (map['id'] ?? map['url'] ?? map['photo_media_id'])?.toString(),
              );
            })
            .whereType<String>()
            .toList(growable: false);
      }
      return const <String>[];
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to upload validation photos right now.',
      );
    }
  }

  @override
  Future<List<AiPredictionFeatureValidation>> fetchPredictionValidations({
    required String projectId,
    required String predictionId,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/predictions/$predictionId/validations',
      );
      final payload = _toMap(response.data?['data']);
      final rows = payload['validations'];
      if (rows is! List) {
        return const <AiPredictionFeatureValidation>[];
      }
      return rows
          .map((row) => AiPredictionFeatureValidation.fromMap(_toMap(row)))
          .toList(growable: false);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load AI validation submissions right now.',
      );
    }
  }

  @override
  Future<AiPredictionFeatureDetails> reviewPredictionFeature({
    required String projectId,
    required String predictionId,
    required String approvalStatus,
    String? approvedClass,
    String? adminNote,
  }) async {
    final data = <String, dynamic>{
      'approval_status': approvalStatus,
      if (_nonEmpty(approvedClass) != null)
        'approved_class': _nonEmpty(approvedClass),
      if (_nonEmpty(adminNote) != null) 'admin_note': _nonEmpty(adminNote),
    };
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/predictions/$predictionId/admin-review',
        data: data,
      );
      final payload = response.data ?? const <String, dynamic>{};
      return AiPredictionFeatureDetails.fromMap(_toMap(payload['data']));
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to save this AI prediction review right now.',
      );
    }
  }

  @override
  Future<AiPredictionValidationTaskList> fetchMyValidationTasks({
    String? status,
    String? aiRunId,
    int page = 1,
    int limit = 50,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_meBasePath/ai-validation-tasks',
        queryParameters: _validationTaskQueryParameters(
          status: status,
          aiRunId: aiRunId,
          page: page,
          limit: limit,
        ),
      );
      return AiPredictionValidationTaskList.fromResponse(
        response.data ?? const <String, dynamic>{},
        fallbackPage: page,
        fallbackLimit: limit,
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load AI validation tasks right now.',
      );
    }
  }

  @override
  Future<AiPredictionValidationTaskList> fetchProjectValidationTasks({
    required String projectId,
    String? status,
    String? assignedTo,
    String? aiRunId,
    int page = 1,
    int limit = 50,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/prediction-validation-tasks',
        queryParameters: _validationTaskQueryParameters(
          status: status,
          assignedTo: assignedTo,
          aiRunId: aiRunId,
          page: page,
          limit: limit,
        ),
      );
      return AiPredictionValidationTaskList.fromResponse(
        response.data ?? const <String, dynamic>{},
        fallbackPage: page,
        fallbackLimit: limit,
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load AI validation tasks right now.',
      );
    }
  }

  @override
  Future<AiPredictionValidationGenerateResult> generateValidationTasks({
    required String projectId,
    String? aiRunId,
    String? aiOutputLayerId,
    String? aiPredictionFeatureId,
    double? confidenceThreshold,
    int? limit,
    int? priority,
  }) async {
    final data = <String, dynamic>{
      if (_nonEmpty(aiRunId) != null) 'ai_run_id': _nonEmpty(aiRunId),
      if (_nonEmpty(aiOutputLayerId) != null)
        'ai_output_layer_id': _nonEmpty(aiOutputLayerId),
      if (_nonEmpty(aiPredictionFeatureId) != null)
        'ai_prediction_feature_id': _nonEmpty(aiPredictionFeatureId),
    };
    if (confidenceThreshold != null) {
      data['confidence_threshold'] = confidenceThreshold;
    }
    if (limit != null) {
      data['limit'] = limit;
    }
    if (priority != null) {
      data['priority'] = priority;
    }

    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_projectsBasePath/$projectId/ai/prediction-validation-tasks/generate',
        data: data,
      );
      final payload = response.data ?? const <String, dynamic>{};
      return AiPredictionValidationGenerateResult.fromMap(
        _toMap(payload['data']),
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to generate AI validation tasks right now.',
      );
    }
  }

  @override
  Future<AiPredictionValidationTask> fetchValidationTask({
    required String taskId,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_aiBasePath/prediction-validation-tasks/$taskId',
      );
      final payload = response.data ?? const <String, dynamic>{};
      return AiPredictionValidationTask.fromMap(_toMap(payload['data']));
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to load this AI validation task right now.',
      );
    }
  }

  @override
  Future<AiPredictionValidationTask> assignValidationTask({
    required String taskId,
    required String assignedTo,
  }) async {
    try {
      final response = await _apiClient.dio.patch<Map<String, dynamic>>(
        '$_aiBasePath/prediction-validation-tasks/$taskId/assign',
        data: <String, dynamic>{'assigned_to': assignedTo.trim()},
      );
      return _taskFromActionPayload(response.data);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to assign this AI validation task right now.',
      );
    }
  }

  @override
  Future<AiPredictionValidationTask> updateValidationTaskStatus({
    required String taskId,
    required String status,
  }) async {
    try {
      final response = await _apiClient.dio.patch<Map<String, dynamic>>(
        '$_aiBasePath/prediction-validation-tasks/$taskId/status',
        data: <String, dynamic>{'status': status.trim()},
      );
      return _taskFromActionPayload(response.data);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to update this AI validation task right now.',
      );
    }
  }

  @override
  Future<AiPredictionValidationTask> submitValidationTask({
    required String taskId,
    required String result,
    String? correctedClass,
    required String note,
    Map<String, dynamic> evidence = const <String, dynamic>{},
    String? linkedFeatureId,
  }) async {
    final data = <String, dynamic>{
      'result': result,
      'note': note.trim(),
      'evidence': evidence,
      if (_nonEmpty(correctedClass) != null)
        'corrected_class': _nonEmpty(correctedClass),
      if (_nonEmpty(linkedFeatureId) != null)
        'linked_feature_id': _nonEmpty(linkedFeatureId),
    };

    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_aiBasePath/prediction-validation-tasks/$taskId/submissions',
        data: data,
      );
      return _taskFromNestedTaskPayload(response.data);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to submit this AI validation task right now.',
      );
    }
  }

  @override
  Future<AiPredictionValidationTask> reviewValidationTask({
    required String taskId,
    required String decision,
    String? reason,
    String? submissionId,
  }) async {
    final data = <String, dynamic>{
      'decision': decision,
      if (_nonEmpty(reason) != null) 'reason': _nonEmpty(reason),
      if (_nonEmpty(submissionId) != null)
        'submission_id': _nonEmpty(submissionId),
    };

    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '$_aiBasePath/prediction-validation-tasks/$taskId/review',
        data: data,
      );
      return _taskFromNestedTaskPayload(response.data);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback: 'Unable to review this AI validation task right now.',
      );
    }
  }

  Map<String, dynamic> _validationTaskQueryParameters({
    String? status,
    String? assignedTo,
    String? aiRunId,
    int page = 1,
    int limit = 50,
  }) {
    return <String, dynamic>{
      'page': page,
      'limit': limit,
      if (_nonEmpty(status) != null) 'status': _nonEmpty(status),
      if (_nonEmpty(assignedTo) != null) 'assigned_to': _nonEmpty(assignedTo),
      if (_nonEmpty(aiRunId) != null) 'ai_run_id': _nonEmpty(aiRunId),
    };
  }

  AiPredictionValidationTask _taskFromActionPayload(
    Map<String, dynamic>? payload,
  ) {
    final data = _toMap((payload ?? const <String, dynamic>{})['data']);
    return AiPredictionValidationTask.fromMap(data);
  }

  AiPredictionValidationTask _taskFromNestedTaskPayload(
    Map<String, dynamic>? payload,
  ) {
    final data = _toMap((payload ?? const <String, dynamic>{})['data']);
    return AiPredictionValidationTask.fromMap(_toMap(data['task']));
  }

  List<Map<String, dynamic>> _rows(Map<String, dynamic>? payload) {
    final rows = (payload ?? const <String, dynamic>{})['data'] as List?;
    return (rows ?? const <dynamic>[])
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  Map<String, dynamic> _toMap(dynamic raw) {
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    return const <String, dynamic>{};
  }

  List<String> _stringsFromList(dynamic raw) {
    if (raw is! List) {
      return const <String>[];
    }
    return raw
        .map((item) => item?.toString().trim())
        .whereType<String>()
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  int? _toInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }
}
