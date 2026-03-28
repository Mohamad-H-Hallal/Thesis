// ignore_for_file: use_super_parameters

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/core/offline/local_models.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/core/router/route_paths.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_controller.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_engine.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_failure.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/screens/login_screen.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/project.dart';

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
      message: 'Password reset code generated.',
      devResetToken: '123456',
    );
  }

  @override
  Future<void> resetPassword({
    required String token,
    required String newPassword,
  }) async {}

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
  Future<List<LocalDraftFeature>> getDrafts() async =>
      const <LocalDraftFeature>[];

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

SyncController _buildSyncController() {
  final localStore = _FakeLocalStore();
  return SyncController(
    syncEngine: SyncEngine(
      localStore: localStore,
      apiClient: ApiClient(dio: Dio()),
    ),
    localStore: localStore,
  );
}

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

void main() {
  testWidgets('logout clears session and routes back to login', (tester) async {
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
        syncControllerProvider.overrideWith((ref) => _buildSyncController()),
        projectsProvider.overrideWith((ref) async => const <ProjectSummary>[]),
        projectListProvider.overrideWith(
          (ref, scope) async => const <ProjectSummary>[],
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildRoutedApp(container));
    await tester.pumpAndSettle();

    final router = container.read(routerProvider);
    router.go(AppRoutes.profile);
    await tester.pumpAndSettle();

    expect(find.text('Profile'), findsWidgets);

    await tester.tap(find.byIcon(Icons.logout).first);
    await tester.pumpAndSettle();
    expect(find.text('Do you want to logout?'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Logout'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sign in'), findsOneWidget);
    expect(
      container.read(authControllerProvider).status,
      AuthStatus.unauthenticated,
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
        syncControllerProvider.overrideWith((ref) => _buildSyncController()),
        projectsProvider.overrideWith((ref) async => const <ProjectSummary>[]),
        projectListProvider.overrideWith(
          (ref, scope) async => const <ProjectSummary>[],
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildRoutedApp(container));
    await tester.pumpAndSettle();

    final router = container.read(routerProvider);
    router.go(AppRoutes.reviewQueue);
    await tester.pumpAndSettle();

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
        syncControllerProvider.overrideWith((ref) => _buildSyncController()),
        projectsProvider.overrideWith((ref) async => const <ProjectSummary>[]),
        projectListProvider.overrideWith(
          (ref, scope) async => const <ProjectSummary>[],
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildRoutedApp(container));
    await tester.pumpAndSettle();

    expect(find.text('Admin Panel'), findsWidgets);
    expect(find.text('Users'), findsWidgets);
    expect(find.text('Create Admin'), findsWidgets);
    expect(find.text('Requests'), findsWidgets);
  });

  testWidgets(
    'viewer signup shows immediate-access message and returns to login',
    (tester) async {
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
      await tester.pumpAndSettle();

      expect(find.text('Sign in'), findsOneWidget);
      expect(find.byType(LoginScreen), findsOneWidget);
    },
  );

  testWidgets(
    'contributor signup shows pending-approval message and returns to login',
    (tester) async {
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

      final submitButton = find.widgetWithText(
        FilledButton,
        'Request contributor access',
      );
      await tester.ensureVisible(submitButton);
      tester.widget<FilledButton>(submitButton).onPressed!.call();
      await tester.pumpAndSettle();

      expect(find.text('Sign in'), findsOneWidget);
      expect(find.byType(LoginScreen), findsOneWidget);
    },
  );

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
}
