import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';
import '../domain/map_feature.dart';

class ApiMapRepository {
  ApiMapRepository(this._apiClient);

  final ApiClient _apiClient;

  Future<List<MapFeatureSummary>> fetchProjectFeatures(String projectId) async {
    final response = await _apiClient.dio.get<Map<String, dynamic>>(
      '${AppEnv.apiVersionPrefix}/projects/$projectId/features',
      queryParameters: const <String, dynamic>{'limit': 200},
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
            collectedBy: item['collected_by'] as String?,
            reviewedBy: item['reviewed_by'] as String?,
            photoCount: _toInt(item['photo_count']) ?? 0,
          );
        })
        .toList(growable: false);
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
}
