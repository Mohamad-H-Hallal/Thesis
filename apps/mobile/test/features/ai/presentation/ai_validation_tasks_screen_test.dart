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
  Future<AppUser> updateProfile({String? fullName, String? phone}) {
    throw UnimplementedError();
  }
}

class _AuthenticatedAuthController extends AuthController {
  _AuthenticatedAuthController(AuthSession session)
    : super(const _NoopAuthRepository()) {
    state = AuthState.authenticated(session);
  }
}

AuthSession _contributorSession() {
  return const AuthSession(
    accessToken: 'token',
    refreshToken: 'refresh',
    user: AppUser(
      id: 'contributor-1',
      fullName: 'Field Contributor',
      email: 'contributor@example.com',
      role: UserRole.contributor,
    ),
  );
}

AiUncertaintyArea _assignedTask() {
  return const AiUncertaintyArea(
    id: 'task-1',
    aiRunId: 'run-1',
    projectId: 'project-1',
    projectName: 'South Lebanon Fruit Trees Training Dataset',
    geometry: <String, dynamic>{
      'type': 'Point',
      'coordinates': <double>[35.5, 33.9],
    },
    suggestedClass: 'citrus fruit trees',
    uncertaintyScore: 0.68,
    confidenceScore: 0.32,
    status: 'assigned',
    assignedTo: 'contributor-1',
    assignedToName: 'Field Contributor',
  );
}

Widget _wrap(FakeAiRepository repository) {
  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWith(
        (_) => _AuthenticatedAuthController(_contributorSession()),
      ),
      aiRepositoryProvider.overrideWithValue(repository),
    ],
    child: const MaterialApp(home: Scaffold(body: AiValidationTasksScreen())),
  );
}

void main() {
  testWidgets('contributor sees assigned AI validation task details', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repository = FakeAiRepository(
      uncertaintyAreas: <AiUncertaintyArea>[_assignedTask()],
    );

    await tester.pumpWidget(_wrap(repository));
    await tester.pumpAndSettle();

    expect(find.text('AI Validation Tasks'), findsOneWidget);
    expect(find.text('Citrus Fruit Trees'), findsWidgets);
    expect(find.text('Uncertainty 68%'), findsOneWidget);
    expect(find.text('Confidence 32%'), findsOneWidget);
    expect(find.text('Open on map'), findsOneWidget);
    expect(find.text('Submit/link validation'), findsOneWidget);
    expect(
      find.textContaining('AI validation task, not official field data'),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('submit validation links a normal feature for review', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repository = FakeAiRepository(
      uncertaintyAreas: <AiUncertaintyArea>[_assignedTask()],
    );

    await tester.pumpWidget(_wrap(repository));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Submit/link validation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Submit/link validation'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'feature-123');
    await tester.enterText(
      find.byType(TextFormField).last,
      'Checked in field.',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
    await tester.pumpAndSettle();

    expect(repository.submitUncertaintyValidationCount, 1);
    expect(repository.uncertaintyAreas.single.status, 'in_review');
    expect(
      repository.uncertaintyAreas.single.validatedFeatureId,
      'feature-123',
    );
    expect(
      repository.uncertaintyAreas.single.validatedFeatureStatus,
      'pending_review',
    );
    expect(repository.uncertaintyAreas.single.metadata['auto_approved'], false);
    expect(tester.takeException(), isNull);
  });
}
