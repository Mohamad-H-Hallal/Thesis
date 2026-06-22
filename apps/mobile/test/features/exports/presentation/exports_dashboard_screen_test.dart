import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/pagination/paginated_result.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';
import 'package:lebanese_gis_mobile/features/exports/data/mock_exports_repository.dart';
import 'package:lebanese_gis_mobile/features/exports/domain/export_job.dart';
import 'package:lebanese_gis_mobile/features/exports/domain/exports_repository.dart';
import 'package:lebanese_gis_mobile/features/exports/presentation/screens/exports_dashboard_screen.dart';
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
    return const PasswordResetRequestResult(message: 'sent');
  }

  @override
  Future<PasswordResetOtpVerificationResult> verifyPasswordResetOtp({
    required String email,
    required String otp,
  }) async => const PasswordResetOtpVerificationResult(
    message: 'verified',
    resetToken: 'token',
    email: 'admin@example.com',
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
      fullName: fullName ?? 'Admin',
      email: 'admin@example.com',
      role: UserRole.admin,
      phone: phone,
    );
  }
}

class _AuthenticatedAuthController extends AuthController {
  _AuthenticatedAuthController() : super(const _NoopAuthRepository()) {
    state = const AuthState.authenticated(
      AuthSession(
        accessToken: 'token',
        refreshToken: 'refresh',
        user: AppUser(
          id: 'admin-1',
          fullName: 'Admin',
          email: 'admin@example.com',
          role: UserRole.admin,
        ),
      ),
    );
  }
}

class _UnauthenticatedAuthController extends AuthController {
  _UnauthenticatedAuthController() : super(const _NoopAuthRepository()) {
    state = const AuthState.unauthenticated();
  }
}

class _CheckingAuthController extends AuthController {
  _CheckingAuthController() : super(const _NoopAuthRepository()) {
    state = const AuthState.checking();
  }
}

class _MutableAuthController extends AuthController {
  _MutableAuthController() : super(const _NoopAuthRepository()) {
    authenticateAsAdmin();
  }

  void authenticateAsAdmin() {
    state = const AuthState.authenticated(
      AuthSession(
        accessToken: 'token',
        refreshToken: 'refresh',
        user: AppUser(
          id: 'admin-1',
          fullName: 'Admin',
          email: 'admin@example.com',
          role: UserRole.admin,
        ),
      ),
    );
  }

  void authenticateAsContributor() {
    state = const AuthState.authenticated(
      AuthSession(
        accessToken: 'token-2',
        refreshToken: 'refresh-2',
        user: AppUser(
          id: 'contributor-1',
          fullName: 'Contributor',
          email: 'contributor@example.com',
          role: UserRole.contributor,
        ),
      ),
    );
  }

  void logoutNow() {
    state = const AuthState.unauthenticated();
  }
}

class _FailingExportsRepository implements ExportsRepository {
  const _FailingExportsRepository();

  @override
  Future<List<ExportJob>> fetchJobs({required String requestedByUserId}) async {
    return const <ExportJob>[];
  }

  @override
  Future<PaginatedResult<ExportJob>> fetchJobsPage({
    required String requestedByUserId,
    String? categoryId,
    String? projectId,
    ExportJobStatus? status,
    ExportFormat? format,
    int page = 1,
    int limit = 20,
  }) async {
    return const PaginatedResult<ExportJob>(
      items: <ExportJob>[],
      page: 1,
      limit: 20,
      total: 0,
      hasMore: false,
    );
  }

  @override
  Future<ExportDashboardMetrics> fetchSummary({
    required String requestedByUserId,
    String? categoryId,
    String? projectId,
    ExportJobStatus? status,
    ExportFormat? format,
  }) async {
    return const ExportDashboardMetrics(
      total: 0,
      pending: 0,
      processing: 0,
      completed: 0,
      failed: 0,
    );
  }

  @override
  Future<ExportJob> requestExport({
    required String requestedByUserId,
    required String projectId,
    required String projectName,
    required ExportFormat format,
    required Map<String, dynamic> exportParameters,
  }) {
    throw StateError('Export failed');
  }

  @override
  Future<List<ExportJob>> processQueueTick({
    required String requestedByUserId,
  }) async {
    return const <ExportJob>[];
  }

  @override
  Future<ExportJob?> markDownloaded({
    required String requestedByUserId,
    required String exportId,
  }) async {
    return null;
  }

  @override
  Future<ExportJob?> retryFailed({
    required String requestedByUserId,
    required String exportId,
  }) async {
    return null;
  }
}

class _StaticExportsRepository implements ExportsRepository {
  const _StaticExportsRepository(this.jobs);

  final List<ExportJob> jobs;

