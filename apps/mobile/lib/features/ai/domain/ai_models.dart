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
    required this.nationalScopeEnabled,
    required this.nationalScopeEligibility,
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
  final bool nationalScopeEnabled;
  final AiNationalScopeEligibility nationalScopeEligibility;

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
      nationalScopeEnabled:
          _toBool(readiness['national_scope_enabled']) ?? false,
      nationalScopeEligibility: AiNationalScopeEligibility.fromMap(
        _toMap(readiness['national_scope_eligibility']),
      ),
    );
  }
}

class AiNationalScopeEligibility {
  const AiNationalScopeEligibility({
    required this.eligible,
    required this.unmetRequirements,
    required this.warnings,
    this.requirements = const <AiNationalScopeRequirement>[],
  });

  final bool eligible;
  final List<String> unmetRequirements;
  final List<String> warnings;
  final List<AiNationalScopeRequirement> requirements;

  factory AiNationalScopeEligibility.fromMap(Map<String, dynamic> map) {
    return AiNationalScopeEligibility(
      eligible: _toBool(map['eligible']) ?? false,
      requirements: _toList(map['requirements'])
          .whereType<Map>()
          .map(
            (row) => AiNationalScopeRequirement.fromMap(
              Map<String, dynamic>.from(row),
            ),
          )
          .toList(growable: false),
      unmetRequirements: _toStringList(map['unmet_requirements']),
      warnings: _toStringList(map['warnings']),
    );
  }
}

class AiNationalScopeRequirement {
  const AiNationalScopeRequirement({
    required this.key,
    required this.label,
    required this.passed,
    this.currentValue,
    this.requiredValue,
    required this.message,
  });

  final String key;
  final String label;
  final bool passed;
  final Object? currentValue;
  final Object? requiredValue;
  final String message;

