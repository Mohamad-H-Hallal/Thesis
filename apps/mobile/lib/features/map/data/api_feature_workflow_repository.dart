import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_error_message.dart';
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
    required bool collectedOffline,
  }) async {
    try {
      final payload = <String, dynamic>{
        'project_id': projectId,
        'geom': geometry,
        'attributes': attributes,
        'collected_offline': collectedOffline,
      };

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
  Future<void> deleteDraft(String featureId) async {
    try {
      await _apiClient.dio.delete<Map<String, dynamic>>(
        '$_featuresBasePath/$featureId',
      );
    } on DioException catch (error) {
      throw Exception(_messageFrom(error, 'Feature draft deletion failed.'));
    }
  }

  @override
  Future<void> uploadPhotos({
    required String featureId,
    required List<FeaturePhotoUpload> photos,
  }) async {
    if (photos.isEmpty) {
      return;
    }

    try {
      final files = await Future.wait(
        photos.map(
          (photo) async => photo.bytes == null
              ? MultipartFile.fromFile(
                  photo.filePath,
                  filename: photo.fileName.isEmpty
                      ? p.basename(photo.filePath)
                      : photo.fileName,
                )
              : MultipartFile.fromBytes(
                  photo.bytes!,
                  filename: photo.fileName.isEmpty
                      ? p.basename(photo.filePath)
                      : photo.fileName,
                ),
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
    return userFacingErrorMessage(error, fallback: fallback);
  }
}
