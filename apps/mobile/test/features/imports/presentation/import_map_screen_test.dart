import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';
import 'package:lebanese_gis_mobile/features/imports/domain/import_models.dart';
import 'package:lebanese_gis_mobile/features/imports/presentation/import_providers.dart';
import 'package:lebanese_gis_mobile/features/imports/presentation/screens/import_map_screen.dart';
import 'package:lebanese_gis_mobile/features/map/domain/map_feature.dart';

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
    geometryCount: 2,
    pendingFeatureCount: 1,
    approvedFeatureCount: 1,
    rejectedFeatureCount: 0,
    failedFeatureCount: 0,
    warningCount: 0,
    errorCount: 0,
    geometryTypes: const <String>['Point'],
    fileMetadata: const <String, dynamic>{},
    validationSummary: const <String, dynamic>{},
    reviewScope: 'admin',
    uploadedAt: DateTime(2026, 4, 25),
    createdAt: DateTime(2026, 4, 25),
    updatedAt: DateTime(2026, 4, 25),
  );
}

ImportedFeature _importedFeature(
  String id,
  String status,
  double lon,
  double lat,
) {
  return ImportedFeature(
    id: id,
    importJobId: 'import-1',
    sourceIndex: id == 'feature-1' ? 0 : 1,
    displayTitle: 'Imported feature $id',
    geometryType: 'Point',
    geometry: <String, dynamic>{
      'type': 'Point',
      'coordinates': <double>[lon, lat],
    },
    attributes: <String, dynamic>{'name': 'Feature $id'},
    status: status,
    validationWarnings: const <String>[],
    validationErrors: const <String>[],
    validationReport: const <String, dynamic>{},
    createdAt: DateTime(2026, 4, 25),
    updatedAt: DateTime(2026, 4, 25),
  );
}

MapFeatureSummary _approvedFeature() {
  return const MapFeatureSummary(
    id: 'approved-1',
    status: 'approved',
    geometry: <String, dynamic>{
      'type': 'Point',
      'coordinates': <double>[35.52, 33.91],
    },
    attributes: <String, dynamic>{'name': 'Approved context feature'},
  );
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

void main() {
  testWidgets(
    'import map shows staged and approved context layers separately',
    (tester) async {
      const query = ImportMapQuery(
        importId: 'import-1',
        projectId: 'project-1',
        minLon: 35.094,
        minLat: 33.045,
        maxLon: 36.645,
        maxLat: 34.695,
        zoom: 8,
      );
      final details = GisImportDetails(
        job: _job(),
        previewFeatures: const <ImportedFeature>[],
        previewSummary: const ImportPreviewSummary(
          geometryFeatureCount: 2,
          previewFeatureCount: 2,
          outsideWorkspaceFeatureCount: 0,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(
              (_) => _AuthenticatedAuthController(_session()),
            ),
            importDetailsProvider(
              'import-1',
            ).overrideWith((ref) async => details),
            importMapDataProvider(query).overrideWith(
              (ref) async => ImportMapData(
                stagedFeatures: <ImportedFeature>[
                  _importedFeature('feature-1', 'pending_review', 35.5, 33.9),
                  _importedFeature('feature-2', 'approved', 35.55, 33.95),
                ],
                approvedProjectFeatures: <MapFeatureSummary>[
                  _approvedFeature(),
                ],
              ),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: ImportMapScreen(
                importId: 'import-1',
                projectId: 'project-1',
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Import Project'), findsOneWidget);
      expect(find.textContaining('2 imported features'), findsOneWidget);
      expect(find.byType(FlutterMap), findsOneWidget);
    },
  );

  testWidgets('import feature details show only comments for that feature', (
    tester,
  ) async {
    const query = ImportMapQuery(
      importId: 'import-1',
      projectId: 'project-1',
      minLon: 35.094,
      minLat: 33.045,
      maxLon: 36.645,
      maxLat: 34.695,
      zoom: 8,
    );
    final details = GisImportDetails(
      job: _job(),
      previewFeatures: const <ImportedFeature>[],
      previewSummary: const ImportPreviewSummary(
        geometryFeatureCount: 2,
        previewFeatureCount: 2,
        outsideWorkspaceFeatureCount: 0,
      ),
      comments: <ImportComment>[
        ImportComment(
          id: 'comment-1',
          importJobId: 'import-1',
          authorUserId: 'admin-1',
          authorName: 'Admin Reviewer',
          authorRole: 'admin',
          commentText: 'This comment belongs to feature one.',
          importFeatureId: 'feature-1',
          featureDisplayTitle: 'Feature one',
          createdAt: DateTime(2026, 5, 3, 12),
        ),
        ImportComment(
          id: 'comment-2',
          importJobId: 'import-1',
          authorUserId: 'admin-1',
          authorName: 'Admin Reviewer',
          authorRole: 'admin',
          commentText: 'This comment belongs to feature two.',
          importFeatureId: 'feature-2',
          featureDisplayTitle: 'Feature two',
          createdAt: DateTime(2026, 5, 3, 12, 1),
        ),
        ImportComment(
          id: 'comment-3',
          importJobId: 'import-1',
          authorUserId: 'admin-1',
          authorName: 'Admin Reviewer',
          authorRole: 'admin',
          commentText: 'This import-level comment is not feature-specific.',
          createdAt: DateTime(2026, 5, 3, 12, 2),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(
            (_) => _AuthenticatedAuthController(_session()),
          ),
          importDetailsProvider(
            'import-1',
          ).overrideWith((ref) async => details),
          importMapDataProvider(query).overrideWith(
            (ref) async => ImportMapData(
              stagedFeatures: <ImportedFeature>[
                _importedFeature('feature-1', 'pending_review', 35.5, 33.9),
                _importedFeature('feature-2', 'approved', 35.55, 33.95),
              ],
              approvedProjectFeatures: <MapFeatureSummary>[_approvedFeature()],
            ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: ImportMapScreen(
              importId: 'import-1',
              projectId: 'project-1',
              initialFeatureId: 'feature-1',
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Feature comments'), findsOneWidget);
    expect(find.text('This comment belongs to feature one.'), findsOneWidget);
    expect(find.text('This comment belongs to feature two.'), findsNothing);
    expect(
      find.text('This import-level comment is not feature-specific.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
