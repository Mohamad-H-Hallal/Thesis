import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/network_availability_base.dart';
import 'package:lebanese_gis_mobile/core/offline/local_models.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store_web.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/project.dart';

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

class _AlwaysOfflineNetworkAvailability implements NetworkAvailabilityService {
  const _AlwaysOfflineNetworkAvailability();

  @override
  Stream<bool> get onOnlineStatusChanged => const Stream<bool>.empty();

  @override
  Future<bool> isOnline() async => false;
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
  String projectId = 'project-1',
}) {
  return LocalDraftFeature(
    id: id,
    ownerUserId: ownerUserId,
    projectId: projectId,
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

ProjectSummary _project(String id) => ProjectSummary(
  id: id,
  name: 'Project $id',
  category: 'Orchards',
  status: 'active',
  assignedCollectors: 1,
  pendingReviews: 0,
  description: 'Offline project $id',
  visibleToContributors: true,
  currentUserAssignmentRole: ProjectAssignmentRole.contributor,
  currentUserAssignmentStatus: ProjectAssignmentStatus.approved,
);

OfflineProjectPackage _package(String projectId) {
  final now = DateTime.utc(2026, 4, 14, 9);
  return OfflineProjectPackage(
    ownerUserId: 'contributor-1',
    project: _project(projectId),
    packageVersion: '$projectId-package-v1',
    appResourcesVersion: '$projectId-resources-v1',
    baseMapVersion: 'shared-map-v1',
    downloadedAt: now,
    refreshedAt: now,
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

  test(
    'same feature id remains isolated by project and synced pin is not restored',
    () async {
      final store = MemoryLocalStore();
      await store.initialize();
      addTearDown(() async => store.dispose());
      await store.upsertOfflineProjectPackage(_package('project-a'));
      await store.upsertOfflineProjectPackage(_package('project-b'));
      await store.upsertDraft(
        _draft(
          id: 'overlapping-id',
          ownerUserId: 'contributor-1',
          projectId: 'project-a',
          status: 'submitted',
        ),
        enqueueSync: false,
      );
      await store.upsertDraft(
        _draft(
          id: 'overlapping-id',
          ownerUserId: 'contributor-1',
          projectId: 'project-b',
          status: 'draft',
        ),
        enqueueSync: false,
      );

      ProviderContainer buildContainer() => ProviderContainer(
        overrides: <Override>[
          localStoreProvider.overrideWithValue(store),
          networkAvailabilityServiceProvider.overrideWithValue(
            const _AlwaysOfflineNetworkAvailability(),
          ),
          authControllerProvider.overrideWith(
            (ref) => _StaticAuthController(
              _session(userId: 'contributor-1', role: UserRole.contributor),
            ),
          ),
        ],
      );

      var container = buildContainer();
      final projectA = await container.read(
        projectMapFeaturesProvider('project-a').future,
      );
      final projectB = await container.read(
        projectMapFeaturesProvider('project-b').future,
      );
      expect(projectA.single.projectId, 'project-a');
      expect(projectA.single.status, 'pending_review');
      expect(projectB.single.projectId, 'project-b');
      expect(projectB.single.status, 'draft');

      final now = DateTime.utc(2026, 4, 14, 10);
      await store.markSyncSuccess(
        SyncQueueItem(
          id: 'queue-a',
          entityType: 'feature',
          entityId: 'overlapping-id',
          operation: SyncOperationType.create,
          payload: const <String, dynamic>{
            'owner_user_id': 'contributor-1',
            'project_id': 'project-a',
          },
          ownerUserId: 'contributor-1',
          projectId: 'project-a',
          localVersion: 1,
          idempotencyKey: 'queue-a',
          attemptCount: 0,
          status: SyncQueueStatus.processing,
          createdAt: now,
          updatedAt: now,
        ),
      );
      container.dispose();

      container = buildContainer();
      addTearDown(container.dispose);
      final reopenedA = await container.read(
        projectMapFeaturesProvider('project-a').future,
      );
      final reopenedB = await container.read(
        projectMapFeaturesProvider('project-b').future,
      );
      expect(reopenedA, isEmpty);
      expect(reopenedB.single.projectId, 'project-b');
      expect(reopenedB.single.id, 'overlapping-id');
    },
  );
}
