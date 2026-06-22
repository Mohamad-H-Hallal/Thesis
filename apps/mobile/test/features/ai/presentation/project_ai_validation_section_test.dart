import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/features/ai/presentation/ai_providers.dart';
import 'package:lebanese_gis_mobile/features/ai/presentation/screens/project_ai_screen.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';
import 'package:lebanese_gis_mobile/features/map/domain/map_feature.dart';
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

AuthSession _superAdminSession() {
  return const AuthSession(
    accessToken: 'token-admin-1',
    refreshToken: 'refresh-admin-1',
    user: AppUser(
      id: 'admin-1',
      fullName: 'Protected Super Admin',
      email: 'admin@example.com',
      role: UserRole.admin,
      isProtectedSuperAdmin: true,
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

Widget _wrap({required FakeAiRepository repository}) {
  final project = _project();
  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWith(
        (_) => _AuthenticatedAuthController(_superAdminSession()),
      ),
      aiRepositoryProvider.overrideWithValue(repository),
      projectByIdProvider.overrideWith((ref, id) async => project),
      projectMapFeaturesProvider.overrideWith(
        (ref, projectId) async => const <MapFeatureSummary>[],
      ),
      offlineMapPackageProvider.overrideWith((ref) async => null),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: ProjectAiScreen(
          projectId: project.id,
          initialSection: 'validation',
        ),
      ),
    ),
  );
}

void main() {
  group('Project AI validation tab removal', () {
    testWidgets('super-admin no longer sees Validate tab in AI Settings', (
      tester,
    ) async {
      final repository = FakeAiRepository();

      await tester.pumpWidget(_wrap(repository: repository));
      await tester.pumpAndSettle();

      expect(find.text('Ready'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Runs'), findsOneWidget);
      expect(find.text('Validate'), findsNothing);
      expect(find.text('AI Prediction Validation'), findsNothing);
      expect(find.text('Generate validation tasks'), findsNothing);
      expect(find.text('Assign'), findsNothing);
      expect(find.text('Accept'), findsNothing);
    });
  });
}
