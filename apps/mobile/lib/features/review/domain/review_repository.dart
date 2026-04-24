import '../../../core/pagination/paginated_result.dart';
import 'review_item.dart';

abstract class ReviewRepository {
  Future<List<ReviewQueueItem>> fetchReviewItems({
    required String status,
    String? projectId,
  });

  Future<PaginatedResult<ReviewQueueItem>> fetchReviewItemsPage({
    required String status,
    String? projectId,
    int page = 1,
    int limit = 20,
  });

  Future<void> reviewFeature({
    required String featureId,
    required String status,
    String? reviewNotes,
  });
}
