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
import 'package:lebanese_gis_mobile/features/imports/presentation/screens/imports_screen.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/project.dart';
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
  _FakeImportsRepository(this.jobs);

  final List<GisImportJob> jobs;

  @override
  Future<List<GisImportJob>> fetchImports({
    String? status,
    String? projectId,
    String? categoryId,
  }) async {
    return jobs
        .where((job) {
          if (status != null && job.status != status) {
            return false;
          }
          if (projectId != null && job.projectId != projectId) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  @override
  Future<PaginatedResult<GisImportJob>> fetchImportsPage({
    String? status,
    String? projectId,
    String? categoryId,
    int page = 1,
    int limit = 20,
  }) async {
    final items = await fetchImports(
      status: status,
      projectId: projectId,
      categoryId: categoryId,
    );
    final start = (page - 1) * limit;
    final end = (start + limit).clamp(0, items.length);
    return PaginatedResult<GisImportJob>(
      items: start >= items.length
          ? const <GisImportJob>[]
          : items.sublist(start, end),
      page: page,
      limit: limit,
      total: items.length,
      hasMore: end < items.length,
    );
  }

  @override
  Future<GisImportDetails> fetchImportDetails(String importId) {
    throw UnimplementedError();
  }

  @override
  Future<ImportMapData> fetchImportMapData({
    required String importId,
    required String projectId,
    required double minLon,
    required double minLat,
    required double maxLon,
    required double maxLat,
    required double zoom,
    int cacheRevision = 0,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ImportedFeature> fetchImportFeatureById({
    required String importId,
    required String featureId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<ImportComment>> fetchImportComments(String importId) {
    throw UnimplementedError();
  }

  @override
  Future<List<ImportedFeature>> fetchImportFeatures({
    required String importId,
    String? status,
    String? issue,
    int page = 1,
    int limit = 100,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<PaginatedResult<ImportedFeature>> fetchImportFeaturesPage({
    required String importId,
    String? status,
    String? issue,
    String? search,
    String? featureType,
    String? geometryType,
    int page = 1,
    int limit = 20,
  }) async {
    return const PaginatedResult<ImportedFeature>(
      items: <ImportedFeature>[],
      page: 1,
      limit: 20,
      total: 0,
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
    String? featureId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<String> downloadImport(String importId) {
    throw UnimplementedError();
  }
}

void main() {
  testWidgets('contributor import screen shows upload controls and history', (
    tester,
  ) async {
    final project = ProjectSummary(
      id: 'project-1',
      name: 'Assigned Import Project',
      category: 'Agriculture',
      categoryId: 'cat-1',
      status: 'active',
      assignedCollectors: 1,
      pendingReviews: 0,
      description: 'Assigned project',
    );
    final importJob = GisImportJob(
      id: 'import-1',
      projectId: 'project-1',
      projectName: 'Assigned Import Project',
      uploadedByUserId: 'contributor-1',
      uploadedByName: 'Field Contributor',
      possibleDuplicate: false,
      originalFilename: 'cedars.geojson',
      fileSizeBytes: 1024,
      fileChecksumSha256: 'a' * 64,
      fileType: 'geojson',
      status: 'pending_review',
      geometryCount: 2,
      pendingFeatureCount: 2,
      approvedFeatureCount: 0,
      rejectedFeatureCount: 0,
      failedFeatureCount: 0,
      warningCount: 0,
      errorCount: 0,
      geometryTypes: const <String>['Point'],
      fileMetadata: const <String, dynamic>{},
      validationSummary: const <String, dynamic>{},
      reviewScope: 'admin',
      uploadedAt: DateTime(2026, 4, 24),
      createdAt: DateTime(2026, 4, 24),
      updatedAt: DateTime(2026, 4, 24),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(
            (_) => _AuthenticatedAuthController(
              AuthSession(
                accessToken: 'token',
                refreshToken: 'refresh',
                user: const AppUser(
                  id: 'contributor-1',
                  fullName: 'Field Contributor',
                  email: 'contributor@example.com',
                  role: UserRole.contributor,
                ),
              ),
            ),
          ),
          importsRepositoryProvider.overrideWithValue(
            _FakeImportsRepository(<GisImportJob>[importJob]),
          ),
          projectListProvider(
            ProjectViewScope.assigned,
          ).overrideWith((ref) async => <ProjectSummary>[project]),
        ],
        child: const MaterialApp(home: Scaffold(body: ImportsScreen())),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Submit new import'), findsOneWidget);
    expect(find.text('Import history'), findsOneWidget);
    expect(find.text('GIS imports'), findsNothing);
    expect(find.text('No imports submitted yet'), findsNothing);
  });

  testWidgets('admin import screen shows review queue with upload form', (
    tester,
  ) async {
    final project = ProjectSummary(
      id: 'project-1',
      name: 'Import Review Project',
      category: 'Forestry',
      categoryId: 'cat-1',
      status: 'active',
      assignedCollectors: 1,
      pendingReviews: 0,
      description: 'Review project',
    );
    final importJob = GisImportJob(
      id: 'import-1',
      projectId: 'project-1',
      projectName: 'Import Review Project',
      uploadedByUserId: 'contributor-1',
      uploadedByName: 'Field Contributor',
      possibleDuplicate: false,
      originalFilename: 'review.geojson',
      fileSizeBytes: 1024,
      fileChecksumSha256: 'b' * 64,
      fileType: 'geojson',
      status: 'pending_review',
      geometryCount: 2,
      pendingFeatureCount: 2,
      approvedFeatureCount: 0,
      rejectedFeatureCount: 0,
      failedFeatureCount: 0,
      warningCount: 1,
      errorCount: 0,
      geometryTypes: const <String>['Point'],
      fileMetadata: const <String, dynamic>{},
      validationSummary: const <String, dynamic>{},
      reviewScope: 'admin',
      uploadedAt: DateTime(2026, 4, 24),
      createdAt: DateTime(2026, 4, 24),
      updatedAt: DateTime(2026, 4, 24),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(
            (_) => _AuthenticatedAuthController(
              AuthSession(
                accessToken: 'token',
                refreshToken: 'refresh',
                user: const AppUser(
                  id: 'admin-1',
                  fullName: 'Admin Reviewer',
                  email: 'admin@example.com',
                  role: UserRole.admin,
                ),
              ),
            ),
          ),
          importsRepositoryProvider.overrideWithValue(
            _FakeImportsRepository(<GisImportJob>[importJob]),
          ),
          projectListProvider(
            ProjectViewScope.all,
          ).overrideWith((ref) async => <ProjectSummary>[project]),
        ],
        child: const MaterialApp(home: Scaffold(body: ImportsScreen())),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Import review queue'), findsOneWidget);
    expect(find.text('Submit new import'), findsOneWidget);
    await tester.tap(find.text('Filter'));
    await tester.pumpAndSettle();
    expect(find.text('Category filter'), findsOneWidget);
    expect(find.text('Project filter'), findsOneWidget);
    expect(find.text('No imports match this filter'), findsNothing);
  });

  testWidgets(
    'contributor fixed project imports stay unavailable when not assigned',
    (tester) async {
      final assignedProject = ProjectSummary(
        id: 'project-1',
        name: 'Assigned Import Project',
        category: 'Agriculture',
        categoryId: 'cat-1',
        status: 'active',
        assignedCollectors: 1,
        pendingReviews: 0,
        description: 'Assigned project',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(
              (_) => _AuthenticatedAuthController(
                AuthSession(
                  accessToken: 'token',
                  refreshToken: 'refresh',
                  user: const AppUser(
                    id: 'contributor-1',
                    fullName: 'Field Contributor',
                    email: 'contributor@example.com',
                    role: UserRole.contributor,
                  ),
                ),
              ),
            ),
            importsRepositoryProvider.overrideWithValue(
              _FakeImportsRepository(const <GisImportJob>[]),
            ),
            projectListProvider(
              ProjectViewScope.assigned,
            ).overrideWith((ref) async => <ProjectSummary>[assignedProject]),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: ImportsScreen(
                fixedProjectId: 'project-2',
                fixedProjectName: 'Unassigned Project',
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Imports unavailable'), findsOneWidget);
      expect(find.textContaining('approved assignment'), findsOneWidget);
      expect(find.text('Submit new import'), findsNothing);
    },
  );

  testWidgets('contributor import picker keeps assigned non-active projects', (
    tester,
  ) async {
    final pausedProject = ProjectSummary(
      id: 'project-1',
      name: 'Paused Import Project',
      category: 'Agriculture',
      categoryId: 'cat-1',
      status: 'paused',
      assignedCollectors: 1,
      pendingReviews: 0,
      description: 'Assigned project',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(
            (_) => _AuthenticatedAuthController(
              AuthSession(
                accessToken: 'token',
                refreshToken: 'refresh',
                user: const AppUser(
                  id: 'contributor-1',
                  fullName: 'Field Contributor',
                  email: 'contributor@example.com',
                  role: UserRole.contributor,
                ),
              ),
            ),
          ),
          importsRepositoryProvider.overrideWithValue(
            _FakeImportsRepository(const <GisImportJob>[]),
          ),
          projectListProvider(
            ProjectViewScope.assigned,
          ).overrideWith((ref) async => <ProjectSummary>[pausedProject]),
        ],
        child: const MaterialApp(home: Scaffold(body: ImportsScreen())),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Submit new import'), findsOneWidget);
    expect(find.text('Paused Import Project'), findsOneWidget);
  });
}
