import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';
import 'package:lebanese_gis_mobile/features/legal/domain/legal_models.dart';
import 'package:lebanese_gis_mobile/features/legal/domain/legal_repository.dart';
import 'package:lebanese_gis_mobile/features/legal/presentation/legal_providers.dart';
import 'package:lebanese_gis_mobile/features/legal/presentation/screens/privacy_center_screen.dart';

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

class _PrivacyRepository extends LegalRepository {
  _PrivacyRepository(
    Iterable<PrivacyRequestRecord> requests, {
    Iterable<ContentReportRecord> reports = const [],
    this.downloadPath = '',
  }) : requests = List<PrivacyRequestRecord>.of(requests),
       reports = List<ContentReportRecord>.of(reports);

  final List<PrivacyRequestRecord> requests;
  final List<ContentReportRecord> reports;
  final String downloadPath;
  String? savedDownloadPath;
  int createCalls = 0;
  int cancelCalls = 0;
  int downloadCalls = 0;
  String? lastCancelledId;

  @override
  Future<List<PrivacyRequestRecord>> fetchMyPrivacyRequests() async => requests;

  @override
  Future<String> downloadPersonalDataExport({
    required String requestId,
    required String currentPassword,
  }) async {
    downloadCalls += 1;
    savedDownloadPath = downloadPath;
    return downloadPath;
  }

  @override
  Future<String?> fetchPersonalDataExportLocalPath(String requestId) async =>
      savedDownloadPath;

  @override
  Future<List<ContentReportRecord>> fetchMyContentReports() async => reports;

  @override
  Future<PrivacyRequestRecord> createPrivacyRequest({
    required PrivacyRequestType type,
    String? currentPassword,
    Map<String, dynamic>? details,
  }) async {
    createCalls += 1;
    return PrivacyRequestRecord(
      id: 'new-request',
      type: type,
      status: 'submitted',
      requestedAt: DateTime.utc(2026, 8, 19),
      internalTargetAt: DateTime.utc(2026, 9, 18),
    );
  }

  @override
  Future<void> acceptCurrentDocuments(List<LegalDocument> documents) async {}

  @override
  Future<PrivacyRequestRecord> cancelPrivacyRequest(String requestId) async {
    cancelCalls += 1;
    lastCancelledId = requestId;
    final request = requests.firstWhere((item) => item.id == requestId);
    requests.removeWhere((item) => item.id == requestId);
    return PrivacyRequestRecord(
      id: request.id,
      type: request.type,
      status: 'cancelled',
      requestedAt: request.requestedAt,
      internalTargetAt: request.internalTargetAt,
      cancelledAt: DateTime.utc(2026, 8, 20),
    );
  }

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
      const [];

  @override
  Future<void> reportContent({
    required String projectId,
    required String entityType,
    required String entityId,
    required String reasonCode,
    String? description,
  }) async {}
}

Widget _app({
  required UserRole role,
  required _PrivacyRepository repository,
  bool isProtectedSuperAdmin = false,
  Size? mediaSize,
}) => ProviderScope(
  overrides: [
    authControllerProvider.overrideWith(
      (ref) => _StaticAuthController(
        AppUser(
          id: 'user-1',
          fullName: 'Test User',
          email: 'test@example.com',
          role: role,
          isProtectedSuperAdmin: isProtectedSuperAdmin,
        ),
      ),
    ),
    legalRepositoryProvider.overrideWithValue(repository),
  ],
  child: MaterialApp(
    builder: mediaSize == null
        ? null
        : (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: mediaSize),
            child: child!,
          ),
    home: const PrivacyCenterScreen(),
  ),
);

