import 'feature_workflow.dart';

abstract class FeatureWorkflowRepository {
  Future<CreatedFeatureDraft> createDraft({
    required String projectId,
    required Map<String, dynamic> geometry,
    required Map<String, dynamic> attributes,
    double? accuracyMeters,
    required bool collectedOffline,
  });

  Future<void> updateDraft({
    required String featureId,
    required Map<String, dynamic> geometry,
    required Map<String, dynamic> attributes,
  });

  Future<void> uploadPhotos({
    required String featureId,
    required List<String> filePaths,
  });

  Future<void> submitForReview(String featureId);
}
