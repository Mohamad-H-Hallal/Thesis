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
    List<AiPredictionValidationTask> validationTasks =
        const <AiPredictionValidationTask>[],
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
       reviews = List<AiReviewDecision>.from(reviews),
       validationTasks = List<AiPredictionValidationTask>.from(validationTasks);

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
  List<AiPredictionValidationTask> validationTasks;
  bool failReadiness;
  int saveCount = 0;
  int createCount = 0;
  int reviewCount = 0;
  int publishCount = 0;
  int unpublishCount = 0;
  int readinessFetchCount = 0;
  int validationGenerateCount = 0;
  int validationAssignCount = 0;
  int validationStatusCount = 0;
  int validationSubmitCount = 0;
  int validationReviewCount = 0;

  @override
  Future<AiRun> createRun({
    required String projectId,
    required String status,
    String? labelField,
    String? scopeType,
    int? minSamplesPerClass,
    String? executionMode,
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
      metadata: <String, dynamic>{
        if (executionMode?.trim().isNotEmpty ?? false)
          'execution_mode': executionMode!.trim(),
      },
      createdAt: DateTime.utc(2026, 6, 1),
    );
    runs = <AiRun>[run, ...runs];
    logs = <AiRunLog>[
      AiRunLog(
        id: 'log-$createCount',
        level: 'info',
        message: status == 'queued'
            ? 'AI run queued. Worker processing has not started yet.'
            : 'Draft AI run record created. No worker command was started.',
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
    final requestsNationalMode =
        settings.scopeType == 'national' ||
        settings.modelPreferences['national_scope_enabled'] == true;
    if (requestsNationalMode && !readiness.nationalScopeEligibility.eligible) {
      throw StateError(
        'National Lebanon is locked until national readiness requirements are met.',
      );
    }
    this.settings = settings.copyWith(projectId: projectId, persisted: true);
    return this.settings;
  }

  @override
  Future<AiPredictionValidationTaskList> fetchMyValidationTasks({
    String? status,
    String? aiRunId,
    int page = 1,
    int limit = 50,
  }) async {
    final filtered = validationTasks
        .where((task) {
          final visibleToProjectContributor =
              (task.assignedTo == null &&
                  const <String>{'open', 'submitted'}.contains(task.status)) ||
              task.assignedTo == 'contributor-1' ||
              task.latestSubmission?.submittedBy == 'contributor-1';
          return visibleToProjectContributor &&
              (status == null || task.status == status) &&
              (aiRunId == null || task.aiRunId == aiRunId);
        })
        .toList(growable: false);
    return _validationTaskList(filtered, page: page, limit: limit);
  }

  @override
  Future<AiPredictionValidationTaskList> fetchProjectValidationTasks({
    required String projectId,
    String? status,
    String? assignedTo,
    String? aiRunId,
    int page = 1,
    int limit = 50,
  }) async {
    final filtered = validationTasks
        .where((task) {
          return task.projectId == projectId &&
              (status == null || task.status == status) &&
              (assignedTo == null || task.assignedTo == assignedTo) &&
              (aiRunId == null || task.aiRunId == aiRunId);
        })
        .toList(growable: false);
    return _validationTaskList(filtered, page: page, limit: limit);
  }

  @override
  Future<AiPredictionValidationGenerateResult> generateValidationTasks({
    required String projectId,
    String? aiRunId,
    String? aiOutputLayerId,
    String? aiPredictionFeatureId,
    double? confidenceThreshold,
    int? limit,
    int? priority,
  }) async {
    validationGenerateCount++;
    final existing = validationTasks
        .where((task) => task.projectId == projectId)
        .map((task) => task.aiPredictionFeatureId)
        .toSet();
    final desiredCount = (limit ?? 2).clamp(1, 5).toInt();
    final created = <AiPredictionValidationTask>[];
    for (var index = 0; index < desiredCount; index++) {
      final predictionId =
          aiPredictionFeatureId ?? 'prediction-generated-$index';
      if (existing.contains(predictionId)) {
        continue;
      }
      final task = fakeAiValidationTask(
        id: 'generated-task-$validationGenerateCount-$index',
        projectId: projectId,
        aiRunId: aiRunId ?? 'run-1',
        aiPredictionFeatureId: predictionId,
        status: 'open',
        priority: priority ?? 0,
        prediction: fakeAiValidationPrediction(
          id: predictionId,
          predictedClass: index.isEven ? 'Olives' : 'Fruit Trees',
          confidence: confidenceThreshold == null
              ? 0.52
              : confidenceThreshold - 0.05,
          layer: aiOutputLayerId == null
              ? null
              : AiPredictionValidationLayerRef(
                  id: aiOutputLayerId,
                  layerType: 'classification',
                  name: 'Classification predictions',
                ),
        ),
      );
      created.add(task);
      existing.add(predictionId);
    }
    validationTasks = <AiPredictionValidationTask>[
      ...created,
      ...validationTasks,
    ];
    return AiPredictionValidationGenerateResult(
      createdCount: created.length,
      candidateCount: desiredCount,
      existingActiveCount: desiredCount - created.length,
      threshold: confidenceThreshold ?? 0.6,
      thresholdSource: confidenceThreshold == null ? 'default' : 'request',
      candidateLayerType: 'classification',
      criterion: 'confidence_below_threshold',
      taskIds: created.map((task) => task.id).toList(growable: false),
      noSpatialFeatureWrites: true,
    );
  }

  @override
  Future<AiPredictionValidationTask> fetchValidationTask({
    required String taskId,
  }) async {
    return _findValidationTask(taskId);
  }

  @override
  Future<AiPredictionValidationTask> assignValidationTask({
    required String taskId,
    required String assignedTo,
  }) async {
    validationAssignCount++;
    return _updateValidationTask(
      taskId,
      (task) => _copyValidationTask(
        task,
        status: 'assigned',
        assignedTo: assignedTo,
        assignedUser: AiPredictionValidationUser(
          id: assignedTo,
          fullName: 'Contributor ${_shortId(assignedTo)}',
        ),
      ),
    );
  }

  @override
  Future<AiPredictionValidationTask> updateValidationTaskStatus({
    required String taskId,
    required String status,
  }) async {
    validationStatusCount++;
    return _updateValidationTask(
      taskId,
      (task) => _copyValidationTask(task, status: status),
    );
  }

  @override
  Future<AiPredictionValidationTask> submitValidationTask({
    required String taskId,
    required String result,
    String? correctedClass,
    required String note,
    Map<String, dynamic> evidence = const <String, dynamic>{},
    String? linkedFeatureId,
  }) async {
    validationSubmitCount++;
    if (result == 'wrong_class' &&
        (correctedClass == null || correctedClass.trim().isEmpty)) {
      throw StateError('Corrected class is required.');
    }
    if (note.trim().isEmpty) {
      throw StateError('Note/evidence is required.');
    }
    return _updateValidationTask(taskId, (task) {
      if (!const <String>{
        'open',
        'assigned',
        'in_progress',
        'submitted',
      }.contains(task.status)) {
        throw StateError(
          'This AI validation task is no longer accepting submissions.',
        );
      }
      if (task.assignedTo != null && task.assignedTo != 'contributor-1') {
        throw StateError(
          'This AI validation task is assigned to another contributor.',
        );
      }
      final latestSubmission = task.latestSubmission;
      if (latestSubmission?.submittedBy == 'contributor-1' &&
          latestSubmission?.status == 'submitted') {
        throw StateError(
          'You already submitted active evidence for this AI validation task.',
        );
      }
      if (result == 'wrong_class' && correctedClass != null) {
        final trainedClasses =
            (task.prediction.metadata['trained_classes'] as List?)
                ?.whereType<String>()
                .toSet();
        if (trainedClasses != null &&
            trainedClasses.isNotEmpty &&
            !trainedClasses.contains(correctedClass)) {
          throw StateError(
            'Corrected class must be one of the trained AI classes.',
          );
        }
      }
      final submission = AiPredictionValidationSubmission(
        id: 'submission-$validationSubmitCount',
        result: result,
        correctedClass: correctedClass,
        note: note,
        evidence: evidence,
        linkedFeatureId: linkedFeatureId,
        status: 'submitted',
        submittedBy: task.assignedTo ?? 'contributor-1',
        createdAt: DateTime.utc(2026, 6, 12, 9, validationSubmitCount),
      );
      return _copyValidationTask(
        task,
        status: 'submitted',
        latestSubmission: submission,
      );
    });
  }

  @override
  Future<AiPredictionValidationTask> reviewValidationTask({
    required String taskId,
    required String decision,
    String? reason,
    String? submissionId,
  }) async {
    validationReviewCount++;
    if (decision == 'rejected' && (reason?.trim().isEmpty ?? true)) {
      throw StateError('Reject reason is required.');
    }
    return _updateValidationTask(taskId, (task) {
      final submission = task.latestSubmission;
      final reviewedSubmission = submission == null
          ? null
          : AiPredictionValidationSubmission(
              id: submission.id,
              result: submission.result,
              correctedClass: submission.correctedClass,
              note: submission.note,
              evidence: submission.evidence,
              linkedFeatureId: submission.linkedFeatureId,
              status: decision,
              submittedBy: submission.submittedBy,
              createdAt: submission.createdAt,
              reviewedAt: DateTime.utc(2026, 6, 12, 10, validationReviewCount),
              reviewedBy: 'admin-1',
            );
      return _copyValidationTask(
        task,
        status: decision,
        reviewedBy: 'admin-1',
        reviewedUser: const AiPredictionValidationUser(
          id: 'admin-1',
          fullName: 'Protected Super Admin',
        ),
        reviewDecision: decision,
        reviewReason: reason,
        latestSubmission: reviewedSubmission,
      );
    });
  }

  AiPredictionValidationTask _findValidationTask(String taskId) {
    return validationTasks.firstWhere(
      (task) => task.id == taskId,
      orElse: () => throw StateError('Validation task not found'),
    );
  }

  AiPredictionValidationTask _updateValidationTask(
    String taskId,
    AiPredictionValidationTask Function(AiPredictionValidationTask task) update,
  ) {
    final index = validationTasks.indexWhere((task) => task.id == taskId);
    if (index < 0) {
      throw StateError('Validation task not found');
    }
    final updated = update(validationTasks[index]);
    validationTasks = <AiPredictionValidationTask>[
      ...validationTasks.take(index),
      updated,
      ...validationTasks.skip(index + 1),
    ];
    return updated;
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

AiPredictionValidationTaskList _validationTaskList(
  List<AiPredictionValidationTask> tasks, {
  required int page,
  required int limit,
}) {
  final counts = <String, int>{};
  for (final task in tasks) {
    counts[task.status] = (counts[task.status] ?? 0) + 1;
  }
  final safePage = page < 1 ? 1 : page;
  final safeLimit = limit < 1 ? 50 : limit;
  final start = (safePage - 1) * safeLimit;
  final end = start + safeLimit > tasks.length
      ? tasks.length
      : start + safeLimit;
  final pageItems = start >= tasks.length
      ? const <AiPredictionValidationTask>[]
      : tasks.sublist(start, end);
  return AiPredictionValidationTaskList(
    tasks: pageItems,
    statusCounts: counts,
    page: safePage,
    limit: safeLimit,
    total: tasks.length,
    hasMore: end < tasks.length,
    notOfficialFieldData: true,
    noSpatialFeatureWrites: true,
  );
}

AiPredictionValidationTask _copyValidationTask(
  AiPredictionValidationTask task, {
  String? status,
  String? assignedTo,
  AiPredictionValidationUser? assignedUser,
  String? reviewedBy,
  AiPredictionValidationUser? reviewedUser,
  String? reviewDecision,
  String? reviewReason,
  AiPredictionValidationSubmission? latestSubmission,
}) {
  return AiPredictionValidationTask(
    id: task.id,
    projectId: task.projectId,
    aiRunId: task.aiRunId,
    aiPredictionFeatureId: task.aiPredictionFeatureId,
    status: status ?? task.status,
    assignedTo: assignedTo ?? task.assignedTo,
    assignedUser: assignedUser ?? task.assignedUser,
    createdBy: task.createdBy,
    createdUser: task.createdUser,
    reviewedBy: reviewedBy ?? task.reviewedBy,
    reviewedUser: reviewedUser ?? task.reviewedUser,
    reviewDecision: reviewDecision ?? task.reviewDecision,
    reviewReason: reviewReason ?? task.reviewReason,
    priority: task.priority,
    dueAt: task.dueAt,
    metadata: task.metadata,
    prediction: task.prediction,
    latestSubmission: latestSubmission ?? task.latestSubmission,
    notOfficialFieldData: task.notOfficialFieldData,
    noSpatialFeatureWrites: task.noSpatialFeatureWrites,
    createdAt: task.createdAt,
    updatedAt: DateTime.utc(2026, 6, 12),
  );
}

String _shortId(String id) {
  final trimmed = id.trim();
  return trimmed.length <= 8 ? trimmed : trimmed.substring(0, 8);
}

AiPredictionValidationPrediction fakeAiValidationPrediction({
  String id = 'prediction-1',
  String? predictedClass = 'Olives',
  double? confidence = 0.53,
  double? uncertaintyScore = 0.47,
  String modelName = 'random_forest',
  AiPredictionValidationLayerRef? layer,
  Map<String, dynamic> metadata = const <String, dynamic>{
    'trained_classes': <String>['Olives', 'Fruit Trees', 'Citrus Fruit Trees'],
  },
}) {
  return AiPredictionValidationPrediction(
    id: id,
    artifactFeatureId: 'artifact-$id',
    geometry: const <String, dynamic>{
      'type': 'Point',
      'coordinates': <double>[35.45, 33.28],
    },
    geometryType: 'Point',
    predictedClass: predictedClass,
    confidence: confidence,
    uncertaintyScore: uncertaintyScore,
    modelName: modelName,
    source: 'ai_prediction',
    status: 'ready_for_review',
    metadata: metadata,
    layer:
        layer ??
        const AiPredictionValidationLayerRef(
          id: 'layer-1',
          layerType: 'classification',
          name: 'Classification predictions',
        ),
    notOfficialFieldData: true,
  );
}

AiPredictionValidationTask fakeAiValidationTask({
  String id = 'validation-task-1',
  String projectId = 'project-1',
  String aiRunId = 'run-1',
  String aiPredictionFeatureId = 'prediction-1',
  String status = 'assigned',
  String? assignedTo = 'contributor-1',
  AiPredictionValidationUser? assignedUser = const AiPredictionValidationUser(
    id: 'contributor-1',
    fullName: 'Field Contributor',
  ),
  AiPredictionValidationPrediction? prediction,
  AiPredictionValidationSubmission? latestSubmission,
  int priority = 0,
}) {
  return AiPredictionValidationTask(
    id: id,
    projectId: projectId,
    aiRunId: aiRunId,
    aiPredictionFeatureId: aiPredictionFeatureId,
    status: status,
    assignedTo: assignedTo,
    assignedUser: assignedTo == null ? null : assignedUser,
    createdBy: 'admin-1',
    createdUser: const AiPredictionValidationUser(
      id: 'admin-1',
      fullName: 'Protected Super Admin',
    ),
    priority: priority,
    metadata: const <String, dynamic>{
      'threshold_used': 0.6,
      'task_source': 'low_confidence_prediction',
    },
    prediction:
        prediction ?? fakeAiValidationPrediction(id: aiPredictionFeatureId),
    latestSubmission: latestSubmission,
    notOfficialFieldData: true,
    noSpatialFeatureWrites: true,
    createdAt: DateTime.utc(2026, 6, 12, 8),
    updatedAt: DateTime.utc(2026, 6, 12, 8),
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
    requirements: <AiNationalScopeRequirement>[
      AiNationalScopeRequirement(
        key: 'national_mode_allowed',
        label: 'National mode allowed for this project',
        passed: false,
        currentValue: false,
        requiredValue: true,
        message:
            'A protected super-admin must allow national AI mode for this project.',
      ),
      AiNationalScopeRequirement(
        key: 'lebanon_boundary_configured',
        label: 'Lebanon boundary configured',
        passed: false,
        currentValue: 'not configured',
        requiredValue: 'usable Lebanon boundary',
        message:
            'Lebanon boundary/ROI must be configured before national mode can be enabled.',
      ),
      AiNationalScopeRequirement(
        key: 'pipeline_supports_national_processing',
        label: 'Pipeline supports national processing',
        passed: false,
        currentValue:
            'national scope: false; backend bridge: false; Python pipeline: false',
        requiredValue:
            'backend bridge and Python pipeline support national ROI',
        message:
            'National mode stays locked until the backend bridge and Python pipeline support national ROI/config processing.',
      ),
      AiNationalScopeRequirement(
        key: 'regional_coverage_configured',
        label: 'Geographic coverage is broad enough',
        passed: false,
        currentValue: 'coverage check not configured',
        requiredValue:
            'configured regional/governorate or environmental-zone coverage check',
        message: 'Regional coverage check is not configured yet.',
      ),
    ],
    unmetRequirements: <String>[
      'A protected super-admin must allow national AI mode for this project.',
      'Lebanon boundary/ROI must be configured before national mode can be enabled.',
      'National mode stays locked until the backend bridge and Python pipeline support national ROI/config processing.',
      'Regional coverage check is not configured yet.',
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
