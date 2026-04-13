import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/offline/local_models.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store_web.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';

class _NoopAuthRepository implements AuthRepository {
  const _NoopAuthRepository();

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {}

  @override
  Future<void> logout() async {}

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
    required bool rememberMe,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<PasswordResetRequestResult> requestPasswordReset(String email) async {
    throw UnimplementedError();
  }

  @override
  Future<PasswordResetOtpVerificationResult> verifyPasswordResetOtp({
    required String email,
    required String otp,
  }) async {
    throw UnimplementedError();
  }

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

class _StaticAuthController extends AuthController {
  _StaticAuthController(AuthSession session)
    : super(const _NoopAuthRepository()) {
    state = AuthState.authenticated(session);
  }
}

AuthSession _session({required String userId, required UserRole role}) {
  return AuthSession(
    accessToken: 'token',
    refreshToken: 'refresh',
    user: AppUser(
      id: userId,
      fullName: 'Field User',
      email: '$userId@example.com',
      role: role,
    ),
  );
}

LocalDraftFeature _draft({
  required String id,
  required String ownerUserId,
  required String status,
}) {
  return LocalDraftFeature(
    id: id,
    ownerUserId: ownerUserId,
    projectId: 'project-1',
    projectName: 'Bekaa Orchard Census',
    geometryType: 'Point',
    geometryJson: '{"type":"Point","coordinates":[35.58,33.92]}',
    attributesJson: '{"tree_type":"olive"}',
    photos: const <DraftPhoto>[],
    status: status,
    localVersion: 1,
    updatedAt: DateTime.utc(2026, 4, 14, 9),
  );
}

void main() {
  test('local drafts are scoped to the authenticated owner', () async {
    final store = MemoryLocalStore();
    await store.initialize();
    addTearDown(() async => store.dispose());

    await store.upsertDraft(
      _draft(id: 'own-draft', ownerUserId: 'contributor-1', status: 'draft'),
      enqueueSync: false,
    );
    await store.upsertDraft(
      _draft(
        id: 'other-draft',
        ownerUserId: 'contributor-2',
        status: 'submitted',
      ),
      enqueueSync: false,
    );

    final container = ProviderContainer(
      overrides: <Override>[
        localStoreProvider.overrideWithValue(store),
        authControllerProvider.overrideWith(
          (ref) => _StaticAuthController(
            _session(userId: 'contributor-1', role: UserRole.contributor),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final drafts = await container.read(localDraftFeaturesProvider.future);

    expect(drafts.map((item) => item.id), <String>['own-draft']);
  });
}
