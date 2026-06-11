import 'package:lebanese_gis_mobile/core/pagination/paginated_result.dart';
import 'package:lebanese_gis_mobile/features/ai/domain/ai_models.dart';
import 'package:lebanese_gis_mobile/features/ai/domain/ai_repository.dart';

class FakeAiRepository implements AiRepository {
  FakeAiRepository({
    AiProjectSettings? settings,
    AiReadinessResult? readiness,
    List<AiRun> runs = const <AiRun>[],
    List<AiRunMetric> metrics = const <AiRunMetric>[],
    List<AiOutputLayer> layers = const <AiOutputLayer>[],
    Map<String, AiLayerFeatureCollection> layerFeatures =
        const <String, AiLayerFeatureCollection>{},
    List<AiRunLog> logs = const <AiRunLog>[],
    List<AiReviewDecision> reviews = const <AiReviewDecision>[],
    this.failReadiness = false,
  }) : settings = settings ?? AiProjectSettings.defaults('project-1'),
       readiness = readiness ?? fakeReadiness(projectId: 'project-1'),
       runs = List<AiRun>.from(runs),
       metrics = List<AiRunMetric>.from(metrics),
       layers = List<AiOutputLayer>.from(layers),
       layerFeatures = Map<String, AiLayerFeatureCollection>.from(
         layerFeatures,
       ),
       logs = List<AiRunLog>.from(logs),
       reviews = List<AiReviewDecision>.from(reviews);

  AiProjectSettings settings;
  AiReadinessResult readiness;
  List<AiRun> runs;
  List<AiRunMetric> metrics;
  List<AiOutputLayer> layers;
  Map<String, AiLayerFeatureCollection> layerFeatures;
  final Map<String, int> layerFeatureFetchCounts = <String, int>{};
  final List<AiLayerFeaturesQuery> layerFeatureQueries =
      <AiLayerFeaturesQuery>[];
  List<AiRunLog> logs;
  List<AiReviewDecision> reviews;
  bool failReadiness;
  int saveCount = 0;
  int createCount = 0;
  int reviewCount = 0;
  int publishCount = 0;
  int unpublishCount = 0;
  int readinessFetchCount = 0;

  @override
  Future<AiRun> createRun({
    required String projectId,
    required String status,
    String? labelField,
    String? scopeType,
    int? minSamplesPerClass,
  }) async {
    createCount++;
    final run = AiRun(
      id: 'run-$createCount',
      projectId: projectId,
      status: status,
      labelField: labelField ?? settings.labelField,
      scopeType: scopeType ?? settings.scopeType,
      trainingFeatureCount: readiness.approvedFeatureCount,
      eligibleFeatureCount: readiness.eligibleFeatureCount,
      excludedFeatureCount: readiness.excludedFeatureCount,
      createdAt: DateTime.utc(2026, 6, 1),
    );
    runs = <AiRun>[run, ...runs];
    logs = <AiRunLog>[
      AiRunLog(
        id: 'log-$createCount',
        level: 'info',
        message: 'Draft AI run record created. No worker command was started.',
        createdAt: DateTime.utc(2026, 6, 1),
      ),
      ...logs,
    ];
    return run;
  }

  @override
  Future<AiRun> fetchRun({required String runId}) async {
    return runs.firstWhere(
      (run) => run.id == runId,
      orElse: () => AiRun(
        id: runId,
        projectId: settings.projectId,
        status: 'draft',
        labelField: settings.labelField,
        scopeType: settings.scopeType,
        trainingFeatureCount: 0,
        eligibleFeatureCount: 0,
        excludedFeatureCount: 0,
      ),
    );
  }

  @override
  Future<List<AiOutputLayer>> fetchRunLayers({required String runId}) async {
    return layers;
  }

  @override
  Future<List<AiOutputLayer>> fetchPublishedProjectLayers({
    required String projectId,
  }) async {
    return layers
        .where(
          (layer) =>
              layer.projectId == projectId &&
              layer.status == 'published' &&
              layer.publishedAt != null,
        )
        .toList(growable: false);
  }

