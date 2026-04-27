import 'package:file_picker/file_picker.dart';
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
import 'package:lebanese_gis_mobile/features/imports/presentation/screens/import_review_screen.dart';

class _NoopAuthRepository implements AuthRepository {
  const _NoopAuthRepository();

  @override
  Future<void> changePassword({required String currentPassword, required String newPassword}) async {}

  @override
  Future<AuthSession> login({required String email, required String password, required bool rememberMe}) {
    throw UnimplementedError();
  }

  @override
  Future<void> logout() async {}

  @override
  Future<PasswordResetRequestResult> requestPasswordReset(String email) async =>
      const PasswordResetRequestResult(message: 'sent');

  @override
  Future<PasswordResetOtpVerificationResult> verifyPasswordResetOtp({required String email, required String otp}) async =>
      const PasswordResetOtpVerificationResult(message: 'verified', resetToken: 'token', email: 'admin@example.com');

  @override
  Future<void> resetPassword({required String resetToken, required String newPassword}) async {}

  @override
  Future<AuthSession> reactivateContributorAndLogin({required String email, required String password, required bool rememberMe}) {
    throw UnimplementedError();
  }

  @override
  Future<void> selfDeactivate() async {}

  @override
  Future<AuthSession?> restoreSession() async => null;

  @override
  Future<String> signup({required String fullName, required String email, required String password, required UserRole role, String? phone}) {
    throw UnimplementedError();
  }

  @override
  Future<AppUser> updateProfile({String? fullName, String? phone}) async {
    throw UnimplementedError();
  }
}

class _AuthenticatedAuthController extends AuthController {
  _AuthenticatedAuthController(AuthSession session) : super(const _NoopAuthRepository()) {
    state = AuthState.authenticated(session);
  }
}

class _FakeImportsRepository implements ImportsRepository {
  _FakeImportsRepository({required this.details, required this.features});

  final GisImportDetails details;
  final List<ImportedFeature> features;
  final List<String?> requestedStatuses = <String?>[];

  @override
  Future<List<GisImportJob>> fetchImports({String? status, String? projectId, String? categoryId}) {
    throw UnimplementedError();
  }

  @override
  Future<PaginatedResult<GisImportJob>> fetchImportsPage({String? status, String? projectId, String? categoryId, int page = 1, int limit = 20}) {
    throw UnimplementedError();
  }

  @override
  Future<GisImportDetails> fetchImportDetails(String importId) async => details;

  @override
  Future<List<ImportComment>> fetchImportComments(String importId) async => details.comments;

  @override
  Future<List<ImportedFeature>> fetchImportFeatures({required String importId, String? status, String? issue, int page = 1, int limit = 100}) async => features;

  @override
  Future<PaginatedResult<ImportedFeature>> fetchImportFeaturesPage({required String importId, String? status, String? issue, int page = 1, int limit = 20}) async {
    requestedStatuses.add(status);
    final statusFiltered = status == null
        ? features
        : features.where((item) => item.status == status).toList(growable: false);
    final issueFiltered = issue == null
        ? statusFiltered
        : statusFiltered
            .where((item) => item.validationWarnings.contains(issue) || item.validationErrors.contains(issue))
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
  Future<GisImportJob> reviewImport({required String importId, required String status, String? reason, List<String>? featureIds}) {
    throw UnimplementedError();
  }

  @override
  Future<ImportComment> addImportComment({required String importId, required String comment}) {
    throw UnimplementedError();
  }

  @override
  Future<String> downloadImport(String importId) async => '/tmp/$importId.geojson';

  @override
  Future<GisImportJob> uploadImport({required String projectId, required PlatformFile file}) {
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

GisImportJob _job() {
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
    status: 'pending_review',
    geometryCount: 3,
    pendingFeatureCount: 1,
    approvedFeatureCount: 1,
    rejectedFeatureCount: 0,
    failedFeatureCount: 1,
    warningCount: 0,
    errorCount: 1,
    geometryTypes: const <String>['Point'],
    fileMetadata: const <String, dynamic>{},
    validationSummary: const <String, dynamic>{},
    reviewScope: 'admin',
    uploadedAt: DateTime(2026, 4, 25),
    createdAt: DateTime(2026, 4, 25),
    updatedAt: DateTime(2026, 4, 25),
  );
}

ImportedFeature _feature(String id, String status, String title) {
  return ImportedFeature(
    id: id,
    importJobId: 'import-1',
    sourceIndex: id == 'pending-1' ? 0 : id == 'approved-1' ? 1 : 2,
    displayTitle: title,
    geometryType: 'Point',
    geometry: const <String, dynamic>{
      'type': 'Point',
      'coordinates': <double>[35.5, 33.9],
    },
    attributes: const <String, dynamic>{'name': 'Feature'},
    status: status,
    validationWarnings: const <String>[],
    validationErrors: const <String>[],
    validationReport: const <String, dynamic>{},
    createdAt: DateTime(2026, 4, 25),
    updatedAt: DateTime(2026, 4, 25),
  );
}

void main() {
  testWidgets('review screen applies status filter through paginated provider', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2200);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final repository = _FakeImportsRepository(
      details: GisImportDetails(
        job: _job(),
        previewFeatures: const <ImportedFeature>[],
        previewSummary: const ImportPreviewSummary(
          geometryFeatureCount: 3,
          previewFeatureCount: 3,
          outsideWorkspaceFeatureCount: 0,
        ),
      ),
      features: <ImportedFeature>[
        _feature('pending-1', 'pending_review', 'Pending feature'),
        _feature('approved-1', 'approved', 'Approved feature'),
        _feature('failed-1', 'failed', 'Failed feature'),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith((_) => _AuthenticatedAuthController(_session())),
          importsRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ImportReviewScreen(importId: 'import-1')),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Pending feature'), findsOneWidget);
    expect(find.text('Approved feature'), findsOneWidget);
    expect(find.text('Failed feature'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'Approved'));
    await tester.pumpAndSettle();

    expect(repository.requestedStatuses, contains('approved'));
    expect(find.text('Approved feature'), findsOneWidget);
    expect(find.text('Pending feature'), findsNothing);
    expect(find.text('Failed feature'), findsNothing);
  });
}
