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
  Future<List<ImportedFeature>> fetchImportFeatures({
    required String importId,
    String? status,
    int page = 1,
    int limit = 100,
  }) async => features;

  @override
  Future<PaginatedResult<ImportedFeature>> fetchImportFeaturesPage({
    required String importId,
    String? status,
    int page = 1,
    int limit = 20,
  }) async {
    final filtered = status == null
        ? features
        : features
              .where((item) => item.status == status)
              .toList(growable: false);
    return PaginatedResult<ImportedFeature>(
      items: filtered,
      page: 1,
      limit: limit,
      total: filtered.length,
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

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('File-wide issues'), findsOneWidget);
      expect(
        find.textContaining(
          'Geometry falls outside the Lebanon workspace bounds.',
        ),
        findsWidgets,
      );
      expect(
        find.textContaining('This preview only renders staged geometries'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