  @override
  Future<AiLayerFeatureCollection> fetchLayerFeatures({
    required String layerId,
    String detail = 'overview',
    String geometry = 'simplified',
    String? bounds,
    double? zoom,
    int? limit,
    int? page,
    String? search,
    String? classLabel,
    String? featureId,
  }) async {
    layerFeatureFetchCounts[layerId] =
        (layerFeatureFetchCounts[layerId] ?? 0) + 1;
    layerFeatureQueries.add(
      AiLayerFeaturesQuery(
        layerId: layerId,
        detail: detail,
        geometry: geometry,
        bounds: bounds,
        zoom: zoom,
        limit: limit,
        page: page,
        search: search,
        classLabel: classLabel,
        featureId: featureId,
      ),
    );
    final collection = layerFeatures[layerId];
    if (collection != null) {
      var filteredFeatures = collection.features;
      final normalizedClass = classLabel?.trim().toLowerCase();
      if (normalizedClass != null && normalizedClass.isNotEmpty) {
        filteredFeatures = filteredFeatures
            .where(
              (feature) =>
                  _fakeAiFeatureClass(feature)?.toLowerCase() ==
                  normalizedClass,
            )
            .toList(growable: false);
      }
      final normalizedSearch = search?.trim().toLowerCase();
      if (normalizedSearch != null && normalizedSearch.isNotEmpty) {
        filteredFeatures = filteredFeatures
            .where(
              (feature) =>
                  _fakeAiFeatureSearchBlob(feature).contains(normalizedSearch),
            )
            .toList(growable: false);
      }
      final normalizedFeatureId = featureId?.trim().toLowerCase();
      if (normalizedFeatureId != null && normalizedFeatureId.isNotEmpty) {
        filteredFeatures = filteredFeatures
            .where((feature) => feature.id.toLowerCase() == normalizedFeatureId)
            .toList(growable: false);
      }
      final isFiltered =
          normalizedClass != null ||
          normalizedSearch != null ||
          normalizedFeatureId != null;
      if (page == null || limit == null) {
        if (!isFiltered) {
          return collection;
        }
        return AiLayerFeatureCollection(
          layer: collection.layer,
          features: filteredFeatures,
          featureCount: collection.featureCount,
          matchingFeatureCount: filteredFeatures.length,
          returnedFeatureCount: filteredFeatures.length,
          detail: collection.detail,
          geometryMode: collection.geometryMode,
          optimizedPreview: collection.optimizedPreview,
          capped: collection.capped,
          cap: collection.cap,
          classCounts: collection.classCounts,
          geometryTypes: collection.geometryTypes,
        );
      }
      final safePage = page < 1 ? 1 : page;
      final start = (safePage - 1) * limit;
      final end = start + limit > filteredFeatures.length
          ? filteredFeatures.length
          : start + limit;
      final pageFeatures = start >= filteredFeatures.length
          ? const <AiLayerFeature>[]
          : filteredFeatures.sublist(start, end);
      return AiLayerFeatureCollection(
        layer: collection.layer,
        features: pageFeatures,
        featureCount: collection.featureCount,
        matchingFeatureCount: isFiltered
            ? filteredFeatures.length
            : collection.matchingFeatureCount,
        returnedFeatureCount: pageFeatures.length,
        detail: collection.detail,
        geometryMode: collection.geometryMode,
        optimizedPreview: collection.optimizedPreview,
        capped: end < filteredFeatures.length,
        cap: collection.cap,
        classCounts: collection.classCounts,
        geometryTypes: collection.geometryTypes,
      );
    }
    final layer = layers.firstWhere(
      (item) => item.id == layerId,
      orElse: () => AiOutputLayer(
        id: layerId,
        layerType: 'classification',
        status: 'ready_for_review',
        name: 'AI preview layer',
      ),
    );
    return AiLayerFeatureCollection(
      layer: layer,
      features: const <AiLayerFeature>[],
      featureCount: 0,
      matchingFeatureCount: 0,
      returnedFeatureCount: 0,
      detail: detail,
      geometryMode: geometry,
    );
  }

  @override
  Future<PaginatedResult<AiRunLog>> fetchRunLogsPage({
    required String runId,
    int page = 1,
    int limit = 20,
  }) async {
    return PaginatedResult<AiRunLog>(
      items: logs,
      page: page,
      limit: limit,
      total: logs.length,
      hasMore: false,
    );
  }

  @override
  Future<List<AiReviewDecision>> fetchRunReviews({
    required String runId,
  }) async {
    return reviews;
  }

  @override
  Future<List<AiRunMetric>> fetchRunMetrics({required String runId}) async {
    return metrics;
  }

