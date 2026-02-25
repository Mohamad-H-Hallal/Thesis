import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';
import '../../auth/domain/auth_models.dart';
import '../domain/project.dart';
import '../domain/projects_repository.dart';

class ApiProjectsRepository implements ProjectsRepository {
  ApiProjectsRepository(this._apiClient);

  final ApiClient _apiClient;

  String get _projectsBasePath => '${AppEnv.apiVersionPrefix}/projects';

  @override
  Future<List<ProjectSummary>> fetchAssignedProjects({
    required String userId,
    required UserRole role,
  }) async {
    final response = await _apiClient.dio.get<Map<String, dynamic>>(_projectsBasePath);
    final payload = response.data ?? const <String, dynamic>{};
    final rows = (payload['data'] as List? ?? const <dynamic>[]);
    return rows
        .map((row) => _toProjectSummary(Map<String, dynamic>.from(row as Map)))
        .toList(growable: false);
  }

  @override
  Future<ProjectSummary?> byId({
    required String id,
    required String userId,
    required UserRole role,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '$_projectsBasePath/$id',
      );
      final payload = response.data ?? const <String, dynamic>{};
      final row = Map<String, dynamic>.from(
        payload['data'] as Map? ?? const <String, dynamic>{},
      );
      return _toProjectSummary(row);
    } catch (_) {
      return null;
    }
  }

  ProjectSummary _toProjectSummary(Map<String, dynamic> row) {
    final schemaRaw = row['collection_form_schema'];
    final schemaMap = _toMap(schemaRaw);
    final fieldsRaw = (schemaMap['fields'] as List?) ?? const <dynamic>[];
    final normalizedSchema = CollectionFormSchema(
      version:
          (schemaMap['version'] as String?) ??
          (schemaMap['schemaVersion'] as String?) ??
          'v0.0',
      fields: fieldsRaw
          .map((field) => _toFieldSchema(Map<String, dynamic>.from(field as Map)))
          .toList(growable: false),
    );

    return ProjectSummary(
      id: (row['id'] as String?) ?? '',
      name: (row['name'] as String?) ?? 'Unnamed project',
      category: (row['category_name'] as String?) ?? 'Uncategorized',
      status: (row['status'] as String?) ?? 'draft',
      assignedCollectors:
          _toInt(row['contributor_count']) ??
          _toInt(row['assigned_collectors']) ??
          0,
      pendingReviews:
          _toInt(row['pending_features']) ??
          _toInt(row['pending_reviews']) ??
          0,
      description:
          (row['description'] as String?) ??
          (row['objectives'] as String?) ??
          'No description provided.',
      assignments: const <ProjectAssignment>[],
      collectionFormSchema: normalizedSchema,
      requiresPhotos: (row['requires_photos'] as bool?) ?? false,
      minPhotos: _toInt(row['min_photos']) ?? 0,
      maxPhotos: _toInt(row['max_photos']) ?? 5,
      allowedGeometryTypes:
          (schemaMap['allowedGeometryTypes'] as List?)
              ?.cast<String>()
              .toList(growable: false) ??
          const <String>['Point'],
      maxGpsAccuracyMeters: _toDouble(schemaMap['maxGpsAccuracyMeters']) ?? 25,
    );
  }

  CollectionFormFieldSchema _toFieldSchema(Map<String, dynamic> raw) {
    final typeRaw = (raw['type'] as String?) ?? 'text';
    CollectionFieldType normalizedType = CollectionFieldType.text;
    if (typeRaw == 'textarea') {
      normalizedType = CollectionFieldType.multiline;
    } else if (typeRaw == 'float' || typeRaw == 'int') {
      normalizedType = CollectionFieldType.number;
    } else {
      for (final candidate in CollectionFieldType.values) {
        if (candidate.name == typeRaw) {
          normalizedType = candidate;
          break;
        }
      }
    }

    return CollectionFormFieldSchema(
      key: (raw['key'] as String?) ?? '',
      label: (raw['label'] as String?) ?? (raw['key'] as String?) ?? 'Field',
      type: normalizedType,
      required: (raw['required'] as bool?) ?? false,
      options: ((raw['options'] as List?) ?? const <dynamic>[])
          .map((value) => value.toString())
          .toList(growable: false),
      hint: raw['hint'] as String?,
      min: raw['min'] as num?,
      max: raw['max'] as num?,
      unit: raw['unit'] as String?,
    );
  }

  Map<String, dynamic> _toMap(dynamic raw) {
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    return const <String, dynamic>{};
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
}