void main() {
  testWidgets('protected super administrator sees only legal information', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        role: UserRole.admin,
        repository: _PrivacyRepository(const []),
        isProtectedSuperAdmin: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Legal information'), findsOneWidget);
    expect(find.text('Your data'), findsNothing);
    expect(find.text('Your requests'), findsNothing);
    expect(find.text('Your content reports'), findsNothing);
  });

  testWidgets('viewer can request and download personal data', (tester) async {
    await tester.pumpWidget(
      _app(role: UserRole.viewer, repository: _PrivacyRepository(const [])),
    );
    await tester.pumpAndSettle();

    expect(find.text('Get my data'), findsOneWidget);
    expect(find.text('Your data exports'), findsOneWidget);
    expect(find.text('Correct my data'), findsOneWidget);
  });

  testWidgets('empty privacy sections fill the available card width', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(450, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(role: UserRole.viewer, repository: _PrivacyRepository(const [])),
    );
    await tester.pumpAndSettle();

    final messages = <String>[
      'No data exports requested.',
      'No privacy requests submitted.',
      'No content reports submitted.',
    ];
    final widths = messages
        .map(
          (message) => tester
              .getSize(
                find
                    .ancestor(
                      of: find.text(message),
                      matching: find.byType(Card),
                    )
                    .first,
              )
              .width,
        )
        .toList(growable: false);
    expect(widths.every((width) => width > 300), isTrue);
    expect(widths.toSet().length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling the data request dialog is lifecycle safe', (
    tester,
  ) async {
    final repository = _PrivacyRepository(const []);
    await tester.pumpWidget(
      _app(
        role: UserRole.contributor,
        repository: repository,
        mediaSize: const Size(411, 900),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Get my data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(repository.createCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an active correction toggles only its action to cancel', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(411, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final active = PrivacyRequestRecord(
      id: 'active-request',
      type: PrivacyRequestType.correction,
      status: 'submitted',
      requestedAt: DateTime.utc(2026, 8, 19),
      internalTargetAt: DateTime.utc(2026, 9, 18),
    );
    final repository = _PrivacyRepository([active]);
    await tester.pumpWidget(
      _app(
        role: UserRole.contributor,
        repository: repository,
        mediaSize: const Size(411, 900),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('already submitted'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Get my data'),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Cancel correction request'),
          )
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.text('Cancel correction request'));
    await tester.pumpAndSettle();
    expect(find.text('Keep'), findsOneWidget);
    final keepButton = tester.getRect(find.widgetWithText(TextButton, 'Keep'));
    final cancelButtonFinder = find.widgetWithText(FilledButton, 'Cancel');
    final cancelButton = tester.getRect(cancelButtonFinder);
    final cancelLabel = tester.getRect(
      find.descendant(of: cancelButtonFinder, matching: find.text('Cancel')),
    );
    expect(cancelButton.top, closeTo(keepButton.top, 0.1));
    expect(cancelButton.width, closeTo(keepButton.width, 0.1));
    expect(cancelButton.left, greaterThan(keepButton.right));
    expect(cancelLabel.height, lessThan(24));
    expect(cancelLabel.center.dx, closeTo(cancelButton.center.dx, 0.1));
    expect(cancelLabel.center.dy, closeTo(cancelButton.center.dy, 0.1));
    await tester.tap(find.widgetWithText(FilledButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(repository.cancelCalls, 1);
    expect(repository.lastCancelledId, active.id);
    expect(find.text('Correct my data'), findsOneWidget);
  });

  testWidgets('an undecided export toggles only its action to cancel', (
    tester,
  ) async {
    final active = PrivacyRequestRecord(
      id: 'active-export',
      type: PrivacyRequestType.accessExport,
      status: 'in_review',
      requestedAt: DateTime.utc(2026, 8, 19),
      internalTargetAt: DateTime.utc(2026, 9, 18),
    );
    await tester.pumpWidget(
      _app(
        role: UserRole.contributor,
        repository: _PrivacyRepository([active]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('already in review'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Cancel data request'),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Correct my data'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('an active deletion does not block export or correction', (
    tester,
  ) async {
    final active = PrivacyRequestRecord(
      id: 'active-deletion',
      type: PrivacyRequestType.deletion,
      status: 'submitted',
      requestedAt: DateTime.utc(2026, 8, 19),
      internalTargetAt: DateTime.utc(2026, 9, 18),
    );
    await tester.pumpWidget(
      _app(
        role: UserRole.contributor,
        repository: _PrivacyRepository([active]),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Get my data'),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Correct my data'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('a decided request restores its normal request action', (
    tester,
  ) async {
    final decided = PrivacyRequestRecord(
      id: 'rejected-correction',
      type: PrivacyRequestType.correction,
      status: 'rejected',
      requestedAt: DateTime.utc(2026, 8, 19),
      internalTargetAt: DateTime.utc(2026, 9, 18),
    );
    await tester.pumpWidget(
      _app(
        role: UserRole.contributor,
        repository: _PrivacyRepository([decided]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cancel correction request'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Correct my data'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('data request does not depend on collected contributions', (
    tester,
  ) async {
    final repository = _PrivacyRepository(const []);
    await tester.pumpWidget(
      _app(role: UserRole.contributor, repository: repository),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Get my data'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'current-password');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(repository.createCalls, 1);
    expect(find.textContaining('collected contributions'), findsNothing);
  });

  testWidgets('ready personal export offers download and file actions', (
    tester,
  ) async {
    final ready = PrivacyRequestRecord(
      id: 'ready-export',
      type: PrivacyRequestType.accessExport,
      status: 'completed',
      requestedAt: DateTime.utc(2026, 8, 19),
      internalTargetAt: DateTime.utc(2026, 9, 18),
      exportStatus: 'ready',
      exportExpiresAt: DateTime.now().add(const Duration(days: 2)),
    );
    final repository = _PrivacyRepository([
      ready,
    ], downloadPath: '/tmp/terraleb-personal-data-ready-export.html');
    await tester.pumpWidget(
      _app(role: UserRole.contributor, repository: repository),
    );
    await tester.pumpAndSettle();

    expect(find.text('Your data exports'), findsOneWidget);
    expect(find.text('Personal data export'), findsOneWidget);
    expect(find.text('Download report'), findsOneWidget);
    expect(find.text('Get my data'), findsOneWidget);

    await tester.ensureVisible(find.text('Download report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download report'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'current-password');
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();

    expect(repository.downloadCalls, 1);
    expect(find.text('Download again'), findsOneWidget);
    expect(find.text('Show in folder'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
  });

  testWidgets('privacy center paginates each history independently at ten', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(450, 8000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final exports = List.generate(
      11,
      (index) => PrivacyRequestRecord(
        id: 'export-$index',
        type: PrivacyRequestType.accessExport,
        status: 'completed',
        requestedAt: DateTime.utc(2026, 8, index + 1),
        internalTargetAt: DateTime.utc(2026, 9, index + 1),
        userMessage: 'Export record $index',
      ),
    );
    final requests = List.generate(
      11,
      (index) => PrivacyRequestRecord(
        id: 'request-$index',
        type: PrivacyRequestType.correction,
        status: 'completed',
        requestedAt: DateTime.utc(2026, 7, index + 1),
        internalTargetAt: DateTime.utc(2026, 8, index + 1),
        userMessage: 'Request record $index',
      ),
    );
    final reports = List.generate(
      11,
      (index) => ContentReportRecord(
        id: 'report-$index',
        projectId: 'project-$index',
        projectTitle: 'Project $index',
        entityType: 'project',
        entityId: 'project-$index',
        reasonCode: 'report_$index',
        status: 'resolved',
        createdAt: DateTime.utc(2026, 6, index + 1),
        internalTargetAt: DateTime.utc(2026, 7, index + 1),
        overdue: false,
      ),
    );

    await tester.pumpWidget(
      _app(
        role: UserRole.contributor,
        repository: _PrivacyRepository([
          ...exports,
          ...requests,
        ], reports: reports),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Page 1 of 2'), findsNWidgets(3));
    expect(find.text('Export record 0'), findsNothing);
    expect(find.text('Request record 0'), findsNothing);
    expect(find.text('report 0'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('data-exports-next-page')));
    await tester.pumpAndSettle();
    expect(find.text('Export record 0'), findsOneWidget);
    expect(find.text('Request record 0'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('privacy-requests-next-page')));
    await tester.pumpAndSettle();
    expect(find.text('Request record 0'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('content-reports-next-page')));
    await tester.pumpAndSettle();
    expect(find.text('report 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
