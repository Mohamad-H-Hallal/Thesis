import 'package:flutter/material.dart';
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
    expect(find.text('Custom polygon - future'), findsNothing);
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
      find.text('Project scope uses approved data from this project.'),
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

  testWidgets('custom polygon scope is visible as a disabled future option', (
    tester,
  ) async {
    final project = _project();
    await _pumpAiScreen(
      tester,
      session: _session(role: UserRole.admin, isProtectedSuperAdmin: true),
      project: project,
      section: 'settings',
    );

    await tester.tap(find.text('Project').last);
    await tester.pumpAndSettle();

    expect(find.text('Custom polygon - future'), findsOneWidget);
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

  testWidgets('runs list displays empty state and creates draft metadata only', (
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

    await tester.tap(find.text('Create draft run record'));
    await tester.pumpAndSettle();

    expect(repository.createCount, 1);
    expect(find.text('Run summary'), findsOneWidget);
    expect(find.textContaining('Execution type: Not set'), findsOneWidget);
    expect(
      find.text('Draft run record only. No worker processing has started.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Model metrics will appear after a regional model evaluation run.',
      ),
      findsOneWidget,
    );
    expect(find.text('No published AI layers yet.'), findsOneWidget);
    expect(
      find.text('AI map layers are planned for a later phase.'),
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
    expect(find.textContaining('Status: Ready for review'), findsOneWidget);
    expect(
      find.textContaining('Execution type: Regional model evaluation'),
      findsOneWidget,
    );
    expect(find.textContaining('Label/class field: L4_descr'), findsOneWidget);
    expect(find.textContaining('Duration: 1m 00s'), findsOneWidget);

    expect(find.text('What happened'), findsOneWidget);
    expect(
      find.text('Evaluated regional AI models using approved project data.'),
      findsOneWidget,
    );
    expect(find.textContaining('Approved samples: 1406'), findsOneWidget);
    expect(find.textContaining('Eligible samples: 1394'), findsOneWidget);
    expect(find.textContaining('Excluded classes: 1'), findsOneWidget);

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
    expect(find.textContaining('Accuracy: 0.716'), findsOneWidget);
    expect(find.textContaining('Macro-F1: 0.617'), findsOneWidget);
    expect(find.textContaining('Weighted-F1: 0.739'), findsOneWidget);

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
    expect(find.text('No published AI layers yet.'), findsOneWidget);
    expect(
      find.text('AI map layers are planned for a later phase.'),
      findsOneWidget,
    );
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
      find.textContaining('Execution type: Regional feature extraction'),
      findsOneWidget,
    );
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
      find.textContaining('Execution type: Ground truth export'),
      findsOneWidget,
    );
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

    expect(find.textContaining('Failure reason:'), findsOneWidget);
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
    expect(find.text('No published AI layers yet.'), findsOneWidget);
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
    expect(
      find.textContaining('Label/class field: feature_type'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('Run run-firs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run run-firs'));
    await tester.pumpAndSettle();

    expect(find.text('Run summary'), findsOneWidget);
    expect(find.textContaining('Label/class field: L4_descr'), findsOneWidget);
    expect(
      find.textContaining('Label/class field: feature_type'),
      findsNothing,
    );

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
