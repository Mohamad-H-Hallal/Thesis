import 'package:dio/dio.dart';

import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';
import '../../../core/pagination/paginated_result.dart';
import '../domain/review_item.dart';
import '../domain/review_repository.dart';

class ApiReviewRepository implements ReviewRepository {
  ApiReviewRepository(this._apiClient);

  final ApiClient _apiClient;

  String get _featuresBasePath => '${AppEnv.apiVersionPrefix}/features';

  @override
  Future<List<ReviewQueueItem>> fetchReviewItems({
    required String status,
    String? projectId,
  }) async {
    final page = await fetchReviewItemsPage(
      status: status,
      projectId: projectId,
      limit: 100,
    );
    return page.items;
  }

  @override
  Future<PaginatedResult<ReviewQueueItem>> fetchReviewItemsPage({
    required String status,
    String? projectId,
    int page = 1,
    int limit = 20,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        _featuresBasePath,
        queryParameters: <String, dynamic>{
          'status': status,
          if (projectId != null && projectId.trim().isNotEmpty)
            'project_id': projectId.trim(),
          'page': page,
          'limit': limit,
        },
      );

      final payload = response.data ?? const <String, dynamic>{};
      final rows = (payload['data'] as List? ?? const <dynamic>[]);

      final items = rows
          .map((row) {
            final item = Map<String, dynamic>.from(row as Map);
            final geometry = Map<String, dynamic>.from(
              item['geometry'] as Map? ?? const <String, dynamic>{},
            );

            return ReviewQueueItem(
              id: (item['id'] as String?) ?? '',
              projectId: (item['project_id'] as String?) ?? '',
              projectName: (item['project_name'] as String?) ?? 'Project',
              geometryType: (geometry['type'] as String?) ?? 'Point',
              status: (item['status'] as String?) ?? status,
              collectedBy: item['collected_by'] as String?,
              collectedAt: DateTime.tryParse(
                item['collected_at'] as String? ?? '',
              ),
              photoCount: _toInt(item['photo_count']) ?? 0,
            );
          })
          .toList(growable: false);
      final pagination = Map<String, dynamic>.from(
        payload['pagination'] as Map? ?? const <String, dynamic>{},
      );
      final total = (pagination['total'] as num?)?.toInt() ?? items.length;
      final hasMore =
          (pagination['has_more'] as bool?) ??
          ((page * limit) < total && items.isNotEmpty);
      return PaginatedResult<ReviewQueueItem>(
        items: items,
        page: (pagination['page'] as num?)?.toInt() ?? page,
        limit: (pagination['limit'] as num?)?.toInt() ?? limit,
        total: total,
        hasMore: hasMore,
      );
    } on DioException catch (error) {
      throw _messageFrom(error, 'Review queue request failed.');
    }
  }

  @override
  Future<void> reviewFeature({
    required String featureId,
    required String status,
    String? reviewNotes,
  }) async {
    try {
      await _apiClient.dio.post<Map<String, dynamic>>(
        '$_featuresBasePath/$featureId/review',
        data: <String, dynamic>{
          'status': status,
          'review_notes': reviewNotes?.trim(),
        },
      );
    } on DioException catch (error) {
      throw _messageFrom(error, 'Feature review update failed.');
    }
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

  String _messageFrom(DioException error, String fallback) {
    final data = error.response?.data;
    if (data is Map<String, dynamic>) {
      final message = data['message'] ?? data['error'];
      if (message is String && message.trim().isNotEmpty) {
        return message.trim();
      }
    }
    if (data is String && data.trim().isNotEmpty) {
      return data.trim();
    }
    return fallback;
  }
}