  @override
  Future<List<ExportJob>> fetchJobs({required String requestedByUserId}) async =>
      jobs;

  @override
  Future<PaginatedResult<ExportJob>> fetchJobsPage({
    required String requestedByUserId,
    String? categoryId,
    String? projectId,
    ExportJobStatus? status,
    ExportFormat? format,
    int page = 1,
    int limit = 20,
  }) async {
    final filtered = jobs
        .where((job) => job.requestedByUserId == requestedByUserId)
        .where((job) => projectId == null || job.projectId == projectId)
        .where((job) => format == null || job.format == format)
        .where((job) => status == null || job.status == status)
        .toList(growable: false)
      ..sort((a, b) => b.requestedAt.compareTo(a.requestedAt));
    final start = (page - 1) * limit;
    final end = (start + limit).clamp(0, filtered.length);
    return PaginatedResult<ExportJob>(
      items: start >= filtered.length
          ? const <ExportJob>[]
          : filtered.sublist(start, end),
      page: page,
      limit: limit,
      total: filtered.length,
      hasMore: end < filtered.length,
    );
  }

  @override
  Future<ExportDashboardMetrics> fetchSummary({
    required String requestedByUserId,
    String? categoryId,
    String? projectId,
    ExportJobStatus? status,
    ExportFormat? format,
  }) async {
    final page = await fetchJobsPage(
      requestedByUserId: requestedByUserId,
      categoryId: categoryId,
      projectId: projectId,
      status: status,
      format: format,
      page: 1,
      limit: 1000,
    );
    return ExportDashboardMetrics.fromJobs(page.items);
  }

  @override
  Future<ExportJob> requestExport({
    required String requestedByUserId,
    required String projectId,
    required String projectName,
    required ExportFormat format,
    required Map<String, dynamic> exportParameters,
  }) async {
    return ExportJob(
      id: 'regenerated-export',
      projectId: projectId,
      projectName: projectName,
      format: format,
      status: ExportJobStatus.pending,
      requestedByUserId: requestedByUserId,
      requestedAt: DateTime.utc(2026, 6, 20),
      exportParameters: exportParameters,
    );
  }

  @override
  Future<List<ExportJob>> processQueueTick({
    required String requestedByUserId,
  }) async => jobs;

  @override
  Future<ExportJob?> markDownloaded({
    required String requestedByUserId,
    required String exportId,
  }) async => null;

  @override
  Future<ExportJob?> retryFailed({
    required String requestedByUserId,
    required String exportId,
  }) async => requestExport(
        requestedByUserId: requestedByUserId,
        projectId: jobs.first.projectId,
        projectName: jobs.first.projectName,
        format: jobs.first.format,
        exportParameters: jobs.first.exportParameters,
      );
}

