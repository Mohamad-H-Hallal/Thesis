import 'package:dio/dio.dart';

import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';
import '../domain/review_item.dart';
import '../domain/review_repository.dart';

class ApiReviewRepository implements ReviewRepository {
  ApiReviewRepository(this._apiClient);

  final ApiClient _apiClient;

  String get _featuresBasePath => '${AppEnv.apiVersionPrefix}/features';

  @override
  Future<List<ReviewQueueItem>> fetchPendingReviewItems() async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        _featuresBasePath,
        queryParameters: const <String, dynamic>{
          'status': 'pending_review',
          'limit': 100,
        },
      );

      final payload = response.data ?? const <String, dynamic>{};
      final rows = (payload['data'] as List? ?? const <dynamic>[]);

      return rows.map((row) {
        final item = Map<String, dynamic>.from(row as Map);
        final geometry = Map<String, dynamic>.from(
          item['geometry'] as Map? ?? const <String, dynamic>{},
        );

        return ReviewQueueItem(
          id: (item['id'] as String?) ?? '',
          projectId: (item['project_id'] as String?) ?? '',
          projectName: (item['project_name'] as String?) ?? 'Project',
          geometryType: (geometry['type'] as String?) ?? 'Point',
          status: (item['status'] as String?) ?? 'pending_review',
          collectedBy: item['collected_by'] as String?,
          collectedAt: DateTime.tryParse(item['collected_at'] as String? ?? ''),
          photoCount: _toInt(item['photo_count']) ?? 0,
        );
      }).toList(growable: false);
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
