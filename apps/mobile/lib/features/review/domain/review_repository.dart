import 'review_item.dart';

abstract class ReviewRepository {
  Future<List<ReviewQueueItem>> fetchReviewItems({required String status});

  Future<void> reviewFeature({
    required String featureId,
    required String status,
    String? reviewNotes,
  });
}
