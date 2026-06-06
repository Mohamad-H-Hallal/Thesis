import '../../../core/pagination/paginated_result.dart';

const List<String> aiScopeTypes = <String>[
  'project',
  'custom_polygon',
  'governorate',
  'district',
  'city',
  'national',
];

const List<String> aiEditableScopeTypes = <String>['project', 'custom_polygon'];

class AiProjectSettings {
  const AiProjectSettings({
    this.id,
    required this.projectId,
    required this.isEnabled,
    this.labelField,
    required this.scopeType,
    this.scopeGeometry,
    required this.minSamplesPerClass,
    this.modelPreferences = const <String, dynamic>{},
    this.persisted = false,
  });

  final String? id;
  final String projectId;
  final bool isEnabled;
  final String? labelField;
  final String scopeType;
  final Map<String, dynamic>? scopeGeometry;
  final int minSamplesPerClass;
  final Map<String, dynamic> modelPreferences;
  final bool persisted;

  static AiProjectSettings defaults(String projectId) => AiProjectSettings(
    projectId: projectId,
    isEnabled: false,
    scopeType: 'project',
    minSamplesPerClass: 50,
  );

  AiProjectSettings copyWith({
    String? id,
    String? projectId,
    bool? isEnabled,
    String? labelField,
    String? scopeType,
    Map<String, dynamic>? scopeGeometry,
    int? minSamplesPerClass,
    Map<String, dynamic>? modelPreferences,
    bool? persisted,
  }) {
    return AiProjectSettings(
      id: id ?? this.id,
      projectId: projectId ?? this.projectId,
      isEnabled: isEnabled ?? this.isEnabled,
      labelField: labelField ?? this.labelField,
      scopeType: scopeType ?? this.scopeType,
      scopeGeometry: scopeGeometry ?? this.scopeGeometry,
      minSamplesPerClass: minSamplesPerClass ?? this.minSamplesPerClass,
      modelPreferences: modelPreferences ?? this.modelPreferences,
      persisted: persisted ?? this.persisted,
    );
  }

  Map<String, dynamic> toRequestBody() {
    return <String, dynamic>{
      'is_enabled': isEnabled,
      'label_field': labelField,
      'scope_type': scopeType,
      'scope_geometry': scopeGeometry,
      'min_samples_per_class': minSamplesPerClass,
      'model_preferences': modelPreferences,
    };
  }

  factory AiProjectSettings.fromMap(
    Map<String, dynamic> map, {
    required String projectId,
  }) {
    return AiProjectSettings(
      id: _toStringOrNull(map['id']),
      projectId: _toStringOrNull(map['project_id']) ?? projectId,
      isEnabled: _toBool(map['is_enabled']) ?? false,
      labelField: _toStringOrNull(map['label_field']),
      scopeType: _toStringOrNull(map['scope_type']) ?? 'project',
      scopeGeometry: _toMapOrNull(map['scope_geometry']),
      minSamplesPerClass: _toInt(map['min_samples_per_class']) ?? 50,
      modelPreferences: _toMap(map['model_preferences']),
      persisted: _toBool(map['persisted']) ?? map['id'] != null,
    );
  }
}

class AiReadinessResult {
  const AiReadinessResult({
    required this.projectId,
    required this.projectName,
    required this.status,
    this.labelField,
    required this.minSamplesPerClass,
    required this.approvedFeatureCount,
    required this.labeledFeatureCount,
    required this.eligibleFeatureCount,
    required this.missingLabelCount,
    required this.invalidGeometryCount,
    required this.excludedFeatureCount,
    required this.classCount,
    required this.eligibleClassCount,
    required this.labelCounts,
    required this.classesBelowMinimum,
    required this.candidateLabelFields,
    required this.sourceColumnAvailable,
    required this.sourceCounts,
    this.spatialExtent,
    required this.coverageWarningApplies,
    required this.warnings,
    required this.blockers,
    required this.settings,
  });

