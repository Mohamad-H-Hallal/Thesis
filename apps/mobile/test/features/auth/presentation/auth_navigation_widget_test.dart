// ignore_for_file: use_super_parameters

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/core/network/network_availability_base.dart';
import 'package:lebanese_gis_mobile/core/offline/local_models.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store.dart';
import 'package:lebanese_gis_mobile/core/pagination/paginated_result.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/core/realtime/realtime_models.dart';
import 'package:lebanese_gis_mobile/core/realtime/realtime_scope_registry.dart';
import 'package:lebanese_gis_mobile/core/realtime/workflow_realtime_coordinator.dart';
import 'package:lebanese_gis_mobile/core/realtime/workflow_realtime_service.dart';
import 'package:lebanese_gis_mobile/core/router/route_paths.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_controller.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_engine.dart';
import 'package:lebanese_gis_mobile/features/admin/domain/admin_models.dart';
import 'package:lebanese_gis_mobile/features/auth/data/contact_verification_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_failure.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/contact_verification_models.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/screens/contact_verification_screen.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/screens/login_screen.dart';
import 'package:lebanese_gis_mobile/features/legal/domain/legal_models.dart';
import 'package:lebanese_gis_mobile/features/legal/domain/legal_repository.dart';
import 'package:lebanese_gis_mobile/features/legal/presentation/legal_providers.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/project.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/projects_repository.dart';

class _TestAuthRepository implements AuthRepository {
  const _TestAuthRepository({
    this.loginFailure,
    this.signupMessage,
    this.signupFailure,
  });

  final AuthFailure? loginFailure;
  final String? signupMessage;
  final AuthFailure? signupFailure;

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
    required bool rememberMe,
  }) async {
    if (loginFailure != null) {
      throw loginFailure!;
    }

    return AuthSession(
      accessToken: 'token',
      refreshToken: 'refresh',
      user: AppUser(
        id: 'user-1',
        fullName: 'Test User',
        email: email,
        role: UserRole.viewer,
      ),
    );
  }

  @override
  Future<void> logout() async {}

  @override
  Future<PasswordResetRequestResult> requestPasswordReset(String email) async {
    return const PasswordResetRequestResult(
      message: 'A verification code has been sent to your email.',
      email: 'test@example.com',
    );
  }

  @override
  Future<PasswordResetOtpVerificationResult> verifyPasswordResetOtp({
    required String email,
    required String otp,
  }) async => const PasswordResetOtpVerificationResult(
    message: 'Verification code confirmed.',
    resetToken: 'reset-session-token',
    email: 'test@example.com',
  );

  @override
  Future<void> resetPassword({
    required String resetToken,
    required String newPassword,
  }) async {}

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {}

  @override
  Future<AppUser> updateProfile({String? fullName, String? phone}) async {
    return AppUser(
      id: 'user-1',
      fullName: fullName ?? 'Test User',
      email: 'test@example.com',
      role: UserRole.viewer,
      phone: phone,
    );
  }

  @override
  Future<AuthSession> reactivateContributorAndLogin({
    required String email,
    required String password,
    required bool rememberMe,
  }) async {
    if (loginFailure != null) {
      throw loginFailure!;
    }
    return AuthSession(
      accessToken: 'token',
      refreshToken: 'refresh',
      user: AppUser(
        id: 'user-1',
        fullName: 'Test User',
        email: email,
        role: UserRole.contributor,
      ),
    );
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
  }) async {
    if (signupFailure != null) {
      throw signupFailure!;
    }
    return signupMessage ?? 'Signup completed';
  }
}

class _CountingSignupRepository extends _TestAuthRepository {
  int signupCalls = 0;

  @override
  Future<String> signup({
    required String fullName,
    required String email,
    required String password,
    required UserRole role,
    String? phone,
  }) async {
    signupCalls += 1;
    return super.signup(
      fullName: fullName,
      email: email,
      password: password,
      role: role,
      phone: phone,
    );
  }
}

class _TestRealtimeService extends WorkflowRealtimeService {
  void Function(RealtimeConnectionState state)? _onStateChanged;

  @override
  void connect({
    required String accessToken,
    required RealtimeAccessTokenProvider accessTokenProvider,
    required RealtimeScopeRegistry scopeRegistry,
    required void Function(RealtimeDomainEvent value) onDomainChanged,
    required void Function(List<RealtimeKnownRevision> value) onStaleScopes,
    void Function(WorkflowRealtimeEvent value)? onLegacyWorkflowChanged,
    void Function(RealtimeConnectionState value)? onStateChanged,
  }) {
    _onStateChanged = onStateChanged;
    onStateChanged?.call(RealtimeConnectionState.connected);
  }

