import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:lebanese_gis_mobile/core/pagination/paginated_list_controller.dart';
import 'package:lebanese_gis_mobile/core/pagination/paginated_result.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/core/router/route_paths.dart';
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

GisImportJob _job({
  int geometryCount = 2,
  int pendingFeatureCount = 1,
  int approvedFeatureCount = 1,
  int rejectedFeatureCount = 0,
  int failedFeatureCount = 0,
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
    status: 'pending_review',
    geometryCount: geometryCount,
    pendingFeatureCount: pendingFeatureCount,
    approvedFeatureCount: approvedFeatureCount,
    rejectedFeatureCount: rejectedFeatureCount,
    failedFeatureCount: failedFeatureCount,
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
  double lat, {
  String? approvedFeatureId,
}) {
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
    approvedFeatureId: approvedFeatureId,
    createdAt: DateTime(2026, 4, 25),
    updatedAt: DateTime(2026, 4, 25),
  );
}

ImportedFeature _l4ImportMapFeature() {
  return ImportedFeature(
    id: 'feature-l4-1',
    importJobId: 'import-1',
    sourceIndex: 0,
    sourceIdentifier: 'source-parcel-123',
    sourceFeatureName: 'Self-intersecting polygon',
    displayTitle: 'Imported polygon',
    geometryType: 'Polygon',
    geometry: const <String, dynamic>{
      'type': 'Polygon',
      'coordinates': <dynamic>[
        <dynamic>[
          <double>[35.5, 33.9],
          <double>[35.6, 34.0],
          <double>[35.6, 33.9],
          <double>[35.5, 34.0],
          <double>[35.5, 33.9],
        ],
      ],
    },
    attributes: const <String, dynamic>{
      'L4_descr': 'Olives',
      'feature_type': 'Olives',
      'OBJECTID_1': '123',
    },
    status: 'failed',
    validationWarnings: const <String>[],
    validationErrors: const <String>[
      'Invalid value for L4_descr: Bananas. Allowed values: Olives, Fruit Trees.',
      'Ring Self-intersection[35.55 33.95]',
    ],
    validationReport: const <String, dynamic>{},
    createdAt: DateTime(2026, 4, 25),
    updatedAt: DateTime(2026, 4, 25),
  );
}

ImportedFeature _summaryImportedFeature(String id) {
  return ImportedFeature(
    id: id,
    importJobId: 'import-1',
    sourceIndex: 0,
    displayTitle: 'Summary-only feature',
    geometryType: 'Polygon',
    geometry: null,
    attributes: const <String, dynamic>{},
    summaryAttributes: const <String, dynamic>{'feature_type': 'Olives'},
    attributeCount: 12,
    status: 'pending_review',
    validationWarnings: const <String>[],
    validationErrors: const <String>[],
    validationReport: const <String, dynamic>{},
    isSummary: true,
    createdAt: DateTime(2026, 4, 25),
    updatedAt: DateTime(2026, 4, 25),
  );
}

ImportedFeature _fullPolygonImportedFeature(String id) {
  return ImportedFeature(
    id: id,
    importJobId: 'import-1',
    sourceIndex: 0,
    displayTitle: 'Full polygon feature',
    geometryType: 'Polygon',
    geometry: const <String, dynamic>{
      'type': 'Polygon',
      'coordinates': <dynamic>[
        <dynamic>[
          <double>[35.45, 33.35],
          <double>[35.46, 33.35],
          <double>[35.46, 33.36],
          <double>[35.45, 33.36],
          <double>[35.45, 33.35],
        ],
      ],
    },
    attributes: const <String, dynamic>{
      'feature_type': 'Olives',
      'source_name': 'Full row from feature API',
    },
    status: 'pending_review',
    validationWarnings: const <String>[],
    validationErrors: const <String>[],
    validationReport: const <String, dynamic>{},
    createdAt: DateTime(2026, 4, 25),
    updatedAt: DateTime(2026, 4, 25),
  );
}