  final String projectId;
  final String projectName;
  final String status;
  final String? labelField;
  final int minSamplesPerClass;
  final int approvedFeatureCount;
  final int labeledFeatureCount;
  final int eligibleFeatureCount;
  final int missingLabelCount;
  final int invalidGeometryCount;
  final int excludedFeatureCount;
  final int classCount;
  final int eligibleClassCount;
  final List<AiLabelCount> labelCounts;
  final List<AiLabelCount> classesBelowMinimum;
  final List<AiLabelFieldCandidate> candidateLabelFields;
  final bool sourceColumnAvailable;
  final List<AiSourceCount> sourceCounts;
  final AiSpatialExtent? spatialExtent;
  final bool coverageWarningApplies;
  final List<String> warnings;
  final List<String> blockers;
  final AiProjectSettings settings;

  bool get isReady => status == 'ready';
  bool get hasWarning => status == 'warning';
  bool get isNotReady => status == 'not_ready';
  bool get hasRegionalOnlyWarning =>
      coverageWarningApplies ||
      warnings.any((warning) => warning.toLowerCase().contains('national'));

  factory AiReadinessResult.fromResponse(Map<String, dynamic> data) {
    final project = _toMap(data['project']);
    final settingsMap = _toMap(data['settings']);
    final readiness = _toMap(data['readiness']);
    final projectId = _toStringOrNull(project['id']) ?? '';

    return AiReadinessResult(
      projectId: projectId,
      projectName: _toStringOrNull(project['name']) ?? 'Project',
      status: _toStringOrNull(readiness['status']) ?? 'not_ready',
      labelField: _toStringOrNull(readiness['label_field']),
      minSamplesPerClass: _toInt(readiness['min_samples_per_class']) ?? 50,
      approvedFeatureCount: _toInt(readiness['approved_feature_count']) ?? 0,
      labeledFeatureCount:
          _toInt(readiness['labeled_feature_count']) ??
          _toInt(readiness['eligible_feature_count']) ??
          0,
      eligibleFeatureCount: _toInt(readiness['eligible_feature_count']) ?? 0,
      missingLabelCount: _toInt(readiness['missing_label_count']) ?? 0,
      invalidGeometryCount: _toInt(readiness['invalid_geometry_count']) ?? 0,
      excludedFeatureCount: _toInt(readiness['excluded_feature_count']) ?? 0,
      eligibleClassCount:
          _toInt(readiness['eligible_class_count']) ??
          _toInt(readiness['class_count']) ??
          0,
      classCount: _toInt(readiness['class_count']) ?? 0,
      labelCounts: _toList(readiness['label_counts'])
          .whereType<Map>()
          .map((row) => AiLabelCount.fromMap(Map<String, dynamic>.from(row)))
          .toList(growable: false),
      classesBelowMinimum: _toList(readiness['classes_below_minimum'])
          .whereType<Map>()
          .map((row) => AiLabelCount.fromMap(Map<String, dynamic>.from(row)))
          .toList(growable: false),
      candidateLabelFields: _toList(readiness['candidate_label_fields'])
          .whereType<Map>()
          .map(
            (row) =>
                AiLabelFieldCandidate.fromMap(Map<String, dynamic>.from(row)),
          )
          .toList(growable: false),
      sourceColumnAvailable:
          _toBool(readiness['source_column_available']) ?? false,
      sourceCounts: _toList(readiness['source_counts'])
          .whereType<Map>()
          .map((row) => AiSourceCount.fromMap(Map<String, dynamic>.from(row)))
          .toList(growable: false),
      spatialExtent: AiSpatialExtent.fromMapOrNull(
        _toMapOrNull(readiness['spatial_extent']),
      ),
      coverageWarningApplies:
          _toBool(readiness['coverage_warning_applies']) ?? false,
      warnings: _toStringList(readiness['warnings']),
      blockers: _toStringList(readiness['blockers']),
      settings: AiProjectSettings.fromMap(settingsMap, projectId: projectId),
    );
  }
}

class AiLabelFieldCandidate {
  const AiLabelFieldCandidate({
    required this.field,
    required this.sources,
    required this.labeledFeatureCount,
    required this.classCount,
    required this.usable,
    this.selectable = true,
    this.diagnosticOnly = false,
    this.aliasOf,
    this.aliases = const <String>[],
    required this.recommended,
    this.note,
  });