  @override
  Future<AiRunReviewResult> reviewRun({
    required String runId,
    required String action,
    String? reason,
  }) async {
    reviewCount++;
    final decision = AiReviewDecision(
      id: 'review-$reviewCount',
      aiRunId: runId,
      decision: switch (action) {
        'approve_for_publication' => 'approved_for_publish',
        'reject' => 'rejected',
        'request_more_data' => 'needs_more_data',
        'keep_draft' => 'keep_draft',
        _ => action,
      },
      reason: reason,
      decidedBy: 'admin-1',
      decidedAt: DateTime.utc(2026, 6, 6, 10, reviewCount),
      metadata: <String, dynamic>{
        'action': action,
        'viewer_publication_enabled': false,
      },
    );
    reviews = <AiReviewDecision>[decision, ...reviews];

    final nextLayerStatus = switch (action) {
      'approve_for_publication' => 'approved',
      'reject' => 'rejected',
      'request_more_data' => 'draft',
      'keep_draft' => 'draft',
      _ => 'draft',
    };
    layers = layers
        .map(
          (layer) => AiOutputLayer(
            id: layer.id,
            aiRunId: layer.aiRunId,
            projectId: layer.projectId,
            layerType: layer.layerType,
            status: nextLayerStatus,
            name: layer.name,
            description: layer.description,
            storagePath: layer.storagePath,
            assetId: layer.assetId,
            crs: layer.crs,
            bounds: layer.bounds,
            style: layer.style,
            publishedAt: null,
            publishedBy: null,
            createdAt: layer.createdAt,
            updatedAt: layer.updatedAt,
          ),
        )
        .toList(growable: false);

    final run = await fetchRun(runId: runId);
    logs = <AiRunLog>[
      AiRunLog(
        id: 'review-log-$reviewCount',
        level: 'info',
        message:
            'AI review decision saved. No viewer-facing layer was published.',
        metadata: <String, dynamic>{
          'action': action,
          'viewer_publication_enabled': false,
        },
        createdAt: DateTime.utc(2026, 6, 6, 10, reviewCount),
      ),
      ...logs,
    ];
    return AiRunReviewResult(
      decision: decision,
      run: run,
      layers: layers,
      viewerPublished: false,
    );
  }

  @override
  Future<AiOutputLayer> publishLayer({required String layerId}) async {
    publishCount++;
    final index = layers.indexWhere((layer) => layer.id == layerId);
    if (index < 0) {
      throw StateError('Layer not found');
    }
    final layer = layers[index];
    final updated = _copyLayer(
      layer,
      status: 'published',
      publishedAt: DateTime.utc(2026, 6, 9, 9, publishCount),
      publishedBy: 'admin-1',
    );
    layers = <AiOutputLayer>[
      ...layers.take(index),
      updated,
      ...layers.skip(index + 1),
    ];
    logs = <AiRunLog>[
      AiRunLog(
        id: 'publish-log-$publishCount',
        level: 'info',
        message: 'AI output layer published for read-only viewer map access.',
        metadata: const <String, dynamic>{
          'viewer_publication_enabled': true,
          'spatial_feature_writes': false,
        },
        createdAt: DateTime.utc(2026, 6, 9, 9, publishCount),
      ),
      ...logs,
    ];
    return updated;
  }

  @override
  Future<AiOutputLayer> unpublishLayer({required String layerId}) async {
    unpublishCount++;
    final index = layers.indexWhere((layer) => layer.id == layerId);
    if (index < 0) {
      throw StateError('Layer not found');
    }
    final layer = layers[index];
    final updated = _copyLayer(
      layer,
      status: 'approved',
      publishedAt: null,
      publishedBy: null,
    );
    layers = <AiOutputLayer>[
      ...layers.take(index),
      updated,
      ...layers.skip(index + 1),
    ];
    logs = <AiRunLog>[
      AiRunLog(
        id: 'unpublish-log-$unpublishCount',
        level: 'info',
        message: 'AI output layer unpublished. Viewer map access was removed.',
        metadata: const <String, dynamic>{
          'viewer_publication_enabled': false,
          'spatial_feature_writes': false,
        },
        createdAt: DateTime.utc(2026, 6, 9, 10, unpublishCount),
      ),
      ...logs,
    ];
    return updated;
  }

