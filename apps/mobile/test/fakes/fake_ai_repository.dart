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
    List<AiRunLog> logs = const <AiRunLog>[],
    this.failReadiness = false,
  }) : settings = settings ?? AiProjectSettings.defaults('project-1'),
       readiness = readiness ?? fakeReadiness(projectId: 'project-1'),
       runs = List<AiRun>.from(runs),
       metrics = List<AiRunMetric>.from(metrics),
       layers = List<AiOutputLayer>.from(layers),
       logs = List<AiRunLog>.from(logs);

  AiProjectSettings settings;
  AiReadinessResult readiness;
  List<AiRun> runs;
  List<AiRunMetric> metrics;
  List<AiOutputLayer> layers;
  List<AiRunLog> logs;
  bool failReadiness;
  int saveCount = 0;
  int createCount = 0;
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
        message: 'Draft AI run record created. Worker not connected yet.',
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
  Future<List<AiRunMetric>> fetchRunMetrics({required String runId}) async {
    return metrics;
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
    return readiness;
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

AiProjectSettings fakeAiSettings({
  String projectId = 'project-1',
  bool isEnabled = false,
  String? labelField = 'L4_descr',
  String scopeType = 'project',
  int minSamplesPerClass = 50,
}) {
  return AiProjectSettings(
    projectId: projectId,
    isEnabled: isEnabled,
    labelField: labelField,
    scopeType: scopeType,
    minSamplesPerClass: minSamplesPerClass,
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
  );
}
