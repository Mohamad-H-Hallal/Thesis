import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/features/ai/domain/ai_models.dart';
import 'package:lebanese_gis_mobile/features/ai/presentation/ai_model_labels.dart';
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
        'eligible': true,
        'requirements': <Map<String, dynamic>>[
          <String, dynamic>{
            'key': 'overall_coverage',
            'label': 'Overall coverage',
            'passed': true,
            'current_value': 74,
            'message': 'Good for a national run.',
          },
        ],
        'unmet_requirements': <String>[],
        'warnings': <String>[],
        'coverage': <String, dynamic>{'score': 74, 'rating': 'good'},
      },
      'ai_settings': <String, dynamic>{
        'satellite_sources': <String>['sentinel2'],
        'satellite_timeframes': <String, dynamic>{
          'sentinel2': <String, dynamic>{
            'map_year': 2026,
            'seasons': <Map<String, dynamic>>[
              <String, dynamic>{
                'season': 'growing',
                'from_date': '2026-03-01',
                'to_date': '2026-10-31',
              },
            ],
          },
        },
        'confidence_threshold': 0.6,
        'feature_groups': <String>['vegetation_indices'],
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
          'satellite_sources',
          'satellite_timeframes',
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
      'scientific_limitations': <String>[],
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
          'gradient_boosting': <String, dynamic>{
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
    'satellite_sources': <String>['sentinel2'],
    'satellite_timeframes': <String, dynamic>{
      'sentinel2': <String, dynamic>{
        'map_year': 2025,
        'seasons': <Map<String, dynamic>>[
          <String, dynamic>{
            'season': 'summer',
            'from_date': '2025-06-01',
            'to_date': '2025-08-31',
          },
        ],
      },
    },
    'confidence_threshold': 0.55,
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
    'satellite_sources': <String>['sentinel2'],
    'satellite_timeframes': <String, dynamic>{
      'sentinel2': <String, dynamic>{
        'map_year': 2025,
        'seasons': <Map<String, dynamic>>[
          <String, dynamic>{
            'season': 'summer',
            'from_date': '2025-06-01',
            'to_date': '2025-08-31',
          },
        ],
      },
    },
    'confidence_threshold': 0.55,
    'feature_groups': <String>['spectral_bands', 'vegetation_indices'],
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
      'satellite_sources',
      'satellite_timeframes',
      'confidence_threshold',
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
  test('formatModelName expands model abbreviations for UI copy', () {
    expect(formatModelName('rf'), 'Random Forest');
    expect(formatModelName('random_forest'), 'Random Forest');
    expect(formatModelName('svm'), 'Support Vector Machine');
    expect(formatModelName('support_vector_machine'), 'Support Vector Machine');
    expect(formatModelName('gb'), 'Gradient Boosting');
    expect(formatModelName('gradient_boosting'), 'Gradient Boosting');
    expect(formatModelName('xgb'), 'Extreme Gradient Boosting');
    expect(formatModelName('xgboost'), 'Extreme Gradient Boosting');
    expect(formatModelName('nn'), 'Neural Network');
    expect(formatModelName('neural_network'), 'Neural Network');
  });

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
    expect(find.text('AI Settings'), findsOneWidget);
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
      expect(
        find.textContaining('AI server connected', skipOffstage: false),
        findsOneWidget,
      );
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

  testWidgets('readiness card explains AI server configuration states', (
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
          status: 'not_ready',
          blockers: const <String>['AI server URL is not configured.'],
          aiServer: const AiServerReadiness(
            configured: false,
            available: false,
            status: 'unconfigured',
          ),
        ),
      ),
    );

    expect(
      find.text('AI server URL is not configured on the backend.'),
      findsOneWidget,
    );

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
          blockers: const <String>['AI server unavailable.'],
          aiServer: const AiServerReadiness(
            configured: true,
            available: false,
            status: 'unavailable',
          ),
        ),
      ),
    );

    expect(
      find.textContaining(
        'AI server is unavailable. Start the AI server and refresh readiness.',
        skipOffstage: false,
      ),
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
      find.textContaining('Project feature extent (rectangular fallback)'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'The backend will use the bounding rectangle around approved project features and training samples',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Draw a Custom AI area to limit the run'),
      findsOneWidget,
    );

    final minField = find.widgetWithText(
      TextFormField,
      'Minimum samples per class',
    );
    await tester.enterText(minField, '40');
    final saveButton = find.widgetWithText(FilledButton, 'Save settings');
    tester.widget<FilledButton>(saveButton).onPressed?.call();
    await tester.pumpAndSettle();

    expect(repository.saveCount, 1);
    expect(repository.settings.labelField, 'L4_descr');
    expect(repository.settings.minSamplesPerClass, 40);
    expect(find.text('AI settings saved successfully.'), findsOneWidget);
  });

  testWidgets('extracted feature selector groups types and toggles all', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(
        projectId: project.id,
        isEnabled: true,
        modelPreferences: const <String, dynamic>{
          'satellite_sources': <String>['sentinel2', 'landsat'],
          'feature_inputs': <String>['B2', 'NDVI'],
        },
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

    await tester.scrollUntilVisible(
      find.text('Sentinel-2 bands').last,
      500,
      maxScrolls: 8,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('Sentinel-2 bands'), findsOneWidget);
    expect(find.text('Landsat bands'), findsOneWidget);
    expect(find.text('Vegetation indices'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Sentinel-2 bands')).dy,
      lessThan(tester.getTopLeft(find.text('Landsat bands')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Landsat bands')).dy,
      lessThan(tester.getTopLeft(find.text('Vegetation indices')).dy),
    );

    await tester.tap(find.byTooltip('Feature requirements'));
    await tester.pumpAndSettle();
    expect(find.text('Feature requirements'), findsOneWidget);
    expect(
      find.textContaining('static_texture_pc1 (orchard texture pattern)'),
      findsOneWidget,
    );
    expect(find.textContaining('B2 (Blue)'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    final selectAll = find.widgetWithText(ActionChip, 'Select all');
    expect(selectAll, findsOneWidget);
    await tester.tap(selectAll);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('static_texture_pc1 was not selected'),
      findsOneWidget,
    );

    final unselectAll = find.widgetWithText(ActionChip, 'Unselect all');
    expect(unselectAll, findsOneWidget);
    await tester.tap(unselectAll);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ActionChip, 'Select all'), findsOneWidget);
    await tester.tap(find.widgetWithText(ActionChip, 'Select all'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('static_texture_pc1 was not selected'),
      findsOneWidget,
    );

    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Save settings'),
      500,
      maxScrolls: 8,
      scrollable: find.byType(Scrollable).first,
    );
    final saveButton = find.widgetWithText(FilledButton, 'Save settings');
    tester.widget<FilledButton>(saveButton).onPressed?.call();
    await tester.pumpAndSettle();

    expect(
      find.textContaining('AI settings saved, but 1 feature was skipped'),
      findsOneWidget,
    );

    final preferences = repository.settings.modelPreferences;
    expect(preferences['feature_inputs'], contains('NDVI'));
    expect(
      preferences['feature_inputs'],
      isNot(contains('static_texture_pc1')),
    );
    final timeframes = preferences['satellite_timeframes'] as Map;
    final sentinel2Frame = timeframes['sentinel2'] as Map;
    final sentinel2Seasons = sentinel2Frame['seasons'] as List;
    expect(
      sentinel2Seasons.any(
        (season) => season is Map && season['season'] == 'dry',
      ),
      isFalse,
    );
  });

  testWidgets('custom polygon scope is available in settings', (tester) async {
    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id, isEnabled: true),
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
    expect(find.text('National Lebanon (not available)'), findsWidgets);
    expect(find.text('Draw AI area'), findsNothing);
    await tester.tap(find.text('Project area').last);
    await tester.pumpAndSettle();

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

    final drawAreaButton = find.widgetWithText(FilledButton, 'Draw AI area');
    await tester.scrollUntilVisible(
      drawAreaButton,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(drawAreaButton);
    await tester.pumpAndSettle();

    expect(find.text('Draw AI area'), findsWidgets);
    expect(find.text('Use AI area'), findsOneWidget);
    expect(find.textContaining('Export'), findsNothing);
  });

  testWidgets('national scope stays disabled while pipeline blocks it', (
    tester,
  ) async {
    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(
        projectId: project.id,
        nationalScopeEligibility: const AiNationalScopeEligibility(
          eligible: true,
          unmetRequirements: <String>[],
          warnings: <String>[],
          coverage: <String, dynamic>{
            'governorates_covered': 2,
            'total_governorates': 8,
            'governorate_rating': 'weak',
            'grid_cells_covered': 4,
            'total_grid_cells': 20,
            'grid_rating': 'weak',
            'usable_class_count': 2,
            'weak_class_count': 2,
            'class_rating': 'limited',
            'score': 34,
            'rating': 'weak',
          },
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

    final areaDropdown = find.byKey(const ValueKey<String>('ai-area-dropdown'));
    await tester.tap(areaDropdown);
    await tester.pumpAndSettle();

    expect(find.text('National Coverage'), findsOneWidget);
    expect(find.text('National Lebanon (not available)'), findsWidgets);
    await tester.tap(find.text('National Lebanon (not available)').last);
    await tester.pumpAndSettle();

    expect(find.text('Run national classification?'), findsNothing);
    expect(repository.saveCount, 0);
    await tester.tap(find.text('Project area').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Save settings'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save settings'));
    await tester.pumpAndSettle();

    expect(repository.saveCount, 1);
    expect(repository.settings.scopeType, 'project');
    expect(
      repository
          .settings
          .modelPreferences['national_scope_warning_acknowledged'],
      isNot(true),
    );
  });

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

  testWidgets('runs list displays empty state and starts full regional run', (
    tester,
  ) async {
    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id, isEnabled: true),
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
    expect(find.text('View AI server run status and results.'), findsOneWidget);
    expect(
      find.textContaining(
        'Starts an AI run through the backend AI server.',
        skipOffstage: false,
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
    expect(find.text('Detailed run results'), findsNothing);
    expect(find.text('Technical output files'), findsOneWidget);
    expect(find.text('AI run started.'), findsOneWidget);

    expect(find.text('AI run started.'), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('Technical output files'),
      600,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Technical output files'));
    await tester.pumpAndSettle();
    expect(
      find.text('No technical output files were reported for this run.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Prediction features inserted: 0'),
      findsOneWidget,
    );
  });

  testWidgets('start AI run is disabled when AI server is not configured', (
    tester,
  ) async {
    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id, isEnabled: true),
      readiness: fakeReadiness(
        projectId: project.id,
        status: 'not_ready',
        blockers: const <String>['AI server URL is not configured.'],
        aiServer: const AiServerReadiness(
          configured: false,
          available: false,
          status: 'unconfigured',
        ),
      ),
    );
    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    expect(
      find.text('AI server URL is not configured on the backend.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Start AI run'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(repository.createCount, 0);
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
    expect(find.text('Execution support'), findsNothing);
    expect(find.textContaining('Label field: L4_descr'), findsWidgets);
    expect(
      find.textContaining('Satellite sources: Sentinel-2'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Sentinel-2: Year 2026; Growing season 2026-03-01 to 2026-10-31',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Area used: Project feature extent'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Prediction area: Project feature extent'),
      findsOneWidget,
    );
    expect(find.textContaining('Pipeline use:'), findsNothing);
    expect(
      find.textContaining('Selected features: NDVI, EVI, NDRE'),
      findsOneWidget,
    );
    expect(find.textContaining('Feature count: 3'), findsOneWidget);
    expect(
      find.textContaining('Preferred model requested: Support Vector Machine'),
      findsOneWidget,
    );
    expect(find.textContaining('Confidence threshold: 0.6'), findsOneWidget);
    expect(find.textContaining('Settings: Saved for run'), findsNothing);
    expect(
      find.textContaining('Training samples area: Effective now'),
      findsNothing,
    );
    expect(find.textContaining('Pipeline support pending:'), findsNothing);
    expect(find.textContaining('National Lebanon: Available'), findsWidgets);

    expect(find.text('Detailed run results'), findsNothing);
    expect(find.text('What happened'), findsNothing);
    expect(find.text('Model result'), findsOneWidget);
    expect(
      find.textContaining('Best balanced model: Support Vector Machine'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Highest accuracy model: Gradient Boosting'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Final selected model: Support Vector Machine'),
      findsOneWidget,
    );
    expect(find.textContaining('Accuracy: 0.716'), findsOneWidget);
    expect(find.textContaining('Macro-F1: 0.617'), findsOneWidget);
    expect(find.textContaining('Weighted-F1: 0.739'), findsOneWidget);

    expect(find.text('Detailed run results'), findsNothing);
    expect(find.text('What happened'), findsNothing);
    expect(find.text('Limitations'), findsNothing);
    expect(find.text('Technical output files'), findsOneWidget);

    await tester.ensureVisible(find.text('Technical output files'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Technical output files'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Feature table:'), findsOneWidget);
    expect(find.textContaining('Metrics file:'), findsOneWidget);
    expect(find.textContaining('metrics.json'), findsWidgets);
    expect(find.textContaining('model_metadata.json'), findsWidgets);
    expect(find.text('AI server logs'), findsNothing);
    expect(find.text('Technical metadata'), findsNothing);
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
        find.textContaining('Satellite sources: Sentinel-2'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Sentinel-2: Year 2026; Growing season'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Selected features: NDVI, EVI, NDRE'),
        findsOneWidget,
      );
      expect(find.textContaining('Feature count: 3'), findsOneWidget);
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
      findsNothing,
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
    expect(
      find.textContaining('Satellite sources: Sentinel-2'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Sentinel-2: Year 2025; Summer 2025-06-01 to 2025-08-31',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Selected features: B2, B3, B4, B5, B8, B11, B12, NDVI, EVI, NDRE',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Feature count: 10'), findsOneWidget);
    expect(
      find.textContaining('Preferred model requested: Random Forest'),
      findsOneWidget,
    );
    expect(find.textContaining('Pipeline use:'), findsNothing);
    expect(find.textContaining('Confidence threshold: 0.55'), findsOneWidget);
    expect(find.textContaining('Effective now:'), findsNothing);
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
          id: 'metric-gb',
          modelName: 'gradient_boosting',
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

    expect(
      find.textContaining('Best balanced model: Support Vector Machine'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Highest accuracy model: Gradient Boosting'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Final selected model: Support Vector Machine'),
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

  testWidgets('AI output layer section hides statistics artifacts', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 3200));
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

    await tester.ensureVisible(find.text('Output Layer'));
    await tester.pumpAndSettle();

    expect(find.text('Output Layer'), findsOneWidget);
    expect(
      find.text('No AI classification layer has been registered yet.'),
      findsOneWidget,
    );
    expect(find.textContaining('Statistics'), findsNothing);
    expect(find.textContaining('statistics_layer.json'), findsNothing);
    expect(find.text('Layer details'), findsNothing);
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

    await tester.ensureVisible(find.text('Output Layer'));
    await tester.pumpAndSettle();

    expect(find.text('Output Layer'), findsOneWidget);
    expect(
      find.text('No AI classification layer has been registered yet.'),
      findsOneWidget,
    );
    expect(find.textContaining('Statistics'), findsNothing);
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
      layers: _phaseNReviewLayers(),
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

    expect(find.text('Output Layer'), findsOneWidget);
    expect(find.text('Review and publishing'), findsNothing);

    Future<void> openExpansion(String label) async {
      final finder = find.text(label).first;
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

    for (final label in <String>['Layer technical details']) {
      await openExpansion(label);
    }
    expect(find.text('Detailed run results'), findsNothing);
    expect(find.text('AI server logs'), findsNothing);
    expect(find.text('Technical metadata'), findsNothing);
    expect(find.text('Technical output files'), findsOneWidget);
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

    expect(find.text('Publish'), findsOneWidget);
    expect(find.text('Unpublish'), findsNothing);

    final publishButton = find.widgetWithText(FilledButton, 'Publish');
    await tester.scrollUntilVisible(
      publishButton,
      600,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(publishButton);
    await tester.pumpAndSettle();

    expect(repository.publishCount, 1);
    expect(
      find.text('AI layer published as a read-only map overlay.'),
      findsOneWidget,
    );
    expect(find.text('Unpublish'), findsOneWidget);

    final unpublishButton = find.widgetWithText(OutlinedButton, 'Unpublish');
    await tester.scrollUntilVisible(
      unpublishButton,
      600,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(unpublishButton);
    await tester.pumpAndSettle();

    expect(repository.unpublishCount, 1);
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

    expect(find.text('Classification layer'), findsWidgets);
    expect(find.text('Confidence layer'), findsNothing);
    expect(find.text('Uncertainty layer'), findsNothing);
    expect(find.text('Ready for review'), findsWidgets);
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
    expect(find.text('AI features: 1394'), findsOneWidget);
    expect(find.textContaining('Showing'), findsNothing);
    expect(find.text('Optimized preview'), findsNothing);
    expect(find.byTooltip('Browse AI features'), findsOneWidget);
    expect(find.text('1394'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'Confidence'), findsNothing);

    await tester.tap(find.byTooltip('Show AI layers'));
    await tester.pumpAndSettle();

    expect(find.text('Classification'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'Confidence'), findsNothing);
    expect(find.widgetWithText(FilterChip, 'Uncertainty'), findsNothing);
    expect(find.text('Total: 1394'), findsNothing);
    expect(find.text('Visible: 1394'), findsNothing);
    expect(find.text('Loaded: 2'), findsNothing);
    expect(find.textContaining('visible features in this view'), findsNothing);
    expect(find.text('Olives'), findsOneWidget);
    expect(find.text('Citrus Fruit Trees'), findsOneWidget);
    expect(find.text('Fruit Trees'), findsOneWidget);
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
    await tester.ensureVisible(find.text('Filter'));
    await tester.tap(find.text('Filter'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Fruit Trees'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Fruit Trees'));
    await tester.pumpAndSettle();

    final classFilterQuery = repository.layerFeatureQueries.lastWhere(
      (query) =>
          query.layerId == 'layer-classification' &&
          query.page == 1 &&
          query.limit == 20 &&
          query.classLabel == 'Fruit Trees',
    );
    expect(classFilterQuery.limit, 20);
    expect(classFilterQuery.bounds, isNull);
    final filteredSummaryQuery = repository.layerFeatureQueries.lastWhere(
      (query) =>
          query.layerId == 'layer-classification' &&
          query.page == 1 &&
          query.limit == 1 &&
          query.classLabel == 'Fruit Trees',
    );
    expect(filteredSummaryQuery.bounds, isNull);
    final filteredMapQuery = repository.layerFeatureQueries.lastWhere(
      (query) =>
          query.layerId == 'layer-classification' &&
          query.page == null &&
          query.classLabel == 'Fruit Trees',
    );
    expect(filteredMapQuery.bounds, isNotNull);

    final queryCountBeforeClear = repository.layerFeatureQueries.length;
    final allClassChip = find.widgetWithText(ChoiceChip, 'All');
    await tester.ensureVisible(allClassChip);
    await tester.pumpAndSettle();
    await tester.tap(allClassChip.hitTestable());
    await tester.pumpAndSettle();

    expect(
      repository.layerFeatureQueries.length,
      greaterThan(queryCountBeforeClear),
    );
    final clearedClassQuery = repository.layerFeatureQueries
        .skip(queryCountBeforeClear)
        .lastWhere(
          (query) =>
              query.layerId == 'layer-classification' &&
              query.page == 1 &&
              query.classLabel == null,
        );
    expect(clearedClassQuery.limit, 20);
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
    expect(find.text('Prediction details'), findsOneWidget);
    expect(find.text('Attributes'), findsOneWidget);
    expect(find.text('Predicted Class'), findsOneWidget);
    expect(find.text('Confidence'), findsOneWidget);
    expect(find.text('82.0%'), findsWidgets);
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('Random Forest'), findsOneWidget);
    expect(find.text('Review Status'), findsOneWidget);
    expect(find.text('Ready for review'), findsWidgets);
    expect(
      find.textContaining(
        'This is one AI classification layer. Confidence is metadata.',
      ),
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

  testWidgets('statistics layers stay hidden from run details', (tester) async {
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
          storagePath: 'outputs/runs/phase-j/statistics_layer.json',
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

    await tester.ensureVisible(find.text('Output Layer'));
    await tester.pumpAndSettle();

    expect(
      find.text('No AI classification layer has been registered yet.'),
      findsOneWidget,
    );
    expect(find.textContaining('Statistics'), findsNothing);
    expect(find.textContaining('statistics_layer.json'), findsNothing);
    expect(find.text('Layer details'), findsNothing);
    expect(
      find.text('No viewer-facing AI layer is published yet.'),
      findsNothing,
    );

    expect(
      find.text('No viewer-facing AI layer is published yet.'),
      findsNothing,
    );
    expect(find.text('Detailed run results'), findsNothing);
  });

  testWidgets('review and publishing card is removed from run details', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1080, 1900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[_phaseFRegionalRun(projectId: project.id)],
      layers: _phaseNReviewLayers(),
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

    expect(find.text('Output Layer'), findsOneWidget);
    expect(find.text('Classification layer'), findsWidgets);
    expect(find.text('Review and publishing'), findsNothing);
    expect(find.text('Review result'), findsNothing);
    expect(find.text('Approve'), findsNothing);
    expect(find.text('Reject'), findsNothing);
    expect(find.text('Request data'), findsNothing);
    expect(find.text('Keep draft'), findsNothing);
    expect(repository.reviewCount, 0);
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
    expect(find.text('Detailed run results'), findsNothing);
    expect(find.text('Technical output files'), findsOneWidget);
  });

  testWidgets('worker logs section is removed from run details', (
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

    expect(find.text('AI server logs'), findsNothing);
    expect(
      find.text('Worker started regional model evaluation.'),
      findsNothing,
    );
    expect(find.textContaining('secret-value'), findsNothing);
    expect(find.textContaining('[redacted]'), findsNothing);
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
    expect(find.text('Detailed run results'), findsNothing);

    await tester.ensureVisible(find.text('Run ground-r'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run ground-r'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Execution mode: Ground truth export'),
      findsWidgets,
    );
    expect(find.text('Detailed run results'), findsNothing);
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
    expect(find.text('AI server logs'), findsNothing);
    expect(find.text('Technical output files'), findsOneWidget);
    expect(find.text('Detailed run results'), findsNothing);
    await tester.ensureVisible(find.text('Output Layer'));
    await tester.pumpAndSettle();
    expect(
      find.text('No AI classification layer has been registered yet.'),
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

    await tester.ensureVisible(find.text('Run run-seco'));
    await tester.pumpAndSettle();
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

  testWidgets('runs history loads beyond the first backend page latest first', (
    tester,
  ) async {
    final project = _project();
    final runs = List<AiRun>.generate(
      105,
      (index) => AiRun(
        id: 'run-${index.toString().padLeft(3, '0')}',
        projectId: project.id,
        status: 'draft',
        labelField: 'L4_descr',
        scopeType: 'project',
        trainingFeatureCount: 10,
        eligibleFeatureCount: 10,
        excludedFeatureCount: 0,
        createdAt: DateTime.utc(2026, 1, 1).add(Duration(days: index)),
      ),
    );
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: runs,
    );

    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      aiRepository: repository,
      section: 'runs',
    );

    expect(repository.runPageFetchCount, greaterThanOrEqualTo(2));
    expect(find.text('Run run-104'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Run run-000'),
      900,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 30,
    );
    await tester.pumpAndSettle();

    expect(find.text('Run run-000'), findsOneWidget);
  });

  testWidgets('published AI layer panel stays concise', (tester) async {
    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      runs: <AiRun>[
        AiRun(
          id: 'newer-active-run',
          projectId: project.id,
          status: 'running',
          labelField: 'L4_descr',
          scopeType: 'project',
          trainingFeatureCount: 10,
          eligibleFeatureCount: 10,
          excludedFeatureCount: 0,
          createdAt: DateTime.utc(2026, 6, 17),
        ),
        AiRun(
          id: 'published-run-id',
          projectId: project.id,
          status: 'completed',
          labelField: 'L4_descr',
          scopeType: 'project',
          trainingFeatureCount: 10,
          eligibleFeatureCount: 10,
          excludedFeatureCount: 0,
          createdAt: DateTime.utc(2026, 6, 16),
        ),
      ],
      layers: <AiOutputLayer>[
        AiOutputLayer(
          id: 'published-layer',
          aiRunId: 'published-run-id',
          projectId: project.id,
          layerType: 'classification',
          status: 'published',
          name: 'Published classification',
          predictionCount: 12,
          publishedAt: DateTime.utc(2026, 6, 17),
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

    expect(find.text('Open Active Run'), findsNothing);
    expect(find.text('Open Published Run'), findsNothing);
    expect(find.text('View on map'), findsNothing);
    expect(find.text('Current Published AI Layer'), findsOneWidget);
    expect(find.textContaining('Published Run: Run publishe'), findsOneWidget);
    expect(find.textContaining('Prediction Count: 12'), findsOneWidget);
    expect(find.textContaining('Published At:'), findsOneWidget);
    expect(find.textContaining('Published layer:'), findsNothing);
    expect(find.textContaining('Run ID:'), findsNothing);
    expect(find.textContaining('Published by:'), findsNothing);
  });

  testWidgets('check status keeps the selected run details open', (
    tester,
  ) async {
    final project = _project();
    final repository = FakeAiRepository(
      settings: fakeAiSettings(projectId: project.id),
      readiness: fakeReadiness(projectId: project.id),
      onFetchRunStatus: (current) => AiRun(
        id: current.id,
        projectId: current.projectId,
        status: 'completed',
        labelField: current.labelField,
        scopeType: current.scopeType,
        trainingFeatureCount: current.trainingFeatureCount,
        eligibleFeatureCount: current.eligibleFeatureCount,
        excludedFeatureCount: current.excludedFeatureCount,
        progress: 1,
        completedAt: DateTime.utc(2026, 6, 17, 8),
        updatedAt: DateTime.utc(2026, 6, 17, 8),
      ),
      runs: <AiRun>[
        AiRun(
          id: 'check-status-run',
          projectId: project.id,
          status: 'running',
          labelField: 'L4_descr',
          scopeType: 'project',
          trainingFeatureCount: 1406,
          eligibleFeatureCount: 1394,
          excludedFeatureCount: 12,
          stage: 'training',
          progress: 0.44,
          canCancel: true,
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

    await tester.tap(find.text('Run check-st'));
    await tester.pumpAndSettle();
    expect(find.text('Run summary'), findsOneWidget);

    await tester.ensureVisible(find.text('Check status'));
    await tester.tap(find.text('Check status'));
    await tester.pumpAndSettle();

    expect(repository.statusFetchCount, 1);
    expect(find.text('Run summary'), findsOneWidget);
    expect(find.textContaining('Status: Completed'), findsWidgets);
    expect(find.text('Check status'), findsOneWidget);

    await tester.ensureVisible(find.text('Run check-st'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run check-st'));
    await tester.pumpAndSettle();
    expect(find.text('Run summary'), findsNothing);

    await tester.ensureVisible(find.text('Run check-st'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run check-st'));
    await tester.pumpAndSettle();
    expect(find.text('Run summary'), findsOneWidget);
    expect(find.textContaining('Status: Completed'), findsWidgets);
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
