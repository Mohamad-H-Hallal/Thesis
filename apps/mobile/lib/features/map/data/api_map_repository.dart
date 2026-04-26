import 'package:dio/dio.dart';

import '../../../core/offline/local_models.dart';
import '../../../core/config/app_env.dart';
import '../../../core/network/api_error_message.dart';
import '../../../core/network/api_client.dart';
import '../../../core/pagination/paginated_result.dart';
import '../domain/map_feature.dart';

class ApiMapRepository {
  ApiMapRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<List<MapFeatureSummary>> fetchProjectFeatures(String projectId) async {
    final page = await fetchProjectFeaturesPage(projectId: projectId, limit: 100);
    return page.items;
  }

  Future<PaginatedResult<MapFeatureSummary>> fetchProjectFeaturesPage({
    required String projectId,
    String? search,
    String? status,
    String? geometryType,
    int page = 1,
    int limit = 20,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '${AppEnv.apiVersionPrefix}/projects/$projectId/features',
        queryParameters: <String, dynamic>{
          'page': page,
          'limit': limit,
          if (search?.trim().isNotEmpty ?? false) 'q': search!.trim(),
          if (status?.trim().isNotEmpty ?? false) 'status': status!.trim(),
          if (geometryType?.trim().isNotEmpty ?? false)
            'geometry_type': geometryType!.trim(),
        },
      );

      final payload = response.data ?? const <String, dynamic>{};
      final rows = (payload['data'] as List? ?? const <dynamic>[]);
      final pagination = Map<String, dynamic>.from(
        payload['pagination'] as Map? ?? const <String, dynamic>{},
      );

      final items = rows
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
      final total = (pagination['total'] as num?)?.toInt() ?? items.length;
      final hasMore =
          (pagination['has_more'] as bool?) ??
          ((page * limit) < total && items.isNotEmpty);
      return PaginatedResult<MapFeatureSummary>(
        items: items,
        page: (pagination['page'] as num?)?.toInt() ?? page,
        limit: (pagination['limit'] as num?)?.toInt() ?? limit,
        total: total,
        hasMore: hasMore,
      );
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback:
            'Unable to load project features right now. Please try again.',
      );
    }
  }

  Future<OfflineMapPackage?> fetchCurrentOfflineMapPackage() async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '${AppEnv.apiVersionPrefix}/offline-map/current',
      );
      final payload = response.data ?? const <String, dynamic>{};
      final row = Map<String, dynamic>.from(
        payload['data'] as Map? ?? const <String, dynamic>{},
      );
      if (row.isEmpty) {
        return null;
      }

      return OfflineMapPackage(
        ownerUserId: '',
        version: (row['version'] as String?) ?? 'lebanon-satellite-v1',
        zoomLevelMin: _toInt(row['zoom_level_min']) ?? 7,
        zoomLevelMax: _toInt(row['zoom_level_max']) ?? 18,
        downloadedAt: _toDateTime(row['downloaded_at']),
        lastUpdatedAt: _toDateTime(row['last_updated_at']) ?? DateTime.now(),
        tileCount: _toInt(row['tile_count']),
        sizeBytes: _toInt(row['size_bytes']),
        tileSource: row['tile_source'] as String?,
        isCurrent: (row['is_current'] as bool?) ?? true,
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        return null;
      }
      throw userFacingDioMessage(
        error,
        fallback:
            'Unable to load offline map metadata right now. Please try again.',
      );
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
