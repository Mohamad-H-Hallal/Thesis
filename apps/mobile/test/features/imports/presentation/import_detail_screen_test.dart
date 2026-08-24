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
    this.pageFeatures,
    this.quickMapPreview,
    this.reviewedDetails,
    this.reviewedFeatures,
    this.reviewDelay = Duration.zero,
  });

  GisImportDetails details;
  List<ImportedFeature> features;
  List<ImportedFeature>? pageFeatures;
  final ImportQuickMapPreview? quickMapPreview;
  final GisImportDetails? reviewedDetails;
  final List<ImportedFeature>? reviewedFeatures;
  final Duration reviewDelay;
  final List<String?> requestedIssues = <String?>[];
  final List<List<String>?> reviewedFeatureIds = <List<String>?>[];
  final List<String?> reviewFilterStatuses = <String?>[];
  final List<String?> reviewFilterIssues = <String?>[];
  final List<String> reviewStatuses = <String>[];
  int featurePageRequests = 0;
  int featureByIdRequests = 0;
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
  Future<ImportQuickMapPreview> fetchImportQuickMapPreview({
    required String importId,
  }) async {
    final preview = quickMapPreview;
    if (preview != null) {
      return preview;
    }
    final drawable = details.previewFeatures
        .where((feature) => feature.geometry != null)
        .toList(growable: false);
    return ImportQuickMapPreview(
      totalFeatureCount: details.job.geometryCount,
      geometryFeatureCount: details.previewSummary.geometryFeatureCount,
      renderedFeatureCount: drawable.length,
      isClustered: false,
      statusCounts: <String, int>{
        details.job.status: details.job.geometryCount,
      },
      features: drawable,
    );
  }

  @override
  Future<ImportedFeature> fetchImportFeatureById({
    required String importId,
    required String featureId,
  }) async {
    featureByIdRequests += 1;
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
    final sourceFeatures = pageFeatures ?? features;
    final filtered = status == null
        ? sourceFeatures
        : sourceFeatures
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
    final start = (page - 1) * limit;
    final pageItems = issueFiltered
        .skip(start)
        .take(limit)
        .toList(growable: false);
    return PaginatedResult<ImportedFeature>(
      items: pageItems,
      page: page,
      limit: limit,
      total: issueFiltered.length,
      hasMore: start + pageItems.length < issueFiltered.length,
    );
  }

  @override
  Future<GisImportJob> reviewImport({
    required String importId,
    required String status,
    String? reason,
    List<String>? featureIds,
    String? filterStatus,
    String? filterIssue,
    String? filterSearch,
    String? filterGeometryType,
    String? filterFeatureType,
  }) async {
    reviewedFeatureIds.add(featureIds);
    reviewFilterStatuses.add(filterStatus);
    reviewFilterIssues.add(filterIssue);
    reviewStatuses.add(status);
    if (reviewDelay > Duration.zero) {
      await Future<void>.delayed(reviewDelay);
    }
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
    ImportSourceProvenance? provenance,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<GisImportJob> updateImportProvenance({
    required String importId,
    required ImportSourceProvenance provenance,
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

ImportedFeature _reviewableFeature({
  required String status,
  String id = 'feature-review-1',
  String displayTitle = 'Mountain',
  int sourceIndex = 0,
  Map<String, dynamic>? geometry = const <String, dynamic>{
    'type': 'Point',
    'coordinates': <double>[35.48, 33.89],
  },
  Map<String, dynamic> attributes = const <String, dynamic>{
    'feature_type': 'Mountain',
    'name': 'Mountain',
  },
  Map<String, dynamic> summaryAttributes = const <String, dynamic>{},
  int attributeCount = 0,
  List<String> validationWarnings = const <String>[],
  List<String> validationErrors = const <String>[],
  bool isSummary = false,
}) {
  return ImportedFeature(
    id: id,
    importJobId: 'import-1',
    sourceIndex: sourceIndex,
    displayTitle: displayTitle,
    geometryType: 'Point',
    geometry: geometry,
    attributes: attributes,
    summaryAttributes: summaryAttributes,
    attributeCount: attributeCount,
    status: status,
    validationWarnings: validationWarnings,
    validationErrors: validationErrors,
    validationReport: const <String, dynamic>{},
    isSummary: isSummary,
    createdAt: DateTime(2026, 4, 25),
    updatedAt: DateTime(2026, 4, 25),
  );
}

ImportedFeature _previewPolygonFeature({
  required String id,
  required int clusterCount,
}) {
  return ImportedFeature(
    id: id,
    importJobId: 'import-1',
    sourceIndex: 0,
    displayTitle: '$clusterCount staged feature preview geometry',
    geometryType: 'Polygon',
    geometry: const <String, dynamic>{
      'type': 'Polygon',
      'coordinates': <dynamic>[
        <dynamic>[
          <double>[35.48, 33.88],
          <double>[35.52, 33.88],
          <double>[35.52, 33.92],
          <double>[35.48, 33.92],
          <double>[35.48, 33.88],
        ],
      ],
    },
    attributes: const <String, dynamic>{},
    status: 'pending_review',
    validationWarnings: const <String>[],
    validationErrors: const <String>[],
    validationReport: const <String, dynamic>{},
    isSummary: true,
    isAggregate: true,
    clusterCount: clusterCount,
    createdAt: DateTime(2026, 4, 25),
    updatedAt: DateTime(2026, 4, 25),
  );
}

ImportedFeature _summaryFeatureFrom(
  ImportedFeature feature,
  Map<String, dynamic> requiredAttributes,
) {
  return ImportedFeature(
    id: feature.id,
    importJobId: feature.importJobId,
    sourceIndex: feature.sourceIndex,
    sourceIdentifier: feature.sourceIdentifier,
    displayTitle: feature.displayTitle,
    sourceFeatureName: feature.sourceFeatureName,
    geometryType: feature.geometryType,
    geometry: null,
    attributes: requiredAttributes,
    summaryAttributes: requiredAttributes,
    attributeCount: feature.attributes.length,
    status: feature.status,
    validationWarnings: feature.validationWarnings,
    validationErrors: feature.validationErrors,
    validationReport: feature.validationReport,
    duplicateFeatureId: feature.duplicateFeatureId,
    approvedFeatureId: feature.approvedFeatureId,
    reviewedByUserId: feature.reviewedByUserId,
    reviewedByName: feature.reviewedByName,
    reviewedAt: feature.reviewedAt,
    approvedAt: feature.approvedAt,
    reviewReason: feature.reviewReason,
    isSummary: true,
    createdAt: feature.createdAt,
    updatedAt: feature.updatedAt,
  );
}

ImportedFeature _l4CanonicalDuplicateFeature() {
  return ImportedFeature(
    id: 'feature-l4-1',
    importJobId: 'import-1',
    sourceIndex: 0,
    displayTitle: 'Imported polygon',
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
    attributes: const <String, dynamic>{
      'L4_descr': 'Olives',
      'feature_type': 'Olives',
      'crop_type': 'Olives',
    },
    status: 'failed',
    validationWarnings: const <String>[],
    validationErrors: const <String>[],
    validationReport: const <String, dynamic>{},
    createdAt: DateTime(2026, 4, 25),
    updatedAt: DateTime(2026, 4, 25),
  );
}

ImportedFeature _invalidL4SelectFeature() {
  return ImportedFeature(
    id: 'feature-l4-invalid',
    importJobId: 'import-1',
    sourceIndex: 1,
    displayTitle: 'Invalid L4 descriptor',
    geometryType: 'Point',
    geometry: const <String, dynamic>{
      'type': 'Point',
      'coordinates': <double>[35.48, 33.89],
    },
    attributes: const <String, dynamic>{'L4_descr': 'Bananas'},
    status: 'failed',
    validationWarnings: const <String>[],
    validationErrors: const <String>[
      'Invalid value for L4_descr: Bananas. Allowed values: Olives, Fruit Trees.',
    ],
    validationReport: const <String, dynamic>{},
    createdAt: DateTime(2026, 4, 25),
    updatedAt: DateTime(2026, 4, 25),
  );
}

ImportedFeature _ringSelfIntersectionFeature() {
  return ImportedFeature(
    id: 'feature-ring-self-intersection',
    importJobId: 'import-1',
    sourceIndex: 2,
    sourceIdentifier: 'source-parcel-123',
    sourceFeatureName: 'Self-intersecting polygon',
    displayTitle: 'Self-intersecting polygon',
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
    attributes: const <String, dynamic>{'OBJECTID_1': '123'},
    status: 'failed',
    validationWarnings: const <String>[],
    validationErrors: const <String>['Ring Self-intersection[35.55 33.95]'],
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

      await tester.scrollUntilVisible(
        find
            .byKey(const ValueKey('import-validation-file-wide-issues-title'))
            .first,
        300,
        scrollable: find.byType(Scrollable).first,
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

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('import-preview-map-title')).first,
        300,
        scrollable: find.byType(Scrollable).first,
      );
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
      find.textContaining('Missing required field: Feature type').last,
    );
    await tester.pumpAndSettle();

    expect(
      repository.requestedIssues,
      contains('Missing required attribute: feature_type'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'large import list renders the server page instead of preview features',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 2600);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final previewFeatures = List<ImportedFeature>.generate(
        60,
        (index) => _reviewableFeature(
          status: 'pending_review',
          id: 'preview-$index',
          displayTitle: 'Preview-only ${index + 1}',
        ),
      );
      final fullFeatures = List<ImportedFeature>.generate(
        45,
        (index) => _reviewableFeature(
          status: 'pending_review',
          id: 'page-$index',
          displayTitle: 'Page row ${index + 1}',
          geometry: null,
          sourceIndex: index,
          attributes: <String, dynamic>{
            'feature_type': index.isEven ? 'olive' : 'cedar',
            'name': 'Page row ${index + 1}',
            'OBJECTID_1': index + 1,
            'notes': 'Long note ${index + 1} kept out of list summaries',
          },
        ),
      );
      final pageFeatures = List<ImportedFeature>.generate(
        45,
        (index) => _reviewableFeature(
          status: 'pending_review',
          id: 'page-$index',
          displayTitle: 'Page row ${index + 1}',
          geometry: null,
          sourceIndex: index,
          attributes: <String, dynamic>{
            'feature_type': index.isEven ? 'olive' : 'cedar',
          },
          summaryAttributes: <String, dynamic>{
            'feature_type': index.isEven ? 'olive' : 'cedar',
          },
          attributeCount: 4,
          isSummary: true,
        ),
      );
      final repository = _FakeImportsRepository(
        details: GisImportDetails(
          job: _job(
            status: 'pending_review',
            geometryCount: 1400,
            pendingFeatureCount: 1400,
          ),
          previewFeatures: previewFeatures,
          previewSummary: const ImportPreviewSummary(
            geometryFeatureCount: 1400,
            previewFeatureCount: 20,
            outsideWorkspaceFeatureCount: 0,
          ),
        ),
        quickMapPreview: ImportQuickMapPreview(
          totalFeatureCount: 1400,
          geometryFeatureCount: 1400,
          renderedFeatureCount: 3,
          isClustered: true,
          statusCounts: const <String, int>{'pending_review': 1400},
          bounds: const ImportMapBounds(
            minLon: 35.1,
            minLat: 33.1,
            maxLon: 36.2,
            maxLat: 34.4,
          ),
          features: <ImportedFeature>[
            _previewPolygonFeature(id: 'preview-1', clusterCount: 600),
            _previewPolygonFeature(id: 'preview-2', clusterCount: 500),
            _previewPolygonFeature(id: 'preview-3', clusterCount: 300),
          ],
        ),
        features: fullFeatures,
        pageFeatures: pageFeatures,
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

      expect(repository.featurePageRequests, 1);
      expect(find.text('Page row 1'), findsOneWidget);
      expect(find.text('Page row 20'), findsOneWidget);
      expect(find.text('Page row 21'), findsNothing);
      expect(find.text('Preview-only 1'), findsNothing);
      expect(find.text('Required attributes'), findsWidgets);
      expect(find.text('OBJECTID_1'), findsNothing);
      expect(
        find.text('Open details to view all imported attributes.'),
        findsNothing,
      );
      expect(
        find.text('Tap the preview to open the full import map.'),
        findsOneWidget,
      );
      expect(find.text('Long note 1 kept out of list summaries'), findsNothing);
      expect(
        find.byKey(const ValueKey('import-preview-map-count')),
        findsNothing,
      );
      final polygonLayer =
          tester.widget(find.byType(PolygonLayer).first) as dynamic;
      expect(polygonLayer.polygons, isNotEmpty);
      final markerLayer = tester.widget<MarkerLayer>(
        find.byType(MarkerLayer).first,
      );
      expect(markerLayer.markers, isEmpty);
      expect(
        find.byKey(const ValueKey('import-preview-dot-preview-1')),
        findsNothing,
      );
      final commentButtonLabel = tester.widget<Text>(
        find
            .descendant(
              of: find.widgetWithText(OutlinedButton, 'Comment').first,
              matching: find.text('Comment'),
            )
            .first,
      );
      expect(commentButtonLabel.maxLines, 1);
      expect(commentButtonLabel.softWrap, isFalse);

      await tester.tap(
        find.widgetWithText(OutlinedButton, 'View details').first,
      );
      await tester.pumpAndSettle();

      expect(repository.featureByIdRequests, 1);
      expect(find.text('Imported attributes'), findsOneWidget);
      expect(
        find.text('Long note 1 kept out of list summaries'),
        findsOneWidget,
      );
      expect(find.text('OBJECTID_1'), findsOneWidget);

      Navigator.of(tester.element(find.text('Imported attributes'))).pop();
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.widgetWithText(OutlinedButton, 'Show more').last,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Show more').last);
      await tester.pumpAndSettle();

      expect(repository.featurePageRequests, 2);
      expect(find.text('Page row 21'), findsOneWidget);
      expect(find.text('Page row 40'), findsOneWidget);
      expect(find.text('Page row 41'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'import details show dynamic schema fields and readable validation errors',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 2400);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final l4Feature = _l4CanonicalDuplicateFeature();
      final invalidSelectFeature = _invalidL4SelectFeature();
      final ringFeature = _ringSelfIntersectionFeature();
      final repository = _FakeImportsRepository(
        details: GisImportDetails(
          job: _job(
            status: 'failed',
            geometryCount: 3,
            failedFeatureCount: 3,
            errorCount: 3,
            validationSummary: const <String, dynamic>{
              'top_errors': <Map<String, dynamic>>[
                <String, dynamic>{
                  'message': 'Missing required field: L4_descr',
                  'count': 1,
                },
                <String, dynamic>{
                  'message':
                      'Invalid value for L4_descr: Bananas. Allowed values: Olives, Fruit Trees.',
                  'count': 1,
                },
                <String, dynamic>{
                  'message': 'Ring Self-intersection[35.55 33.95]',
                  'count': 1,
                },
              ],
            },
          ),
          previewFeatures: const <ImportedFeature>[],
          previewSummary: const ImportPreviewSummary(
            geometryFeatureCount: 3,
            previewFeatureCount: 0,
            outsideWorkspaceFeatureCount: 0,
          ),
        ),
        features: <ImportedFeature>[
          l4Feature,
          invalidSelectFeature,
          ringFeature,
        ],
        pageFeatures: <ImportedFeature>[
          _summaryFeatureFrom(l4Feature, const <String, dynamic>{
            'L4_descr': 'Olives',
            'feature_type': 'Olives',
            'crop_type': 'Olives',
          }),
          _summaryFeatureFrom(invalidSelectFeature, const <String, dynamic>{
            'L4_descr': 'Bananas',
          }),
          _summaryFeatureFrom(ringFeature, const <String, dynamic>{}),
        ],
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
      await tester.scrollUntilVisible(
        find.text('Staged features (3)').first,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('L4_descr'), findsWidgets);
      expect(find.text('Feature Type'), findsNothing);
      expect(find.text('Crop Type'), findsNothing);
      expect(
        find.textContaining(
          'Invalid value for L4_descr: Bananas. Allowed values: Olives, Fruit Trees.',
        ),
        findsWidgets,
      );
      expect(
        find.textContaining(
          'Invalid polygon geometry: ring self-intersection. Fix the geometry in GIS software or exclude this feature.',
        ),
        findsWidgets,
      );
      expect(find.textContaining('Ring Self-intersection['), findsNothing);
      expect(find.text('OBJECTID_1'), findsNothing);
      expect(find.text('123'), findsNothing);

      await tester.tap(
        find.widgetWithText(OutlinedButton, 'View details').first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Imported attributes'), findsOneWidget);
      expect(find.text('Feature Type'), findsOneWidget);
      expect(find.text('Crop Type'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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
    expect(find.text('Open map'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('comment feature chip focuses linked staged feature in list', (
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
      pageFeatures: const <ImportedFeature>[],
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

    expect(find.text('This feature needs a clearer type.'), findsOneWidget);
    expect(find.text('Linked feature from comment'), findsNothing);

    await tester.tap(find.widgetWithText(ActionChip, feature.displayTitle));
    await tester.pumpAndSettle();

    expect(repository.featureByIdRequests, 1);
    expect(find.text('Linked feature from comment'), findsOneWidget);
    expect(find.text('Shown even if filters hide it'), findsOneWidget);
    expect(find.text(feature.displayTitle), findsWidgets);
    expect(find.text('Feature comments'), findsNothing);
    expect(find.text('This feature needs a clearer type.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'comment feature chip scrolls visible staged feature without fetch',
    (tester) async {
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
              commentText: 'This feature is already visible.',
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

      await tester.tap(find.widgetWithText(ActionChip, feature.displayTitle));
      await tester.pumpAndSettle();

      expect(repository.featureByIdRequests, 0);
      expect(find.text('Feature linked from comment'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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

    await tester.tap(find.widgetWithText(FilledButton, 'Approve all filtered'));
    await tester.pumpAndSettle();

    expect(repository.detailRequests, greaterThan(1));
    expect(find.text('0 pending review'), findsWidgets);
    expect(find.text('1 approved'), findsWidgets);
    expect(find.text('approved'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('approve all filtered shows loading state and sends filters', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2200);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final pendingFeature = _reviewableFeature(status: 'pending_review');
    final repository = _FakeImportsRepository(
      details: GisImportDetails(
        job: _job(
          status: 'pending_review',
          geometryCount: 25,
          pendingFeatureCount: 25,
          approvedFeatureCount: 0,
          failedFeatureCount: 0,
          errorCount: 0,
        ),
        previewFeatures: <ImportedFeature>[pendingFeature],
        previewSummary: const ImportPreviewSummary(
          geometryFeatureCount: 25,
          previewFeatureCount: 1,
          outsideWorkspaceFeatureCount: 0,
        ),
      ),
      features: <ImportedFeature>[pendingFeature],
      reviewedDetails: GisImportDetails(
        job: _job(
          status: 'approved',
          geometryCount: 25,
          pendingFeatureCount: 0,
          approvedFeatureCount: 25,
          failedFeatureCount: 0,
          errorCount: 0,
          updatedAt: DateTime(2026, 4, 25, 1),
        ),
        previewFeatures: <ImportedFeature>[
          _reviewableFeature(status: 'approved'),
        ],
        previewSummary: const ImportPreviewSummary(
          geometryFeatureCount: 25,
          previewFeatureCount: 1,
          outsideWorkspaceFeatureCount: 0,
        ),
      ),
      reviewedFeatures: <ImportedFeature>[
        _reviewableFeature(status: 'approved'),
      ],
      reviewDelay: const Duration(milliseconds: 100),
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
    await tester.tap(
      find.widgetWithText(
        DropdownButtonFormField<String?>,
        'All staged features',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pending').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Approve all filtered'));
    await tester.pump();

    expect(
      find.text('Approving all filtered reviewable features...'),
      findsOneWidget,
    );

    await tester.pumpAndSettle();

    expect(repository.reviewStatuses.last, 'approved');
    expect(repository.reviewedFeatureIds.last, isNull);
    expect(repository.reviewFilterStatuses.last, 'pending_review');
    expect(repository.reviewFilterIssues.last, isNull);
    expect(find.text('25 approved'), findsWidgets);
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
    await tester.scrollUntilVisible(
      find
          .byKey(const ValueKey('import-validation-file-wide-issues-title'))
          .first,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('feat_id'), findsWidgets);
    expect(find.textContaining('accuracy_meters'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