  final String field;
  final List<String> sources;
  final int labeledFeatureCount;
  final int classCount;
  final bool usable;
  final bool selectable;
  final bool diagnosticOnly;
  final String? aliasOf;
  final List<String> aliases;
  final bool recommended;
  final String? note;

  bool get hasLabels => labeledFeatureCount > 0 && classCount > 0;

  factory AiLabelFieldCandidate.fromMap(Map<String, dynamic> map) {
    return AiLabelFieldCandidate(
      field: _toStringOrNull(map['field']) ?? '',
      sources: _toStringList(map['source']),
      labeledFeatureCount: _toInt(map['labeled_feature_count']) ?? 0,
      classCount: _toInt(map['class_count']) ?? 0,
      usable: _toBool(map['usable']) ?? false,
      selectable:
          _toBool(map['selectable']) ?? (_toBool(map['usable']) ?? false),
      diagnosticOnly: _toBool(map['diagnostic_only']) ?? false,
      aliasOf: _toStringOrNull(map['alias_of']),
      aliases: _toStringList(map['aliases']),
      recommended: _toBool(map['recommended']) ?? false,
      note: _toStringOrNull(map['note']),
    );
  }
}

class AiLabelCount {
  const AiLabelCount({required this.label, required this.sampleCount});

  final String label;
  final int sampleCount;

  factory AiLabelCount.fromMap(Map<String, dynamic> map) {
    return AiLabelCount(
      label: _toStringOrNull(map['class_label']) ?? 'Unlabeled',
      sampleCount: _toInt(map['sample_count']) ?? 0,
    );
  }
}

class AiSourceCount {
  const AiSourceCount({required this.source, required this.featureCount});

  final String source;
  final int featureCount;

  factory AiSourceCount.fromMap(Map<String, dynamic> map) {
    return AiSourceCount(
      source: _toStringOrNull(map['source']) ?? 'unknown',
      featureCount: _toInt(map['feature_count']) ?? 0,
    );
  }
}

class AiSpatialExtent {
  const AiSpatialExtent({
    required this.minLon,
    required this.minLat,
    required this.maxLon,
    required this.maxLat,
  });

  final double minLon;
  final double minLat;
  final double maxLon;
  final double maxLat;

  static AiSpatialExtent? fromMapOrNull(Map<String, dynamic>? map) {
    if (map == null) {
      return null;
    }
    final minLon = _toDouble(map['min_lon']);
    final minLat = _toDouble(map['min_lat']);
    final maxLon = _toDouble(map['max_lon']);
    final maxLat = _toDouble(map['max_lat']);
    if (minLon == null || minLat == null || maxLon == null || maxLat == null) {
      return null;
    }
    return AiSpatialExtent(
      minLon: minLon,
      minLat: minLat,
      maxLon: maxLon,
      maxLat: maxLat,
    );
  }
}

class AiRun {
  const AiRun({
    required this.id,
    required this.projectId,
    this.projectName,
    required this.status,
    this.labelField,
    required this.scopeType,
    this.regionPreset,
    required this.trainingFeatureCount,
    required this.eligibleFeatureCount,
    required this.excludedFeatureCount,
    this.selectedModel,
    this.startedAt,
    this.completedAt,
    this.failedAt,
    this.failureReason,
    this.createdAt,
    this.updatedAt,
    this.metadata = const <String, dynamic>{},
  });

  final String id;
  final String projectId;
  final String? projectName;
  final String status;
  final String? labelField;
  final String scopeType;
  final String? regionPreset;
  final int trainingFeatureCount;
  final int eligibleFeatureCount;
  final int excludedFeatureCount;
  final String? selectedModel;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final DateTime? failedAt;
  final String? failureReason;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final Map<String, dynamic> metadata;