  @override
  void disconnect({bool offline = false}) {
    _onStateChanged?.call(
      offline
          ? RealtimeConnectionState.offline
          : RealtimeConnectionState.disconnected,
    );
  }
}

class _TestLegalRepository extends LegalRepository {
  _TestLegalRepository();

  final AccountDeletionEligibility eligibility =
      const AccountDeletionEligibility(
        canRequest: true,
        operationallyEligible: true,
        protectedAccount: false,
        role: 'viewer',
        blockers: <AccountDeletionBlocker>[],
        manualReviewRequired: true,
        notice: 'Verified review required.',
      );
  int deletionRequests = 0;
  String? submittedPassword;

  @override
  Future<AccountDeletionEligibility> fetchAccountDeletionEligibility() async =>
      eligibility;

  @override
  Future<PrivacyRequestRecord> createPrivacyRequest({
    required PrivacyRequestType type,
    String? currentPassword,
    Map<String, dynamic>? details,
  }) async {
    if (type == PrivacyRequestType.deletion) {
      deletionRequests += 1;
      submittedPassword = currentPassword;
    }
    return PrivacyRequestRecord(
      id: 'privacy-request-1',
      type: type,
      status: 'open',
      requestedAt: DateTime(2026, 8, 13),
      internalTargetAt: DateTime(2026, 8, 23),
    );
  }

  @override
  Future<void> acceptCurrentDocuments(List<LegalDocument> documents) async {}

  @override
  Future<PrivacyRequestRecord> cancelPrivacyRequest(String requestId) =>
      throw UnimplementedError();

  @override
  Future<LegalAcceptanceStatus> fetchAcceptanceStatus() =>
      throw UnimplementedError();

  @override
  Future<LegalDocument> fetchDocument(
    String slug, {
    String locale = 'en',
    String? version,
  }) => throw UnimplementedError();

  @override
  Future<List<LegalDocument>> fetchDocuments({String locale = 'en'}) async =>
      const <LegalDocument>[];

  @override
  Future<List<PrivacyRequestRecord>> fetchMyPrivacyRequests() async =>
      const <PrivacyRequestRecord>[];

  @override
  Future<void> reportContent({
    required String projectId,
    required String entityType,
    required String entityId,
    required String reasonCode,
    String? description,
  }) async {}
}

class _AuthenticatedAuthController extends AuthController {
  _AuthenticatedAuthController({
    required AuthRepository repository,
    required AuthSession session,
  }) : super(repository) {
    state = AuthState.authenticated(session);
  }
}

class _UnauthenticatedAuthController extends AuthController {
  _UnauthenticatedAuthController(AuthRepository repository)
    : super(repository) {
    state = const AuthState.unauthenticated();
  }
}

class _TestContactVerificationRepository extends ContactVerificationRepository {
  _TestContactVerificationRepository({ContactVerificationState? state})
    : _state = state ?? _pendingEmail,
      super(const FlutterSecureStorage(), ApiClient());

  final ContactVerificationState _state;
  int formatValidationCalls = 0;
  int cancellationCalls = 0;
  int clearSessionCalls = 0;

  static final _pendingEmail = ContactVerificationState(
    accountStatus: 'pending_verification',
    emailVerified: false,
    phoneVerified: false,
    phoneFormatValidated: false,
    phoneAssuranceMode: 'format_only',
    phoneAssuranceLevel: 'unvalidated',
    phoneOwnershipRequired: false,
    nextStep: ContactVerificationStep.email,
    maskedEmail: 'v***@example.com',
    maskedPhone: '+961 3 *** ***',
    expiresAt: DateTime.now().add(const Duration(minutes: 5)),
    resendAfterSeconds: 60,
  );

  @override
  Future<bool> hasPendingSession() async => true;

  @override
  Future<ContactVerificationState> status() async => _state;

  @override
  Future<ContactVerificationState> sendEmail({String? correctedEmail}) async =>
      _state;

  @override
  Future<ContactVerificationResult> validatePhone({
    String? correctedPhone,
  }) async {
    formatValidationCalls += 1;
    return const ContactVerificationResult(
      message: 'Email verified. Signup is complete.',
      state: ContactVerificationState(
        accountStatus: 'active',
        emailVerified: true,
        phoneVerified: false,
        phoneFormatValidated: true,
        phoneAssuranceMode: 'format_only',
        phoneAssuranceLevel: 'format_validated',
        phoneOwnershipRequired: false,
        nextStep: ContactVerificationStep.complete,
        maskedEmail: 'v***@example.com',
        maskedPhone: '+961 70 *** ***',
      ),
    );
  }

