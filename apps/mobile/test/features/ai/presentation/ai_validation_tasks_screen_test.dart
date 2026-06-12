import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/features/ai/domain/ai_models.dart';
import 'package:lebanese_gis_mobile/features/ai/presentation/ai_providers.dart';
import 'package:lebanese_gis_mobile/features/ai/presentation/screens/ai_validation_tasks_screen.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/project.dart';

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

AuthSession _session(UserRole role, {String userId = 'contributor-1'}) {
  return AuthSession(
    accessToken: 'token-$userId',
    refreshToken: 'refresh-$userId',
    user: AppUser(
      id: userId,
      fullName: '${role.name} user',
      email: '$userId@example.com',
      role: role,
      isProtectedSuperAdmin: false,
    ),
  );
}

ProjectSummary _project() {
  return const ProjectSummary(
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
  );
}

Widget _wrap({
  required AuthSession session,
  required FakeAiRepository repository,
}) {
  final project = _project();
  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWith(
        (_) => _AuthenticatedAuthController(session),
      ),
      aiRepositoryProvider.overrideWithValue(repository),
      projectByIdProvider.overrideWith((ref, id) async => project),
    ],
    child: const MaterialApp(home: Scaffold(body: AiValidationTasksScreen())),
  );
}

void main() {
  group('AiValidationTasksScreen', () {
    testWidgets('contributor sees available project AI validation tasks', (
      tester,
    ) async {
      final repository = FakeAiRepository(
        validationTasks: <AiPredictionValidationTask>[
          fakeAiValidationTask(status: 'open', assignedTo: null),
        ],
      );

      await tester.pumpWidget(
        _wrap(session: _session(UserRole.contributor), repository: repository),
      );
      await tester.pumpAndSettle();

      expect(find.text('AI Validation'), findsOneWidget);
      expect(find.text('Olives'), findsOneWidget);
      expect(
        find.text('AI validation task, not official field data.'),
        findsOneWidget,
      );
      expect(find.text('Open to project contributors'), findsOneWidget);
      expect(find.text('Submit validation'), findsOneWidget);
    });

    testWidgets('contributor empty state is clear', (tester) async {
      await tester.pumpWidget(
        _wrap(
          session: _session(UserRole.contributor),
          repository: FakeAiRepository(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No AI validation tasks'), findsOneWidget);
      expect(
        find.text(
          'Available project AI prediction validation tasks will appear here.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('viewer is denied validation task screen', (tester) async {
      await tester.pumpWidget(
        _wrap(
          session: _session(UserRole.viewer, userId: 'viewer-1'),
          repository: FakeAiRepository(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('AI validation restricted'), findsOneWidget);
      expect(
        find.text('Only project contributors can open AI validation tasks.'),
        findsOneWidget,
      );
      expect(find.text('Submit validation'), findsNothing);
    });

    testWidgets('correct submission stores evidence for review', (
      tester,
    ) async {
      final repository = FakeAiRepository(
        runs: <AiRun>[
          AiRun(
            id: 'run-1',
            projectId: 'project-1',
            status: 'ready_for_review',
            labelField: 'L4_descr',
            scopeType: 'project',
            trainingFeatureCount: 1394,
            eligibleFeatureCount: 1394,
            excludedFeatureCount: 0,
            selectedModel: 'random_forest',
            metadata: const <String, dynamic>{
              'trained_classes': <String>[
                'Olives',
                'Fruit Trees',
                'Citrus Fruit Trees',
              ],
            },
          ),
        ],
        validationTasks: <AiPredictionValidationTask>[fakeAiValidationTask()],
      );

      await tester.pumpWidget(
        _wrap(session: _session(UserRole.contributor), repository: repository),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Submit validation'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Note / evidence'),
        'Checked in the field and the prediction is correct.',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
      await tester.pumpAndSettle();

      expect(repository.validationSubmitCount, 1);
      expect(repository.validationTasks.single.status, 'submitted');
      expect(
        repository.validationTasks.single.latestSubmission?.result,
        'correct',
      );
      expect(repository.validationTasks.single.noSpatialFeatureWrites, isTrue);

      await tester.tap(find.text('Submit validation'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Note / evidence'),
        'Trying to submit the same validation twice.',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('already submitted active evidence'),
        findsOneWidget,
      );
    });

    testWidgets('wrong class requires eligible corrected class and note', (
      tester,
    ) async {
      final repository = FakeAiRepository(
        validationTasks: <AiPredictionValidationTask>[
          fakeAiValidationTask(
            prediction: fakeAiValidationPrediction(
              metadata: const <String, dynamic>{
                'trained_classes': <String>['Olives', 'Fruit Trees'],
              },
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        _wrap(session: _session(UserRole.contributor), repository: repository),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Submit validation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Correct').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wrong class').last);
      await tester.pumpAndSettle();

      expect(find.text('Corrected class'), findsOneWidget);
      expect(find.text('Banana'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
      await tester.pumpAndSettle();
      expect(find.text('Note/evidence is required.'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Note / evidence'),
        'The field trees match another trained class.',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
      await tester.pumpAndSettle();
      expect(find.text('Corrected class is required.'), findsOneWidget);

      final correctedClassDropdown = find
          .byWidgetPredicate(
            (widget) => widget is DropdownButtonFormField<String>,
          )
          .last;
      await tester.tap(correctedClassDropdown);
      await tester.pumpAndSettle();
      expect(find.text('Olives'), findsWidgets);
      expect(find.text('Fruit Trees'), findsOneWidget);
      expect(find.text('Banana'), findsNothing);
      await tester.tap(find.text('Fruit Trees').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
      await tester.pumpAndSettle();

      expect(repository.validationSubmitCount, 1);
      expect(
        repository.validationTasks.single.latestSubmission?.correctedClass,
        'Fruit Trees',
      );
    });
  });
}