  @override
  Future<AiReadinessResult> fetchReadiness({
    required String projectId,
    String? labelField,
    int? minSamplesPerClass,
    String? scopeType,
  }) async {
    readinessFetchCount++;
    if (failReadiness) {
      throw StateError('Readiness failed');
    }
    return AiReadinessResult(
      projectId: readiness.projectId,
      projectName: readiness.projectName,
      status: readiness.status,
      labelField: readiness.labelField,
      minSamplesPerClass: readiness.minSamplesPerClass,
      approvedFeatureCount: readiness.approvedFeatureCount,
      labeledFeatureCount: readiness.labeledFeatureCount,
      eligibleFeatureCount: readiness.eligibleFeatureCount,
      missingLabelCount: readiness.missingLabelCount,
      invalidGeometryCount: readiness.invalidGeometryCount,
      excludedFeatureCount: readiness.excludedFeatureCount,
      classCount: readiness.classCount,
      eligibleClassCount: readiness.eligibleClassCount,
      labelCounts: readiness.labelCounts,
      classesBelowMinimum: readiness.classesBelowMinimum,
      candidateLabelFields: readiness.candidateLabelFields,
      sourceColumnAvailable: readiness.sourceColumnAvailable,
      sourceCounts: readiness.sourceCounts,
      spatialExtent: readiness.spatialExtent,
      coverageWarningApplies: readiness.coverageWarningApplies,
      warnings: readiness.warnings,
      blockers: readiness.blockers,
      settings: readiness.settings,
      nationalScopeEnabled:
          readiness.nationalScopeEligibility.eligible &&
          settings.modelPreferences['national_scope_enabled'] == true,
      nationalScopeEligibility: readiness.nationalScopeEligibility,
    );
  }

  @override
  Future<PaginatedResult<AiRun>> fetchRunsPage({
    required String projectId,
    String? status,
    int page = 1,
    int limit = 20,
  }) async {
    final filtered = status == null
        ? runs
        : runs.where((run) => run.status == status).toList(growable: false);
    return PaginatedResult<AiRun>(
      items: filtered,
      page: page,
      limit: limit,
      total: filtered.length,
      hasMore: false,
    );
  }

  @override
  Future<AiProjectSettings> fetchSettings({required String projectId}) async {
    return settings.projectId == projectId
        ? settings
        : settings.copyWith(projectId: projectId);
  }

  @override
  Future<AiProjectSettings> saveSettings({
    required String projectId,
    required AiProjectSettings settings,
  }) async {
    saveCount++;
    this.settings = settings.copyWith(projectId: projectId, persisted: true);
    return this.settings;
  }
}

String? _fakeAiFeatureClass(AiLayerFeature feature) {
  for (final key in const <String>[
    'predicted_class',
    'dominant_class',
    'class_label',
    'label',
    'L4_descr',
  ]) {
    final value = feature.properties[key];
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
  }
  return null;
}

String _fakeAiFeatureSearchBlob(AiLayerFeature feature) {
  final values = <Object?>[
    feature.properties['predicted_class'],
    feature.properties['dominant_class'],
    feature.properties['class_label'],
    feature.properties['label'],
    feature.properties['model_name'],
    feature.properties['model'],
  ];
  return values
      .whereType<String>()
      .where((value) => value.trim().isNotEmpty)
      .join(' ')
      .toLowerCase();
}

AiOutputLayer _copyLayer(
  AiOutputLayer layer, {
  String? status,
  DateTime? publishedAt,
  String? publishedBy,
}) {
  return AiOutputLayer(
    id: layer.id,
    aiRunId: layer.aiRunId,
    projectId: layer.projectId,
    layerType: layer.layerType,
    status: status ?? layer.status,
    name: layer.name,
    description: layer.description,
    storagePath: layer.storagePath,
    assetId: layer.assetId,
    crs: layer.crs,
    bounds: layer.bounds,
    style: layer.style,
    publishedAt: publishedAt,
    publishedBy: publishedBy,
    createdAt: layer.createdAt,
    updatedAt: DateTime.utc(2026, 6, 9),
  );
}

AiProjectSettings fakeAiSettings({
  String projectId = 'project-1',
  bool isEnabled = false,
  String? labelField = 'L4_descr',
  String scopeType = 'project',
  int minSamplesPerClass = 50,
  Map<String, dynamic> modelPreferences = const <String, dynamic>{},
}) {
  return AiProjectSettings(
    projectId: projectId,
    isEnabled: isEnabled,
    labelField: labelField,
    scopeType: scopeType,
    minSamplesPerClass: minSamplesPerClass,
    modelPreferences: modelPreferences,
    persisted: true,
  );
}