  @override
  Future<void> cancelPendingSignup() async {
    cancellationCalls += 1;
  }

  @override
  Future<void> clearPendingSession() async {
    clearSessionCalls += 1;
  }
}

class _AlwaysOnlineNetworkAvailability implements NetworkAvailabilityService {
  const _AlwaysOnlineNetworkAvailability();

  @override
  Stream<bool> get onOnlineStatusChanged => const Stream<bool>.empty();

  @override
  Future<bool> isOnline() async => true;
}

class _FakeLocalStore extends LocalStore {
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
  Future<List<LocalDraftFeature>> getDrafts() async =>
      const <LocalDraftFeature>[];

  @override
  Future<LocalDraftFeature?> getDraftById(String draftId) async => null;

  @override
  Future<void> discardDraft(String draftId) async {}

  @override
  Future<void> upsertOfflineMapPackage(OfflineMapPackage package) async {}

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
  Future<List<SyncQueueItem>> getDueSyncItems(
    DateTime now, {
    int limit = 20,
  }) async => const <SyncQueueItem>[];

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
    int? remoteVersion,
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
}

class _EmptyProjectsRepository implements ProjectsRepository {
  const _EmptyProjectsRepository();

  @override
  Future<List<ProjectSummary>> fetchProjects({
    required String userId,
    required UserRole role,
    required ProjectViewScope scope,
  }) async => const <ProjectSummary>[];

  @override
  Future<PaginatedResult<ProjectSummary>> fetchProjectsPage({
    required String userId,
    required UserRole role,
    required ProjectViewScope scope,
    String? query,
    String? status,
    String? categoryId,
    int page = 1,
    int limit = 20,
  }) async => PaginatedResult<ProjectSummary>(
    items: const <ProjectSummary>[],
    page: page,
    limit: limit,
    total: 0,
    hasMore: false,
  );

  @override
  Future<ProjectSummary?> byId({
    required String id,
    required String userId,
    required UserRole role,
  }) async => null;

  @override
  Future<OfflineProjectPackage> fetchOfflinePackage({
    required String projectId,
    required String ownerUserId,
  }) {
    throw UnimplementedError(
      'Offline packages are not used in auth routing tests.',
    );
  }

  @override
  Future<ProjectSummary> updateContributorVisibility({
    required String projectId,
    required bool visibleToContributors,
  }) {
    throw UnimplementedError(
      'Project updates are not used in auth routing tests.',
    );
  }

  @override
  Future<ProjectSummary> updateViewerVisibility({
    required String projectId,
    required bool visibleToViewers,
  }) {
    throw UnimplementedError(
      'Project updates are not used in auth routing tests.',
    );
  }

  @override
  Future<void> requestProjectAccess({required String projectId}) async {}

  @override
  Future<void> cancelProjectAccessRequest({required String projectId}) async {}
}

SyncController _buildSyncController() {
  final localStore = _FakeLocalStore();
  return SyncController(
    syncEngine: SyncEngine(
      localStore: localStore,
      apiClient: ApiClient(dio: Dio()),
    ),
    localStore: localStore,
    networkAvailability: const _AlwaysOnlineNetworkAvailability(),
  );
}

List<Override> _routedShellOverrides() => <Override>[
  networkAvailabilityServiceProvider.overrideWithValue(
    const _AlwaysOnlineNetworkAvailability(),
  ),
  projectsRepositoryProvider.overrideWithValue(
    const _EmptyProjectsRepository(),
  ),
  syncControllerProvider.overrideWith((ref) => _buildSyncController()),
  projectsProvider.overrideWith((ref) async => const <ProjectSummary>[]),
  projectListProvider.overrideWith(
    (ref, scope) async => const <ProjectSummary>[],
  ),
  supportSettingsProvider.overrideWith(
    (ref) async => const SupportContactSettings(
      supportEmail: null,
      supportPhone: null,
      officeHours: null,
      helpText: null,
    ),
  ),
];

AuthSession _sessionForRole(
  UserRole role, {
  bool isProtectedSuperAdmin = false,
}) {
  return AuthSession(
    accessToken: 'token',
    refreshToken: 'refresh',
    user: AppUser(
      id: 'user-1',
      fullName: '${role.name} user',
      email: '${role.name}@example.com',
      role: role,
      isProtectedSuperAdmin: isProtectedSuperAdmin,
    ),
  );
}

Widget _buildRoutedApp(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: Consumer(
      builder: (context, ref, _) {
        final router = ref.watch(routerProvider);
        return MaterialApp.router(routerConfig: router);
      },
    ),
  );
}

