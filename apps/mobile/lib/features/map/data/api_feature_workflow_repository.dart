import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';
import '../domain/feature_workflow.dart';
import '../domain/feature_workflow_repository.dart';

class ApiFeatureWorkflowRepository implements FeatureWorkflowRepository {
  ApiFeatureWorkflowRepository(this._apiClient);

  final ApiClient _apiClient;

  String get _featuresBasePath => '${AppEnv.apiVersionPrefix}/features';
  String get _photosBasePath => '${AppEnv.apiVersionPrefix}/photos';

  @override
  Future<CreatedFeatureDraft> createDraft({
    required String projectId,
    required Map<String, dynamic> geometry,
    required Map<String, dynamic> attributes,
    double? accuracyMeters,
    required bool collectedOffline,
  }) async {
    try {
      final payload = <String, dynamic>{
        'project_id': projectId,
        'geom': geometry,
        'attributes': attributes,
        'collected_offline': collectedOffline,
      };
      if (accuracyMeters != null) {
        payload['accuracy_meters'] = accuracyMeters;
      }

      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        _featuresBasePath,
        data: payload,
      );

      final data = Map<String, dynamic>.from(
        (response.data ?? const <String, dynamic>{})['data'] as Map? ??
            const <String, dynamic>{},
      );

      return CreatedFeatureDraft(
        id: (data['id'] as String?) ?? '',
        status: (data['status'] as String?) ?? 'draft',
        projectId: projectId,
      );
    } on DioException catch (error) {
      throw Exception(_messageFrom(error, 'Feature draft creation failed.'));
    }
  }

  @override
  Future<void> updateDraft({
    required String featureId,
    required Map<String, dynamic> geometry,
    required Map<String, dynamic> attributes,
  }) async {
    try {
      await _apiClient.dio.put<Map<String, dynamic>>(
        '$_featuresBasePath/$featureId',
        data: <String, dynamic>{'geom': geometry, 'attributes': attributes},
      );
    } on DioException catch (error) {
      throw Exception(_messageFrom(error, 'Feature draft update failed.'));
    }
  }

  @override
  Future<void> uploadPhotos({
    required String featureId,
    required List<String> filePaths,
  }) async {
    if (filePaths.isEmpty) {
      return;
    }

    try {
      final files = await Future.wait(
        filePaths.map(
          (filePath) async =>
              MultipartFile.fromFile(filePath, filename: p.basename(filePath)),
        ),
      );

      final formData = FormData.fromMap(<String, dynamic>{'photos': files});
      await _apiClient.dio.post<Map<String, dynamic>>(
        '$_photosBasePath/feature/$featureId',
        data: formData,
        options: Options(
          headers: <String, dynamic>{'Content-Type': 'multipart/form-data'},
        ),
      );
    } on DioException catch (error) {
      throw Exception(_messageFrom(error, 'Photo upload failed.'));
    }
  }

  @override
  Future<void> submitForReview(String featureId) async {
    try {
      await _apiClient.dio.post<Map<String, dynamic>>(
        '$_featuresBasePath/$featureId/submit',
      );
    } on DioException catch (error) {
      throw Exception(_messageFrom(error, 'Feature submission failed.'));
    }
  }

  String _messageFrom(DioException error, String fallback) {
    final data = error.response?.data;
    if (data is Map<String, dynamic>) {
      final fieldMessage = _extractFirstFieldError(data['errors']);
      final message = data['message'] ?? data['error'];
      if (message is String && message.trim().isNotEmpty) {
        final trimmed = message.trim();
        if (trimmed.toLowerCase() == 'validation failed' &&
            fieldMessage != null) {
          return fieldMessage;
        }
        return trimmed;
      }
      if (fieldMessage != null) {
        return fieldMessage;
      }
    }
    if (data is String && data.trim().isNotEmpty) {
      return data.trim();
    }
    return fallback;
  }

  String? _extractFirstFieldError(Object? errors) {
    if (errors is! List) {
      return null;
    }

    for (final item in errors) {
      if (item is! Map) {
        continue;
      }
      final raw = Map<String, dynamic>.from(item);
      final message = raw['message'] ?? raw['msg'];
      if (message is String && message.trim().isNotEmpty) {
        return message.trim();
      }
    }

    return null;
  }
}