  factory AiRun.fromMap(Map<String, dynamic> map) {
    return AiRun(
      id: _toStringOrNull(map['id']) ?? '',
      projectId: _toStringOrNull(map['project_id']) ?? '',
      projectName: _toStringOrNull(map['project_name']),
      status: _toStringOrNull(map['status']) ?? 'draft',
      labelField: _toStringOrNull(map['label_field']),
      scopeType: _toStringOrNull(map['scope_type']) ?? 'project',
      regionPreset: _toStringOrNull(map['region_preset']),
      trainingFeatureCount: _toInt(map['training_feature_count']) ?? 0,
      eligibleFeatureCount: _toInt(map['eligible_feature_count']) ?? 0,
      excludedFeatureCount: _toInt(map['excluded_feature_count']) ?? 0,
      selectedModel: _toStringOrNull(map['selected_model']),
      startedAt: _toDateTime(map['started_at']),
      completedAt: _toDateTime(map['completed_at']),
      failedAt: _toDateTime(map['failed_at']),
      failureReason: _toStringOrNull(map['failure_reason']),
      createdAt: _toDateTime(map['created_at']),
      updatedAt: _toDateTime(map['updated_at']),
      metadata: _toMap(map['metadata']),
    );
  }
}

class AiRunMetric {
  const AiRunMetric({
    required this.id,
    required this.modelName,
    this.overallAccuracy,
    this.macroF1,
    this.weightedF1,
  });

  final String id;
  final String modelName;
  final double? overallAccuracy;
  final double? macroF1;
  final double? weightedF1;

  factory AiRunMetric.fromMap(Map<String, dynamic> map) {
    return AiRunMetric(
      id: _toStringOrNull(map['id']) ?? '',
      modelName: _toStringOrNull(map['model_name']) ?? 'Model',
      overallAccuracy: _toDouble(map['overall_accuracy']),
      macroF1: _toDouble(map['macro_f1']),
      weightedF1: _toDouble(map['weighted_f1']),
    );
  }
}

