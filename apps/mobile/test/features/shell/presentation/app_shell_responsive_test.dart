import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/core/network/network_availability_base.dart';
import 'package:lebanese_gis_mobile/core/offline/local_models.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/core/router/route_paths.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_controller.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_engine.dart';
import 'package:lebanese_gis_mobile/features/admin/domain/admin_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/project.dart';
import 'package:lebanese_gis_mobile/features/shell/presentation/app_shell_screen.dart';

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
  }) async => const PasswordResetOtpVerificationResult(
    message: 'verified',
    resetToken: 'token',
    email: 'superadmin@example.com',
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
    return AppUser(
      id: 'admin-1',
      fullName: fullName ?? 'Super Admin',
      email: 'superadmin@example.com',
      role: UserRole.admin,
      phone: phone,
      isProtectedSuperAdmin: true,
    );
  }
}

class _AuthenticatedAuthController extends AuthController {
  _AuthenticatedAuthController(AuthSession session)
    : super(const _NoopAuthRepository()) {
    state = AuthState.authenticated(session);
  }
}

class _AlwaysOnlineNetworkAvailability implements NetworkAvailabilityService {
  const _AlwaysOnlineNetworkAvailability();

  @override
  Stream<bool> get onOnlineStatusChanged => const Stream<bool>.empty();

  @override
  Future<bool> isOnline() async => true;
}

class _FakeLocalStore implements LocalStore {
  @override
  Future<void> cacheProjects(List<ProjectSummary> projects) async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<void> enqueueSyncItem(SyncQueueItem item) async {}

  @override
  Future<List<ProjectSummary>> getCachedProjects() async =>
      const <ProjectSummary>[];

  @override
  Future<LocalDraftFeature?> getDraftById(String draftId) async => null;

  @override
  Future<void> discardDraft(String draftId) async {}

  @override
  Future<List<LocalDraftFeature>> getDrafts() async =>
      const <LocalDraftFeature>[];

  @override
  Future<List<SyncQueueItem>> getDueSyncItems(
    DateTime now, {
    int limit = 20,
  }) async => const <SyncQueueItem>[];

  @override
  Future<OfflineMapPackage?> getCurrentOfflineMapPackage({
    required String ownerUserId,
  }) async => null;

  @override
  Future<void> upsertOfflineProjectPackage(
    OfflineProjectPackage package,
  ) async {}

  @override
  Future<OfflineProjectPackage?> getOfflineProjectPackage({
    required String ownerUserId,
    required String projectId,
  }) async => null;

  @override
  Future<List<OfflineProjectPackage>> getOfflineProjectPackages({
    required String ownerUserId,
  }) async => const <OfflineProjectPackage>[];

  @override
  Future<void> deleteOfflineProjectPackage({
    required String ownerUserId,
    required String projectId,
  }) async {}

  @override
  Future<int> countOfflineProjectPackagesUsingBaseMap({
    required String ownerUserId,
    required String baseMapVersion,
  }) async => 0;

  @override
  Future<int> countUnsyncedDraftsForProject({
    required String ownerUserId,
    required String projectId,
  }) async => 0;

  @override
  Future<int> getPendingSyncCount() async => 0;

  @override
  Future<SyncQueueStats> getSyncQueueStats() async => const SyncQueueStats(
    pending: 0,
    processing: 0,
    failed: 0,
    conflict: 0,
    deadLetter: 0,
  );

  @override
  Future<void> initialize() async {}

  @override
  Future<void> markSyncConflict(
    SyncQueueItem item, {
    required String error,
  }) async {}

  @override
  Future<void> markSyncDeadLetter(
    SyncQueueItem item, {
    required String error,
  }) async {}

  @override
  Future<void> markSyncFailure(
    SyncQueueItem item, {
    required String error,
    required DateTime nextRetryAt,
  }) async {}

  @override
  Future<void> markSyncProcessing(String queueId) async {}

  @override
  Future<void> markSyncSuccess(
    SyncQueueItem item, {
    int? remoteVersion,
    String? draftStatus,
  }) async {}

  @override
  Future<void> seedIfEmpty({
    required List<ProjectSummary> projects,
    required List<LocalDraftFeature> drafts,
  }) async {}

  @override
  Future<void> updateDraftStatus(
    String draftId, {
    required String status,
    int? remoteVersion,
  }) async {}

  @override
  Future<void> upsertDraft(
    LocalDraftFeature draft, {
    bool enqueueSync = true,
  }) async {}

  @override
  Future<void> upsertOfflineMapPackage(OfflineMapPackage package) async {}
}

SyncController _buildSyncController() {
  final localStore = _FakeLocalStore();
  return SyncController(
      syncEngine: SyncEngine(localStore: localStore, apiClient: ApiClient()),
      localStore: localStore,
      networkAvailability: const _AlwaysOnlineNetworkAvailability(),
    )
    ..state = const SyncState(
      pendingCount: 0,
      conflictCount: 0,
      deadLetterCount: 0,
      isSyncing: false,
      isReady: true,
      isInitializing: false,
      autoSyncRunning: false,
    );
}

AuthSession _superAdminSession() {
  return AuthSession(
    accessToken: 'token',
    refreshToken: 'refresh',
    user: const AppUser(
      id: 'admin-1',
      fullName: 'Super Admin',
      email: 'superadmin@example.com',
      role: UserRole.admin,
      isProtectedSuperAdmin: true,
    ),
  );
}

Widget _buildShell() {
  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWith(
        (ref) => _AuthenticatedAuthController(_superAdminSession()),
      ),
      syncControllerProvider.overrideWith((ref) => _buildSyncController()),
      adminDashboardProvider.overrideWith(
        (ref) async => const AdminDashboardSummary(
          totalUsers: 12,
          adminCount: 2,
          viewerCount: 4,
          activeContributorCount: 5,
          blockedCount: 1,
          pendingContributorRequests: 3,
          rejectedContributorRequests: 2,
          totalProjects: 7,
          pendingAssignments: 4,
        ),
      ),
    ],
    child: const MaterialApp(
      home: AppShellScreen(location: AppRoutes.dashboard),
    ),
  );
}

void main() {
  testWidgets('app shell uses bottom navigation on compact widths', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_buildShell());
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDrawer), findsNothing);
    expect(find.text('Admin Panel'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('app shell uses side navigation on tablet widths', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_buildShell());
    await tester.pumpAndSettle();

    expect(find.byType(NavigationDrawer), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Users'), findsWidgets);
    expect(find.text('Projects'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