void main() {
  const project = ProjectSummary(
    id: 'project-1',
    name: 'Export Project',
    category: 'Agriculture',
    categoryId: 'category-1',
    status: 'active',
    approvedFeatures: 3,
    assignedCollectors: 1,
    pendingReviews: 0,
    description: 'Export project',
  );

  Future<void> pumpPicker(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: buildExportAreaPickerForTest()));
    await tester.pumpAndSettle();
  }

  Future<void> pumpDashboard(
    WidgetTester tester, {
    AuthController? authController,
    ExportsRepository? exportsRepository,
    bool settle = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(
            (_) => authController ?? _AuthenticatedAuthController(),
          ),
          exportsRepositoryProvider.overrideWithValue(
            exportsRepository ?? MockExportsRepository(),
          ),
          projectListProvider.overrideWith(
            (ref, scope) async => const <ProjectSummary>[project],
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: ExportsDashboardScreen(
              fixedProjectId: 'project-1',
              fixedProjectName: 'Export Project',
            ),
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Future<void> tapMap(WidgetTester tester, Offset offsetFromCenter) async {
    final mapCenter = tester.getCenter(find.byType(FlutterMap));
    await tester.tapAt(mapCenter + offsetFromCenter);
    await tester.pumpAndSettle();
  }

  Future<void> drawAreaFromDashboard(WidgetTester tester) async {
    final drawButton = find.text('Draw area on map');
    await tester.ensureVisible(drawButton);
    await tester.pumpAndSettle();
    await tester.tap(drawButton);
    await tester.pumpAndSettle();
    await tapMap(tester, Offset.zero);
    await tapMap(tester, const Offset(30, 30));
    await tapMap(tester, const Offset(-30, 40));
    await tester.tap(find.widgetWithText(FilledButton, 'Use area'));
    await tester.pumpAndSettle();
  }

  test('exports controller provider is safe without a session', () {
    final container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(
          (_) => _UnauthenticatedAuthController(),
        ),
        exportsRepositoryProvider.overrideWithValue(MockExportsRepository()),
      ],
    );
    addTearDown(container.dispose);

    expect(() => container.read(exportsControllerProvider), returnsNormally);
  });

  testWidgets('draw export area opens and requires three vertices', (
    tester,
  ) async {
    await pumpPicker(tester);

    expect(find.text('Draw export area'), findsOneWidget);
    expect(find.text('Tap the map to add at least 3 points.'), findsNothing);
    expect(
      find.text('Area ready. Use area to apply this export filter.'),
      findsNothing,
    );
    expect(find.byTooltip('Clear area'), findsNothing);
    expect(find.byTooltip('Undo point'), findsNothing);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('export_area_map_clip')),
      findsOneWidget,
    );

    expect(find.byTooltip('Fit workspace'), findsOneWidget);
    expect(find.byTooltip('Zoom in'), findsOneWidget);
    expect(find.byTooltip('Zoom out'), findsOneWidget);
    expect(find.byTooltip('Switch to Satellite'), findsOneWidget);
    expect(find.byTooltip('Undo last point'), findsOneWidget);
    expect(find.byTooltip('Clear polygon'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byTooltip('Fit workspace')).dy,
      greaterThan(100),
    );
    final railBottom = tester
        .getBottomRight(find.byTooltip('Clear polygon'))
        .dy;
    final panelTop = tester
        .getTopLeft(find.widgetWithText(FilledButton, 'Use area'))
        .dy;
    expect(railBottom, lessThan(panelTop));

    final useArea = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Use area'),
    );
    expect(useArea.onPressed, isNull);
  });

  testWidgets('draw export area back button closes route cleanly', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () {
                  Navigator.of(context).push<Map<String, dynamic>>(
                    MaterialPageRoute<Map<String, dynamic>>(
                      builder: (_) => buildExportAreaPickerForTest(),
                    ),
                  );
                },
                child: const Text('Open picker'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    expect(find.text('Draw export area'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Open picker'), findsOneWidget);
    expect(find.text('Draw export area'), findsNothing);
  });

  testWidgets('map tools stay above bottom panel on compact phone', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpPicker(tester);

    final panelTop = tester
        .getTopLeft(find.widgetWithText(FilledButton, 'Use area'))
        .dy;
    for (final tooltip in const [
      'Fit workspace',
      'Zoom in',
      'Zoom out',
      'Switch to Satellite',
      'Undo last point',
      'Clear polygon',
    ]) {
      expect(find.byTooltip(tooltip), findsOneWidget);
      expect(
        tester.getBottomRight(find.byTooltip(tooltip)).dy,
        lessThan(panelTop),
      );
    }
  });

  testWidgets('tapping three map points enables Use area', (tester) async {
    await pumpPicker(tester);

    await tapMap(tester, Offset.zero);
    await tapMap(tester, const Offset(30, 30));
    await tapMap(tester, const Offset(-30, 40));

    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(
      find.text('Area ready. Use area to apply this export filter.'),
      findsNothing,
    );

    final useArea = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Use area'),
    );
    expect(useArea.onPressed, isNotNull);
  });

  testWidgets('undo and clear controls edit polygon vertices', (tester) async {
    await pumpPicker(tester);

    await tapMap(tester, Offset.zero);
    await tapMap(tester, const Offset(30, 30));
    await tapMap(tester, const Offset(-30, 40));

    await tester.tap(find.byTooltip('Undo last point'));
    await tester.pumpAndSettle();
    expect(find.text('3'), findsNothing);

    await tester.tap(find.byTooltip('Clear polygon'));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsNothing);
    expect(find.text('2'), findsNothing);
  });

  testWidgets('layer toggle does not clear polygon vertices', (tester) async {
    await pumpPicker(tester);

    await tapMap(tester, Offset.zero);
    await tapMap(tester, const Offset(30, 30));
    await tapMap(tester, const Offset(-30, 40));

    await tester.tap(find.byTooltip('Switch to Satellite'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Switch to OSM'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('fit workspace does not trigger camera constraint crash', (
    tester,
  ) async {
    await pumpPicker(tester);

    await tester.tap(find.byTooltip('Fit workspace'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Draw export area'), findsOneWidget);
  });

  testWidgets('Use area returns selected polygon to caller', (tester) async {
    Map<String, dynamic>? selectedPolygon;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  selectedPolygon = await showDialog<Map<String, dynamic>>(
                    context: context,
                    builder: (_) => buildExportAreaPickerForTest(),
                  );
                },
                child: const Text('Open picker'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();

    await tapMap(tester, Offset.zero);
    await tapMap(tester, const Offset(30, 30));
    await tapMap(tester, const Offset(-30, 40));
    await tester.tap(find.widgetWithText(FilledButton, 'Use area'));
    await tester.pumpAndSettle();

    expect(selectedPolygon, isNotNull);
    expect(selectedPolygon!['type'], 'Polygon');
    final coordinates = selectedPolygon!['coordinates'] as List<dynamic>;
    final ring = coordinates.first as List<dynamic>;
    expect(ring, hasLength(4));
    expect(ring.first, equals(ring.last));
  });

  testWidgets('successful export clears selected polygon', (tester) async {
    await pumpDashboard(tester);
    await drawAreaFromDashboard(tester);

    expect(find.text('Polygon area selected'), findsOneWidget);

    await tester.tap(find.text('Request Export'));
    await tester.pumpAndSettle();

    expect(find.text('Polygon area selected'), findsNothing);
  });

  testWidgets('export form keeps bbox area controls compact', (tester) async {
    await pumpDashboard(tester);

    expect(find.text('BBOX'), findsOneWidget);
    expect(find.text('Draw area on map'), findsOneWidget);
    expect(find.byTooltip('Reset filters'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Feature type')).dy,
      lessThan(tester.getTopLeft(find.text('Format')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Feature type')).dy,
      lessThan(tester.getTopLeft(find.text('Optional filters')).dy),
    );
    expect(
      find.text('Drawn areas are combined with BBOX and date filters.'),
      findsNothing,
    );
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('reset filters keeps project and clears optional export state', (
    tester,
  ) async {
    await pumpDashboard(tester);
    await drawAreaFromDashboard(tester);

    final bboxFinder = find.ancestor(
      of: find.text('BBOX'),
      matching: find.byType(TextFormField),
    );
    await tester.enterText(bboxFinder, '35,33,36,34');
    await tester.pumpAndSettle();
    expect(find.text('Polygon area selected'), findsOneWidget);

    await tester.ensureVisible(find.byTooltip('Reset filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Reset filters'));
    await tester.pumpAndSettle();

    expect(find.text('Export Project'), findsWidgets);
    expect(find.text('Polygon area selected'), findsNothing);
    expect(find.text('Change area'), findsNothing);
    expect(find.text('Draw area on map'), findsOneWidget);
    final bboxField = tester.widget<TextFormField>(bboxFinder);
    expect(bboxField.controller?.text, isEmpty);
  });

  testWidgets('failed export keeps selected polygon for retry', (tester) async {
    await pumpDashboard(
      tester,
      exportsRepository: const _FailingExportsRepository(),
    );
    await drawAreaFromDashboard(tester);

    expect(find.text('Polygon area selected'), findsOneWidget);

    await tester.tap(find.text('Request Export'));
    await tester.pumpAndSettle();

    expect(find.text('Polygon area selected'), findsOneWidget);
  });

  testWidgets('expired export shows expired state and regenerate action', (
    tester,
  ) async {
    final expiredJob = ExportJob(
      id: 'expired-export-1',
      projectId: 'project-1',
      projectName: 'Export Project',
      format: ExportFormat.geojson,
      status: ExportJobStatus.expired,
      requestedByUserId: 'admin-1',
      requestedAt: DateTime.utc(2026, 6, 18),
      completedAt: DateTime.utc(2026, 6, 18, 1),
      fileStatus: 'expired',
      displayMessage:
          'Export completed, but the file expired. Regenerate it to download again.',
      canRegenerate: true,
      recordCount: 12,
      exportParameters: const <String, dynamic>{'format': 'geojson'},
    );

    await pumpDashboard(
      tester,
      exportsRepository: _StaticExportsRepository(<ExportJob>[expiredJob]),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();

    expect(find.text('File expired'), findsOneWidget);
    expect(
      find.text('Export completed, but the file expired. Regenerate it to download again.'),
      findsOneWidget,
    );
    expect(find.text('Regenerate'), findsOneWidget);
    expect(find.text('Download'), findsNothing);
    expect(find.text('failed'), findsNothing);
  });

  testWidgets('exports screen handles missing session without provider crash', (
    tester,
  ) async {
    await pumpDashboard(
      tester,
      authController: _UnauthenticatedAuthController(),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Export access restricted'), findsOneWidget);
  });

  testWidgets('exports screen handles auth hydration without provider crash', (
    tester,
  ) async {
    await pumpDashboard(
      tester,
      authController: _CheckingAuthController(),
      settle: false,
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('logout and account switch from exports do not reuse state', (
    tester,
  ) async {
    final authController = _MutableAuthController();
    await pumpDashboard(tester, authController: authController);

    expect(find.text('Export Project'), findsWidgets);

    authController.logoutNow();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Export access restricted'), findsOneWidget);

    authController.authenticateAsContributor();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Export access restricted'), findsOneWidget);
    expect(find.text('Polygon area selected'), findsNothing);
  });
}