  factory AiNationalScopeRequirement.fromMap(Map<String, dynamic> map) {
    return AiNationalScopeRequirement(
      key: _toStringOrNull(map['key']) ?? '',
      label: _toStringOrNull(map['label']) ?? '',
      passed: _toBool(map['passed']) ?? false,
      currentValue: map['current_value'],
      requiredValue: map['required_value'],
      message: _toStringOrNull(map['message']) ?? '',
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

class AiLayerFeature {
  const AiLayerFeature({
    required this.id,
    required this.geometry,
    required this.properties,
  });

  final String id;
  final Map<String, dynamic> geometry;
  final Map<String, dynamic> properties;

  factory AiLayerFeature.fromMap(Map<String, dynamic> map, int index) {
    final properties = _toMap(map['properties']);
    return AiLayerFeature(
      id:
          _toStringOrNull(map['id']) ??
          _toStringOrNull(properties['id']) ??
          _toStringOrNull(properties['feature_id']) ??
          _toStringOrNull(properties['source_feature_id']) ??
          'ai-feature-$index',
      geometry: _toMap(map['geometry']),
      properties: properties,
    );
  }
}

class AiLayerFeatureCollection {
  const AiLayerFeatureCollection({
    required this.layer,
    required this.features,
    required this.featureCount,
    required this.matchingFeatureCount,
    required this.returnedFeatureCount,
    this.detail = 'overview',
    this.geometryMode = 'simplified',
    this.optimizedPreview = true,
    this.capped = false,
    this.cap,
    this.classCounts = const <String, int>{},
    this.geometryTypes = const <String>[],
  });

  final AiOutputLayer layer;
  final List<AiLayerFeature> features;
  final int featureCount;
  final int matchingFeatureCount;
  final int returnedFeatureCount;
  final String detail;
  final String geometryMode;
  final bool optimizedPreview;
  final bool capped;
  final int? cap;
  final Map<String, int> classCounts;
  final List<String> geometryTypes;

  factory AiLayerFeatureCollection.fromResponse(Map<String, dynamic> data) {
    final featureCollection = _toMap(data['feature_collection']);
    final features = _toList(
      featureCollection['features'],
    ).whereType<Map>().toList(growable: false);
    return AiLayerFeatureCollection(
      layer: AiOutputLayer.fromMap(_toMap(data['layer'])),
      features: [
        for (var index = 0; index < features.length; index++)
          AiLayerFeature.fromMap(
            Map<String, dynamic>.from(features[index]),
            index,
          ),
      ],
      featureCount:
          _toInt(data['total_count']) ??
          _toInt(data['feature_count']) ??
          features.length,
      matchingFeatureCount:
          _toInt(data['visible_count']) ??
          _toInt(data['matching_feature_count']) ??
          _toInt(data['returned_feature_count']) ??
          features.length,
      returnedFeatureCount:
          _toInt(data['returned_count']) ??
          _toInt(data['returned_feature_count']) ??
          features.length,
      detail: _toStringOrNull(data['detail']) ?? 'overview',
      geometryMode: _toStringOrNull(data['geometry_mode']) ?? 'simplified',
      optimizedPreview: data['optimized_preview'] is bool
          ? data['optimized_preview'] as bool
          : true,
      capped: data['capped'] is bool ? data['capped'] as bool : false,
      cap: _toInt(data['cap']),
      classCounts: _toIntMap(data['class_counts']),
      geometryTypes: _toStringList(data['geometry_types']),
    );
  }
}

class AiLayerFeaturesQuery {
  const AiLayerFeaturesQuery({
    required this.layerId,
    this.detail = 'overview',
    this.geometry = 'simplified',
    this.bounds,
    this.zoom,
    this.limit,
    this.page,
    this.search,
    this.classLabel,
    this.featureId,
  });

  final String layerId;
  final String detail;
  final String geometry;
  final String? bounds;
  final double? zoom;
  final int? limit;
  final int? page;
  final String? search;
  final String? classLabel;
  final String? featureId;

  @override
  bool operator ==(Object other) {
    return other is AiLayerFeaturesQuery &&
        other.layerId == layerId &&
        other.detail == detail &&
        other.geometry == geometry &&
        other.bounds == bounds &&
        other.zoom == zoom &&
        other.limit == limit &&
        other.page == page &&
        other.search == search &&
        other.classLabel == classLabel &&
        other.featureId == featureId;
  }

  @override
  int get hashCode => Object.hash(
    layerId,
    detail,
    geometry,
    bounds,
    zoom,
    limit,
    page,
    search,
    classLabel,
    featureId,
  );
}

class AiLayerFeatureBrowserQuery {
  const AiLayerFeatureBrowserQuery({
    required this.layerId,
    this.search,
    this.classLabel,
  });

  final String layerId;
  final String? search;
  final String? classLabel;

  @override
  bool operator ==(Object other) {
    return other is AiLayerFeatureBrowserQuery &&
        other.layerId == layerId &&
        other.search == search &&
        other.classLabel == classLabel;
  }

  @override
  int get hashCode => Object.hash(layerId, search, classLabel);
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

const List<String> aiPredictionValidationTaskStatuses = <String>[
  'open',
  'assigned',
  'in_progress',
  'submitted',
  'accepted',
  'rejected',
  'cancelled',
];

const List<String> aiPredictionValidationResults = <String>[
  'correct',
  'wrong_class',
  'not_target_class',
  'unsure',
];

class AiPredictionValidationUser {
  const AiPredictionValidationUser({required this.id, this.fullName});

  final String id;
  final String? fullName;

  String get displayName => fullName?.trim().isNotEmpty == true
      ? fullName!.trim()
      : id.length <= 8
      ? id
      : id.substring(0, 8);

  factory AiPredictionValidationUser.fromMap(Map<String, dynamic> map) {
    return AiPredictionValidationUser(
      id: _toStringOrNull(map['id']) ?? '',
      fullName: _toStringOrNull(map['full_name']),
    );
  }
}

class AiPredictionValidationLayerRef {
  const AiPredictionValidationLayerRef({
    required this.id,
    required this.layerType,
    required this.name,
  });

  final String id;
  final String layerType;
  final String name;

  factory AiPredictionValidationLayerRef.fromMap(Map<String, dynamic> map) {
    return AiPredictionValidationLayerRef(
      id: _toStringOrNull(map['id']) ?? '',
      layerType: _toStringOrNull(map['layer_type']) ?? 'classification',
      name: _toStringOrNull(map['name']) ?? 'AI prediction layer',
    );
  }
}

class AiPredictionValidationPrediction {
  const AiPredictionValidationPrediction({
    required this.id,
    this.artifactFeatureId,
    required this.geometry,
    this.geometryType,
    this.predictedClass,
    this.confidence,
    this.uncertaintyScore,
    this.modelName,
    required this.source,
    required this.status,
    required this.metadata,
    this.layer,
    required this.notOfficialFieldData,
  });

  final String id;
  final String? artifactFeatureId;
  final Map<String, dynamic> geometry;
  final String? geometryType;
  final String? predictedClass;
  final double? confidence;
  final double? uncertaintyScore;
  final String? modelName;
  final String source;
  final String status;
  final Map<String, dynamic> metadata;
  final AiPredictionValidationLayerRef? layer;
  final bool notOfficialFieldData;

  factory AiPredictionValidationPrediction.fromMap(Map<String, dynamic> map) {
    final layerMap = _toMapOrNull(map['layer']);
    return AiPredictionValidationPrediction(
      id: _toStringOrNull(map['id']) ?? '',
      artifactFeatureId: _toStringOrNull(map['artifact_feature_id']),
      geometry: _toMap(map['geometry']),
      geometryType: _toStringOrNull(map['geometry_type']),
      predictedClass: _toStringOrNull(map['predicted_class']),
      confidence: _toDouble(map['confidence']),
      uncertaintyScore: _toDouble(map['uncertainty_score']),
      modelName: _toStringOrNull(map['model_name']),
      source: _toStringOrNull(map['source']) ?? 'ai_prediction',
      status: _toStringOrNull(map['status']) ?? 'draft',
      metadata: _toMap(map['metadata']),
      layer: layerMap == null
          ? null
          : AiPredictionValidationLayerRef.fromMap(layerMap),
      notOfficialFieldData: _toBool(map['not_official_field_data']) ?? true,
    );
  }
}

class AiPredictionValidationSubmission {
  const AiPredictionValidationSubmission({
    required this.id,
    required this.result,
    this.correctedClass,
    this.note,
    required this.evidence,
    this.linkedFeatureId,
    required this.status,
    this.submittedBy,
    this.createdAt,
    this.reviewedAt,
    this.reviewedBy,
  });

  final String id;
  final String result;
  final String? correctedClass;
  final String? note;
  final Map<String, dynamic> evidence;
  final String? linkedFeatureId;
  final String status;
  final String? submittedBy;
  final DateTime? createdAt;
  final DateTime? reviewedAt;
  final String? reviewedBy;

  factory AiPredictionValidationSubmission.fromMap(Map<String, dynamic> map) {
    return AiPredictionValidationSubmission(
      id: _toStringOrNull(map['id']) ?? '',
      result: _toStringOrNull(map['result']) ?? 'unsure',
      correctedClass: _toStringOrNull(map['corrected_class']),
      note: _toStringOrNull(map['note']),
      evidence: _toMap(map['evidence']),
      linkedFeatureId: _toStringOrNull(map['linked_feature_id']),
      status: _toStringOrNull(map['status']) ?? 'submitted',
      submittedBy: _toStringOrNull(map['submitted_by']),
      createdAt: _toDateTime(map['created_at']),
      reviewedAt: _toDateTime(map['reviewed_at']),
      reviewedBy: _toStringOrNull(map['reviewed_by']),
    );
  }
}

class AiPredictionValidationTask {
  const AiPredictionValidationTask({
    required this.id,
    required this.projectId,
    required this.aiRunId,
    required this.aiPredictionFeatureId,
    required this.status,
    this.assignedTo,
    this.assignedUser,
    this.createdBy,
    this.createdUser,
    this.reviewedBy,
    this.reviewedUser,
    this.reviewDecision,
    this.reviewReason,
    required this.priority,
    this.dueAt,
    required this.metadata,
    required this.prediction,
    this.latestSubmission,
    required this.notOfficialFieldData,
    required this.noSpatialFeatureWrites,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String projectId;
  final String aiRunId;
  final String aiPredictionFeatureId;
  final String status;
  final String? assignedTo;
  final AiPredictionValidationUser? assignedUser;
  final String? createdBy;
  final AiPredictionValidationUser? createdUser;
  final String? reviewedBy;
  final AiPredictionValidationUser? reviewedUser;
  final String? reviewDecision;
  final String? reviewReason;
  final int priority;
  final DateTime? dueAt;
  final Map<String, dynamic> metadata;
  final AiPredictionValidationPrediction prediction;
  final AiPredictionValidationSubmission? latestSubmission;
  final bool notOfficialFieldData;
  final bool noSpatialFeatureWrites;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get canSubmit =>
      status == 'open' ||
      status == 'assigned' ||
      status == 'in_progress' ||
      status == 'submitted';
  bool get canReview => status == 'submitted' && latestSubmission != null;
  bool get hasSubmission => latestSubmission != null;

  factory AiPredictionValidationTask.fromMap(Map<String, dynamic> map) {
    AiPredictionValidationUser? userFrom(Object? value) {
      final userMap = _toMapOrNull(value);
      if (userMap == null) {
        return null;
      }
      final user = AiPredictionValidationUser.fromMap(userMap);
      return user.id.isEmpty ? null : user;
    }

    final submissionMap = _toMapOrNull(map['latest_submission']);
    return AiPredictionValidationTask(
      id: _toStringOrNull(map['id']) ?? '',
      projectId: _toStringOrNull(map['project_id']) ?? '',
      aiRunId: _toStringOrNull(map['ai_run_id']) ?? '',
      aiPredictionFeatureId:
          _toStringOrNull(map['ai_prediction_feature_id']) ?? '',
      status: _toStringOrNull(map['status']) ?? 'open',
      assignedTo: _toStringOrNull(map['assigned_to']),
      assignedUser: userFrom(map['assigned_user']),
      createdBy: _toStringOrNull(map['created_by']),
      createdUser: userFrom(map['created_user']),
      reviewedBy: _toStringOrNull(map['reviewed_by']),
      reviewedUser: userFrom(map['reviewed_user']),
      reviewDecision: _toStringOrNull(map['review_decision']),
      reviewReason: _toStringOrNull(map['review_reason']),
      priority: _toInt(map['priority']) ?? 0,
      dueAt: _toDateTime(map['due_at']),
      metadata: _toMap(map['metadata']),
      prediction: AiPredictionValidationPrediction.fromMap(
        _toMap(map['prediction']),
      ),
      latestSubmission: submissionMap == null
          ? null
          : AiPredictionValidationSubmission.fromMap(submissionMap),
      notOfficialFieldData: _toBool(map['not_official_field_data']) ?? true,
      noSpatialFeatureWrites: _toBool(map['no_spatial_feature_writes']) ?? true,
      createdAt: _toDateTime(map['created_at']),
      updatedAt: _toDateTime(map['updated_at']),
    );
  }
}

class AiPredictionValidationTaskList {
  const AiPredictionValidationTaskList({
    required this.tasks,
    required this.statusCounts,
    required this.page,
    required this.limit,
    required this.total,
    required this.hasMore,
    required this.notOfficialFieldData,
    required this.noSpatialFeatureWrites,
  });

  final List<AiPredictionValidationTask> tasks;
  final Map<String, int> statusCounts;
  final int page;
  final int limit;
  final int total;
  final bool hasMore;
  final bool notOfficialFieldData;
  final bool noSpatialFeatureWrites;

  factory AiPredictionValidationTaskList.fromResponse(
    Map<String, dynamic> payload, {
    int fallbackPage = 1,
    int fallbackLimit = 50,
  }) {
    final data = _toMap(payload['data']);
    final pagination = _toMap(payload['pagination']);
    final tasks = _toList(data['tasks'])
        .whereType<Map>()
        .map(
          (row) => AiPredictionValidationTask.fromMap(
            Map<String, dynamic>.from(row),
          ),
        )
        .toList(growable: false);
    final page = _toInt(pagination['page']) ?? fallbackPage;
    final limit = _toInt(pagination['limit']) ?? fallbackLimit;
    final total = _toInt(pagination['total']) ?? tasks.length;
    return AiPredictionValidationTaskList(
      tasks: tasks,
      statusCounts: _toIntMap(data['status_counts']),
      page: page,
      limit: limit,
      total: total,
      hasMore:
          _toBool(pagination['has_more']) ??
          (page * limit < total && tasks.isNotEmpty),
      notOfficialFieldData: _toBool(data['not_official_field_data']) ?? true,
      noSpatialFeatureWrites:
          _toBool(data['no_spatial_feature_writes']) ?? true,
    );
  }
}

class AiPredictionValidationGenerateResult {
  const AiPredictionValidationGenerateResult({
    required this.createdCount,
    required this.candidateCount,
    required this.existingActiveCount,
    this.threshold,
    this.thresholdSource,
    this.candidateLayerType,
    this.criterion,
    required this.taskIds,
    required this.noSpatialFeatureWrites,
  });

  final int createdCount;
  final int candidateCount;
  final int existingActiveCount;
  final double? threshold;
  final String? thresholdSource;
  final String? candidateLayerType;
  final String? criterion;
  final List<String> taskIds;
  final bool noSpatialFeatureWrites;

  factory AiPredictionValidationGenerateResult.fromMap(
    Map<String, dynamic> map,
  ) {
    return AiPredictionValidationGenerateResult(
      createdCount: _toInt(map['created_count']) ?? 0,
      candidateCount: _toInt(map['candidate_count']) ?? 0,
      existingActiveCount: _toInt(map['existing_active_count']) ?? 0,
      threshold: _toDouble(map['threshold']),
      thresholdSource: _toStringOrNull(map['threshold_source']),
      candidateLayerType: _toStringOrNull(map['candidate_layer_type']),
      criterion: _toStringOrNull(map['criterion']),
      taskIds: _toStringList(map['task_ids']),
      noSpatialFeatureWrites: _toBool(map['no_spatial_feature_writes']) ?? true,
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

class AiPredictionValidationTasksQuery {
  const AiPredictionValidationTasksQuery({
    this.projectId,
    this.status,
    this.assignedTo,
    this.aiRunId,
    this.page = 1,
    this.limit = 50,
  });

  final String? projectId;
  final String? status;
  final String? assignedTo;
  final String? aiRunId;
  final int page;
  final int limit;

  @override
  bool operator ==(Object other) {
    return other is AiPredictionValidationTasksQuery &&
        other.projectId == projectId &&
        other.status == status &&
        other.assignedTo == assignedTo &&
        other.aiRunId == aiRunId &&
        other.page == page &&
        other.limit == limit;
  }

  @override
  int get hashCode =>
      Object.hash(projectId, status, assignedTo, aiRunId, page, limit);
}

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

Map<String, int> _toIntMap(dynamic raw) {
  final source = _toMap(raw);
  if (source.isEmpty) {
    return const <String, int>{};
  }
  return <String, int>{
    for (final entry in source.entries)
      if (entry.key.trim().isNotEmpty && _toInt(entry.value) != null)
        entry.key.trim(): _toInt(entry.value)!,
  };
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
