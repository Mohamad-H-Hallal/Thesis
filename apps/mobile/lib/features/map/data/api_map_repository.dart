import 'dart:collection';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../../../core/maps/tile_query.dart';
import '../../../core/offline/local_models.dart';
import '../../../core/config/app_env.dart';
import '../../../core/network/api_error_message.dart';
import '../../../core/network/api_client.dart';
import '../../../core/pagination/paginated_result.dart';
import '../domain/map_feature.dart';

class ApiMapRepository {
  ApiMapRepository(this._apiClient);

  final ApiClient _apiClient;
  final LinkedHashMap<String, List<MapFeatureSummary>> _projectTileCache =
      LinkedHashMap<String, List<MapFeatureSummary>>();
  static const int _projectTileCacheMaxEntries = 192;
  static const int _projectTileBatchSize = 4;
  int _projectTileCacheRevision = 0;

  Future<List<MapFeatureSummary>> fetchProjectFeatures(String projectId) async {
    final page = await fetchProjectFeaturesPage(projectId: projectId, limit: 100);
    return page.items;
  }

  Future<List<MapFeatureSummary>> fetchProjectFeaturesViewport({
    required String projectId,
    required double minLon,
    required double minLat,
    required double maxLon,
    required double maxLat,
    required double zoom,
    int cacheRevision = 0,
  }) async {
    if (_projectTileCacheRevision != cacheRevision) {
      _projectTileCacheRevision = cacheRevision;
      _projectTileCache.clear();
    }
    try {
      final tiles = buildVisibleTileQueries(
        minLon: minLon,
        minLat: minLat,
        maxLon: maxLon,
        maxLat: maxLat,
        zoom: zoom,
        buffer: 0,
      );
      final tileResults = <List<MapFeatureSummary>>[];
      Object? firstError;
      for (var start = 0; start < tiles.length; start += _projectTileBatchSize) {
        final end = math.min(start + _projectTileBatchSize, tiles.length);
        final batch = tiles.sublist(start, end);
        final batchResults = await Future.wait(
          batch.map((tile) async {
            try {
              return await fetchProjectFeatureTile(
                projectId: projectId,
                z: tile.z,
                x: tile.x,
                y: tile.y,
              );
            } catch (error) {
              firstError ??= error;
              return null;
            }
          }),
        );
        for (final result in batchResults) {
          if (result != null) {
            tileResults.add(result);
          }
        }
      }
      if (tileResults.isEmpty && firstError != null) {
        throw firstError!;
      }
      final merged = <String, MapFeatureSummary>{};
      for (final features in tileResults) {
        for (final feature in features) {
          merged.putIfAbsent(feature.id, () => feature);
        }
      }
      return merged.values.toList(growable: false);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback:
            'Unable to load project map features right now. Please try again.',
      );
    }
  }

  Future<List<MapFeatureSummary>> fetchProjectFeatureTile({
    required String projectId,
    required int z,
    required int x,
    required int y,
  }) async {
    final cacheKey = '$projectId:$z:$x:$y';
    final cached = _projectTileCache.remove(cacheKey);
    if (cached != null) {
      _projectTileCache[cacheKey] = cached;
      return cached;
    }
    final response = await _apiClient.dio.get<Map<String, dynamic>>(
      '${AppEnv.apiVersionPrefix}/features/tiles/$z/$x/$y',
      queryParameters: <String, dynamic>{'project_id': projectId},
    );
    final payload = response.data ?? const <String, dynamic>{};
    final featureCollection = Map<String, dynamic>.from(
      payload['data'] as Map? ?? const <String, dynamic>{},
    );
    final rows =
        (featureCollection['features'] as List? ?? const <dynamic>[])
            .cast<Map>();
    final items = rows
        .map(
          (row) => _toViewportFeature(
            Map<String, dynamic>.from(row),
          ),
        )
        .toList(growable: false);
    _rememberProjectTile(cacheKey, items);
    return items;
  }

  Future<PaginatedResult<MapFeatureSummary>> fetchProjectFeaturesPage({
    required String projectId,
    String? search,
    String? status,
    String? geometryType,
    String? featureType,
    String? excludeImportId,
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
          if (featureType?.trim().isNotEmpty ?? false)
            'feature_type': featureType!.trim(),
          if (excludeImportId?.trim().isNotEmpty ?? false)
            'exclude_import_id': excludeImportId!.trim(),
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
            return _toProjectFeature(item);
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

  Future<MapFeatureSummary> fetchProjectFeatureById(String featureId) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '${AppEnv.apiVersionPrefix}/features/$featureId',
      );
      final payload = response.data ?? const <String, dynamic>{};
      final row = Map<String, dynamic>.from(
        payload['data'] as Map? ?? const <String, dynamic>{},
      );
      return _toProjectFeature(row);
    } on DioException catch (error) {
      throw userFacingDioMessage(
        error,
        fallback:
            'Unable to load this project feature right now. Please try again.',
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

  MapFeatureSummary _toProjectFeature(Map<String, dynamic> item) {
    return MapFeatureSummary(
      id: (item['id'] as String?) ?? '',
      status: (item['status'] as String?) ?? 'draft',
      geometry: Map<String, dynamic>.from(
        item['geometry'] as Map? ?? const <String, dynamic>{},
      ),
      attributes: Map<String, dynamic>.from(
        item['attributes'] as Map? ?? const <String, dynamic>{},
      ),
      sourceGeometryType: item['source_geometry_type'] as String?,
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
      isSummary: item['is_summary'] as bool? ?? false,
    );
  }

  MapFeatureSummary _toViewportFeature(Map<String, dynamic> feature) {
    final properties = Map<String, dynamic>.from(
      feature['properties'] as Map? ?? const <String, dynamic>{},
    );
    return MapFeatureSummary(
      id: (feature['id'] as String?) ?? '',
      status: (properties['status'] as String?) ?? 'approved',
      geometry: Map<String, dynamic>.from(
        feature['geometry'] as Map? ?? const <String, dynamic>{},
      ),
      attributes: Map<String, dynamic>.from(
        properties['attributes'] as Map? ?? const <String, dynamic>{},
      ),
      sourceGeometryType: properties['source_geometry_type'] as String?,
      collectedBy: properties['collected_by'] as String?,
      reviewedBy: properties['reviewed_by'] as String?,
      reviewNotes: properties['review_notes'] as String?,
      collectedAt: _toDateTime(properties['collected_at']),
      submittedAt: _toDateTime(properties['submitted_at']),
      reviewedAt: _toDateTime(properties['reviewed_at']),
      photoCount: _toInt(properties['photo_count']) ?? 0,
      isSummary: true,
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

  void _rememberProjectTile(String cacheKey, List<MapFeatureSummary> items) {
    _projectTileCache[cacheKey] = items;
    while (_projectTileCache.length > _projectTileCacheMaxEntries) {
      _projectTileCache.remove(_projectTileCache.keys.first);
    }
  }
}