AiReadinessResult fakeReadiness({
  String projectId = 'project-1',
  String status = 'ready',
  int approvedFeatureCount = 1394,
  int? labeledFeatureCount,
  int eligibleFeatureCount = 1394,
  int missingLabelCount = 0,
  int invalidGeometryCount = 0,
  int? eligibleClassCount,
  List<AiLabelCount> labelCounts = const <AiLabelCount>[
    AiLabelCount(label: 'Olives', sampleCount: 580),
    AiLabelCount(label: 'Fruit Trees', sampleCount: 480),
    AiLabelCount(label: 'Citrus Fruit Trees', sampleCount: 334),
  ],
  List<AiLabelCount> classesBelowMinimum = const <AiLabelCount>[],
  List<AiLabelFieldCandidate> candidateLabelFields =
      const <AiLabelFieldCandidate>[
        AiLabelFieldCandidate(
          field: 'L4_descr',
          sources: <String>['schema', 'approved_attributes', 'selected'],
          labeledFeatureCount: 1394,
          classCount: 3,
          usable: true,
          selectable: true,
          diagnosticOnly: false,
          aliases: <String>['feature_type'],
          recommended: true,
          note: 'Recommended project label field.',
        ),
        AiLabelFieldCandidate(
          field: 'feature_type',
          sources: <String>['schema', 'approved_attributes'],
          labeledFeatureCount: 1394,
          classCount: 3,
          usable: true,
          selectable: false,
          diagnosticOnly: true,
          aliasOf: 'L4_descr',
          recommended: false,
          note: 'Equivalent field mapped automatically to L4_descr.',
        ),
        AiLabelFieldCandidate(
          field: 'crop_type',
          sources: <String>['schema'],
          labeledFeatureCount: 0,
          classCount: 0,
          usable: false,
          selectable: false,
          diagnosticOnly: true,
          recommended: false,
          note: 'No labels found in approved features.',
        ),
      ],
  List<String> warnings = const <String>[],
  List<String> blockers = const <String>[],
  bool nationalScopeEnabled = false,
  AiNationalScopeEligibility
  nationalScopeEligibility = const AiNationalScopeEligibility(
    eligible: false,
    unmetRequirements: <String>[
      'National mode is enabled for this project.',
      'Lebanon boundary is configured for AI prediction.',
      'Approved training samples cover multiple Lebanese regions and environmental conditions.',
      'Every class has enough approved samples: minimum 50, recommended 100+.',
      'All samples used for training have valid and consistent labels.',
      'No class or region is dangerously underrepresented, or the warning is reviewed.',
      'The AI pipeline supports the selected satellite, dates, features, and national boundary.',
      'A validation/review plan exists before national results are published.',
    ],
    warnings: <String>[],
  ),
}) {
  return AiReadinessResult(
    projectId: projectId,
    projectName: 'South Lebanon Fruit Trees Training Dataset',
    status: status,
    labelField: 'L4_descr',
    minSamplesPerClass: 50,
    approvedFeatureCount: approvedFeatureCount,
    labeledFeatureCount: labeledFeatureCount ?? eligibleFeatureCount,
    eligibleFeatureCount: eligibleFeatureCount,
    missingLabelCount: missingLabelCount,
    invalidGeometryCount: invalidGeometryCount,
    excludedFeatureCount: approvedFeatureCount - eligibleFeatureCount,
    classCount: labelCounts.length,
    eligibleClassCount: eligibleClassCount ?? labelCounts.length,
    labelCounts: labelCounts,
    classesBelowMinimum: classesBelowMinimum,
    candidateLabelFields: candidateLabelFields,
    sourceColumnAvailable: true,
    sourceCounts: const <AiSourceCount>[
      AiSourceCount(source: 'import', featureCount: 1394),
    ],
    spatialExtent: const AiSpatialExtent(
      minLon: 35.16,
      minLat: 33.08,
      maxLon: 35.68,
      maxLat: 33.58,
    ),
    coverageWarningApplies: false,
    warnings: warnings,
    blockers: blockers,
    settings: fakeAiSettings(projectId: projectId),
    nationalScopeEnabled: nationalScopeEnabled,
    nationalScopeEligibility: nationalScopeEligibility,
  );
}
