import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/pagination/paginated_result.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';
import 'package:lebanese_gis_mobile/features/legal/domain/legal_models.dart';
import 'package:lebanese_gis_mobile/features/legal/domain/legal_repository.dart';
import 'package:lebanese_gis_mobile/features/legal/presentation/legal_providers.dart';
import 'package:lebanese_gis_mobile/features/legal/presentation/screens/privacy_moderation_admin_screen.dart';

class _NoopAuthRepository extends AuthRepository {
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
  }) => throw UnimplementedError();
  @override
  Future<void> logout() async {}
  @override
  Future<AuthSession> reactivateContributorAndLogin({
    required String email,
    required String password,
    required bool rememberMe,
  }) => throw UnimplementedError();
  @override
  Future<PasswordResetRequestResult> requestPasswordReset(String email) =>
      throw UnimplementedError();
  @override
  Future<void> resetPassword({
    required String resetToken,
    required String newPassword,
  }) async {}
  @override
  Future<AuthSession?> restoreSession() async => null;
  @override
  Future<void> selfDeactivate() async {}
  @override
  Future<String> signup({
    required String fullName,
    required String email,
    required String password,
    required UserRole role,
    String? phone,
  }) => throw UnimplementedError();
  @override
  Future<AppUser> updateProfile({String? fullName, String? phone}) =>
      throw UnimplementedError();
  @override
  Future<PasswordResetOtpVerificationResult> verifyPasswordResetOtp({
    required String email,
    required String otp,
  }) => throw UnimplementedError();
}

class _StaticAuthController extends AuthController {
  _StaticAuthController(AppUser user) : super(_NoopAuthRepository()) {
    state = AuthState.authenticated(
      AuthSession(accessToken: 'token', refreshToken: 'refresh', user: user),
    );
  }
}

class _AdminLegalRepository extends LegalRepository {
  _AdminLegalRepository({
    this.privacyStatus = 'submitted',
    this.reportStatus = 'submitted',
  });

  final now = DateTime.utc(2026, 8, 16, 10);
  final String privacyStatus;
  final String reportStatus;

  PrivacyAdminRequest get privacyRequest => PrivacyAdminRequest(
    id: 'request-1',
    type: PrivacyRequestType.accessExport,
    status: privacyStatus,
    requesterLabel: 'Test User',
    requesterContact: 'test.user@example.com',
    requesterRole: 'viewer',
    requestedAt: now,
    internalTargetAt: now.add(const Duration(days: 10)),
    overdue: false,
    requestDetails: const <String, dynamic>{
      'reason': 'I need a copy for my records.',
    },
  );

  ContentReportRecord get contentReport => ContentReportRecord(
    id: 'report-1',
    projectId: 'project-1',
    projectTitle: 'Moderation workflow project',
    entityType: 'project',
    entityId: 'project-1',
    reasonCode: 'privacy',
    status: reportStatus,
    createdAt: now,
    internalTargetAt: now.add(const Duration(days: 10)),
    overdue: false,
    reporterLabel: 'Reporter',
    reporterContact: 'reporter@example.com',
    description: 'Please check the project privacy settings.',
    entityAvailable: true,
  );

  @override
  Future<PaginatedResult<PrivacyAdminRequest>> fetchPrivacyAdminRequests({
    required int page,
    required int limit,
    String? status,
    String? requestType,
    String? query,
  }) async => PaginatedResult(
    items: <PrivacyAdminRequest>[privacyRequest],
    page: page,
    limit: limit,
    total: 1,
    hasMore: false,
  );

  @override
  Future<PaginatedResult<ContentReportRecord>> fetchContentReportsForAdmin({
    required int page,
    required int limit,
    String? status,
    String? entityType,
    String? query,
  }) async => PaginatedResult(
    items: <ContentReportRecord>[contentReport],
    page: page,
    limit: limit,
    total: 1,
    hasMore: false,
  );

  @override
  Future<PrivacyQueueCounts> fetchPrivacyQueueCounts() async =>
      const PrivacyQueueCounts(
        openPrivacyRequests: 1,
        overduePrivacyRequests: 0,
        openContentReports: 1,
        overdueContentReports: 0,
      );

  @override
  Future<PrivacyAdminRequestDetail> fetchPrivacyAdminRequest(
    String requestId,
  ) async => PrivacyAdminRequestDetail(
    request: privacyRequest,
    history: <WorkflowHistoryRecord>[
      WorkflowHistoryRecord(
        toStatus: privacyStatus,
        occurredAt: now,
        actorKind: 'requester',
      ),
    ],
  );

  @override
  Future<ContentReportDetail> fetchContentReportForAdmin(
    String reportId,
  ) async => ContentReportDetail(
    report: contentReport,
    history: <WorkflowHistoryRecord>[
      WorkflowHistoryRecord(
        toStatus: reportStatus,
        occurredAt: now,
        actorKind: 'reporter',
      ),
    ],
  );

  @override
  Future<ContentReportRecord> updateContentReportForAdmin({
    required String reportId,
    required String status,
    String? outcomeCode,
    String? userMessage,
  }) async => contentReport;

