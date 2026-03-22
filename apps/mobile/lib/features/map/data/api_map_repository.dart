import 'package:dio/dio.dart';

import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';
import '../domain/map_feature.dart';

class ApiMapRepository {
  ApiMapRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<List<MapFeatureSummary>> fetchProjectFeatures(String projectId) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '${AppEnv.apiVersionPrefix}/projects/$projectId/features',
        queryParameters: const <String, dynamic>{'limit': 100},
      );

      final payload = response.data ?? const <String, dynamic>{};
      final rows = (payload['data'] as List? ?? const <dynamic>[]);

      return rows
          .map((row) {
            final item = Map<String, dynamic>.from(row as Map);
            return MapFeatureSummary(
              id: (item['id'] as String?) ?? '',
              status: (item['status'] as String?) ?? 'draft',
              geometry: Map<String, dynamic>.from(
                item['geometry'] as Map? ?? const <String, dynamic>{},
              ),
              attributes: Map<String, dynamic>.from(
                item['attributes'] as Map? ?? const <String, dynamic>{},
              ),
              collectedBy: item['collected_by'] as String?,
              reviewedBy: item['reviewed_by'] as String?,
              reviewNotes: item['review_notes'] as String?,
              accuracyMeters: _toDouble(item['accuracy_meters']),
              collectedAt: _toDateTime(item['collected_at']),
              submittedAt: _toDateTime(item['submitted_at']),
              reviewedAt: _toDateTime(item['reviewed_at']),
              photoCount: _toInt(item['photo_count']) ?? 0,
              photos: ((item['photos'] as List?) ?? const <dynamic>[])
                  .map((raw) => _toPhoto(Map<String, dynamic>.from(raw as Map)))
                  .toList(growable: false),
            );
          })
          .toList(growable: false);
    } on DioException catch (error) {
      final message = error.response?.data is Map<String, dynamic>
          ? (error.response?.data as Map<String, dynamic>)['message']
                    as String? ??
                'Map features request failed.'
          : 'Map features request failed.';
      throw Exception(message);
    }
  }

  MapFeaturePhoto _toPhoto(Map<String, dynamic> item) {
    return MapFeaturePhoto(
      id: (item['id'] as String?) ?? '',
      filePath: (item['file_path'] as String?) ?? '',
      thumbnailPath: item['thumbnail_path'] as String?,
      status: item['status'] as String?,
      takenAt: _toDateTime(item['taken_at']),
      displayOrder: _toInt(item['display_order']),
    );
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

  double? _toDouble(dynamic value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  DateTime? _toDateTime(dynamic value) {
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value);
    }
    return value is DateTime ? value : null;
  }
}
