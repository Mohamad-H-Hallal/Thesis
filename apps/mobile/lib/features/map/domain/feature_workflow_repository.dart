import 'feature_workflow.dart';

class FeaturePhotoUpload {
  const FeaturePhotoUpload({
    required this.filePath,
    required this.fileName,
    this.bytes,
  });

  final String filePath;
  final String fileName;
  final List<int>? bytes;
}

abstract class FeatureWorkflowRepository {
  Future<CreatedFeatureDraft> createDraft({
    required String projectId,
    required Map<String, dynamic> geometry,
    required Map<String, dynamic> attributes,
    required bool collectedOffline,
  });

  Future<void> updateDraft({
    required String featureId,
    required Map<String, dynamic> geometry,
    required Map<String, dynamic> attributes,
  });

  Future<void> deleteDraft(String featureId);

  Future<void> uploadPhotos({
    required String featureId,
    required List<FeaturePhotoUpload> photos,
  });

  Future<void> submitForReview(String featureId);
}