class AiOutputLayer {
  const AiOutputLayer({
    required this.id,
    required this.layerType,
    required this.status,
    required this.name,
    this.aiRunId,
    this.projectId,
    this.description,
    this.storagePath,
    this.assetId,
    this.crs,
    this.bounds = const <String, dynamic>{},
    this.style = const <String, dynamic>{},
    this.publishedAt,
    this.publishedBy,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String layerType;
  final String status;
  final String name;
  final String? aiRunId;
  final String? projectId;
  final String? description;
  final String? storagePath;
  final String? assetId;
  final String? crs;
  final Map<String, dynamic> bounds;
  final Map<String, dynamic> style;
  final DateTime? publishedAt;
  final String? publishedBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory AiOutputLayer.fromMap(Map<String, dynamic> map) {
    return AiOutputLayer(
      id: _toStringOrNull(map['id']) ?? '',
      aiRunId: _toStringOrNull(map['ai_run_id']),
      projectId: _toStringOrNull(map['project_id']),
      layerType: _toStringOrNull(map['layer_type']) ?? 'classification',
      status: _toStringOrNull(map['status']) ?? 'draft',
      name: _toStringOrNull(map['name']) ?? 'AI layer',
      description: _toStringOrNull(map['description']),
      storagePath: _toStringOrNull(map['storage_path']),
      assetId: _toStringOrNull(map['asset_id']),
      crs: _toStringOrNull(map['crs']),
      bounds: _toMap(map['bounds']),
      style: _toMap(map['style']),
      publishedAt: _toDateTime(map['published_at']),
      publishedBy: _toStringOrNull(map['published_by']),
      createdAt: _toDateTime(map['created_at']),
      updatedAt: _toDateTime(map['updated_at']),
    );
  }
}

class AiRunLog {
  const AiRunLog({
    required this.id,
    required this.level,
    required this.message,
    this.metadata = const <String, dynamic>{},
    this.createdAt,
  });

  final String id;
  final String level;
  final String message;
  final Map<String, dynamic> metadata;
  final DateTime? createdAt;

  factory AiRunLog.fromMap(Map<String, dynamic> map) {
    return AiRunLog(
      id: _toStringOrNull(map['id']) ?? '',
      level: _toStringOrNull(map['level']) ?? 'info',
      message: _toStringOrNull(map['message']) ?? '',
      metadata: _toMap(map['metadata']),
      createdAt: _toDateTime(map['created_at']),
    );
  }
}

class AiReviewDecision {
  const AiReviewDecision({
    required this.id,
    required this.aiRunId,
    required this.decision,
    this.reason,
    this.decidedBy,
    this.decidedAt,
    this.metadata = const <String, dynamic>{},
  });

  final String id;
  final String aiRunId;
  final String decision;
  final String? reason;
  final String? decidedBy;
  final DateTime? decidedAt;
  final Map<String, dynamic> metadata;

  factory AiReviewDecision.fromMap(Map<String, dynamic> map) {
    return AiReviewDecision(
      id: _toStringOrNull(map['id']) ?? '',
      aiRunId: _toStringOrNull(map['ai_run_id']) ?? '',
      decision: _toStringOrNull(map['decision']) ?? 'keep_draft',
      reason: _toStringOrNull(map['reason']),
      decidedBy: _toStringOrNull(map['decided_by']),
      decidedAt: _toDateTime(map['decided_at']),
      metadata: _toMap(map['metadata']),
    );
  }
}

class AiRunReviewResult {
  const AiRunReviewResult({
    required this.decision,
    required this.run,
    required this.layers,
    required this.viewerPublished,
  });

  final AiReviewDecision decision;
  final AiRun run;
  final List<AiOutputLayer> layers;
  final bool viewerPublished;

  factory AiRunReviewResult.fromResponse(Map<String, dynamic> data) {
    return AiRunReviewResult(
      decision: AiReviewDecision.fromMap(_toMap(data['decision'])),
      run: AiRun.fromMap(_toMap(data['run'])),
      layers: _toList(data['layers'])
          .whereType<Map>()
          .map((row) => AiOutputLayer.fromMap(Map<String, dynamic>.from(row)))
          .toList(growable: false),
      viewerPublished: _toBool(data['viewer_published']) ?? false,
    );
  }
}

class AiReadinessQuery {
  const AiReadinessQuery({
    required this.projectId,
    this.labelField,
    this.minSamplesPerClass,
    this.scopeType,
  });

  final String projectId;
  final String? labelField;
  final int? minSamplesPerClass;
  final String? scopeType;

  @override
  bool operator ==(Object other) {
    return other is AiReadinessQuery &&
        other.projectId == projectId &&
        other.labelField == labelField &&
        other.minSamplesPerClass == minSamplesPerClass &&
        other.scopeType == scopeType;
  }

  @override
  int get hashCode =>
      Object.hash(projectId, labelField, minSamplesPerClass, scopeType);
}

class AiRunsQuery {
  const AiRunsQuery({
    required this.projectId,
    this.status,
    this.page = 1,
    this.limit = 20,
  });

  final String projectId;
  final String? status;
  final int page;
  final int limit;

  @override
  bool operator ==(Object other) {
    return other is AiRunsQuery &&
        other.projectId == projectId &&
        other.status == status &&
        other.page == page &&
        other.limit == limit;
  }

  @override
  int get hashCode => Object.hash(projectId, status, page, limit);
}

typedef AiRunsPage = PaginatedResult<AiRun>;

String? _toStringOrNull(dynamic value) {
  if (value == null) {
    return null;
  }
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
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

bool? _toBool(dynamic value) {
  if (value is bool) {
    return value;
  }
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true') {
      return true;
    }
    if (normalized == 'false') {
      return false;
    }
  }
  return null;
}

DateTime? _toDateTime(dynamic value) {
  if (value is DateTime) {
    return value;
  }
  if (value is String && value.trim().isNotEmpty) {
    return DateTime.tryParse(value);
  }
  return null;
}

List<dynamic> _toList(dynamic raw) {
  if (raw is List) {
    return raw;
  }
  return const <dynamic>[];
}

List<String> _toStringList(dynamic raw) {
  return _toList(raw)
      .map((value) => value.toString().trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
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

Map<String, dynamic>? _toMapOrNull(dynamic raw) {
  if (raw == null) {
    return null;
  }
  final value = _toMap(raw);
  return value.isEmpty ? null : value;
}
