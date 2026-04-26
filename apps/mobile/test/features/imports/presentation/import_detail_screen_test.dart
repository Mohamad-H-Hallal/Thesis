import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/pagination/paginated_result.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';
import 'package:lebanese_gis_mobile/features/imports/domain/import_models.dart';
import 'package:lebanese_gis_mobile/features/imports/domain/imports_repository.dart';
import 'package:lebanese_gis_mobile/features/imports/presentation/screens/import_detail_screen.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_map/flutter_map.dart';

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
    email: 'user@example.com',
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

class _FakeImportsRepository implements ImportsRepository {
  _FakeImportsRepository({
    required this.details,
    this.features = const <ImportedFeature>[],
  });

  final GisImportDetails details;
  final List<ImportedFeature> features;
  final List<String?> requestedIssues = <String?>[];

  @override
  Future<List<GisImportJob>> fetchImports({
    String? status,
    String? projectId,
    String? categoryId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<PaginatedResult<GisImportJob>> fetchImportsPage({
    String? status,
    String? projectId,
    String? categoryId,
    int page = 1,
    int limit = 20,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<GisImportDetails> fetchImportDetails(String importId) async => details;

  @override
  Future<List<ImportComment>> fetchImportComments(String importId) async =>
      details.comments;

  @override
  Future<List<ImportedFeature>> fetchImportFeatures({
    required String importId,
    String? status,
    String? issue,
    int page = 1,
    int limit = 100,
  }) async => features;

  @override
  Future<PaginatedResult<ImportedFeature>> fetchImportFeaturesPage({
    required String importId,
    String? status,
    String? issue,
    int page = 1,
    int limit = 20,
  }) async {
    requestedIssues.add(issue);
    final filtered = status == null
        ? features
        : features
              .where((item) => item.status == status)
              .toList(growable: false);
    final issueFiltered = issue == null
        ? filtered
        : filtered
              .where(
                (item) =>
                    item.validationErrors.contains(issue) ||
                    item.validationWarnings.contains(issue),
              )
              .toList(growable: false);
    return PaginatedResult<ImportedFeature>(
      items: issueFiltered,
      page: 1,
      limit: limit,
      total: issueFiltered.length,
      hasMore: false,
    );
  }

  @override
  Future<GisImportJob> reviewImport({
    required String importId,
    required String status,
    String? reason,
    List<String>? featureIds,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<GisImportJob> uploadImport({
    required String projectId,
    required PlatformFile file,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ImportComment> addImportComment({
    required String importId,
    required String comment,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<String> downloadImport(String importId) async =>
      '/mock/imports/$importId.geojson';
}

AuthSession _session() {
  return const AuthSession(
    accessToken: 'token',
    refreshToken: 'refresh',
    user: AppUser(
      id: 'admin-1',
      fullName: 'Admin Reviewer',
      email: 'admin@example.com',
      role: UserRole.admin,
    ),
  );
}

GisImportJob _job({
  required String status,
  Map<String, dynamic> validationSummary = const <String, dynamic>{},
  String? processingMessage,
}) {
  return GisImportJob(
    id: 'import-1',
    projectId: 'project-1',
    projectName: 'Import Project',
    uploadedByUserId: 'contributor-1',
    uploadedByName: 'Field Contributor',
    possibleDuplicate: false,
    originalFilename: 'dataset.geojson',
    fileSizeBytes: 2048,
    fileChecksumSha256: 'a' * 64,
    fileType: 'geojson',
    status: status,
    geometryCount: 1,
    pendingFeatureCount: 0,
    approvedFeatureCount: 0,
    rejectedFeatureCount: 0,
    failedFeatureCount: status == 'failed' ? 1 : 0,
    warningCount: 0,
    errorCount: status == 'failed' ? 1 : 0,
    geometryTypes: const <String>['Point'],
    fileMetadata: const <String, dynamic>{},
    validationSummary: validationSummary,
    processingMessage: processingMessage,
    reviewScope: 'admin',
    uploadedAt: DateTime(2026, 4, 25),
    createdAt: DateTime(2026, 4, 25),
    updatedAt: DateTime(2026, 4, 25),
  );
}

ImportedFeature _outsideLebanonFeature() {
  return ImportedFeature(
    id: 'feature-1',
    importJobId: 'import-1',
    sourceIndex: 0,
    displayTitle: 'Outside workspace feature',
    geometryType: 'Point',
    geometry: const <String, dynamic>{
      'type': 'Point',
      'coordinates': <double>[30.5234, 50.4501],
    },
    attributes: const <String, dynamic>{'name': 'Outside workspace feature'},
    status: 'failed',
    validationWarnings: const <String>[],
    validationErrors: const <String>[
      'Geometry falls outside the Lebanon workspace bounds.',
    ],
    validationReport: const <String, dynamic>{},
    createdAt: DateTime(2026, 4, 25),
    updatedAt: DateTime(2026, 4, 25),
  );
}

ImportedFeature _missingFeatureTypeFeature() {
  return ImportedFeature(
    id: 'feature-2',
    importJobId: 'import-1',
    sourceIndex: 1,
    displayTitle: 'Missing type feature',
    geometryType: 'Polygon',
    geometry: const <String, dynamic>{
      'type': 'Polygon',
      'coordinates': <dynamic>[
        <dynamic>[
          <double>[35.48, 33.89],
          <double>[35.49, 33.89],
          <double>[35.49, 33.90],
          <double>[35.48, 33.89],
        ],
      ],
    },
    attributes: const <String, dynamic>{'name': 'Missing type feature'},
    status: 'failed',
    validationWarnings: const <String>[
      'Attributes not defined in the project form were kept: name',
    ],
    validationErrors: const <String>[
      'Missing required attribute: feature_type',
    ],
    validationReport: const <String, dynamic>{},
    createdAt: DateTime(2026, 4, 25),
    updatedAt: DateTime(2026, 4, 25),
  );
}

void main() {
  testWidgets('processing import shows processing card instead of map', (
    tester,
  ) async {
    final repository = _FakeImportsRepository(
      details: GisImportDetails(
        job: _job(
          status: 'processing',
          processingMessage: 'Processing imported features 10/13249',
        ),
        previewFeatures: const <ImportedFeature>[],
        previewSummary: const ImportPreviewSummary(
          geometryFeatureCount: 0,
          previewFeatureCount: 0,
          outsideWorkspaceFeatureCount: 0,
        ),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(
            (_) => _AuthenticatedAuthController(_session()),
          ),
          importsRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ImportDetailScreen(importId: 'import-1')),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Spatial preview'), findsOneWidget);
    expect(find.textContaining('Processing imported features'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed import outside Lebanon shows file issues without map exception',
    (tester) async {
      final feature = _outsideLebanonFeature();
      final repository = _FakeImportsRepository(
        details: GisImportDetails(
          job: _job(
            status: 'failed',
            validationSummary: const <String, dynamic>{
              'top_errors': <Map<String, dynamic>>[
                <String, dynamic>{
                  'message':
                      'Geometry falls outside the Lebanon workspace bounds.',
                  'count': 1,
                },
              ],
            },
            processingMessage:
                'Import processing finished, but no staged features were eligible for review.',
        ),
        previewFeatures: <ImportedFeature>[feature],
        previewSummary: const ImportPreviewSummary(
          geometryFeatureCount: 1,
          previewFeatureCount: 0,
          outsideWorkspaceFeatureCount: 1,
        ),
      ),
        features: <ImportedFeature>[feature],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(
              (_) => _AuthenticatedAuthController(_session()),
            ),
            importsRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(
            home: Scaffold(body: ImportDetailScreen(importId: 'import-1')),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('File-wide issues'), findsOneWidget);
      expect(
        find.textContaining(
          'Geometry falls outside the Lebanon workspace bounds.',
        ),
        findsWidgets,
      );
      expect(find.byType(FlutterMap), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('issue filter narrows staged features by validation message', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2200);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final outsideFeature = _outsideLebanonFeature();
    final missingTypeFeature = _missingFeatureTypeFeature();
    final repository = _FakeImportsRepository(
      details: GisImportDetails(
        job: _job(
          status: 'failed',
          validationSummary: const <String, dynamic>{
            'error_breakdown': <String, dynamic>{
              'Geometry falls outside the Lebanon workspace bounds.': 1,
              'Missing required attribute: feature_type': 1,
            },
          },
        ),
        previewFeatures: <ImportedFeature>[outsideFeature, missingTypeFeature],
        previewSummary: const ImportPreviewSummary(
          geometryFeatureCount: 2,
          previewFeatureCount: 1,
          outsideWorkspaceFeatureCount: 1,
        ),
      ),
      features: <ImportedFeature>[outsideFeature, missingTypeFeature],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(
            (_) => _AuthenticatedAuthController(_session()),
          ),
          importsRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ImportDetailScreen(importId: 'import-1')),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(repository.requestedIssues, contains(isNull));

    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();
    await tester.tap(
      find.textContaining('Missing required attribute: feature_type').last,
    );
    await tester.pumpAndSettle();

    expect(
      repository.requestedIssues,
      contains('Missing required attribute: feature_type'),
    );
    expect(tester.takeException(), isNull);
  });
}
