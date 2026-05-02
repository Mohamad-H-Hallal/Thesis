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
import 'package:lebanese_gis_mobile/features/map/domain/map_feature.dart';
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
    this.reviewedDetails,
    this.reviewedFeatures,
  });

  GisImportDetails details;
  List<ImportedFeature> features;
  final GisImportDetails? reviewedDetails;
  final List<ImportedFeature>? reviewedFeatures;
  final List<String?> requestedIssues = <String?>[];
  int featurePageRequests = 0;
  int detailRequests = 0;

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
  Future<GisImportDetails> fetchImportDetails(String importId) async {
    detailRequests += 1;
    return details;
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
  }) async => const ImportMapData(
    stagedFeatures: <ImportedFeature>[],
    approvedProjectFeatures: <MapFeatureSummary>[],
  );

  @override
  Future<ImportedFeature> fetchImportFeatureById({
    required String importId,
    required String featureId,
  }) async {
    return features.firstWhere((item) => item.id == featureId);
  }

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
    String? search,
    String? featureType,
    String? geometryType,
    int page = 1,
    int limit = 20,
  }) async {
    featurePageRequests += 1;
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
  }) async {
    if (reviewedDetails != null) {
      details = reviewedDetails!;
    }
    if (reviewedFeatures != null) {
      features = reviewedFeatures!;
    }
    return details.job;
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
  }) async {
    final nextComment = ImportComment(
      id: 'comment-${details.comments.length + 1}',
      importJobId: importId,
      authorUserId: 'admin-1',
      authorName: 'GIS Super Administrator',
      authorRole: 'admin',
      commentText: comment,
      importFeatureId: featureId,
      featureDisplayTitle: featureId == null
          ? null
          : _featureTitleForComment(featureId),
      createdAt: DateTime(2026, 5, 3, 12),
    );
    details = GisImportDetails(
      job: details.job,
      previewFeatures: details.previewFeatures,
      previewSummary: details.previewSummary,
      comments: <ImportComment>[...details.comments, nextComment],
    );
    return nextComment;
  }

  @override
  Future<String> downloadImport(String importId) async =>
      '/mock/imports/$importId.geojson';

  String? _featureTitleForComment(String featureId) {
    for (final feature in features) {
      if (feature.id == featureId) {
        return feature.displayTitle;
      }
    }
    return null;
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

AuthSession _contributorSession() {
  return const AuthSession(
    accessToken: 'token',
    refreshToken: 'refresh',
    user: AppUser(
      id: 'contributor-1',
      fullName: 'Field Contributor',
      email: 'contributor@example.com',
      role: UserRole.contributor,
    ),
  );
}

GisImportJob _job({
  required String status,
  Map<String, dynamic> validationSummary = const <String, dynamic>{},
  String? processingMessage,
  List<String> geometryTypes = const <String>['Point'],
  int geometryCount = 1,
  int pendingFeatureCount = 0,
  int approvedFeatureCount = 0,
  int rejectedFeatureCount = 0,
  int? failedFeatureCount,
  int warningCount = 0,
  int? errorCount,
  DateTime? updatedAt,
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
    geometryCount: geometryCount,
    pendingFeatureCount: pendingFeatureCount,
    approvedFeatureCount: approvedFeatureCount,
    rejectedFeatureCount: rejectedFeatureCount,
    failedFeatureCount: failedFeatureCount ?? (status == 'failed' ? 1 : 0),
    warningCount: warningCount,
    errorCount: errorCount ?? (status == 'failed' ? 1 : 0),
    geometryTypes: geometryTypes,
    fileMetadata: const <String, dynamic>{},
    validationSummary: validationSummary,
    processingMessage: processingMessage,
    reviewScope: 'admin',
    uploadedAt: DateTime(2026, 4, 25),
    createdAt: DateTime(2026, 4, 25),
    updatedAt: updatedAt ?? DateTime(2026, 4, 25),
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

ImportedFeature _hiddenAccuracyWarningFeature() {
  return ImportedFeature(
    id: 'feature-3',
    importJobId: 'import-1',
    sourceIndex: 2,
    displayTitle: 'Imported line feature',
    geometryType: 'LineString',
    geometry: const <String, dynamic>{
      'type': 'LineString',
      'coordinates': <dynamic>[
        <double>[35.48, 33.89],
        <double>[35.49, 33.90],
      ],
    },
    attributes: const <String, dynamic>{
      'name': 'Imported line feature',
      'feat_id': 'abc-123',
      'accuracy_meters': 7,
    },
    status: 'failed',
    validationWarnings: const <String>[
      'Attributes not defined in the project form were kept: feat_id, accuracy_meters',
    ],
    validationErrors: const <String>[
      'Missing required attribute: feature_type',
    ],
    validationReport: const <String, dynamic>{},
    createdAt: DateTime(2026, 4, 25),
    updatedAt: DateTime(2026, 4, 25),
  );
}

ImportedFeature _reviewableFeature({required String status}) {
  return ImportedFeature(
    id: 'feature-review-1',
    importJobId: 'import-1',
    sourceIndex: 0,
    displayTitle: 'Mountain',
    geometryType: 'Point',
    geometry: const <String, dynamic>{
      'type': 'Point',
      'coordinates': <double>[35.48, 33.89],
    },
    attributes: const <String, dynamic>{
      'feature_type': 'Mountain',
      'name': 'Mountain',
    },
    status: status,
    validationWarnings: const <String>[],
    validationErrors: const <String>[],
    validationReport: const <String, dynamic>{},
    createdAt: DateTime(2026, 4, 25),
    updatedAt: DateTime(2026, 4, 25),
  );
}

void main() {
  testWidgets('processing import shows processing card instead of map', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2200);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

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
    expect(repository.featurePageRequests, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('import section shortcuts scroll to mounted sections', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

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

    await tester.pumpAndSettle();

    final scrollableState = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    expect(scrollableState.position.pixels, 0);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Features (1)'));
    await tester.pumpAndSettle();

    expect(scrollableState.position.pixels, greaterThan(0));
    expect(find.text('Staged features (1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('contributors do not see reviewer file actions', (tester) async {
    final repository = _FakeImportsRepository(
      details: GisImportDetails(
        job: _job(status: 'failed'),
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
            (_) => _AuthenticatedAuthController(_contributorSession()),
          ),
          importsRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ImportDetailScreen(importId: 'import-1')),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('File actions'), findsNothing);
    expect(find.text('Download file'), findsNothing);
    expect(find.text('Add comment'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed import outside Lebanon shows file issues without map exception',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 2200);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

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

      await tester.scrollUntilVisible(find.text('File-wide issues'), 300);
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

  testWidgets(
    'preview stays visible for in-workspace geometry when only some staged features are outside Lebanon',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 2200);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final repository = _FakeImportsRepository(
        details: GisImportDetails(
          job: _job(
            status: 'failed',
            validationSummary: const <String, dynamic>{
              'top_warnings': <Map<String, dynamic>>[
                <String, dynamic>{
                  'message':
                      'Geometry falls outside the Lebanon workspace bounds.',
                  'count': 1,
                },
              ],
            },
          ),
          previewFeatures: <ImportedFeature>[_missingFeatureTypeFeature()],
          previewSummary: const ImportPreviewSummary(
            geometryFeatureCount: 2,
            previewFeatureCount: 1,
            outsideWorkspaceFeatureCount: 1,
          ),
        ),
        features: <ImportedFeature>[_missingFeatureTypeFeature()],
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

      await tester.scrollUntilVisible(find.text('Import map').last, 300);
      await tester.pumpAndSettle();

      expect(find.byType(FlutterMap), findsOneWidget);
      expect(
        find.textContaining(
          '1 staged feature(s) fall outside the Lebanon workspace',
        ),
        findsOneWidget,
      );
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
        previewFeatures: const <ImportedFeature>[],
        previewSummary: const ImportPreviewSummary(
          geometryFeatureCount: 2,
          previewFeatureCount: 0,
          outsideWorkspaceFeatureCount: 2,
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

    await tester.tap(
      find
          .widgetWithText(
            DropdownButtonFormField<String?>,
            'All staged features',
          )
          .last,
    );
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

  testWidgets('import summary uses friendly geometry labels', (tester) async {
    final repository = _FakeImportsRepository(
      details: GisImportDetails(
        job: _job(
          status: 'pending_review',
          geometryTypes: const <String>['LineString'],
        ),
        previewFeatures: const <ImportedFeature>[],
        previewSummary: const ImportPreviewSummary(
          geometryFeatureCount: 2,
          previewFeatureCount: 2,
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

    await tester.pumpAndSettle();

    expect(find.text('Line feature'), findsOneWidget);
    expect(find.text('LineString'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('comments are separated and use readable feature labels', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2200);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final repository = _FakeImportsRepository(
      details: GisImportDetails(
        job: _job(status: 'failed'),
        previewFeatures: const <ImportedFeature>[],
        previewSummary: const ImportPreviewSummary(
          geometryFeatureCount: 0,
          previewFeatureCount: 0,
          outsideWorkspaceFeatureCount: 0,
        ),
        comments: <ImportComment>[
          ImportComment(
            id: 'comment-1',
            importJobId: 'import-1',
            authorUserId: 'admin-1',
            authorName: 'GIS Super Administrator',
            authorRole: 'super_admin',
            commentText: 'change the feature type',
            importFeatureId: 'feature-1',
            featureDisplayTitle: 'Mountain LineString',
            createdAt: DateTime(2026, 5, 2, 22, 59),
          ),
          ImportComment(
            id: 'comment-2',
            importJobId: 'import-1',
            authorUserId: 'admin-1',
            authorName: 'GIS Super Administrator',
            authorRole: 'super_admin',
            commentText: 'where this comment appear',
            importFeatureId: 'feature-2',
            featureDisplayTitle: 'Meadow LineString',
            createdAt: DateTime(2026, 5, 2, 23),
          ),
        ],
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

    await tester.pumpAndSettle();

    expect(find.text('Comments'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('change the feature type'), findsOneWidget);
    expect(find.text('where this comment appear'), findsOneWidget);
    expect(find.text('Mountain'), findsOneWidget);
    expect(find.text('Meadow'), findsOneWidget);
    expect(find.text('Mountain LineString'), findsNothing);
    expect(find.text('Meadow LineString'), findsNothing);
    expect(find.text('Open on map'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('staged feature cards show their own feature comments', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2200);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final feature = _missingFeatureTypeFeature();
    final repository = _FakeImportsRepository(
      details: GisImportDetails(
        job: _job(status: 'failed'),
        previewFeatures: const <ImportedFeature>[],
        previewSummary: const ImportPreviewSummary(
          geometryFeatureCount: 1,
          previewFeatureCount: 0,
          outsideWorkspaceFeatureCount: 0,
        ),
        comments: <ImportComment>[
          ImportComment(
            id: 'comment-1',
            importJobId: 'import-1',
            authorUserId: 'admin-1',
            authorName: 'GIS Super Administrator',
            authorRole: 'super_admin',
            commentText: 'This feature needs a clearer type.',
            importFeatureId: feature.id,
            featureDisplayTitle: feature.displayTitle,
            createdAt: DateTime(2026, 5, 3, 12),
          ),
        ],
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

    expect(find.text('Feature comments'), findsOneWidget);
    expect(find.text('This feature needs a clearer type.'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('adding an import comment refreshes the page immediately', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2200);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final repository = _FakeImportsRepository(
      details: GisImportDetails(
        job: _job(status: 'failed'),
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

    await tester.pumpAndSettle();

    expect(find.text('Comments (0)'), findsOneWidget);
    expect(find.text('Please fix the feature type.'), findsNothing);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Add comment'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).last,
      'Please fix the feature type.',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(repository.detailRequests, greaterThan(1));
    expect(find.text('Comments (1)'), findsOneWidget);
    expect(find.text('Please fix the feature type.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('review action refreshes displayed counts and staged features', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2200);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final pendingFeature = _reviewableFeature(status: 'pending_review');
    final approvedFeature = _reviewableFeature(status: 'approved');
    final repository = _FakeImportsRepository(
      details: GisImportDetails(
        job: _job(
          status: 'pending_review',
          geometryCount: 1,
          pendingFeatureCount: 1,
          approvedFeatureCount: 0,
          failedFeatureCount: 0,
          errorCount: 0,
        ),
        previewFeatures: <ImportedFeature>[pendingFeature],
        previewSummary: const ImportPreviewSummary(
          geometryFeatureCount: 1,
          previewFeatureCount: 1,
          outsideWorkspaceFeatureCount: 0,
        ),
      ),
      features: <ImportedFeature>[pendingFeature],
      reviewedDetails: GisImportDetails(
        job: _job(
          status: 'approved',
          geometryCount: 1,
          pendingFeatureCount: 0,
          approvedFeatureCount: 1,
          failedFeatureCount: 0,
          errorCount: 0,
          updatedAt: DateTime(2026, 4, 25, 1),
        ),
        previewFeatures: <ImportedFeature>[approvedFeature],
        previewSummary: const ImportPreviewSummary(
          geometryFeatureCount: 1,
          previewFeatureCount: 1,
          outsideWorkspaceFeatureCount: 0,
        ),
      ),
      reviewedFeatures: <ImportedFeature>[approvedFeature],
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

    expect(find.text('1 pending review'), findsWidgets);
    expect(find.text('0 approved'), findsWidgets);

    await tester.tap(
      find.widgetWithText(FilledButton, 'Approve all reviewable'),
    );
    await tester.pumpAndSettle();

    expect(repository.detailRequests, greaterThan(1));
    expect(find.text('0 pending review'), findsWidgets);
    expect(find.text('1 approved'), findsWidgets);
    expect(find.text('approved'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('import warnings hide accuracy_meters but keep real fields', (
    tester,
  ) async {
    final feature = _hiddenAccuracyWarningFeature();
    final repository = _FakeImportsRepository(
      details: GisImportDetails(
        job: _job(
          status: 'failed',
          validationSummary: const <String, dynamic>{
            'top_warnings': <Map<String, dynamic>>[
              <String, dynamic>{
                'message':
                    'Attributes not defined in the project form were kept: feat_id, accuracy_meters',
                'count': 1,
              },
            ],
          },
        ),
        previewFeatures: const <ImportedFeature>[],
        previewSummary: const ImportPreviewSummary(
          geometryFeatureCount: 1,
          previewFeatureCount: 0,
          outsideWorkspaceFeatureCount: 0,
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
    await tester.scrollUntilVisible(find.text('File-wide issues'), 300);
    await tester.pumpAndSettle();

    expect(find.textContaining('feat_id'), findsWidgets);
    expect(find.textContaining('accuracy_meters'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