ImportedFeature _aggregatePolygonImportFeature() {
  return ImportedFeature(
    id: 'cluster:approved:12:34',
    importJobId: 'import-1',
    sourceIndex: 0,
    displayTitle: '39 imported features',
    geometryType: 'Polygon',
    geometry: const <String, dynamic>{
      'type': 'Point',
      'coordinates': <double>[35.45, 33.35],
    },
    attributes: const <String, dynamic>{},
    status: 'approved',
    validationWarnings: const <String>[],
    validationErrors: const <String>[],
    validationReport: const <String, dynamic>{},
    isAggregate: true,
    clusterCount: 39,
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
        zoom: 7.4,
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

  testWidgets(
    'import map hides approved project context duplicate from same import',
    (tester) async {
      const query = ImportMapQuery(
        importId: 'import-1',
        projectId: 'project-1',
        minLon: 35.094,
        minLat: 33.045,
        maxLon: 36.645,
        maxLat: 34.695,
        zoom: 7.4,
      );
      final details = GisImportDetails(
        job: _job(
          geometryCount: 1,
          pendingFeatureCount: 0,
          approvedFeatureCount: 1,
        ),
        previewFeatures: const <ImportedFeature>[],
        previewSummary: const ImportPreviewSummary(
          geometryFeatureCount: 1,
          previewFeatureCount: 1,
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
                  _importedFeature(
                    'feature-2',
                    'approved',
                    35.52,
                    33.91,
                    approvedFeatureId: 'approved-1',
                  ),
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
      await tester.tap(find.byTooltip('Show quick filters'));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 imported feature'), findsWidgets);
      expect(find.text('0 project context features'), findsOneWidget);
      expect(find.text('1 project context feature'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'import map keeps polygon aggregate pins lightweight and non-detail',
    (tester) async {
      const query = ImportMapQuery(
        importId: 'import-1',
        projectId: 'project-1',
        minLon: 35.094,
        minLat: 33.045,
        maxLon: 36.645,
        maxLat: 34.695,
        zoom: 7.4,
      );
      final details = GisImportDetails(
        job: _job(
          geometryCount: 39,
          pendingFeatureCount: 0,
          approvedFeatureCount: 39,
        ),
        previewFeatures: const <ImportedFeature>[],
        previewSummary: const ImportPreviewSummary(
          geometryFeatureCount: 39,
          previewFeatureCount: 39,
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
                  _aggregatePolygonImportFeature(),
                ],
                approvedProjectFeatures: const <MapFeatureSummary>[],
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

      final markerCount = tester
          .widgetList<MarkerLayer>(find.byType(MarkerLayer))
          .fold<int>(0, (total, layer) => total + layer.markers.length);
      expect(markerCount, 1);
      expect(find.text('Valid featureId is required'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'imported feature browser fetches full feature before focusing details',
    (tester) async {
      var featureFetchCount = 0;
      const mapQuery = ImportMapQuery(
        importId: 'import-1',
        projectId: 'project-1',
        minLon: 35.094,
        minLat: 33.045,
        maxLon: 36.645,
        maxLat: 34.695,
        zoom: 7.4,
      );
      const browserQuery = ImportedFeatureListQuery(importId: 'import-1');
      final summaryFeature = _summaryImportedFeature('feature-summary-1');
      final fullFeature = _fullPolygonImportedFeature('feature-summary-1');
      final details = GisImportDetails(
        job: _job(
          geometryCount: 1,
          pendingFeatureCount: 1,
          approvedFeatureCount: 0,
        ),
        previewFeatures: const <ImportedFeature>[],
        previewSummary: const ImportPreviewSummary(
          geometryFeatureCount: 1,
          previewFeatureCount: 1,
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
            importMapDataProvider(mapQuery).overrideWith(
              (ref) async => ImportMapData(
                stagedFeatures: <ImportedFeature>[fullFeature],
                approvedProjectFeatures: const <MapFeatureSummary>[],
              ),
            ),
            paginatedImportFeaturesProvider(browserQuery).overrideWith(
              (ref) => PaginatedListController<ImportedFeature>(
                loadPage: ({required page, required limit}) async =>
                    PaginatedResult<ImportedFeature>(
                      items: <ImportedFeature>[summaryFeature],
                      page: page,
                      limit: limit,
                      total: 1,
                      hasMore: false,
                    ),
              ),
            ),
            importFeatureProvider.overrideWith((ref, query) async {
              featureFetchCount += 1;
              return fullFeature;
            }),
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
      await tester.tap(find.byTooltip('Browse imported features'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Summary-only feature'));
      await tester.pumpAndSettle();

      expect(featureFetchCount, 1);
      expect(find.text('Summary-only feature'), findsNothing);
      expect(find.text('Attributes'), findsOneWidget);
      expect(find.text('Olives'), findsAtLeastNWidgets(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('import feature details show only comments for that feature', (
    tester,
  ) async {
    var featureFetchCount = 0;
    const query = ImportMapQuery(
      importId: 'import-1',
      projectId: 'project-1',
      minLon: 35.094,
      minLat: 33.045,
      maxLon: 36.645,
      maxLat: 34.695,
      zoom: 7.4,
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
          importFeatureProvider.overrideWith((ref, query) async {
            featureFetchCount += 1;
            return _importedFeature(
              query.featureId,
              'pending_review',
              35.5,
              33.9,
            );
          }),
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
    expect(featureFetchCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'import map feature details show dynamic fields and validation messages',
    (tester) async {
      const query = ImportMapQuery(
        importId: 'import-1',
        projectId: 'project-1',
        minLon: 35.094,
        minLat: 33.045,
        maxLon: 36.645,
        maxLat: 34.695,
        zoom: 7.4,
      );
      final feature = _l4ImportMapFeature();
      final details = GisImportDetails(
        job: _job(
          geometryCount: 1,
          pendingFeatureCount: 0,
          approvedFeatureCount: 0,
          failedFeatureCount: 1,
        ),
        previewFeatures: const <ImportedFeature>[],
        previewSummary: const ImportPreviewSummary(
          geometryFeatureCount: 1,
          previewFeatureCount: 1,
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
                stagedFeatures: <ImportedFeature>[feature],
                approvedProjectFeatures: const <MapFeatureSummary>[],
              ),
            ),
            importFeatureProvider.overrideWith((ref, query) async => feature),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: ImportMapScreen(
                importId: 'import-1',
                projectId: 'project-1',
                initialFeatureId: 'feature-l4-1',
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('L4_descr'),
        240,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();

      expect(find.text('L4_descr'), findsOneWidget);
      expect(find.text('Feature Type'), findsNothing);
      expect(find.text('OBJECTID_1'), findsOneWidget);
      expect(find.text('123'), findsOneWidget);
      expect(
        find.textContaining(
          'Invalid value for L4_descr: Bananas. Allowed values: Olives, Fruit Trees.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Invalid polygon geometry: ring self-intersection. Fix the geometry in GIS software or exclude this feature.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Ring Self-intersection['), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'import map can focus approved project context from a route target',
    (tester) async {
      var projectFeatureFetchCount = 0;
      const query = ImportMapQuery(
        importId: 'import-1',
        projectId: 'project-1',
        minLon: 35.094,
        minLat: 33.045,
        maxLon: 36.645,
        maxLat: 34.695,
        zoom: 7.4,
      );
      final details = GisImportDetails(
        job: _job(),
        previewFeatures: const <ImportedFeature>[],
        previewSummary: const ImportPreviewSummary(
          geometryFeatureCount: 1,
          previewFeatureCount: 1,
          outsideWorkspaceFeatureCount: 0,
        ),
        comments: const <ImportComment>[],
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
                ],
                approvedProjectFeatures: <MapFeatureSummary>[
                  _approvedFeature(),
                ],
              ),
            ),
            projectFeatureDetailsProvider.overrideWith((ref, featureId) async {
              projectFeatureFetchCount += 1;
              return _approvedFeature();
            }),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: ImportMapScreen(
                importId: 'import-1',
                projectId: 'project-1',
                initialFeatureId: 'approved-1',
                initialFeatureSource: AppRoutes.focusSourceApprovedContext,
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(
        find.text('Approved project feature shown only as map context.'),
        findsOneWidget,
      );
      expect(find.text('Approved context feature'), findsWidgets);
      expect(projectFeatureFetchCount, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
