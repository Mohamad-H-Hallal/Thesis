import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/features/ai/domain/ai_models.dart';
import 'package:lebanese_gis_mobile/features/ai/presentation/ai_providers.dart';
import 'package:lebanese_gis_mobile/features/ai/presentation/screens/project_ai_screen.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';
import 'package:lebanese_gis_mobile/features/map/domain/map_feature.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/project.dart';
import 'package:lebanese_gis_mobile/features/projects/presentation/screens/project_details_screen.dart';

import '../../../fakes/fake_ai_repository.dart';

class _NoopAuthRepository implements AuthRepository {
  const _NoopAuthRepository();

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {}

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
    required bool rememberMe,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> logout() async {}

  @override
  Future<PasswordResetRequestResult> requestPasswordReset(String email) async {
    return const PasswordResetRequestResult(message: 'sent');
  }

  @override
  Future<PasswordResetOtpVerificationResult> verifyPasswordResetOtp({
    required String email,
    required String otp,
  }) async => PasswordResetOtpVerificationResult(
    message: 'verified',
    resetToken: 'token',
    email: email,
  );

  @override
  Future<void> resetPassword({
    required String resetToken,
    required String newPassword,
  }) async {}

  @override
  Future<AuthSession> reactivateContributorAndLogin({
    required String email,
    required String password,
    required bool rememberMe,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> selfDeactivate() async {}

  @override
  Future<AuthSession?> restoreSession() async => null;

  @override
  Future<String> signup({
    required String fullName,
    required String email,
    required String password,
    required UserRole role,
    String? phone,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<AppUser> updateProfile({String? fullName, String? phone}) async {
    throw UnimplementedError();
  }
}

class _AuthenticatedAuthController extends AuthController {
  _AuthenticatedAuthController(AuthSession session)
    : super(const _NoopAuthRepository()) {
    state = AuthState.authenticated(session);
  }
}

AuthSession _session({
  required UserRole role,
  String userId = 'admin-1',
  bool isProtectedSuperAdmin = false,
}) {
  return AuthSession(
    accessToken: 'token-$userId',
    refreshToken: 'refresh-$userId',
    user: AppUser(
      id: userId,
      fullName: '${role.name} user',
      email: '${role.name}-$userId@example.com',
      role: role,
      isProtectedSuperAdmin: isProtectedSuperAdmin,
    ),
  );
}

ProjectSummary _project({
  ProjectAssignmentRole? currentRole,
  ProjectAssignmentStatus? currentStatus,
  List<CollectionFormFieldSchema> fields = const <CollectionFormFieldSchema>[
    CollectionFormFieldSchema(
      key: 'L4_descr',
      label: 'L4 description',
      type: CollectionFieldType.select,
      required: true,
    ),
    CollectionFormFieldSchema(
      key: 'feature_type',
      label: 'Feature type',
      type: CollectionFieldType.select,
    ),
    CollectionFormFieldSchema(
      key: 'crop_type',
      label: 'Crop type',
      type: CollectionFieldType.select,
    ),
  ],
}) {
  return ProjectSummary(
    id: 'project-1',
    name: 'South Lebanon Fruit Trees Training Dataset',
    category: 'Agriculture',
    status: 'active',
    approvedFeatures: 1394,
    assignedCollectors: 2,
    pendingReviews: 0,
    description: 'Training data project',
    visibleToViewers: true,
    visibleToContributors: true,
    currentUserAssignmentRole: currentRole,
    currentUserAssignmentStatus: currentStatus,
    collectionFormSchema: CollectionFormSchema(version: 'v2', fields: fields),
  );
}

Widget _wrap({
  required AuthSession session,
  required ProjectSummary project,
  required Widget child,
  FakeAiRepository? aiRepository,
}) {
  final fakeAi =
      aiRepository ??
      FakeAiRepository(
        settings: fakeAiSettings(projectId: project.id),
        readiness: fakeReadiness(projectId: project.id),
      );

  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWith(
        (_) => _AuthenticatedAuthController(session),
      ),
      aiRepositoryProvider.overrideWithValue(fakeAi),
      projectByIdProvider.overrideWith((ref, id) async => project),
      projectMapFeaturesProvider.overrideWith(
        (ref, projectId) async => const <MapFeatureSummary>[],
      ),
      offlineMapPackageProvider.overrideWith((ref) async => null),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

Future<void> _pumpAiScreen(
  WidgetTester tester, {
  required AuthSession session,
  required ProjectSummary project,
  FakeAiRepository? aiRepository,
  String section = 'readiness',
}) async {
  await tester.pumpWidget(
    _wrap(
      session: session,
      project: project,
      aiRepository: aiRepository,
      child: ProjectAiScreen(projectId: project.id, initialSection: section),
    ),
  );
  await tester.pumpAndSettle();
}

AiRun _phaseFRegionalRun({
  required String projectId,
  String id = '00f4bb0c-66cc-4fec-80c3-f3ecc96175f4',
  String status = 'ready_for_review',
  String executionMode = 'regional_model_eval',
  String? failureReason,
}) {
  return AiRun(
    id: id,
    projectId: projectId,
    status: status,
    labelField: 'L4_descr',
    scopeType: 'project',
    trainingFeatureCount: 1406,
    eligibleFeatureCount: 1394,
    excludedFeatureCount: 12,
    selectedModel: 'svm_rbf',
    createdAt: DateTime.utc(2026, 6, 5, 10),
    startedAt: DateTime.utc(2026, 6, 5, 10, 1),
    completedAt: status == 'failed' ? null : DateTime.utc(2026, 6, 5, 10, 2, 1),
    failedAt: status == 'failed' ? DateTime.utc(2026, 6, 5, 10, 2) : null,
    failureReason: failureReason,
    metadata: <String, dynamic>{
      'execution_mode': executionMode,
      'duration_ms': 60155,
      'training_samples_area_type': 'project_area',
      'prediction_area_type': 'project_area',
      'national_scope_enabled': false,
      'national_scope_eligibility': <String, dynamic>{
        'eligible': false,
        'requirements': <Map<String, dynamic>>[
          <String, dynamic>{
            'key': 'national_mode_allowed',
            'label': 'National mode allowed for this project',
            'passed': false,
            'message':
                'A protected super-admin must allow national AI mode for this project.',
          },
          <String, dynamic>{
            'key': 'regional_coverage_configured',
            'label': 'Geographic coverage is broad enough',
            'passed': false,
            'message': 'Regional coverage check is not configured yet.',
          },
        ],
        'unmet_requirements': <String>[
          'A protected super-admin must allow national AI mode for this project.',
          'Regional coverage check is not configured yet.',
        ],
        'warnings': <String>[],
      },
      'ai_settings': <String, dynamic>{
        'satellite_source': 'sentinel2',
        'target_year': 2026,
        'season': 'growing',
        'date_from': '2026-03-01',
        'date_to': '2026-10-31',
        'feature_inputs': <String>['NDVI', 'EVI', 'NDRE'],
        'preferred_model': 'svm_rbf',
        'scope_type': 'project',
        'training_samples_area_type': 'project_area',
        'prediction_area_type': 'project_area',
        'custom_scope_applied': false,
      },
      'pipeline_execution_support': <String, dynamic>{
        'settings_saved_for_run': true,
        'backend_scope_applied': true,
        'pipeline_config_payload_ready': true,
        'effective_pipeline_settings': <String>[
          'label_field',
          'execution_mode',
          'training_samples_area_type',
        ],
        'pending_pipeline_settings': <String>[
          'satellite_source',
          'date_range',
          'feature_inputs',
          'prediction_area_type',
        ],
      },
      'ai_pipeline_run_id': 'app-ai-00f4bb0c66cc4fec80c3f3ec',
      'pipeline_bridge_phase': 'phase_f',
      'worker_phase': 'regional_worker',
      'output_directory': 'outputs/runs/app-ai-00f4bb0c66cc4fec80c3f3ec',
      'output_paths': <String>[
        'outputs/projects/$projectId/ground_truth.geojson',
        'outputs/runs/app-ai-00f4bb0c66cc4fec80c3f3ec/feature_table.csv',
        'outputs/runs/app-ai-00f4bb0c66cc4fec80c3f3ec/metrics.json',
        'outputs/runs/app-ai-00f4bb0c66cc4fec80c3f3ec/confusion_matrix.csv',
        'outputs/runs/app-ai-00f4bb0c66cc4fec80c3f3ec/model_metadata.json',
        'outputs/runs/app-ai-00f4bb0c66cc4fec80c3f3ec/feature_importance.csv',
      ],
      'class_counts': <Map<String, dynamic>>[
        <String, dynamic>{'class_label': 'Olives', 'sample_count': 940},
        <String, dynamic>{'class_label': 'Fruit Trees', 'sample_count': 253},
        <String, dynamic>{
          'class_label': 'Citrus Fruit Trees',
          'sample_count': 201,
        },
        <String, dynamic>{'class_label': 'Vineyards', 'sample_count': 12},
      ],
      'excluded_classes': <Map<String, dynamic>>[
        <String, dynamic>{'class_label': 'Vineyards', 'sample_count': 12},
      ],
      'scientific_limitations': <String>[
        'Regional proof-of-concept only; not a national model.',
        'AI predictions remain separate from approved field/import features.',
      ],
      'model_metrics_summary': <String, dynamic>{
        'best_model': 'svm_rbf',
        'sample_count': 1394,
        'train_count': 1105,
        'test_count': 289,
        'dropped_null_rows': 0,
        'models': <String, dynamic>{
          'random_forest': <String, dynamic>{
            'accuracy': 0.7785467128027682,
            'macro_f1': 0.5460684259981677,
            'weighted_f1': 0.7448882408657982,
          },
          'svm_rbf': <String, dynamic>{
            'accuracy': 0.7162629757785467,
            'macro_f1': 0.6167855821573912,
            'weighted_f1': 0.7390514814008126,
          },
          'xgboost': <String, dynamic>{
            'accuracy': 0.7923875432525952,
            'macro_f1': 0.5765313488008162,
            'weighted_f1': 0.7600163582946212,
          },
        },
        'warnings': <String>[
          'Dataset is South/Southwest Lebanon only; do not claim national accuracy.',
          'Vineyards excluded because n=12 is below the current threshold.',
          'Fruit Trees is a broad/ambiguous label.',
        ],
      },
    },
  );
}

AiRun _phaseQRegionalRun({required String projectId}) {
  final base = _phaseFRegionalRun(
    projectId: projectId,
    id: 'phase-q-settings-driven-run',
    executionMode: 'regional_feature_extraction',
  );
  final metadata = Map<String, dynamic>.from(base.metadata);
  metadata['run_config_path'] =
      'tmp/ai-run-configs/phase-q-settings-driven-run.json';
  metadata['run_config'] = <String, dynamic>{
    'contract_version': 1,
    'satellite_source': 'sentinel2',
    'season': 'summer',
    'from_date': '2025-06-01',
    'to_date': '2025-08-31',
    'selected_extracted_feature_count': 10,
    'preferred_model': 'random_forest',
    'training_samples_area_type': 'project_area',
    'prediction_area_type': 'project_area',
    'custom_polygon_used': false,
    'national_scope_enabled': false,
    'allow_spatial_feature_writes': false,
    'publish_outputs': false,
  };
  metadata['ai_settings'] = <String, dynamic>{
    'satellite_source': 'sentinel2',
    'target_year': 2025,
    'season': 'summer',
    'date_from': '2025-06-01',
    'date_to': '2025-08-31',
    'feature_inputs': <String>[
      'B2',
      'B3',
      'B4',
      'B5',
      'B8',
      'B11',
      'B12',
      'NDVI',
      'EVI',
      'NDRE',
    ],
    'preferred_model': 'random_forest',
    'scope_type': 'project',
    'training_samples_area_type': 'project_area',
    'prediction_area_type': 'project_area',
    'custom_scope_applied': false,
  };
  metadata['pipeline_execution_support'] = <String, dynamic>{
    'settings_saved_for_run': true,
    'backend_scope_applied': true,
    'pipeline_config_payload_ready': true,
    'python_pipeline_config_consumed': true,
    'effective_pipeline_settings': <String>[
      'satellite_source',
      'date_range',
      'feature_inputs',
      'preferred_model',
      'label_field',
      'execution_mode',
      'training_samples_area_type',
      'prediction_area_type',
    ],
    'pending_pipeline_settings': <String>[],
  };

  return AiRun(
    id: base.id,
    projectId: base.projectId,
    projectName: base.projectName,
    status: base.status,
    labelField: base.labelField,
    scopeType: base.scopeType,
    regionPreset: base.regionPreset,
    trainingFeatureCount: base.trainingFeatureCount,
    eligibleFeatureCount: base.eligibleFeatureCount,
    excludedFeatureCount: base.excludedFeatureCount,
    selectedModel: 'random_forest',
    startedAt: base.startedAt,
    completedAt: base.completedAt,
    failedAt: base.failedAt,
    failureReason: base.failureReason,
    createdAt: base.createdAt,
    updatedAt: base.updatedAt,
    metadata: metadata,
  );
}

List<AiRunLog> _phaseFLogs() {
  return <AiRunLog>[
    AiRunLog(
      id: 'log-1',
      level: 'info',
      message: 'Worker started regional model evaluation.',
      metadata: const <String, dynamic>{'step': 'extracting_features'},
      createdAt: DateTime.utc(2026, 6, 5, 10, 1),
    ),
    AiRunLog(
      id: 'log-2',
      level: 'info',
      message: 'Feature extraction completed.',
      metadata: const <String, dynamic>{
        'step': 'extracting_features',
        'duration_ms': 143950,
      },
      createdAt: DateTime.utc(2026, 6, 5, 10, 1, 45),
    ),
    AiRunLog(
      id: 'log-3',
      level: 'warning',
      message: 'Config checked with DB_PASSWORD=secret-value',
      metadata: const <String, dynamic>{'step': 'training'},
      createdAt: DateTime.utc(2026, 6, 5, 10, 2),
    ),
  ];
}

List<AiOutputLayer> _reviewableLayers() {
  return <AiOutputLayer>[
    AiOutputLayer(
      id: 'layer-statistics',
      aiRunId: '00f4bb0c-66cc-4fec-80c3-f3ecc96175f4',
      projectId: 'project-1',
      layerType: 'statistics',
      status: 'ready_for_review',
      name: 'Regional model statistics',
      description: 'Unpublished regional class statistics for review.',
      storagePath: 'outputs/runs/phase-j/statistics_layer.json',
      crs: 'EPSG:4326',
      bounds: const <String, dynamic>{'type': 'Polygon'},
      createdAt: DateTime.utc(2026, 6, 5, 10, 3),
    ),
  ];
}

List<AiOutputLayer> _phaseNReviewLayers() {
  return <AiOutputLayer>[
    AiOutputLayer(
      id: 'layer-classification',
      aiRunId: '00f4bb0c-66cc-4fec-80c3-f3ecc96175f4',
      projectId: 'project-1',
      layerType: 'classification',
      status: 'ready_for_review',
      name: 'Regional classification review',
      description: 'Unpublished AI classification polygons.',
      storagePath: 'outputs/runs/phase-m/ai_classification_review.geojson',
      crs: 'EPSG:4326',
      createdAt: DateTime.utc(2026, 6, 6, 12),
    ),
    AiOutputLayer(
      id: 'layer-confidence',
      aiRunId: '00f4bb0c-66cc-4fec-80c3-f3ecc96175f4',
      projectId: 'project-1',
      layerType: 'confidence',
      status: 'ready_for_review',
      name: 'Regional confidence review',
      description: 'Unpublished confidence artifact.',
      storagePath: 'outputs/runs/phase-m/ai_confidence_review.geojson',
      crs: 'EPSG:4326',
      createdAt: DateTime.utc(2026, 6, 6, 12),
    ),
    AiOutputLayer(
      id: 'layer-uncertainty',
      aiRunId: '00f4bb0c-66cc-4fec-80c3-f3ecc96175f4',
      projectId: 'project-1',
      layerType: 'uncertainty',
      status: 'ready_for_review',
      name: 'Regional uncertainty review',
      description: 'Unpublished uncertain validation areas.',
      storagePath: 'outputs/runs/phase-m/ai_uncertainty_areas.geojson',
      crs: 'EPSG:4326',
      createdAt: DateTime.utc(2026, 6, 6, 12),
    ),
    ..._reviewableLayers(),
  ];
}

Map<String, AiLayerFeatureCollection> _phaseNLayerFeatures(
  List<AiOutputLayer> layers,
) {
  AiOutputLayer layer(String id) => layers.firstWhere((item) => item.id == id);
  final geometry = <String, dynamic>{
    'type': 'Polygon',
    'coordinates': <List<List<double>>>[
      <List<double>>[
        <double>[35.52, 33.46],
        <double>[35.54, 33.46],
        <double>[35.54, 33.48],
        <double>[35.52, 33.48],
        <double>[35.52, 33.46],
      ],
    ],
  };
  AiLayerFeature feature(
    String id,
    Map<String, dynamic> properties, {
    Map<String, dynamic>? featureGeometry,
  }) {
    return AiLayerFeature(
      id: id,
      geometry: featureGeometry ?? geometry,
      properties: properties,
    );
  }

  final invalidPolygonGeometry = <String, dynamic>{
    'type': 'Polygon',
    'coordinates': <List<List<double>>>[
      <List<double>>[
        <double>[35.55, 33.49],
        <double>[35.56, 33.50],
      ],
    ],
  };
  final classificationFeatures = <AiLayerFeature>[
    feature('classification-1', const <String, dynamic>{
      'predicted_class': 'Olives',
      'confidence': 0.82,
      'model_name': 'random_forest',
      'source': 'ai_prediction',
      'run_id': '00f4bb0c-66cc-4fec-80c3-f3ecc96175f4',
      'area_ha': 1.4,
    }),
    feature('classification-invalid-ring', const <String, dynamic>{
      'predicted_class': 'Olives',
      'confidence': 0.77,
      'model_name': 'random_forest',
      'source': 'ai_prediction',
      'run_id': '00f4bb0c-66cc-4fec-80c3-f3ecc96175f4',
    }, featureGeometry: invalidPolygonGeometry),
    for (var index = 2; index < 25; index++)
      feature('classification-$index', <String, dynamic>{
        'predicted_class': switch (index % 3) {
          0 => 'Olives',
          1 => 'Citrus fruit trees',
          _ => 'Fruit Trees',
        },
        'confidence': 0.6 + (index / 100),
        'model_name': 'random_forest',
        'source': 'ai_prediction',
        'run_id': '00f4bb0c-66cc-4fec-80c3-f3ecc96175f4',
      }),
  ];

  return <String, AiLayerFeatureCollection>{
    'layer-classification': AiLayerFeatureCollection(
      layer: layer('layer-classification'),
      features: classificationFeatures,
      featureCount: 1394,
      matchingFeatureCount: 1394,
      returnedFeatureCount: 2,
      detail: 'overview',
      geometryMode: 'simplified',
      capped: true,
      cap: 2,
      classCounts: const <String, int>{
        'Olives': 1147,
        'Citrus fruit trees': 181,
        'Fruit Trees': 66,
      },
    ),
    'layer-confidence': AiLayerFeatureCollection(
      layer: layer('layer-confidence'),
      features: <AiLayerFeature>[
        feature('confidence-1', const <String, dynamic>{
          'predicted_class': 'Olives',
          'confidence': 0.82,
          'model_name': 'random_forest',
          'source': 'ai_prediction',
          'run_id': '00f4bb0c-66cc-4fec-80c3-f3ecc96175f4',
        }),
      ],
      featureCount: 1394,
      matchingFeatureCount: 1394,
      returnedFeatureCount: 1,
      detail: 'overview',
      geometryMode: 'simplified',
    ),
    'layer-uncertainty': AiLayerFeatureCollection(
      layer: layer('layer-uncertainty'),
      features: <AiLayerFeature>[
        feature('uncertainty-1', const <String, dynamic>{
          'predicted_class': 'Fruit Trees',
          'confidence': 0.41,
          'model_name': 'random_forest',
          'source': 'ai_prediction',
          'run_id': '00f4bb0c-66cc-4fec-80c3-f3ecc96175f4',
        }),
      ],
      featureCount: 279,
      matchingFeatureCount: 279,
      returnedFeatureCount: 1,
      detail: 'overview',
      geometryMode: 'simplified',
    ),
  };
}

List<AiReviewDecision> _reviewHistory() {
  return <AiReviewDecision>[
    AiReviewDecision(
      id: 'review-1',
      aiRunId: '00f4bb0c-66cc-4fec-80c3-f3ecc96175f4',
      decision: 'approved_for_publish',
      reason: 'Metrics are acceptable for future publication review.',
      decidedBy: 'NCRS Administrator',
      decidedAt: DateTime.utc(2026, 6, 6, 10),
      metadata: const <String, dynamic>{'viewer_publication_enabled': false},
    ),
  ];
}

void main() {
  testWidgets('AI controls are visible only for protected super-admins', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    await tester.pumpWidget(
      _wrap(
        session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
        project: project,
        child: ProjectDetailsScreen(projectId: project.id),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('AI'), findsWidgets);
    expect(find.text('AI settings'), findsOneWidget);
    expect(find.text('AI Runs'), findsNothing);
    expect(find.text('Check readiness'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      _wrap(
        session: _session(role: UserRole.admin, userId: 'admin-1'),
        project: project,
        child: ProjectDetailsScreen(projectId: project.id),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('AI settings'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      _wrap(
        session: _session(role: UserRole.viewer, userId: 'viewer-1'),
        project: project,
        child: ProjectDetailsScreen(projectId: project.id),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('AI settings'), findsNothing);
  });

  testWidgets('project-admin contributor cannot see AI foundation yet', (
    tester,
  ) async {
    final project = _project(
      currentRole: ProjectAssignmentRole.admin,
      currentStatus: ProjectAssignmentStatus.approved,
    );

    await tester.pumpWidget(
      _wrap(
        session: _session(role: UserRole.contributor, userId: 'project-admin'),
        project: project,
        child: ProjectDetailsScreen(projectId: project.id),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('AI settings'), findsNothing);
  });

  testWidgets(
    'readiness card displays ready state, class counts, and scope warning',
    (tester) async {
      final project = _project();
      await _pumpAiScreen(
        tester,
        session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
        project: project,
      );

      expect(find.text('AI Readiness'), findsOneWidget);
      expect(find.text('Ready for regional AI'), findsWidgets);
      expect(find.textContaining('Olives: 580'), findsOneWidget);
      expect(find.textContaining('Fruit Trees: 480'), findsOneWidget);
      expect(find.textContaining('Citrus Fruit Trees: 334'), findsOneWidget);
      expect(
        find.text('Regional AI only. National AI requires wider coverage.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('readiness card handles warning and not ready states', (
    tester,
  ) async {
    final project = _project();
    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: FakeAiRepository(
        settings: fakeAiSettings(projectId: project.id),
        readiness: fakeReadiness(
          projectId: project.id,
          status: 'warning',
          approvedFeatureCount: 1406,
          labeledFeatureCount: 1406,
          eligibleFeatureCount: 1394,
          eligibleClassCount: 3,
          labelCounts: const <AiLabelCount>[
            AiLabelCount(label: 'Olives', sampleCount: 940),
            AiLabelCount(label: 'Fruit Trees', sampleCount: 253),
            AiLabelCount(label: 'Citrus Fruit Trees', sampleCount: 201),
            AiLabelCount(label: 'Vineyards', sampleCount: 12),
          ],
          classesBelowMinimum: const <AiLabelCount>[
            AiLabelCount(label: 'Vineyards', sampleCount: 12),
          ],
          warnings: const <String>[
            'Classes below 50 samples will be excluded from the AI run: Vineyards (12).',
          ],
        ),
      ),
    );

    expect(
      find.text('Warning: ready for regional AI with limitations'),
      findsOneWidget,
    );
    expect(find.text('Eligible classes 3'), findsOneWidget);
    expect(find.text('Eligible samples 1394'), findsOneWidget);
    expect(find.text('Classes excluded from AI run'), findsOneWidget);
    expect(find.textContaining('Vineyards:'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: FakeAiRepository(
        settings: fakeAiSettings(projectId: project.id),
        readiness: fakeReadiness(
          projectId: project.id,
          status: 'not_ready',
          approvedFeatureCount: 4,
          labeledFeatureCount: 4,
          eligibleFeatureCount: 0,
          eligibleClassCount: 0,
          blockers: const <String>[
            'At least two labeled classes are required.',
          ],
          labelCounts: const <AiLabelCount>[
            AiLabelCount(label: 'Olives', sampleCount: 4),
          ],
        ),
      ),
    );

    expect(find.text('Not ready for AI yet'), findsOneWidget);
    expect(
      find.text('At least two labeled classes are required.'),
      findsOneWidget,
    );
  });

  testWidgets('readiness refresh gives visible feedback', (tester) async {
    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
    );

    expect(repository.readinessFetchCount, 1);

    await tester.ensureVisible(find.text('Refresh readiness'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh readiness'));
    await tester.pumpAndSettle();

    expect(repository.readinessFetchCount, greaterThanOrEqualTo(2));
    expect(find.text('Readiness checked.'), findsWidgets);
  });

  testWidgets('workspace tabs stay compact on a narrow Android-sized screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
    );

    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Runs'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings form loads values and saves super-admin edits', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(
        projectId: project.id,
        isEnabled: false,
        labelField: 'feature_type',
        minSamplesPerClass: 25,
      ),
      readiness: fakeReadiness(projectId: project.id),
    );
    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'settings',
    );

    expect(find.text('AI Settings'), findsOneWidget);
    expect(find.text('L4_descr - recommended'), findsOneWidget);
    expect(find.text('feature_type - available'), findsNothing);
    expect(find.text('crop_type - no labels'), findsNothing);
    expect(find.text('Custom AI area'), findsNothing);
    expect(
      find.text('Choose the field the AI should learn as the class label.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Equivalent imported fields were detected and mapped automatically.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Project area uses approved samples from this project. National Lebanon requires representative samples across Lebanon.',
      ),
      findsOneWidget,
    );

    final minField = find.widgetWithText(
      TextFormField,
      'Minimum samples per class',
    );
    await tester.enterText(minField, '40');
    final saveButton = find.widgetWithText(FilledButton, 'Save settings');
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(repository.saveCount, 1);
    expect(repository.settings.labelField, 'L4_descr');
    expect(repository.settings.minSamplesPerClass, 40);
    expect(find.text('AI settings saved successfully.'), findsOneWidget);
  });

  testWidgets('custom polygon scope is available in settings', (tester) async {
    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
    );
    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'settings',
    );

    final areaDropdown = find.byKey(const ValueKey<String>('ai-area-dropdown'));
    await tester.tap(areaDropdown);
    await tester.pumpAndSettle();

    expect(find.text('Custom AI area'), findsWidgets);
    expect(find.text('National Lebanon - locked'), findsWidgets);
    await tester.tap(find.text('National Lebanon - locked').last);
    await tester.pumpAndSettle();

    expect(find.text('National Lebanon is locked'), findsOneWidget);
    expect(
      find.text(
        'Backend readiness requirements must pass before National Lebanon can be enabled.',
      ),
      findsOneWidget,
    );
    expect(find.text('National mode allowed for this project'), findsOneWidget);
    expect(find.text('Lebanon boundary configured'), findsOneWidget);
    expect(find.text('Pipeline supports national processing'), findsOneWidget);
    expect(find.text('Geographic coverage is broad enough'), findsOneWidget);
    expect(
      find.text('Regional coverage check is not configured yet.'),
      findsOneWidget,
    );

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(find.text('National Lebanon is locked'), findsNothing);
    expect(find.text('Draw AI area'), findsNothing);

    final saveButton = find.widgetWithText(FilledButton, 'Save settings');
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(repository.saveCount, 1);
    expect(repository.settings.scopeType, 'project');

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('ai-area-dropdown')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('ai-area-dropdown')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Custom AI area').last);
    await tester.pumpAndSettle();

    expect(find.text('Draw AI area'), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('ai-area-dropdown')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('ai-area-dropdown')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('National Lebanon - locked').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(find.text('Draw AI area'), findsOneWidget);
    expect(find.text('National Lebanon is locked'), findsNothing);

    await tester.ensureVisible(find.text('Draw AI area'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw AI area'));
    await tester.pumpAndSettle();

    expect(find.text('Draw AI area'), findsWidgets);
    expect(find.text('Use AI area'), findsOneWidget);
    expect(find.textContaining('Export'), findsNothing);
  });

  testWidgets(
    'national scope becomes selectable only after backend-ready enable action',
    (tester) async {
      final project = _project();
      final repository = FakeAiRepository(
        settings: fakeAiSettings(projectId: project.id),
        readiness: fakeReadiness(
          projectId: project.id,
          nationalScopeEligibility: const AiNationalScopeEligibility(
            eligible: true,
            unmetRequirements: <String>[],
            warnings: <String>[],
          ),
        ),
      );
      await _pumpAiScreen(
        tester,
        session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
        project: project,
        aiRepository: repository,
        section: 'settings',
      );

      final areaDropdown = find.byKey(
        const ValueKey<String>('ai-area-dropdown'),
      );
      await tester.tap(areaDropdown);
      await tester.pumpAndSettle();

      expect(find.text('National Lebanon - ready'), findsWidgets);
      await tester.tap(find.text('National Lebanon - ready').last);
      await tester.pumpAndSettle();

      expect(find.text('Enable national mode'), findsWidgets);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(repository.saveCount, 0);

      await tester.tap(areaDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('National Lebanon - ready').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Enable national mode'),
      );
      await tester.pumpAndSettle();

      expect(repository.saveCount, 1);
      expect(repository.settings.scopeType, 'project');
      expect(
        repository.settings.modelPreferences['national_scope_enabled'],
        true,
      );
      expect(
        find.text(
          'National mode enabled. Select National Lebanon when starting a run.',
        ),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await tester.ensureVisible(areaDropdown);
      await tester.pumpAndSettle();
      await tester.tap(areaDropdown);
      await tester.pumpAndSettle();
      expect(find.text('National Lebanon'), findsWidgets);
      await tester.tap(find.text('National Lebanon').last);
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Save settings'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save settings'));
      await tester.pumpAndSettle();

      expect(repository.saveCount, 2);
      expect(repository.settings.scopeType, 'national');
      expect(
        repository.settings.modelPreferences['national_scope_enabled'],
        true,
      );
    },
  );

  testWidgets('label field dropdown hides aliases and fields without labels', (
    tester,
  ) async {
    final project = _project();
    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      section: 'settings',
    );

    await tester.tap(find.text('L4_descr - recommended'));
    await tester.pumpAndSettle();

    expect(find.text('L4_descr - recommended'), findsWidgets);
    expect(find.text('feature_type - available'), findsNothing);
    expect(find.text('crop_type - no labels'), findsNothing);
    expect(
      find.text(
        'Equivalent imported fields were detected and mapped automatically.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'label field dropdown uses admin-facing schema classifier and hides raw fields',
    (tester) async {
      final project = _project(
        fields: const <CollectionFormFieldSchema>[
          CollectionFormFieldSchema(
            key: 'feature_type',
            label: 'L4_descr',
            type: CollectionFieldType.select,
            required: true,
          ),
          CollectionFormFieldSchema(
            key: 'crop_type',
            label: 'Crop type',
            type: CollectionFieldType.select,
          ),
        ],
      );
      final repository = FakeAiRepository(
        settings: fakeAiSettings(projectId: project.id, labelField: null),
        readiness: fakeReadiness(
          projectId: project.id,
          candidateLabelFields: const <AiLabelFieldCandidate>[
            AiLabelFieldCandidate(
              field: 'L4_descr',
              sources: <String>[
                'schema_label',
                'approved_attributes',
                'selected',
              ],
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
            AiLabelFieldCandidate(
              field: 'OBJECTID_1',
              sources: <String>['approved_attributes'],
              labeledFeatureCount: 1394,
              classCount: 1394,
              usable: true,
              selectable: false,
              diagnosticOnly: true,
              recommended: false,
              note:
                  'Hidden because values are mostly unique and look like IDs.',
            ),
            AiLabelFieldCandidate(
              field: 'Shape_Area',
              sources: <String>['approved_attributes'],
              labeledFeatureCount: 1394,
              classCount: 1394,
              usable: true,
              selectable: false,
              diagnosticOnly: true,
              recommended: false,
              note:
                  'Hidden because this looks like a source ID, code, geometry, or measurement field.',
            ),
          ],
        ),
      );

      await _pumpAiScreen(
        tester,
        session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
        project: project,
        aiRepository: repository,
        section: 'settings',
      );

      expect(find.text('L4_descr - recommended'), findsOneWidget);

      await tester.tap(find.text('L4_descr - recommended'));
      await tester.pumpAndSettle();

      expect(find.text('L4_descr - recommended'), findsWidgets);
      expect(find.text('feature_type - available'), findsNothing);
      expect(find.text('crop_type - no labels'), findsNothing);
      expect(find.text('OBJECTID_1 - available'), findsNothing);
      expect(find.text('Shape_Area - available'), findsNothing);

      await tester.tap(find.text('L4_descr - recommended').last);
      await tester.pumpAndSettle();

      final saveButton = find.widgetWithText(FilledButton, 'Save settings');
      await tester.ensureVisible(saveButton);
      await tester.pumpAndSettle();
      await tester.tap(saveButton);
      await tester.pumpAndSettle();

      expect(repository.saveCount, 1);
      expect(repository.settings.labelField, 'L4_descr');
    },
  );

  testWidgets(
    'label field dropdown shows genuinely different classifier fields',
    (tester) async {
      final project = _project(
        fields: const <CollectionFormFieldSchema>[
          CollectionFormFieldSchema(
            key: 'land_cover',
            label: 'Land cover',
            type: CollectionFieldType.select,
            required: true,
          ),
          CollectionFormFieldSchema(
            key: 'irrigation_type',
            label: 'Irrigation type',
            type: CollectionFieldType.select,
          ),
        ],
      );
      final repository = FakeAiRepository(
        settings: fakeAiSettings(
          projectId: project.id,
          labelField: 'land_cover',
        ),
        readiness: fakeReadiness(
          projectId: project.id,
          candidateLabelFields: const <AiLabelFieldCandidate>[
            AiLabelFieldCandidate(
              field: 'land_cover',
              sources: <String>['schema', 'approved_attributes', 'selected'],
              labeledFeatureCount: 120,
              classCount: 2,
              usable: true,
              selectable: true,
              recommended: true,
              note: 'Recommended project label field.',
            ),
            AiLabelFieldCandidate(
              field: 'irrigation_type',
              sources: <String>['schema', 'approved_attributes'],
              labeledFeatureCount: 120,
              classCount: 2,
              usable: true,
              selectable: true,
              recommended: false,
              note: 'Approved labels available.',
            ),
          ],
        ),
      );

      await _pumpAiScreen(
        tester,
        session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
        project: project,
        aiRepository: repository,
        section: 'settings',
      );

      await tester.tap(find.text('land_cover - recommended'));
      await tester.pumpAndSettle();

      expect(find.text('land_cover - recommended'), findsWidgets);
      expect(find.text('irrigation_type - available'), findsOneWidget);
    },
  );

  testWidgets('runs list displays empty state and queues full regional run', (
    tester,
  ) async {
    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
    );
    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    expect(find.text('No AI run records yet'), findsOneWidget);
    expect(
      find.text(
        'View AI run records, worker logs, and regional proof-of-concept results.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Queues a regional review run from saved settings. Results appear after the backend AI worker processes it.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Start AI run'));
    await tester.pumpAndSettle();

    expect(repository.createCount, 1);
    expect(find.text('Run summary'), findsOneWidget);
    expect(
      find.textContaining('Execution mode: Full regional review run'),
      findsWidgets,
    );
    expect(find.text('Detailed run results'), findsOneWidget);
    expect(find.text('Run queued. Worker is not running.'), findsOneWidget);

    await tester.ensureVisible(find.text('Detailed run results'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Detailed run results'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detailed run results'));
    await tester.pumpAndSettle();

    expect(find.text('Run queued. Worker is not running.'), findsWidgets);
    expect(
      find.text(
        'Ran the full regional review workflow: approved data export, feature extraction, model evaluation, review predictions, vector artifacts, and database prediction rows.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('No AI output layers are registered yet.'),
      findsOneWidget,
    );
    expect(
      find.text('Worker processing must finish before review layers appear.'),
      findsOneWidget,
    );
  });

  testWidgets('run details use readable summary and hide technical paths', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[_phaseFRegionalRun(projectId: project.id)],
      logs: _phaseFLogs(),
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.tap(find.text('Run 00f4bb0c'));
    await tester.pumpAndSettle();

    expect(find.text('Run summary'), findsOneWidget);
    expect(find.text('Run status'), findsOneWidget);
    expect(find.textContaining('Status: Ready for review'), findsWidgets);
    expect(
      find.textContaining('Execution mode: Regional model evaluation'),
      findsWidgets,
    );
    expect(find.textContaining('Label field: L4_descr'), findsWidgets);
    expect(find.textContaining('Duration: 1m 00s'), findsOneWidget);
    expect(find.text('Run configuration'), findsOneWidget);
    expect(find.text('Imagery'), findsOneWidget);
    expect(find.text('Training samples'), findsOneWidget);
    expect(find.text('Prediction area'), findsOneWidget);
    expect(find.text('Extracted features'), findsOneWidget);
    expect(find.text('Execution support'), findsOneWidget);
    expect(find.textContaining('Label field: L4_descr'), findsWidgets);
    expect(find.textContaining('Satellite source: Sentinel-2'), findsOneWidget);
    expect(find.textContaining('Year: 2026'), findsOneWidget);
    expect(find.textContaining('Season: Growing season'), findsOneWidget);
    expect(
      find.textContaining('Date range: 2026-03-01 to 2026-10-31'),
      findsOneWidget,
    );
    expect(find.textContaining('Area used: Project area'), findsOneWidget);
    expect(
      find.textContaining('Prediction area: Project area'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Pipeline use: Pipeline support pending'),
      findsWidgets,
    );
    expect(
      find.textContaining('Selected features: 3 selected: NDVI, EVI, NDRE'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Preferred model requested: SVM RBF'),
      findsOneWidget,
    );
    expect(find.textContaining('Settings: Saved for run'), findsOneWidget);
    expect(
      find.textContaining('Training samples area: Effective now'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Pipeline support pending: satellite, date range, selected features, prediction area',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('National Lebanon: Locked / requirements unmet'),
      findsWidgets,
    );

    expect(find.text('Detailed run results'), findsOneWidget);
    expect(find.text('What happened'), findsNothing);
    expect(find.text('Model result'), findsOneWidget);
    expect(find.textContaining('Best balanced model: SVM RBF'), findsOneWidget);
    expect(
      find.textContaining('Highest accuracy model: XGBoost'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Final selected model: SVM RBF'),
      findsOneWidget,
    );
    expect(find.textContaining('Accuracy: 0.716'), findsOneWidget);
    expect(find.textContaining('Macro-F1: 0.617'), findsOneWidget);
    expect(find.textContaining('Weighted-F1: 0.739'), findsOneWidget);

    await tester.ensureVisible(find.text('Detailed run results'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Detailed run results'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detailed run results'));
    await tester.pumpAndSettle();

    expect(find.text('What happened'), findsOneWidget);
    expect(
      find.text('Evaluated regional AI models using approved project data.'),
      findsOneWidget,
    );
    expect(find.textContaining('Approved samples: 1406'), findsWidgets);
    expect(find.textContaining('Eligible samples: 1394'), findsWidgets);
    expect(find.textContaining('Excluded classes: 1'), findsOneWidget);

    await tester.ensureVisible(find.text('Class counts'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Olives: 940 samples'), findsOneWidget);
    expect(find.textContaining('Fruit Trees: 253 samples'), findsOneWidget);
    expect(find.text('Excluded classes'), findsOneWidget);
    expect(find.textContaining('Vineyards: 12 samples'), findsWidgets);

    expect(
      find.text('This is a regional proof-of-concept, not a national model.'),
      findsOneWidget,
    );
    expect(find.text('South Lebanon only.'), findsOneWidget);
    expect(
      find.text(
        'Vineyards were excluded because only 12 samples are available.',
      ),
      findsOneWidget,
    );
    expect(find.text('Fruit Trees is a broad class.'), findsOneWidget);
    expect(
      find.text('National AI requires wider Lebanon coverage.'),
      findsOneWidget,
    );

    expect(find.text('Technical output files'), findsOneWidget);
    expect(find.textContaining('metrics.json'), findsNothing);
    expect(find.textContaining('model_metadata.json'), findsNothing);

    await tester.ensureVisible(find.text('Technical output files'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Technical output files'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Feature table:'), findsOneWidget);
    expect(find.textContaining('Metrics file:'), findsOneWidget);
    expect(find.textContaining('metrics.json'), findsWidgets);
    expect(find.textContaining('model_metadata.json'), findsWidgets);
    expect(
      find.text('No AI output layers are registered yet.'),
      findsOneWidget,
    );
    expect(
      find.text('Worker processing must finish before review layers appear.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'run configuration uses run snapshot instead of current settings',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 1700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final project = _project();
      final repository = FakeAiRepository(
        settings: fakeAiSettings(
          projectId: project.id,
          modelPreferences: const <String, dynamic>{
            'satellite_source': 'landsat',
            'target_year': 2023,
            'season': 'winter',
            'feature_inputs': <String>['SR_B5'],
          },
        ),
        readiness: fakeReadiness(projectId: project.id),
        runs: <AiRun>[_phaseFRegionalRun(projectId: project.id)],
      );

      await _pumpAiScreen(
        tester,
        session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
        project: project,
        aiRepository: repository,
        section: 'runs',
      );

      await tester.tap(find.text('Run 00f4bb0c'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Satellite source: Sentinel-2'),
        findsOneWidget,
      );
      expect(find.textContaining('Year: 2026'), findsOneWidget);
      expect(
        find.textContaining('Selected features: 3 selected'),
        findsOneWidget,
      );
      expect(find.textContaining('Satellite source: Landsat'), findsNothing);
      expect(find.textContaining('Year: 2023'), findsNothing);
      expect(find.textContaining('SR_B5'), findsNothing);
    },
  );

  testWidgets('old runs without configuration metadata show not recorded', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    final oldRun = AiRun(
      id: 'old-run-1',
      projectId: project.id,
      status: 'draft',
      labelField: 'L4_descr',
      scopeType: 'project',
      trainingFeatureCount: 0,
      eligibleFeatureCount: 0,
      excludedFeatureCount: 0,
      createdAt: DateTime.utc(2026, 5, 1),
    );
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[oldRun],
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.tap(find.text('Run old-run-'));
    await tester.pumpAndSettle();

    expect(find.text('Run configuration'), findsOneWidget);
    expect(
      find.textContaining('Satellite source: Not recorded for this run'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Selected features: Not recorded for this run'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Settings: Not recorded for this run'),
      findsOneWidget,
    );
  });

  testWidgets('Phase Q runs show effective settings consumed by pipeline', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 1700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[_phaseQRegionalRun(projectId: project.id)],
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.tap(find.text('Run phase-q-'));
    await tester.pumpAndSettle();

    expect(find.text('Run configuration'), findsOneWidget);
    expect(find.textContaining('Satellite source: Sentinel-2'), findsOneWidget);
    expect(find.textContaining('Year: 2025'), findsOneWidget);
    expect(find.textContaining('Season: Summer'), findsOneWidget);
    expect(
      find.textContaining('Date range: 2025-06-01 to 2025-08-31'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Selected features: 10 selected'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Preferred model requested: Random Forest'),
      findsOneWidget,
    );
    expect(find.textContaining('Pipeline use: Effective now'), findsWidgets);
    expect(
      find.textContaining(
        'Effective now: satellite, date range, selected features, preferred model, label field, execution mode, training samples area, prediction area',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Pipeline support pending:'), findsNothing);
  });

  testWidgets('model result prefers structured metric rows over metadata', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[_phaseFRegionalRun(projectId: project.id)],
      metrics: const <AiRunMetric>[
        AiRunMetric(
          id: 'metric-rf',
          modelName: 'random_forest',
          overallAccuracy: 0.800,
          macroF1: 0.500,
          weightedF1: 0.700,
        ),
        AiRunMetric(
          id: 'metric-svm',
          modelName: 'svm_rbf',
          overallAccuracy: 0.720,
          macroF1: 0.660,
          weightedF1: 0.750,
        ),
        AiRunMetric(
          id: 'metric-xgb',
          modelName: 'xgboost',
          overallAccuracy: 0.840,
          macroF1: 0.610,
          weightedF1: 0.780,
        ),
      ],
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.tap(find.text('Run 00f4bb0c'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Model result'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Best balanced model: SVM RBF'), findsOneWidget);
    expect(
      find.textContaining('Highest accuracy model: XGBoost'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Final selected model: SVM RBF'),
      findsOneWidget,
    );
    expect(find.textContaining('Accuracy: 0.720'), findsOneWidget);
    expect(find.textContaining('Macro-F1: 0.660'), findsOneWidget);
    expect(find.textContaining('Weighted-F1: 0.750'), findsOneWidget);
    expect(find.textContaining('Accuracy: 0.716'), findsNothing);
    expect(find.text('Model comparison'), findsOneWidget);
    expect(
      find.textContaining(
        'Random Forest: Accuracy 0.800, Macro-F1 0.500, Weighted-F1 0.700',
      ),
      findsOneWidget,
    );
  });

  testWidgets('AI output layer section shows unpublished statistics safely', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[_phaseFRegionalRun(projectId: project.id)],
      layers: _reviewableLayers(),
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.tap(find.text('Run 00f4bb0c'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Output layers'));
    await tester.pumpAndSettle();

    expect(find.text('Output layers'), findsOneWidget);
    expect(find.textContaining('Statistics: Report summary'), findsOneWidget);
    expect(find.textContaining('statistics_layer.json'), findsNothing);
    expect(find.text('Layer details'), findsOneWidget);

    await tester.tap(find.text('Layer details'));
    await tester.pumpAndSettle();

    expect(find.text('Statistics layer'), findsOneWidget);
    expect(
      find.textContaining('Layer name: Regional model statistics'),
      findsOneWidget,
    );
    expect(find.textContaining('Status: Ready for review'), findsWidgets);
    expect(
      find.textContaining('Usage: Review/report summary only'),
      findsOneWidget,
    );
    expect(find.textContaining('CRS: EPSG:4326'), findsOneWidget);
    expect(
      find.textContaining('Bounds: Recorded in layer metadata'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Project Map shows published map layers only. Statistics stay as reports.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Citrus Fruit Trees: 201 samples'),
      findsWidgets,
    );
    expect(find.textContaining('Fruit Trees: 253 samples'), findsWidgets);
    expect(find.textContaining('Olives: 940 samples'), findsWidgets);
    expect(
      find.textContaining('Vineyards: 12 samples below threshold'),
      findsOneWidget,
    );
    expect(find.text('Area statistics not available yet.'), findsOneWidget);
    expect(
      find.text('Confidence statistics not available yet.'),
      findsOneWidget,
    );
    expect(find.textContaining('statistics_layer.json'), findsNothing);

    await tester.tap(find.text('Layer technical details'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Related run id:'), findsOneWidget);
    expect(find.textContaining('Output/storage path:'), findsOneWidget);
    expect(find.textContaining('statistics_layer.json'), findsOneWidget);
  });

  testWidgets('AI output layer summary wraps on narrow screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[_phaseFRegionalRun(projectId: project.id)],
      layers: _reviewableLayers(),
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.ensureVisible(find.text('Run 00f4bb0c'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run 00f4bb0c'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Output layers'));
    await tester.pumpAndSettle();

    expect(find.text('Output layers'), findsOneWidget);
    expect(find.textContaining('Statistics: Report summary'), findsOneWidget);
    expect(find.textContaining('Not a map overlay'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('run detail expandable sections use material surfaces', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[_phaseFRegionalRun(projectId: project.id)],
      layers: _reviewableLayers(),
      logs: _phaseFLogs(),
      reviews: <AiReviewDecision>[
        ..._reviewHistory(),
        AiReviewDecision(
          id: 'review-older',
          aiRunId: '00f4bb0c-66cc-4fec-80c3-f3ecc96175f4',
          decision: 'keep_draft',
          reason: 'Keep internal while checking map artifacts.',
          decidedBy: 'NCRS Administrator',
          decidedAt: DateTime.utc(2026, 6, 5, 12),
          metadata: const <String, dynamic>{
            'viewer_publication_enabled': false,
          },
        ),
      ],
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.ensureVisible(find.text('Run 00f4bb0c'));
    await tester.tap(find.text('Run 00f4bb0c'));
    await tester.pumpAndSettle();

    expect(find.text('Output layers'), findsOneWidget);
    expect(find.text('Review and publishing'), findsOneWidget);

    Future<void> openExpansion(String label) async {
      final finder = find.text(label);
      await tester.scrollUntilVisible(
        finder,
        600,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    for (final label in <String>[
      'Layer details',
      'Layer technical details',
      'Review history',
      'Detailed run results',
      'Technical output files',
      'Worker logs',
      'Technical metadata',
    ]) {
      await openExpansion(label);
    }
  });

  testWidgets('approved AI output layer can be published and unpublished', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    final layer = AiOutputLayer(
      id: 'layer-classification',
      aiRunId: '00f4bb0c-66cc-4fec-80c3-f3ecc96175f4',
      projectId: project.id,
      layerType: 'classification',
      status: 'approved',
      name: 'Regional classification review',
      description: 'Approved AI classification polygons.',
      storagePath: 'outputs/runs/phase-m/ai_classification_review.geojson',
      crs: 'EPSG:4326',
      createdAt: DateTime.utc(2026, 6, 6, 12),
    );
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[_phaseFRegionalRun(projectId: project.id)],
      layers: <AiOutputLayer>[layer],
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.tap(find.text('Run 00f4bb0c'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Layer details'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Layer details'));
    await tester.pumpAndSettle();

    expect(find.text('Publish'), findsOneWidget);
    expect(find.text('Unpublish'), findsNothing);

    await tester.ensureVisible(find.text('Publish'));
    await tester.tap(find.text('Publish'));
    await tester.pumpAndSettle();

    expect(repository.publishCount, 1);
    expect(
      find.text('AI layer published as a read-only map overlay.'),
      findsOneWidget,
    );
    if (find.text('Unpublish').evaluate().isEmpty) {
      await tester.ensureVisible(find.text('Layer details'));
      await tester.tap(find.text('Layer details'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Unpublish'), findsOneWidget);

    await tester.ensureVisible(find.text('Unpublish'));
    await tester.tap(find.text('Unpublish'));
    await tester.pumpAndSettle();

    expect(repository.unpublishCount, 1);
    if (find.text('Publish').evaluate().isEmpty) {
      await tester.ensureVisible(find.text('Layer details'));
      await tester.tap(find.text('Layer details'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Publish'), findsOneWidget);
  });

  testWidgets('AI preview map opens from run details and lazy-loads layers', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    final layers = _phaseNReviewLayers();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[_phaseFRegionalRun(projectId: project.id)],
      layers: layers,
      layerFeatures: _phaseNLayerFeatures(layers),
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.tap(find.text('Run 00f4bb0c'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Preview map'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Classification: Ready for review'),
      findsOneWidget,
    );
    expect(find.textContaining('Confidence: Ready for review'), findsOneWidget);
    expect(
      find.textContaining('Uncertainty: Ready for review'),
      findsOneWidget,
    );
    expect(
      find.text(
        'AI layer preview is protected super-admin review only. These layers are not published to viewers.',
      ),
      findsNothing,
    );
    expect(
      find.text('Preview is protected super-admin review only.'),
      findsOneWidget,
    );
    expect(find.byType(FlutterMap), findsNothing);

    await tester.pumpWidget(
      _wrap(
        session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
        project: project,
        aiRepository: repository,
        child: ProjectAiPreviewMapScreen(
          projectId: project.id,
          runId: '00f4bb0c-66cc-4fec-80c3-f3ecc96175f4',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Run 00f4bb0c preview'), findsOneWidget);
    expect(find.byType(FlutterMap), findsOneWidget);
    await tester.tap(find.byType(FlutterMap));
    await tester.pumpAndSettle();

    expect(find.text('Not published'), findsOneWidget);
    expect(find.text('Review only'), findsOneWidget);
    expect(find.text('Total AI features: 1394'), findsOneWidget);
    expect(find.textContaining('Showing'), findsNothing);
    expect(find.text('Optimized preview'), findsNothing);
    expect(find.byTooltip('Browse AI features'), findsOneWidget);
    expect(find.text('1394'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'Confidence'), findsNothing);

    await tester.tap(find.byTooltip('Show AI layers'));
    await tester.pumpAndSettle();

    expect(find.text('Classification'), findsOneWidget);
    expect(find.text('Confidence'), findsOneWidget);
    expect(find.text('Uncertainty'), findsOneWidget);
    expect(find.text('Total: 1394'), findsNothing);
    expect(find.text('Visible: 1394'), findsNothing);
    expect(find.text('Loaded: 2'), findsNothing);
    expect(find.textContaining('visible features in this view'), findsNothing);
    expect(find.text('Olives'), findsOneWidget);
    expect(find.text('Citrus fruit trees'), findsOneWidget);
    expect(find.text('Fruit trees'), findsOneWidget);
    expect(
      find.text('AI predictions remain separate from field data.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('ai_classification_review.geojson'),
      findsNothing,
    );
    expect(
      repository.layerFeatureFetchCounts['layer-classification'],
      greaterThanOrEqualTo(1),
    );
    final classificationQuery = repository.layerFeatureQueries.lastWhere(
      (query) => query.layerId == 'layer-classification',
    );
    expect(classificationQuery.detail, 'overview');
    expect(classificationQuery.geometry, 'aggregate');
    expect(classificationQuery.bounds, isNotNull);
    expect(classificationQuery.bounds!.split(','), hasLength(4));
    expect(classificationQuery.zoom, isNotNull);
    expect(repository.layerFeatureFetchCounts['layer-uncertainty'], isNull);
    expect(repository.layerFeatureFetchCounts['layer-confidence'], isNull);

    await tester.tap(find.widgetWithText(FilterChip, 'Confidence'));
    await tester.pumpAndSettle();

    expect(find.text('Confidence'), findsWidgets);
    expect(
      repository.layerFeatureFetchCounts['layer-confidence'],
      greaterThanOrEqualTo(1),
    );

    await tester.tap(find.widgetWithText(FilterChip, 'Uncertainty'));
    await tester.pumpAndSettle();

    expect(
      find.text('Uncertain areas are candidates for future field validation.'),
      findsOneWidget,
    );
    expect(
      repository.layerFeatureFetchCounts['layer-uncertainty'],
      greaterThanOrEqualTo(1),
    );

    await tester.tap(find.byTooltip('Browse AI features'));
    await tester.pumpAndSettle();

    expect(find.text('AI features'), findsOneWidget);
    expect(find.text('Search AI features'), findsOneWidget);
    expect(
      find.text('Showing 20 of 1394 AI review feature(s)'),
      findsOneWidget,
    );
    final listPageOneQuery = repository.layerFeatureQueries.lastWhere(
      (query) =>
          query.layerId == 'layer-classification' &&
          query.page == 1 &&
          query.limit == 20,
    );
    expect(listPageOneQuery.limit, 20);
    expect(listPageOneQuery.bounds, isNull);
    expect(listPageOneQuery.geometry, 'simplified');

    for (var index = 0; index < 4; index++) {
      await tester.dragFrom(const Offset(540, 2050), const Offset(0, -600));
      await tester.pumpAndSettle();
    }
    expect(find.text('Show more'), findsOneWidget);
    expect(find.text('Show more').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Show more').hitTestable());
    await tester.pumpAndSettle();

    final listPageTwoQuery = repository.layerFeatureQueries.lastWhere(
      (query) => query.layerId == 'layer-classification' && query.page == 2,
    );
    expect(listPageTwoQuery.limit, 20);
    expect(listPageTwoQuery.bounds, isNull);

    for (var index = 0; index < 4; index++) {
      await tester.dragFrom(const Offset(540, 700), const Offset(0, 600));
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(find.text('Search AI features'));
    await tester.enterText(
      find.widgetWithText(TextField, 'Search AI features'),
      'citrus',
    );
    await tester.pumpAndSettle();

    final searchQuery = repository.layerFeatureQueries.lastWhere(
      (query) =>
          query.layerId == 'layer-classification' &&
          query.page == 1 &&
          query.search == 'citrus',
    );
    expect(searchQuery.limit, 20);
    expect(searchQuery.bounds, isNull);
    expect(find.textContaining('matching AI feature(s)'), findsOneWidget);

    await tester.ensureVisible(find.byTooltip('Clear search'));
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Fruit Trees'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Fruit Trees'));
    await tester.pumpAndSettle();

    final classFilterQuery = repository.layerFeatureQueries.lastWhere(
      (query) =>
          query.layerId == 'layer-classification' &&
          query.page == 1 &&
          query.classLabel == 'Fruit Trees',
    );
    expect(classFilterQuery.limit, 20);
    expect(classFilterQuery.bounds, isNull);
  });

  testWidgets('AI preview feature tap opens review-only details sheet', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    final layers = _phaseNReviewLayers();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[_phaseFRegionalRun(projectId: project.id)],
      layers: layers,
      layerFeatures: _phaseNLayerFeatures(layers),
    );

    await tester.pumpWidget(
      _wrap(
        session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
        project: project,
        aiRepository: repository,
        child: ProjectAiPreviewMapScreen(
          projectId: project.id,
          runId: '00f4bb0c-66cc-4fec-80c3-f3ecc96175f4',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Fit Lebanon workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Browse AI features'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Confidence 82.0%').last);
    await tester.pumpAndSettle();

    final exactFeatureQuery = repository.layerFeatureQueries.lastWhere(
      (query) =>
          query.layerId == 'layer-classification' &&
          query.featureId == 'classification-1',
    );
    expect(exactFeatureQuery.detail, 'full');
    expect(exactFeatureQuery.geometry, 'full');
    expect(exactFeatureQuery.limit, 1);

    expect(find.text('Olives'), findsWidgets);
    expect(
      find.text('AI prediction for review, not approved field data.'),
      findsOneWidget,
    );
    expect(find.textContaining('Predicted class: Olives'), findsOneWidget);
    expect(find.textContaining('Confidence: 82.0%'), findsOneWidget);
    expect(find.textContaining('Model: Random Forest'), findsOneWidget);
    expect(find.textContaining('Source: ai_prediction'), findsOneWidget);
    expect(
      find.textContaining('Regional proof-of-concept. Not a national model.'),
      findsOneWidget,
    );
  });

  testWidgets('AI preview map is restricted to protected super-admin', (
    tester,
  ) async {
    final project = _project();
    final layers = _phaseNReviewLayers();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[_phaseFRegionalRun(projectId: project.id)],
      layers: layers,
      layerFeatures: _phaseNLayerFeatures(layers),
    );

    await tester.pumpWidget(
      _wrap(
        session: _session(role: UserRole.admin),
        project: project,
        aiRepository: repository,
        child: ProjectAiPreviewMapScreen(
          projectId: project.id,
          runId: '00f4bb0c-66cc-4fec-80c3-f3ecc96175f4',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('AI preview restricted'), findsOneWidget);
    expect(find.byType(FlutterMap), findsNothing);
  });

  testWidgets('AI output layer review decisions stay separate from status', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[_phaseFRegionalRun(projectId: project.id)],
      layers: <AiOutputLayer>[
        AiOutputLayer(
          id: 'layer-approved',
          aiRunId: '00f4bb0c-66cc-4fec-80c3-f3ecc96175f4',
          layerType: 'statistics',
          status: 'approved',
          name: 'Approved regional statistics',
          description: 'Approved internally, not viewer-facing.',
          storagePath: 'outputs/runs/phase-j/approved_statistics.json',
          crs: 'EPSG:4326',
          createdAt: DateTime.utc(2026, 6, 5, 10, 3),
        ),
      ],
      reviews: _reviewHistory(),
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.tap(find.text('Run 00f4bb0c'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Output layers'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Statistics: Report summary'), findsOneWidget);
    await tester.tap(find.text('Layer details'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Status: Approved'), findsOneWidget);
    expect(
      find.textContaining('Status: Approved for future publication'),
      findsNothing,
    );
    expect(
      find.textContaining('Usage: Review/report summary only'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Review decision: Approved for future publication by NCRS Administrator',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Review reason: Metrics are acceptable for future publication review.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Published:'), findsNothing);
    expect(find.textContaining('approved_statistics.json'), findsNothing);
  });

  testWidgets('AI output layer section shows rejected reasons clearly', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[_phaseFRegionalRun(projectId: project.id)],
      layers: const <AiOutputLayer>[
        AiOutputLayer(
          id: 'layer-rejected',
          layerType: 'statistics',
          status: 'rejected',
          name: 'Rejected regional statistics',
        ),
      ],
      reviews: <AiReviewDecision>[
        AiReviewDecision(
          id: 'review-rejected',
          aiRunId: '00f4bb0c-66cc-4fec-80c3-f3ecc96175f4',
          decision: 'rejected',
          reason: 'Need broader regional validation before publishing.',
          decidedBy: 'NCRS Administrator',
          decidedAt: DateTime.utc(2026, 6, 6, 11),
        ),
      ],
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.tap(find.text('Run 00f4bb0c'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Output layers'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Statistics: Report summary'), findsOneWidget);
    await tester.tap(find.text('Layer details'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Status: Rejected'), findsOneWidget);
    expect(
      find.textContaining('Review decision: Rejected by NCRS Administrator'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Review reason: Need broader regional validation before publishing.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Usage: Review/report summary only'),
      findsOneWidget,
    );
  });

  testWidgets('review section records protected super-admin decisions safely', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 1900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[_phaseFRegionalRun(projectId: project.id)],
      layers: _reviewableLayers(),
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.tap(find.text('Run 00f4bb0c'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Review result'));
    await tester.pumpAndSettle();

    expect(
      find.text('No review decision has been recorded yet.'),
      findsOneWidget,
    );
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
    expect(find.text('Request data'), findsOneWidget);
    expect(find.text('Publish now'), findsNothing);
    expect(
      find.text(
        'Review decisions prepare AI results for a separate publishing step. They do not publish map layers by themselves.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Approve accepts the result'), findsOneWidget);

    await tester.tap(find.text('Reject'));
    await tester.pumpAndSettle();

    expect(repository.reviewCount, 0);
    expect(find.text('Please add a reason before rejecting.'), findsOneWidget);

    await tester.tap(find.text('Request data'));
    await tester.pumpAndSettle();

    expect(repository.reviewCount, 0);
    expect(find.text('Please explain what data is needed.'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Review reason or comment'),
      'Metrics need more review before publication.',
    );
    await tester.tap(find.text('Reject'));
    await tester.pumpAndSettle();

    expect(repository.reviewCount, 1);
    expect(
      find.text('AI review saved. No viewer-facing layer was published.'),
      findsOneWidget,
    );
    expect(find.text('Latest decision'), findsOneWidget);
    expect(find.textContaining('Decision: Rejected'), findsOneWidget);
    expect(
      find.textContaining(
        'Reason: Metrics need more review before publication.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('review actions keep mobile layout aligned', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.binding.setSurfaceSize(const Size(390, 1500));
    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[_phaseFRegionalRun(projectId: project.id)],
      layers: _reviewableLayers(),
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.ensureVisible(find.text('Run 00f4bb0c'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run 00f4bb0c'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Approve'));
    await tester.pumpAndSettle();

    final mobileApprove = tester.getRect(
      find.widgetWithText(FilledButton, 'Approve'),
    );
    final mobileReason = tester.getRect(
      find.widgetWithText(TextField, 'Review reason or comment'),
    );
    final mobileReject = tester.getRect(
      find.widgetWithText(OutlinedButton, 'Reject'),
    );
    final mobileRequest = tester.getRect(
      find.widgetWithText(OutlinedButton, 'Request data'),
    );
    final mobileKeep = tester.getRect(
      find.widgetWithText(OutlinedButton, 'Keep draft'),
    );

    expect(mobileReason.left, closeTo(mobileApprove.left, 1));
    expect(mobileReason.width, closeTo(mobileApprove.width, 1));
    final secondaryActionsShareRow =
        (mobileReject.top - mobileRequest.top).abs() < 1;
    if (secondaryActionsShareRow) {
      expect(mobileApprove.width, greaterThan(mobileReject.width));
    } else {
      expect(mobileReject.width, closeTo(mobileApprove.width, 1));
      expect(mobileRequest.width, closeTo(mobileApprove.width, 1));
      expect(mobileRequest.top, greaterThan(mobileReject.top));
    }
    expect(mobileKeep.left, closeTo(mobileApprove.left, 1));
    expect(mobileKeep.width, closeTo(mobileApprove.width, 1));
  });

  testWidgets('review actions keep wide layout aligned', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.binding.setSurfaceSize(const Size(1080, 1500));
    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[_phaseFRegionalRun(projectId: project.id)],
      layers: _reviewableLayers(),
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.ensureVisible(find.text('Run 00f4bb0c'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run 00f4bb0c'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Approve'));
    await tester.pumpAndSettle();

    final wideReject = tester.getRect(
      find.widgetWithText(OutlinedButton, 'Reject'),
    );
    final wideReason = tester.getRect(
      find.widgetWithText(TextField, 'Review reason or comment'),
    );
    final wideRequest = tester.getRect(
      find.widgetWithText(OutlinedButton, 'Request data'),
    );
    final wideKeep = tester.getRect(
      find.widgetWithText(OutlinedButton, 'Keep draft'),
    );

    expect(wideReason.left, closeTo(wideReject.left, 1));
    expect(wideReason.width, closeTo(wideReject.width * 3 + 24, 2));
    expect((wideReject.top - wideRequest.top).abs(), lessThan(1));
    expect((wideReject.top - wideKeep.top).abs(), lessThan(1));
    expect(wideReject.width, closeTo(wideRequest.width, 1));
    expect(wideRequest.width, closeTo(wideKeep.width, 1));
  });

  testWidgets('approve and keep draft can be saved without a reason', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 1900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[_phaseFRegionalRun(projectId: project.id)],
      layers: _reviewableLayers(),
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.tap(find.text('Run 00f4bb0c'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Approve'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();

    expect(repository.reviewCount, 1);
    expect(repository.reviews.first.decision, 'approved_for_publish');
    expect(
      repository.reviews.first.metadata['viewer_publication_enabled'],
      false,
    );
    expect(
      find.text('AI review saved. No viewer-facing layer was published.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Keep draft'));
    await tester.pumpAndSettle();

    expect(repository.reviewCount, 2);
    expect(repository.reviews.first.decision, 'keep_draft');
    expect(
      repository.reviews.first.metadata['viewer_publication_enabled'],
      false,
    );
  });

  testWidgets('review history and unpublished layer state display cleanly', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 1900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[_phaseFRegionalRun(projectId: project.id)],
      layers: const <AiOutputLayer>[
        AiOutputLayer(
          id: 'layer-statistics',
          layerType: 'statistics',
          status: 'approved',
          name: 'Regional model statistics',
        ),
      ],
      reviews: _reviewHistory(),
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.tap(find.text('Run 00f4bb0c'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Statistics: Report summary'), findsOneWidget);
    expect(find.text('Not a map overlay'), findsOneWidget);
    expect(
      find.text('No viewer-facing AI layer is published yet.'),
      findsNothing,
    );

    await tester.ensureVisible(find.text('Detailed run results'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detailed run results'));
    await tester.pumpAndSettle();

    expect(
      find.text('No viewer-facing AI layer is published yet.'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('Review result'));
    await tester.pumpAndSettle();

    expect(find.text('Latest decision'), findsOneWidget);
    expect(
      find.textContaining('Decision: Approved for future publication'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Reason: Metrics are acceptable for future publication review.',
      ),
      findsOneWidget,
    );
    expect(find.text('Publish now'), findsNothing);
  });

  testWidgets('model result is hidden when no metrics or summary exist', (
    tester,
  ) async {
    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[
        AiRun(
          id: 'run-no-metrics',
          projectId: project.id,
          status: 'ready_for_review',
          labelField: 'L4_descr',
          scopeType: 'project',
          trainingFeatureCount: 1406,
          eligibleFeatureCount: 1394,
          excludedFeatureCount: 12,
          metadata: const <String, dynamic>{
            'execution_mode': 'regional_model_eval',
            'class_counts': <Map<String, dynamic>>[
              <String, dynamic>{'class_label': 'Olives', 'sample_count': 940},
              <String, dynamic>{
                'class_label': 'Fruit Trees',
                'sample_count': 253,
              },
            ],
          },
        ),
      ],
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.tap(find.text('Run run-no-m'));
    await tester.pumpAndSettle();

    expect(find.text('Model result'), findsNothing);
    expect(find.textContaining('Accuracy:'), findsNothing);
    await tester.ensureVisible(find.text('Detailed run results'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detailed run results'));
    await tester.pumpAndSettle();
    expect(
      find.text('This is a regional proof-of-concept, not a national model.'),
      findsOneWidget,
    );
  });

  testWidgets('worker logs are hidden by default, expandable, and redacted', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[_phaseFRegionalRun(projectId: project.id)],
      logs: _phaseFLogs(),
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.tap(find.text('Run 00f4bb0c'));
    await tester.pumpAndSettle();

    expect(find.text('Worker logs'), findsOneWidget);
    expect(
      find.text('Worker started regional model evaluation.'),
      findsNothing,
    );
    expect(find.textContaining('secret-value'), findsNothing);

    await tester.ensureVisible(find.text('Worker logs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Worker logs'));
    await tester.pumpAndSettle();

    expect(
      find.text('Worker started regional model evaluation.'),
      findsOneWidget,
    );
    expect(find.text('Feature extraction completed.'), findsOneWidget);
    expect(find.textContaining('Step extracting_features'), findsWidgets);
    expect(find.textContaining('2m 23s'), findsOneWidget);
    expect(find.textContaining('secret-value'), findsNothing);
    expect(find.textContaining('[redacted]'), findsOneWidget);
  });

  testWidgets('friendly labels describe safe non-model execution modes', (
    tester,
  ) async {
    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[
        _phaseFRegionalRun(
          projectId: project.id,
          id: 'feature-run-1',
          executionMode: 'regional_feature_extraction',
        ),
        _phaseFRegionalRun(
          projectId: project.id,
          id: 'ground-run-1',
          executionMode: 'local_ground_truth_export',
        ),
      ],
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.tap(find.text('Run feature-'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Execution mode: Regional feature extraction'),
      findsWidgets,
    );
    await tester.ensureVisible(find.text('Detailed run results'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detailed run results'));
    await tester.pumpAndSettle();
    expect(
      find.text('Extracted satellite features for approved project samples.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Satellite collection: Sentinel-2'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('Run ground-r'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run ground-r'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Execution mode: Ground truth export'),
      findsWidgets,
    );
    await tester.ensureVisible(find.text('Detailed run results'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detailed run results'));
    await tester.pumpAndSettle();
    expect(
      find.text('Prepared approved project data for AI training.'),
      findsOneWidget,
    );
  });

  testWidgets('failed run details show failure reason and clean empty states', (
    tester,
  ) async {
    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[
        _phaseFRegionalRun(
          projectId: project.id,
          id: 'failed-run-1',
          status: 'failed',
          executionMode: 'regional_feature_extraction',
          failureReason: 'AI pipeline timed out before training.',
        ),
      ],
      logs: const <AiRunLog>[],
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.tap(find.text('Run failed-r'));
    await tester.pumpAndSettle();

    expect(find.text('Failure reason'), findsOneWidget);
    expect(find.textContaining('AI pipeline timed out'), findsWidgets);
    expect(find.text('Worker logs'), findsOneWidget);
    expect(
      find.text('Worker logs will appear after processing starts.'),
      findsNothing,
    );
    await tester.ensureVisible(find.text('Worker logs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Worker logs'));
    await tester.pumpAndSettle();
    expect(
      find.text('Worker logs will appear after processing starts.'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Detailed run results'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detailed run results'));
    await tester.pumpAndSettle();
    expect(
      find.text('No AI output layers are registered yet.'),
      findsOneWidget,
    );
  });

  testWidgets('runs expand inline and toggle selected details', (tester) async {
    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[
        AiRun(
          id: 'run-second',
          projectId: project.id,
          status: 'draft',
          labelField: 'feature_type',
          scopeType: 'project',
          trainingFeatureCount: 80,
          eligibleFeatureCount: 70,
          excludedFeatureCount: 10,
        ),
        AiRun(
          id: 'run-first',
          projectId: project.id,
          status: 'draft',
          labelField: 'L4_descr',
          scopeType: 'project',
          trainingFeatureCount: 1406,
          eligibleFeatureCount: 1394,
          excludedFeatureCount: 12,
        ),
      ],
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    await tester.tap(find.text('Run run-seco'));
    await tester.pumpAndSettle();

    expect(find.text('Run summary'), findsOneWidget);
    expect(find.textContaining('Label field: feature_type'), findsWidgets);

    await tester.ensureVisible(find.text('Run run-firs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run run-firs'));
    await tester.pumpAndSettle();

    expect(find.text('Run summary'), findsOneWidget);
    expect(find.textContaining('Label field: L4_descr'), findsWidgets);
    expect(find.textContaining('Label field: feature_type'), findsNothing);

    await tester.ensureVisible(find.text('Run run-firs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run run-firs'));
    await tester.pumpAndSettle();

    expect(find.text('Run summary'), findsNothing);
  });

  testWidgets('backend readiness errors show clean UI copy', (tester) async {
    final project = _project();
    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: FakeAiRepository(
        settings: fakeAiSettings(projectId: project.id),
        readiness: fakeReadiness(projectId: project.id),
        failReadiness: true,
      ),
    );

    expect(find.text('AI readiness unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct AI route without permission shows denied state safely', (
    tester,
  ) async {
    final project = _project();
    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.viewer, userId: 'viewer-1'),
      project: project,
    );

    expect(find.text('AI access restricted'), findsOneWidget);
    expect(
      find.text('Only the protected super-admin can manage project AI.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
