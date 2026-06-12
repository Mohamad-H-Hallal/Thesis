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
        '$_aiBasePath/layers/$layerId/features',
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