  @override
  Future<void> acceptCurrentDocuments(List<LegalDocument> documents) async {}
  @override
  Future<PrivacyRequestRecord> cancelPrivacyRequest(String requestId) =>
      throw UnimplementedError();
  @override
  Future<PrivacyRequestRecord> createPrivacyRequest({
    required PrivacyRequestType type,
    String? currentPassword,
    Map<String, dynamic>? details,
  }) => throw UnimplementedError();
  @override
  Future<LegalAcceptanceStatus> fetchAcceptanceStatus() =>
      throw UnimplementedError();
  @override
  Future<AccountDeletionEligibility> fetchAccountDeletionEligibility() =>
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

Widget _app(
  AppUser user, {
  double textScale = 1,
  LegalRepository? repository,
}) => ProviderScope(
  overrides: <Override>[
    authControllerProvider.overrideWith((ref) => _StaticAuthController(user)),
    legalRepositoryProvider.overrideWithValue(
      repository ?? _AdminLegalRepository(),
    ),
  ],
  child: MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: const Scaffold(body: PrivacyModerationAdminScreen()),
  ),
);

void main() {
  testWidgets('ordinary administrators cannot open the protected workspace', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const AppUser(
          id: 'admin-1',
          fullName: 'Admin',
          email: 'admin@example.com',
          role: UserRole.admin,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Protected workspace'), findsOneWidget);
    expect(find.text('Filter'), findsNothing);
  });

  for (final size in <Size>[const Size(320, 720), const Size(900, 900)]) {
    testWidgets('protected queue is responsive at ${size.width}px', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(
          const AppUser(
            id: 'protected-admin',
            fullName: 'Protected Admin',
            email: 'protected@example.com',
            role: UserRole.admin,
            isProtectedSuperAdmin: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Filter'), findsOneWidget);
      expect(find.text('Data access/export'), findsOneWidget);
      expect(find.text('test.user@example.com'), findsOneWidget);
      expect(find.text('OPEN'), findsOneWidget);
      expect(find.text('Review'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Filter'));
      await tester.pumpAndSettle();
      expect(find.text('Privacy (1)'), findsOneWidget);
      expect(find.text('Reports (1)'), findsOneWidget);
      await tester.tap(find.text('Reports (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Hide'), findsOneWidget);
      expect(
        find.text('Moderation workflow project · Reporter'),
        findsOneWidget,
      );
      expect(find.text('reporter@example.com'), findsOneWidget);
      expect(find.text('OPEN'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('protected queue supports large accessibility text on a phone', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        const AppUser(
          id: 'protected-admin',
          fullName: 'Protected Admin',
          email: 'protected@example.com',
          role: UserRole.admin,
          isProtectedSuperAdmin: true,
        ),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Data access/export'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('privacy review and update dialogs stay concise', (tester) async {
    await tester.pumpWidget(
      _app(
        const AppUser(
          id: 'protected-admin',
          fullName: 'Protected Admin',
          email: 'protected@example.com',
          role: UserRole.admin,
          isProtectedSuperAdmin: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    expect(find.text('History'), findsNothing);
    expect(find.text('Update'), findsOneWidget);

    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Message to requester'), findsOneWidget);
    expect(find.text('We are reviewing your request.'), findsOneWidget);
    expect(find.textContaining('Resolution summary'), findsNothing);
    expect(find.textContaining('Internal note'), findsNothing);
    expect(find.textContaining('Transfer'), findsNothing);
  });

  testWidgets(
    'report review uses the project title and a brief decision form',
    (tester) async {
      await tester.pumpWidget(
        _app(
          const AppUser(
            id: 'protected-admin',
            fullName: 'Protected Admin',
            email: 'protected@example.com',
            role: UserRole.admin,
            isProtectedSuperAdmin: true,
          ),
          repository: _AdminLegalRepository(reportStatus: 'in_review'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Filter'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reports (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();

      expect(find.text('Report review'), findsOneWidget);
      expect(find.text('Moderation workflow project'), findsWidgets);
      expect(find.text('project-1'), findsNothing);
      expect(find.text('Open project'), findsOneWidget);
      expect(
        tester
            .getSize(find.widgetWithText(OutlinedButton, 'Open project'))
            .width,
        greaterThan(200),
      );

      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();
      expect(find.text('Report decision'), findsOneWidget);
      expect(find.text('Decision'), findsOneWidget);
      expect(find.text('Action completed'), findsOneWidget);
      expect(find.text('Message to reporter'), findsOneWidget);
      expect(find.textContaining('Workflow reference'), findsNothing);
      expect(find.textContaining('Internal note'), findsNothing);
    },
  );

  for (final status in const ['completed', 'rejected']) {
    testWidgets('$status privacy requests do not show an update action', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const AppUser(
            id: 'protected-admin',
            fullName: 'Protected Admin',
            email: 'protected@example.com',
            role: UserRole.admin,
            isProtectedSuperAdmin: true,
          ),
          repository: _AdminLegalRepository(privacyStatus: status),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('CLOSED'), findsOneWidget);
      await tester.tap(find.text('View decision'));
      await tester.pumpAndSettle();
      expect(find.text('Update'), findsNothing);
      expect(find.text('Close'), findsOneWidget);
    });
  }

  testWidgets('automated open requests are marked as in progress', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const AppUser(
          id: 'protected-admin',
          fullName: 'Protected Admin',
          email: 'protected@example.com',
          role: UserRole.admin,
          isProtectedSuperAdmin: true,
        ),
        repository: _AdminLegalRepository(privacyStatus: 'processing'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('IN PROGRESS'), findsOneWidget);
    expect(find.text('View progress'), findsOneWidget);
    expect(find.text('Review'), findsNothing);
  });
}