Widget _buildRoutedAppWithRealtime(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: Consumer(
      builder: (context, ref, _) {
        final router = ref.watch(routerProvider);
        return MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => WorkflowRealtimeCoordinator(
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
    ),
  );
}

Future<void> _pumpRoutedShell(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}

Future<void> _acceptSignupPolicies(WidgetTester tester) async {
  final checkbox = find.byKey(const ValueKey('signup-policy-acceptance'));
  await tester.ensureVisible(checkbox);
  await tester.tap(checkbox);
  await tester.pump();
}

void main() {
  testWidgets(
    'unverified login back clears the local verification attempt and returns to an empty login',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const authRepository = _TestAuthRepository(
        loginFailure: AuthFailure(
          'Contact verification is required before you can enter TerraLeb.',
          statusCode: 403,
          code: 'contact_verification_required',
        ),
      );
      final contactRepository = _TestContactVerificationRepository();
      final container = ProviderContainer(
        overrides: <Override>[
          authRepositoryProvider.overrideWithValue(authRepository),
          authControllerProvider.overrideWith(
            (ref) => _UnauthenticatedAuthController(authRepository),
          ),
          contactVerificationRepositoryProvider.overrideWithValue(
            contactRepository,
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_buildRoutedApp(container));
      await tester.pumpAndSettle();
      container.read(routerProvider).go(AppRoutes.login);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextFormField).at(0),
        'pending@example.com',
      );
      await tester.enterText(find.byType(TextFormField).at(1), 'Passw0rd!123');
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Login'))
          .onPressed!();
      await tester.pumpAndSettle();

      expect(find.byType(ContactVerificationScreen), findsOneWidget);
      expect(find.text('Back to login'), findsOneWidget);
      expect(find.text('Back to signup'), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('Leave verification?'), findsOneWidget);
      expect(
        find.text('Return to login? Your verification progress will be saved.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('removes the unfinished account'),
        findsNothing,
      );

      final stayButton = find.widgetWithText(TextButton, 'Stay');
      final returnButton = find.widgetWithText(FilledButton, 'Login');
      final stayRect = tester.getRect(stayButton);
      final returnRect = tester.getRect(returnButton);
      expect(stayRect.width, closeTo(returnRect.width, 0.1));
      expect(stayRect.top, closeTo(returnRect.top, 0.1));
      expect(returnRect.left, greaterThan(stayRect.right));

      await tester.tap(returnButton);
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(contactRepository.clearSessionCalls, 1);
      expect(contactRepository.cancellationCalls, 0);
      expect(container.read(authControllerProvider).error, isNull);
      expect(container.read(authControllerProvider).errorCode, isNull);
      for (final field in tester.widgetList<TextFormField>(
        find.byType(TextFormField),
      )) {
        expect(field.controller?.text ?? '', isEmpty);
      }
    },
  );

  testWidgets('signup verification back keeps the account-removal warning', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const authRepository = _TestAuthRepository();
    final contactRepository = _TestContactVerificationRepository();
    final container = ProviderContainer(
      overrides: <Override>[
        authRepositoryProvider.overrideWithValue(authRepository),
        authControllerProvider.overrideWith(
          (ref) => _UnauthenticatedAuthController(authRepository),
        ),
        contactVerificationRepositoryProvider.overrideWithValue(
          contactRepository,
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildRoutedApp(container));
    await tester.pumpAndSettle();
    container
        .read(routerProvider)
        .go(AppRoutes.contactVerification(fromLogin: false));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Back to signup'));
    await tester.pumpAndSettle();
    expect(find.text('Return to signup?'), findsOneWidget);
    expect(
      find.textContaining('remove the unfinished account'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(contactRepository.cancellationCalls, 1);
    expect(find.byType(LoginScreen), findsNothing);
    expect(find.text('Create account'), findsWidgets);
  });

  testWidgets('login opens Privacy and Terms while unauthenticated', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const repository = _TestAuthRepository();
    final container = ProviderContainer(
      overrides: <Override>[
        authRepositoryProvider.overrideWithValue(repository),
        authControllerProvider.overrideWith(
          (ref) => _UnauthenticatedAuthController(repository),
        ),
        legalDocumentProvider.overrideWith(
          (ref, slug) async => LegalDocument(
            type: slug,
            slug: slug,
            locale: 'en',
            version: 'draft-test',
            title: slug == 'privacy' ? 'Privacy Notice' : 'Terms of Use',
            status: 'draft',
            summary: 'Public legal document available before login.',
            sections: const <LegalSection>[],
            contentSha256: List<String>.filled(64, 'a').join(),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildRoutedApp(container));
    await tester.pumpAndSettle();
    container.read(routerProvider).go(AppRoutes.login);
    await tester.pumpAndSettle();

    final accountLine = tester
        .getRect(find.text('No account yet?'))
        .expandToInclude(tester.getRect(find.text('Create account')));
    final legalLine = tester
        .getRect(find.text('Read our'))
        .expandToInclude(tester.getRect(find.text('Privacy Notice')))
        .expandToInclude(tester.getRect(find.text('and')))
        .expandToInclude(tester.getRect(find.text('Terms of Use')));
    expect(accountLine.center.dx, closeTo(450, 1));
    expect(legalLine.center.dx, closeTo(450, 1));

    await tester.tap(find.text('Privacy Notice'));
    await tester.pumpAndSettle();
    expect(find.text('Privacy Notice'), findsOneWidget);

    container.read(routerProvider).go(AppRoutes.login);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Terms of Use'));
    await tester.pumpAndSettle();
    expect(find.text('Terms of Use'), findsOneWidget);
  });

  testWidgets(
    'signup policies are not prechecked and optional purposes stay separate',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const repository = _TestAuthRepository();
      final container = ProviderContainer(
        overrides: <Override>[
          authRepositoryProvider.overrideWithValue(repository),
          authControllerProvider.overrideWith(
            (ref) => _UnauthenticatedAuthController(repository),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_buildRoutedApp(container));
      await tester.pumpAndSettle();
      container.read(routerProvider).go(AppRoutes.signup);
      await tester.pumpAndSettle();

      final checkbox = tester.widget<Checkbox>(
        find.byKey(const ValueKey('signup-policy-acceptance')),
      );
      expect(checkbox.value, isFalse);
      expect(
        find.textContaining('does not grant permission for optional marketing'),
        findsNothing,
      );
      expect(find.text('Privacy Notice'), findsOneWidget);
      expect(find.text('Acceptable Use Policy'), findsOneWidget);
    },
  );

  testWidgets('signup stays disabled until required policies are accepted', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _CountingSignupRepository();
    final container = ProviderContainer(
      overrides: <Override>[
        authRepositoryProvider.overrideWithValue(repository),
        authControllerProvider.overrideWith(
          (ref) => _UnauthenticatedAuthController(repository),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildRoutedApp(container));
    await tester.pumpAndSettle();
    container.read(routerProvider).go(AppRoutes.signup);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'Policy User');
    await tester.enterText(find.byType(TextFormField).at(1), '03123456');
    await tester.enterText(
      find.byType(TextFormField).at(2),
      'policy@example.com',
    );
    await tester.enterText(find.byType(TextFormField).at(3), 'Passw0rd!123');
    await tester.enterText(find.byType(TextFormField).at(4), 'Passw0rd!123');

    final submitButton = find.widgetWithText(
      FilledButton,
      'Request contributor access',
    );
    await tester.ensureVisible(submitButton);
    expect(tester.widget<FilledButton>(submitButton).onPressed, isNull);
    await _acceptSignupPolicies(tester);
    await tester.ensureVisible(submitButton);

    expect(repository.signupCalls, 0);
    expect(tester.widget<FilledButton>(submitButton).onPressed, isNotNull);
    expect(find.text('Agreement required'), findsNothing);
  });

  testWidgets('logout clears session and routes back to login', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repository = const _TestAuthRepository();
    final realtimeService = _TestRealtimeService();
    final container = ProviderContainer(
      overrides: <Override>[
        authRepositoryProvider.overrideWithValue(repository),
        authControllerProvider.overrideWith(
          (ref) => _AuthenticatedAuthController(
            repository: repository,
            session: _sessionForRole(UserRole.viewer),
          ),
        ),
        workflowRealtimeServiceProvider.overrideWithValue(realtimeService),
        networkOnlineProvider.overrideWith((ref) => Stream.value(true)),
        ..._routedShellOverrides(),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildRoutedAppWithRealtime(container));
    await _pumpRoutedShell(tester);

    final router = container.read(routerProvider);
    router.go(AppRoutes.profile);
    await _pumpRoutedShell(tester);

    expect(find.text('Profile'), findsWidgets);
    expect(find.text('Request account deletion'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.logout).first);
    await _pumpRoutedShell(tester);
    expect(find.text('Do you want to logout?'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Logout'),
      ),
    );
    await _pumpRoutedShell(tester);

    expect(find.text('Sign in'), findsOneWidget);
    expect(
      container.read(authControllerProvider).status,
      AuthStatus.unauthenticated,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('viewer can submit an account deletion request from Profile', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const authRepository = _TestAuthRepository();
    final legalRepository = _TestLegalRepository();
    final container = ProviderContainer(
      overrides: <Override>[
        authRepositoryProvider.overrideWithValue(authRepository),
        authControllerProvider.overrideWith(
          (ref) => _AuthenticatedAuthController(
            repository: authRepository,
            session: _sessionForRole(UserRole.viewer),
          ),
        ),
        legalRepositoryProvider.overrideWithValue(legalRepository),
        ..._routedShellOverrides(),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildRoutedApp(container));
    await _pumpRoutedShell(tester);
    container.read(routerProvider).go(AppRoutes.profile);
    await _pumpRoutedShell(tester);

    final deletionButton = find.widgetWithText(
      OutlinedButton,
      'Request account deletion',
    );
    await tester.ensureVisible(deletionButton);
    await tester.tap(deletionButton);
    await tester.pumpAndSettle();

    expect(find.text('Request account deletion'), findsWidgets);
    expect(find.textContaining('No current project-assignment'), findsNothing);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Current password'),
      'Passw0rd!123',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();

    expect(legalRepository.deletionRequests, 1);
    expect(legalRepository.submittedPassword, 'Passw0rd!123');
  });

  testWidgets('self deactivation routes back to login with a success notice', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repository = const _TestAuthRepository();
    final container = ProviderContainer(
      overrides: <Override>[
        authRepositoryProvider.overrideWithValue(repository),
        authControllerProvider.overrideWith(
          (ref) => _AuthenticatedAuthController(
            repository: repository,
            session: _sessionForRole(UserRole.viewer),
          ),
        ),
        ..._routedShellOverrides(),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildRoutedApp(container));
    await _pumpRoutedShell(tester);

    final router = container.read(routerProvider);
    router.go(AppRoutes.profile);
    await _pumpRoutedShell(tester);

    await container.read(authControllerProvider.notifier).selfDeactivate();
    await _pumpRoutedShell(tester);

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(
      find.text('Your account was deactivated successfully.'),
      findsWidgets,
    );
    expect(
      container.read(authControllerProvider).errorCode,
      'self_deactivated',
    );
  });

  testWidgets('pending contributor login shows blocked-state message', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          authRepositoryProvider.overrideWithValue(
            const _TestAuthRepository(
              loginFailure: AuthFailure(
                'Your request is still pending approval. You cannot log in yet.',
                statusCode: 403,
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final emailField = find.byType(TextFormField).at(0);
    final passwordField = find.byType(TextFormField).at(1);

    await tester.enterText(emailField, 'contributor@example.com');
    await tester.enterText(passwordField, 'Passw0rd!123');

    final loginButton = find.widgetWithText(FilledButton, 'Login');
    await tester.ensureVisible(loginButton);
    tester.widget<FilledButton>(loginButton).onPressed!.call();
    await tester.pumpAndSettle();

    expect(find.text('Sign in'), findsOneWidget);
    expect(
      find.text(
        'Your request is still pending approval. You cannot log in yet.',
      ),
      findsWidgets,
    );
    expect(
      tester.widget<TextFormField>(emailField).controller?.text,
      'contributor@example.com',
    );
    expect(
      ProviderScope.containerOf(
        tester.element(find.byType(LoginScreen)),
      ).read(authControllerProvider).status,
      AuthStatus.unauthenticated,
    );
  });

  testWidgets('viewer is redirected away from contributor-only routes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repository = const _TestAuthRepository();
    final container = ProviderContainer(
      overrides: <Override>[
        authRepositoryProvider.overrideWithValue(repository),
        authControllerProvider.overrideWith(
          (ref) => _AuthenticatedAuthController(
            repository: repository,
            session: _sessionForRole(UserRole.viewer),
          ),
        ),
        ..._routedShellOverrides(),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildRoutedApp(container));
    await _pumpRoutedShell(tester);

    final router = container.read(routerProvider);
    router.go(AppRoutes.reviewQueue);
    await _pumpRoutedShell(tester);

    expect(find.text('Projects'), findsWidgets);
    expect(find.text('Reviews'), findsNothing);
  });

  testWidgets('rejected contributor login stays blocked on login screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          authRepositoryProvider.overrideWithValue(
            const _TestAuthRepository(
              loginFailure: AuthFailure(
                'Your contributor request was rejected. You cannot log in with contributor access.',
                statusCode: 403,
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextFormField).at(0),
      'rejected@example.com',
    );
    await tester.enterText(find.byType(TextFormField).at(1), 'Passw0rd!123');

    final loginButton = find.widgetWithText(FilledButton, 'Login');
    tester.widget<FilledButton>(loginButton).onPressed!.call();
    await tester.pumpAndSettle();

    expect(find.text('Sign in'), findsOneWidget);
    expect(
      find.text(
        'Your contributor request was rejected. You cannot log in with contributor access.',
      ),
      findsWidgets,
    );
    expect(
      ProviderScope.containerOf(
        tester.element(find.byType(LoginScreen)),
      ).read(authControllerProvider).isAuthenticated,
      isFalse,
    );
  });

  testWidgets('super admin sees full management shell', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repository = const _TestAuthRepository();
    final container = ProviderContainer(
      overrides: <Override>[
        authRepositoryProvider.overrideWithValue(repository),
        authControllerProvider.overrideWith(
          (ref) => _AuthenticatedAuthController(
            repository: repository,
            session: _sessionForRole(
              UserRole.admin,
              isProtectedSuperAdmin: true,
            ),
          ),
        ),
        ..._routedShellOverrides(),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildRoutedApp(container));
    await _pumpRoutedShell(tester);

    expect(find.text('Admin Panel'), findsWidgets);
    expect(find.text('Users'), findsWidgets);
    expect(find.text('Create Admin'), findsWidgets);
    expect(find.text('Requests'), findsWidgets);
  });

  testWidgets('viewer signup continues to contact ownership verification', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repository = const _TestAuthRepository(
      signupMessage: 'Account created successfully. You can log in now.',
    );
    final container = ProviderContainer(
      overrides: <Override>[
        authRepositoryProvider.overrideWithValue(repository),
        authControllerProvider.overrideWith(
          (ref) => _UnauthenticatedAuthController(repository),
        ),
        contactVerificationRepositoryProvider.overrideWithValue(
          _TestContactVerificationRepository(),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildRoutedApp(container));
    await tester.pumpAndSettle();

    final router = container.read(routerProvider);
    router.go(AppRoutes.signup);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'Viewer User');
    await tester.enterText(find.byType(TextFormField).at(1), '03123456');
    await tester.enterText(
      find.byType(TextFormField).at(2),
      'viewer@example.com',
    );
    await tester.enterText(find.byType(TextFormField).at(3), 'Passw0rd!123');
    await tester.enterText(find.byType(TextFormField).at(4), 'Passw0rd!123');
    await _acceptSignupPolicies(tester);

    final segmented = find.byType(SegmentedButton<UserRole>);
    final viewerSegment = find.descendant(
      of: segmented,
      matching: find.text('Viewer'),
    );
    await tester.ensureVisible(viewerSegment);
    await tester.tap(viewerSegment, warnIfMissed: false);
    await tester.pumpAndSettle();

    final submitButton = find.widgetWithText(
      FilledButton,
      'Create viewer account',
    );
    await tester.ensureVisible(submitButton);
    tester.widget<FilledButton>(submitButton).onPressed!.call();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Verify your email'), findsOneWidget);
    expect(find.byType(ContactVerificationScreen), findsOneWidget);
  });

  testWidgets(
    'provider-free phone-format fallback completes without showing a phone form',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final authRepository = const _TestAuthRepository();
      final formatState = ContactVerificationState(
        accountStatus: 'pending_verification',
        emailVerified: true,
        phoneVerified: false,
        phoneFormatValidated: false,
        phoneAssuranceMode: 'format_only',
        phoneAssuranceLevel: 'unvalidated',
        phoneOwnershipRequired: false,
        nextStep: ContactVerificationStep.phoneFormat,
        maskedEmail: 'v***@example.com',
        maskedPhone: '+961 70 *** ***',
      );
      final contactRepository = _TestContactVerificationRepository(
        state: formatState,
      );
      final container = ProviderContainer(
        overrides: <Override>[
          authRepositoryProvider.overrideWithValue(authRepository),
          authControllerProvider.overrideWith(
            (ref) => _UnauthenticatedAuthController(authRepository),
          ),
          contactVerificationRepositoryProvider.overrideWithValue(
            contactRepository,
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_buildRoutedApp(container));
      await tester.pumpAndSettle();
      container.read(routerProvider).go(AppRoutes.verifyContact);
      await tester.pumpAndSettle();

      expect(contactRepository.formatValidationCalls, 1);
      expect(find.text('Validate your mobile number'), findsNothing);
      expect(find.text('Validate number'), findsNothing);
      expect(find.text('6-digit code'), findsNothing);
      expect(find.text('Resend code'), findsNothing);
      expect(find.text('Sign in'), findsOneWidget);
    },
  );

  testWidgets('contributor signup verifies contacts before approval can begin', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repository = const _TestAuthRepository(
      signupMessage:
          'Account created successfully. Your contributor request is pending admin approval.',
    );
    final container = ProviderContainer(
      overrides: <Override>[
        authRepositoryProvider.overrideWithValue(repository),
        authControllerProvider.overrideWith(
          (ref) => _UnauthenticatedAuthController(repository),
        ),
        contactVerificationRepositoryProvider.overrideWithValue(
          _TestContactVerificationRepository(),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildRoutedApp(container));
    await tester.pumpAndSettle();

    final router = container.read(routerProvider);
    router.go(AppRoutes.signup);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextFormField).at(0),
      'Contributor User',
    );
    await tester.enterText(find.byType(TextFormField).at(1), '03123456');
    await tester.enterText(
      find.byType(TextFormField).at(2),
      'contributor@example.com',
    );
    await tester.enterText(find.byType(TextFormField).at(3), 'Passw0rd!123');
    await tester.enterText(find.byType(TextFormField).at(4), 'Passw0rd!123');
    await _acceptSignupPolicies(tester);

    final submitButton = find.widgetWithText(
      FilledButton,
      'Request contributor access',
    );
    await tester.ensureVisible(submitButton);
    tester.widget<FilledButton>(submitButton).onPressed!.call();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Verify your email'), findsOneWidget);
    expect(find.byType(ContactVerificationScreen), findsOneWidget);
  });

  testWidgets(
    'duplicate email signup stays on signup and highlights the email field',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final repository = const _TestAuthRepository(
        signupFailure: AuthFailure(
          'This email is already registered.',
          statusCode: 409,
        ),
      );
      final container = ProviderContainer(
        overrides: <Override>[
          authRepositoryProvider.overrideWithValue(repository),
          authControllerProvider.overrideWith(
            (ref) => _UnauthenticatedAuthController(repository),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_buildRoutedApp(container));
      await tester.pumpAndSettle();

      final router = container.read(routerProvider);
      router.go(AppRoutes.signup);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextFormField).at(0),
        'Duplicate User',
      );
      await tester.enterText(find.byType(TextFormField).at(1), '03123456');
      await tester.enterText(
        find.byType(TextFormField).at(2),
        'duplicate@example.com',
      );
      await tester.enterText(find.byType(TextFormField).at(3), 'Passw0rd!123');
      await tester.enterText(find.byType(TextFormField).at(4), 'Passw0rd!123');
      await _acceptSignupPolicies(tester);

      final submitButton = find.widgetWithText(
        FilledButton,
        'Request contributor access',
      );
      await tester.ensureVisible(submitButton);
      tester.widget<FilledButton>(submitButton).onPressed!.call();
      await tester.pumpAndSettle();

      expect(find.text('Requested role'), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
      expect(find.text('This email is already registered.'), findsWidgets);
      expect(find.text('duplicate@example.com'), findsOneWidget);
    },
  );

  testWidgets(
    'phone account cap stays on signup and highlights the phone field',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      const limitMessage =
          'This mobile number is already used by the maximum of 3 accounts. Use another Lebanese mobile number.';
      final repository = const _TestAuthRepository(
        signupFailure: AuthFailure(
          limitMessage,
          statusCode: 409,
          code: 'phone_account_limit',
        ),
      );
      final container = ProviderContainer(
        overrides: <Override>[
          authRepositoryProvider.overrideWithValue(repository),
          authControllerProvider.overrideWith(
            (ref) => _UnauthenticatedAuthController(repository),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_buildRoutedApp(container));
      await tester.pumpAndSettle();

      container.read(routerProvider).go(AppRoutes.signup);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).at(0), 'Fourth User');
      await tester.enterText(find.byType(TextFormField).at(1), '70123456');
      await tester.enterText(
        find.byType(TextFormField).at(2),
        'fourth@example.com',
      );
      await tester.enterText(find.byType(TextFormField).at(3), 'Passw0rd!123');
      await tester.enterText(find.byType(TextFormField).at(4), 'Passw0rd!123');
      await _acceptSignupPolicies(tester);

      final submitButton = find.widgetWithText(
        FilledButton,
        'Request contributor access',
      );
      await tester.ensureVisible(submitButton);
      tester.widget<FilledButton>(submitButton).onPressed!.call();
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsNothing);
      expect(find.text(limitMessage), findsWidgets);
      expect(find.text('70 123 456'), findsWidgets);
    },
  );
}
