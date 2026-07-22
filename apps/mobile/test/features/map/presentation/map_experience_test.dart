import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/core/network/network_availability_base.dart';
import 'package:lebanese_gis_mobile/core/offline/local_models.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/core/router/route_paths.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_controller.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_engine.dart';
import 'package:lebanese_gis_mobile/features/ai/domain/ai_models.dart';
import 'package:lebanese_gis_mobile/features/ai/presentation/ai_providers.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';
import 'package:lebanese_gis_mobile/features/map/domain/current_location_service.dart';
import 'package:lebanese_gis_mobile/features/map/domain/map_feature.dart';
import 'package:lebanese_gis_mobile/features/map/presentation/screens/add_feature_screen.dart';
import 'package:lebanese_gis_mobile/features/map/presentation/screens/map_screen.dart';
import 'package:lebanese_gis_mobile/features/map/presentation/widgets/project_quick_map_card.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/project.dart';

import '../../../fakes/fake_ai_repository.dart';

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
    email: 'test@example.com',
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
      id: 'user-1',
      fullName: fullName ?? 'Collector',
      email: 'collector@example.com',
      role: UserRole.contributor,
      phone: phone,
    );
  }
}

class _AuthenticatedAuthController extends AuthController {
  _AuthenticatedAuthController(AuthSession session)
    : super(const _NoopAuthRepository()) {
    state = AuthState.authenticated(session);
  }
}

class _AlwaysOnlineNetworkAvailability implements NetworkAvailabilityService {
  const _AlwaysOnlineNetworkAvailability();

  @override
  Stream<bool> get onOnlineStatusChanged => const Stream<bool>.empty();

  @override
  Future<bool> isOnline() async => true;
}

class _FakeLocalStore extends LocalStore {
  @override
  Future<void> cacheProjects(List<ProjectSummary> projects) async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<void> enqueueSyncItem(SyncQueueItem item) async {}

  @override
  Future<List<ProjectSummary>> getCachedProjects() async =>
      const <ProjectSummary>[];

  @override
  Future<LocalDraftFeature?> getDraftById(String draftId) async => null;

  @override
  Future<void> discardDraft(String draftId) async {}

  @override
  Future<List<LocalDraftFeature>> getDrafts() async =>
      const <LocalDraftFeature>[];

  @override
  Future<List<SyncQueueItem>> getDueSyncItems(
    DateTime now, {
    int limit = 20,
  }) async => const <SyncQueueItem>[];

  @override
  Future<OfflineMapPackage?> getCurrentOfflineMapPackage({
    required String ownerUserId,
  }) async => null;

  @override
  Future<void> upsertOfflineProjectPackage(
    OfflineProjectPackage package,
  ) async {}

  @override
  Future<OfflineProjectPackage?> getOfflineProjectPackage({
    required String ownerUserId,
    required String projectId,
  }) async => null;

  @override
  Future<List<OfflineProjectPackage>> getOfflineProjectPackages({
    required String ownerUserId,
  }) async => const <OfflineProjectPackage>[];

  @override
  Future<void> deleteOfflineProjectPackage({
    required String ownerUserId,
    required String projectId,
  }) async {}

  @override
  Future<int> countOfflineProjectPackagesUsingBaseMap({
    required String ownerUserId,
    required String baseMapVersion,
  }) async => 0;

  @override
  Future<int> countUnsyncedDraftsForProject({
    required String ownerUserId,
    required String projectId,
  }) async => 0;

  @override
  Future<int> getPendingSyncCount() async => 0;

  @override
  Future<SyncQueueStats> getSyncQueueStats() async => const SyncQueueStats(
    pending: 0,
    processing: 0,
    failed: 0,
    conflict: 0,
    deadLetter: 0,
  );

  @override
  Future<void> initialize() async {}

  @override
  Future<void> markSyncConflict(
    SyncQueueItem item, {
    required String error,
  }) async {}

  @override
  Future<void> markSyncDeadLetter(
    SyncQueueItem item, {
    required String error,
  }) async {}

  @override
  Future<void> markSyncFailure(
    SyncQueueItem item, {
    required String error,
    required DateTime nextRetryAt,
  }) async {}

  @override
  Future<void> markSyncProcessing(String queueId) async {}

  @override
  Future<void> markSyncSuccess(
    SyncQueueItem item, {
    int? remoteVersion,
    String? draftStatus,
  }) async {}

  @override
  Future<void> seedIfEmpty({
    required List<ProjectSummary> projects,
    required List<LocalDraftFeature> drafts,
  }) async {}

  @override
  Future<void> updateDraftStatus(
    String draftId, {
    required String status,
    int? remoteVersion,
  }) async {}

  @override
  Future<void> upsertDraft(
    LocalDraftFeature draft, {
    bool enqueueSync = true,
  }) async {}

  @override
  Future<void> upsertOfflineMapPackage(OfflineMapPackage package) async {}
}

SyncController _buildSyncController() {
  final localStore = _FakeLocalStore();
  return SyncController(
    syncEngine: SyncEngine(
      localStore: localStore,
      apiClient: ApiClient(dio: Dio()),
    ),
    localStore: localStore,
    networkAvailability: const _AlwaysOnlineNetworkAvailability(),
  );
}

class _FakeCurrentLocationService implements CurrentLocationService {
  _FakeCurrentLocationService(this.snapshot);

  final CurrentLocationSnapshot snapshot;
  int callCount = 0;

  @override
  Future<CurrentLocationSnapshot> fetchCurrentLocation() async {
    callCount += 1;
    return snapshot;
  }
}

AuthSession _session(UserRole role) {
  return AuthSession(
    accessToken: 'token',
    refreshToken: 'refresh',
    user: AppUser(
      id: 'contributor-1',
      fullName: 'Field Collector',
      email: 'collector@example.com',
      role: role,
    ),
  );
}

ProjectSummary _projectSummary({
  String name = 'Olive Tree Census',
  String id = 'project-1',
  int approvedFeatures = 1,
  int pendingReviews = 1,
  CollectionFormSchema? collectionFormSchema,
}) {
  return ProjectSummary(
    id: id,
    name: name,
    category: 'Fruit Trees',
    status: 'active',
    assignedCollectors: 2,
    pendingReviews: pendingReviews,
    approvedFeatures: approvedFeatures,
    description: 'Lebanon field collection project.',
    currentUserAssignmentRole: ProjectAssignmentRole.contributor,
    currentUserAssignmentStatus: ProjectAssignmentStatus.approved,
    visibleToViewers: true,
    allowedGeometryTypes: const <String>['Point', 'LineString', 'Polygon'],
    collectionFormSchema:
        collectionFormSchema ??
        const CollectionFormSchema(
          version: 'v1.0',
          fields: <CollectionFormFieldSchema>[
            CollectionFormFieldSchema(
              key: 'tree_type',
              label: 'Tree type',
              type: CollectionFieldType.select,
              required: true,
              options: <String>['Olive', 'Citrus'],
            ),
          ],
        ),
  );
}

List<MapFeatureSummary> _projectFeatures() {
  return const <MapFeatureSummary>[
    MapFeatureSummary(
      id: 'feature-olive-001',
      projectId: 'project-1',
      status: 'approved',
      geometry: <String, dynamic>{
        'type': 'Point',
        'coordinates': <double>[35.5018, 33.8938],
      },
      attributes: <String, dynamic>{'tree_type': 'Olive', 'name': 'Mazami'},
      collectedBy: 'Rana',
      photoCount: 2,
    ),
    MapFeatureSummary(
      id: 'feature-line-002',
      projectId: 'project-1',
      status: 'pending_review',
      geometry: <String, dynamic>{
        'type': 'LineString',
        'coordinates': <List<double>>[
          <double>[35.52, 33.91],
          <double>[35.53, 33.92],
        ],
      },
      attributes: <String, dynamic>{'tree_type': 'Orchard'},
      collectedBy: 'Karim',
      photoCount: 0,
    ),
  ];
}

OfflineMapPackage _offlinePackage() {
  return OfflineMapPackage(
    ownerUserId: 'contributor-1',
    version: 'lebanon-satellite-v1',
    zoomLevelMin: 7,
    zoomLevelMax: 18,
    downloadedAt: DateTime.utc(2026, 4, 5),
    lastUpdatedAt: DateTime.utc(2026, 4, 5),
    tileCount: 24,
    sizeBytes: 1024 * 180,
    tileSource: 'ArcGIS World Imagery',
    isCurrent: true,
  );
}

AiOutputLayer _publishedAiLayer() {
  return AiOutputLayer(
    id: 'ai-layer-1',
    aiRunId: 'ai-run-1',
    projectId: 'project-1',
    layerType: 'classification',
    status: 'published',
    name: 'Published AI classification',
    publishedAt: DateTime.utc(2026, 6, 9),
    publishedBy: 'admin-1',
  );
}

AiLayerFeatureCollection _publishedAiFeatureCollection(AiOutputLayer layer) {
  return AiLayerFeatureCollection(
    layer: layer,
    features: const <AiLayerFeature>[
      AiLayerFeature(
        id: 'ai-feature-1',
        geometry: <String, dynamic>{
          'type': 'Point',
          'coordinates': <double>[35.5, 33.9],
        },
        properties: <String, dynamic>{
          'predicted_class': 'olives',
          'confidence': 0.91,
          'model_name': 'random_forest',
          'source': 'ai_prediction',
          'run_id': 'ai-run-1',
        },
      ),
      AiLayerFeature(
        id: 'ai-feature-2',
        geometry: <String, dynamic>{
          'type': 'Point',
          'coordinates': <double>[35.52, 33.92],
        },
        properties: <String, dynamic>{
          'predicted_class': 'citrus fruit trees',
          'confidence': 0.74,
          'model_name': 'random_forest',
          'source': 'ai_prediction',
          'run_id': 'ai-run-1',
        },
      ),
      AiLayerFeature(
        id: 'ai-feature-3',
        geometry: <String, dynamic>{
          'type': 'Point',
          'coordinates': <double>[35.54, 33.94],
        },
        properties: <String, dynamic>{
          'predicted_class': 'fruit trees',
          'confidence': 0.62,
          'model_name': 'random_forest',
          'source': 'ai_prediction',
          'run_id': 'ai-run-1',
        },
      ),
    ],
    featureCount: 1394,
    matchingFeatureCount: 1394,
    returnedFeatureCount: 3,
    classCounts: const <String, int>{
      'almonds': 0,
      'olives': 1147,
      'citrus fruit trees': 181,
      'fruit trees': 66,
    },
    geometryTypes: const <String>['Point'],
  );
}

Widget _wrapWithScope({
  required List<Override> overrides,
  required Widget child,
  FakeAiRepository? aiRepository,
}) {
  return ProviderScope(
    overrides: <Override>[
      aiRepositoryProvider.overrideWithValue(
        aiRepository ?? FakeAiRepository(layers: const <AiOutputLayer>[]),
      ),
      networkAvailabilityServiceProvider.overrideWithValue(
        const _AlwaysOnlineNetworkAvailability(),
      ),
      projectMapViewportFeaturesProvider.overrideWith((ref, query) async {
        final features = await ref.watch(
          projectMapFeaturesProvider(query.projectId).future,
        );
        final featureType = query.featureType?.trim().toLowerCase();
        if (featureType == null || featureType.isEmpty) {
          return features;
        }
        return features
            .where(
              (feature) => feature.attributes.values.any(
                (value) => '$value'.toLowerCase().contains(featureType),
              ),
            )
            .toList(growable: false);
      }),
      projectFeatureDetailsProvider.overrideWith((ref, identity) async {
        return _projectFeatures().firstWhere(
          (feature) => feature.id == identity.featureId,
        );
      }),
      projectFeatureCountProvider.overrideWith((ref, query) async {
        final session = ref.watch(authControllerProvider).session;
        final allFeatures = await ref.watch(
          projectMapFeaturesProvider(query.projectId).future,
        );
        final features = session?.user.role == UserRole.viewer
            ? allFeatures
                  .where((feature) => feature.status == 'approved')
                  .toList(growable: false)
            : allFeatures;
        final statuses = query.statuses;
        final featureType = query.featureType?.trim().toLowerCase();
        return features
            .where(
              (feature) =>
                  statuses == null || statuses.contains(feature.status),
            )
            .where(
              (feature) =>
                  featureType == null ||
                  featureType.isEmpty ||
                  feature.attributes.values.any(
                    (value) => '$value'.toLowerCase().contains(featureType),
                  ),
            )
            .length;
      }),
      ...overrides,
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  testWidgets(
    'quick map preview shows the project-scoped preview entry points',
    (tester) async {
      var openedFullscreen = false;
      final previewFeatures = <MapFeatureSummary>[
        ..._projectFeatures(),
        const MapFeatureSummary(
          id: 'feature-polygon-003',
          projectId: 'project-1',
          status: 'rejected',
          geometry: <String, dynamic>{
            'type': 'Polygon',
            'coordinates': <dynamic>[
              <dynamic>[
                <double>[35.49, 33.89],
                <double>[35.51, 33.89],
                <double>[35.51, 33.91],
                <double>[35.49, 33.91],
                <double>[35.49, 33.89],
              ],
            ],
          },
          attributes: <String, dynamic>{'tree_type': 'Citrus'},
          collectedBy: 'Maya',
        ),
      ];

      await tester.pumpWidget(
        _wrapWithScope(
          overrides: <Override>[
            projectMapFeaturesProvider.overrideWith(
              (ref, projectId) async => previewFeatures,
            ),
          ],
          child: ProjectQuickMapCard(
            projectId: 'project-1',
            onOpenFullscreen: () {
              openedFullscreen = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Project map'), findsOneWidget);
      expect(find.text('3 mapped features'), findsOneWidget);
      expect(
        find.text('Tap the preview to open the full project map.'),
        findsOneWidget,
      );
      final polygonLayer = tester.widget<PolygonLayer>(
        find.byType(PolygonLayer).first,
      );
      expect(polygonLayer.polygons, hasLength(1));
      final polylineLayer = tester.widget<PolylineLayer>(
        find.byType(PolylineLayer).first,
      );
      expect(polylineLayer.polylines, hasLength(1));
      final markerLayer = tester.widget<MarkerLayer>(
        find.byType(MarkerLayer).first,
      );
      expect(markerLayer.markers, hasLength(1));
      expect(tester.takeException(), isNull);

      await tester.tapAt(tester.getCenter(find.byType(FlutterMap)));
      await tester.pump();

      expect(openedFullscreen, isTrue);
    },
  );

  testWidgets(
    'map screen renders map-first workspace and uses current location',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final locationService = _FakeCurrentLocationService(
        const CurrentLocationSnapshot(
          position: LatLng(33.8938, 35.5018),
          accuracyMeters: 6,
        ),
      );
      final project = _projectSummary(
        name: 'Valley Parking Rehabilitation and Orchard Inventory',
      );

      await tester.pumpWidget(
        _wrapWithScope(
          overrides: <Override>[
            authControllerProvider.overrideWith(
              (ref) =>
                  _AuthenticatedAuthController(_session(UserRole.contributor)),
            ),
            syncControllerProvider.overrideWith(
              (ref) => _buildSyncController(),
            ),
            currentLocationServiceProvider.overrideWithValue(locationService),
            mapProjectsProvider.overrideWith(
              (ref) async => <ProjectSummary>[project],
            ),
            projectMapFeaturesProvider.overrideWith(
              (ref, projectId) async => _projectFeatures(),
            ),
            offlineMapPackageProvider.overrideWith(
              (ref) async => _offlinePackage(),
            ),
          ],
          child: const MapScreen(
            initialProjectId: 'project-1',
            lockProjectSelection: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byTooltip('Browse project features'), findsOneWidget);
      expect(find.text('Offline'), findsNothing);
      expect(find.text('Lebanon workspace'), findsNothing);
      expect(find.text('Search visible features'), findsNothing);
      expect(find.byTooltip('Map style'), findsOneWidget);
      expect(find.byTooltip('Offline map'), findsOneWidget);
      expect(find.byTooltip('Search map'), findsOneWidget);
      expect(find.byTooltip('More map tools'), findsOneWidget);

      final projectTitle = tester.widget<Text>(
        find.text('Valley Parking Rehabilitation and Orchard Inventory').first,
      );
      expect(projectTitle.maxLines, 1);
      expect(projectTitle.overflow, TextOverflow.ellipsis);
      expect(find.text('Fruit Trees'), findsOneWidget);
      expect(find.text('2 features'), findsWidgets);

      await tester.tap(find.byTooltip('Search map'));
      await tester.pumpAndSettle();

      expect(find.text('Search visible features'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Search visible features'),
        'Karim',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();

      expect(find.text('Search visible features'), findsNothing);
      expect(find.text('Karim'), findsOneWidget);

      await tester.tap(find.byTooltip('Filter'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilterChip, 'All pins'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'Pending review'), findsOneWidget);
      expect(find.text('Street view'), findsOneWidget);

      await tester.tap(find.byTooltip('Current location'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(locationService.callCount, 1);

      await tester.tap(find.byTooltip('Hide'));
      await tester.pumpAndSettle();

      expect(find.text('Search visible features'), findsNothing);

      await tester.tap(find.byTooltip('More map tools'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide map tools').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(
        find.text('Valley Parking Rehabilitation and Orchard Inventory'),
        findsNothing,
      );
      expect(find.byTooltip('Show map tools'), findsOneWidget);

      await tester.tap(find.byTooltip('Show map tools'));
      await tester.pumpAndSettle();

      expect(
        find.text('Valley Parking Rehabilitation and Orchard Inventory'),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Filter'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(FilterChip, 'Pending review'),
      );
      await tester.tap(find.widgetWithText(FilterChip, 'Pending review'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Browse project features'), findsOneWidget);
      expect(find.text('Pending review'), findsOneWidget);

      await tester.tap(find.byTooltip('Browse project features'));
      await tester.pumpAndSettle();
      expect(find.text('Project features'), findsOneWidget);
      expect(find.textContaining('1 of 1 item(s)'), findsOneWidget);
      expect(find.text('Search this project\'s features'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Pending'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Search this project\'s features'),
        'Karim',
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Karim'), findsWidgets);

      await tester.tapAt(const Offset(16, 16));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add Feature'));
      await tester.pumpAndSettle();

      expect(find.text('Choose geometry'), findsOneWidget);
      expect(find.byTooltip('Current location'), findsNothing);

      await tester.tap(find.text('Point'));
      await tester.pumpAndSettle();

      expect(find.text('Add feature on this map'), findsOneWidget);
      expect(find.text('Point not placed'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Back'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Undo'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Clear'), findsOneWidget);

      await tester.tap(find.byTooltip('Current location'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Point placed'), findsOneWidget);
    },
  );

  testWidgets(
    'project map supports clear map styles and honest offline wording',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _wrapWithScope(
          overrides: <Override>[
            authControllerProvider.overrideWith(
              (ref) =>
                  _AuthenticatedAuthController(_session(UserRole.contributor)),
            ),
            syncControllerProvider.overrideWith(
              (ref) => _buildSyncController(),
            ),
            currentLocationServiceProvider.overrideWithValue(
              _FakeCurrentLocationService(
                const CurrentLocationSnapshot(
                  position: LatLng(33.8938, 35.5018),
                  accuracyMeters: 6,
                ),
              ),
            ),
            mapProjectsProvider.overrideWith(
              (ref) async => <ProjectSummary>[_projectSummary()],
            ),
            projectMapFeaturesProvider.overrideWith(
              (ref, projectId) async => _projectFeatures(),
            ),
            offlineMapPackageProvider.overrideWith(
              (ref) async => _offlinePackage(),
            ),
          ],
          child: const MapScreen(
            initialProjectId: 'project-1',
            lockProjectSelection: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byTooltip('Map style'));
      await tester.pumpAndSettle();
      expect(find.text('Street'), findsOneWidget);
      expect(find.text('Satellite'), findsOneWidget);
      await tester.tap(find.text('Satellite').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Offline map'));
      await tester.pumpAndSettle();

      expect(find.text('Offline contribution'), findsOneWidget);
      expect(find.text('Offline contribution resources'), findsOneWidget);
      expect(find.byTooltip('Close offline map'), findsNothing);
      expect(find.byTooltip('Current location'), findsNothing);
      expect(
        find.textContaining(
          'Download this project and the shared Lebanon Satellite base map',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Project features, AI predictions, and validation pins are not downloaded',
        ),
        findsOneWidget,
      );
      expect(find.text('Download'), findsWidgets);
      expect(find.text('Refresh'), findsWidgets);
      expect(find.text('Delete'), findsWidgets);

      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      expect(find.text('Offline contribution'), findsNothing);
    },
  );

  testWidgets(
    'viewer project map stays read-only and shows only approved features',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _wrapWithScope(
          overrides: <Override>[
            authControllerProvider.overrideWith(
              (ref) => _AuthenticatedAuthController(_session(UserRole.viewer)),
            ),
            syncControllerProvider.overrideWith(
              (ref) => _buildSyncController(),
            ),
            currentLocationServiceProvider.overrideWithValue(
              _FakeCurrentLocationService(
                const CurrentLocationSnapshot(
                  position: LatLng(33.8938, 35.5018),
                  accuracyMeters: 6,
                ),
              ),
            ),
            mapProjectsProvider.overrideWith(
              (ref) async => <ProjectSummary>[_projectSummary()],
            ),
            projectMapFeaturesProvider.overrideWith(
              (ref, projectId) async => _projectFeatures(),
            ),
            offlineMapPackageProvider.overrideWith(
              (ref) async => _offlinePackage(),
            ),
          ],
          child: const MapScreen(
            initialProjectId: 'project-1',
            lockProjectSelection: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byTooltip('Offline map'), findsNothing);
      expect(find.byTooltip('Add Feature'), findsNothing);
      expect(find.text('1 feature'), findsWidgets);
      expect(find.text('Viewer-visible'), findsNothing);

      await tester.tap(find.byTooltip('Filter'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilterChip, 'All pins'), findsNothing);
      expect(find.widgetWithText(FilterChip, 'Pending review'), findsNothing);
      expect(find.text('Street view'), findsOneWidget);

      await tester.tap(find.byTooltip('Browse project features'));
      await tester.pumpAndSettle();

      expect(find.text('Project features'), findsOneWidget);
      expect(find.textContaining('1 of 1 item(s)'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Pending'), findsNothing);
      expect(find.textContaining('Karim'), findsNothing);
      expect(find.textContaining('Rana'), findsWidgets);
    },
  );

  testWidgets('project map opens and focuses routed feature details', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var detailFetchCount = 0;

    await tester.pumpWidget(
      _wrapWithScope(
        overrides: <Override>[
          authControllerProvider.overrideWith(
            (ref) => _AuthenticatedAuthController(_session(UserRole.admin)),
          ),
          syncControllerProvider.overrideWith((ref) => _buildSyncController()),
          currentLocationServiceProvider.overrideWithValue(
            _FakeCurrentLocationService(
              const CurrentLocationSnapshot(
                position: LatLng(33.8938, 35.5018),
                accuracyMeters: 6,
              ),
            ),
          ),
          mapProjectsProvider.overrideWith(
            (ref) async => <ProjectSummary>[_projectSummary()],
          ),
          projectMapFeaturesProvider.overrideWith(
            (ref, projectId) async => _projectFeatures(),
          ),
          projectFeatureDetailsProvider.overrideWith((ref, identity) async {
            detailFetchCount += 1;
            return _projectFeatures().firstWhere(
              (feature) => feature.id == identity.featureId,
            );
          }),
          offlineMapPackageProvider.overrideWith((ref) async => null),
        ],
        child: const MapScreen(
          initialProjectId: 'project-1',
          initialFeatureId: 'feature-line-002',
          lockProjectSelection: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.textContaining('Orchard'), findsWidgets);
    expect(find.text('Feature details'), findsWidgets);
    expect(detailFetchCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('map screen handles out-of-lebanon current location gracefully', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final locationService = _FakeCurrentLocationService(
      const CurrentLocationSnapshot(
        position: LatLng(32.0, 34.0),
        accuracyMeters: 14,
      ),
    );
    final project = _projectSummary();

    await tester.pumpWidget(
      _wrapWithScope(
        overrides: <Override>[
          authControllerProvider.overrideWith(
            (ref) =>
                _AuthenticatedAuthController(_session(UserRole.contributor)),
          ),
          syncControllerProvider.overrideWith((ref) => _buildSyncController()),
          currentLocationServiceProvider.overrideWithValue(locationService),
          mapProjectsProvider.overrideWith(
            (ref) async => <ProjectSummary>[project],
          ),
          projectMapFeaturesProvider.overrideWith(
            (ref, projectId) async => _projectFeatures(),
          ),
          offlineMapPackageProvider.overrideWith(
            (ref) async => _offlinePackage(),
          ),
        ],
        child: const MapScreen(
          initialProjectId: 'project-1',
          lockProjectSelection: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byTooltip('Current location'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.text(
        'Current location is outside Lebanon. Staying on the project workspace.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Current location is outside the Lebanon map workspace.'),
      findsNothing,
    );
  });

  testWidgets('project map stays usable when the project has no features', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrapWithScope(
        overrides: <Override>[
          authControllerProvider.overrideWith(
            (ref) =>
                _AuthenticatedAuthController(_session(UserRole.contributor)),
          ),
          syncControllerProvider.overrideWith((ref) => _buildSyncController()),
          currentLocationServiceProvider.overrideWithValue(
            _FakeCurrentLocationService(
              const CurrentLocationSnapshot(
                position: LatLng(33.8938, 35.5018),
                accuracyMeters: 6,
              ),
            ),
          ),
          mapProjectsProvider.overrideWith(
            (ref) async => <ProjectSummary>[
              _projectSummary(approvedFeatures: 0, pendingReviews: 0),
            ],
          ),
          projectMapFeaturesProvider.overrideWith(
            (ref, projectId) async => const <MapFeatureSummary>[],
          ),
          offlineMapPackageProvider.overrideWith(
            (ref) async => _offlinePackage(),
          ),
        ],
        child: const MapScreen(
          initialProjectId: 'project-1',
          lockProjectSelection: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('0 features'), findsWidgets);
    expect(find.byTooltip('Add Feature'), findsOneWidget);
    expect(find.byTooltip('Fit Lebanon workspace'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('project map stays responsive on compact screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrapWithScope(
        overrides: <Override>[
          authControllerProvider.overrideWith(
            (ref) =>
                _AuthenticatedAuthController(_session(UserRole.contributor)),
          ),
          syncControllerProvider.overrideWith((ref) => _buildSyncController()),
          currentLocationServiceProvider.overrideWithValue(
            _FakeCurrentLocationService(
              const CurrentLocationSnapshot(
                position: LatLng(33.8938, 35.5018),
                accuracyMeters: 6,
              ),
            ),
          ),
          mapProjectsProvider.overrideWith(
            (ref) async => <ProjectSummary>[
              _projectSummary(approvedFeatures: 0, pendingReviews: 0),
            ],
          ),
          projectMapFeaturesProvider.overrideWith(
            (ref, projectId) async => const <MapFeatureSummary>[],
          ),
          offlineMapPackageProvider.overrideWith(
            (ref) async => _offlinePackage(),
          ),
        ],
        child: const MapScreen(
          initialProjectId: 'project-1',
          lockProjectSelection: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.ensureVisible(find.byTooltip('Add Feature'));

    expect(find.byTooltip('Add Feature'), findsOneWidget);
    expect(find.text('0 features'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'add feature screen exposes current-location driven geometry capture',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final locationService = _FakeCurrentLocationService(
        const CurrentLocationSnapshot(
          position: LatLng(33.901, 35.511),
          accuracyMeters: 5.2,
        ),
      );
      final project = _projectSummary();

      await tester.pumpWidget(
        _wrapWithScope(
          overrides: <Override>[
            authControllerProvider.overrideWith(
              (ref) =>
                  _AuthenticatedAuthController(_session(UserRole.contributor)),
            ),
            currentLocationServiceProvider.overrideWithValue(locationService),
            projectListProvider.overrideWith(
              (ref, scope) async => <ProjectSummary>[project],
            ),
            projectMapFeaturesProvider.overrideWith(
              (ref, projectId) async => const <MapFeatureSummary>[],
            ),
            localDraftFeaturesProvider.overrideWith(
              (ref) async => const <LocalDraftFeature>[],
            ),
          ],
          child: const AddFeatureScreen(initialProjectId: 'project-1'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final currentLocationButton = find.text('Use current location');
      expect(currentLocationButton, findsOneWidget);

      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Use current location'),
          )
          .onPressed!
          .call();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(locationService.callCount, 1);
    },
  );

  testWidgets('add feature screen stays responsive on compact screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _projectSummary();

    await tester.pumpWidget(
      _wrapWithScope(
        overrides: <Override>[
          authControllerProvider.overrideWith(
            (ref) =>
                _AuthenticatedAuthController(_session(UserRole.contributor)),
          ),
          currentLocationServiceProvider.overrideWithValue(
            _FakeCurrentLocationService(
              const CurrentLocationSnapshot(
                position: LatLng(33.901, 35.511),
                accuracyMeters: 5.2,
              ),
            ),
          ),
          projectListProvider.overrideWith(
            (ref, scope) async => <ProjectSummary>[project],
          ),
          projectMapFeaturesProvider.overrideWith(
            (ref, projectId) async => const <MapFeatureSummary>[],
          ),
          localDraftFeaturesProvider.overrideWith(
            (ref) async => const <LocalDraftFeature>[],
          ),
        ],
        child: const AddFeatureScreen(initialProjectId: 'project-1'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.ensureVisible(find.text('Use current location'));

    expect(find.text('Use current location'), findsOneWidget);
    expect(find.text('Hybrid'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'add feature screen starts at attributes when launched from project map capture',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final project = _projectSummary();

      await tester.pumpWidget(
        _wrapWithScope(
          overrides: <Override>[
            authControllerProvider.overrideWith(
              (ref) =>
                  _AuthenticatedAuthController(_session(UserRole.contributor)),
            ),
            currentLocationServiceProvider.overrideWithValue(
              _FakeCurrentLocationService(
                const CurrentLocationSnapshot(
                  position: LatLng(33.901, 35.511),
                  accuracyMeters: 5.2,
                ),
              ),
            ),
            projectListProvider.overrideWith(
              (ref, scope) async => <ProjectSummary>[project],
            ),
            projectMapFeaturesProvider.overrideWith(
              (ref, projectId) async => const <MapFeatureSummary>[],
            ),
            localDraftFeaturesProvider.overrideWith(
              (ref) async => const <LocalDraftFeature>[],
            ),
          ],
          child: AddFeatureScreen(
            initialProjectId: 'project-1',
            captureSeed: const AddFeatureCaptureSeed(
              projectId: 'project-1',
              geometryType: 'Point',
              vertices: <LatLng>[LatLng(33.901, 35.511)],
              gpsAccuracyMeters: 4.7,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Collection form'), findsOneWidget);
      expect(find.text('2. Attributes'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Back'), findsOneWidget);
      expect(
        find.textContaining(
          'Use the field map to capture geometry directly in Lebanon',
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'add feature attributes handle malformed schema fields without crashing',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final malformedSchema = CollectionFormSchema.fromMap(<String, dynamic>{
        'version': null,
        'fields': <dynamic>[
          <String, dynamic>{
            'key': 'name',
            'label': null,
            'type': 'text',
            'required': true,
          },
          <String, dynamic>{
            'key': 'kind',
            'label': 'Kind',
            'type': 'select',
            'options': null,
            'required': true,
          },
          <String, dynamic>{'label': null, 'type': 'unknown'},
          null,
          'not a field',
        ],
      });
      final project = _projectSummary(collectionFormSchema: malformedSchema);

      await tester.pumpWidget(
        _wrapWithScope(
          overrides: <Override>[
            authControllerProvider.overrideWith(
              (ref) =>
                  _AuthenticatedAuthController(_session(UserRole.contributor)),
            ),
            currentLocationServiceProvider.overrideWithValue(
              _FakeCurrentLocationService(
                const CurrentLocationSnapshot(
                  position: LatLng(33.901, 35.511),
                  accuracyMeters: 5.2,
                ),
              ),
            ),
            projectListProvider.overrideWith(
              (ref, scope) async => <ProjectSummary>[project],
            ),
            projectMapFeaturesProvider.overrideWith(
              (ref, projectId) async => const <MapFeatureSummary>[],
            ),
            localDraftFeaturesProvider.overrideWith(
              (ref) async => const <LocalDraftFeature>[],
            ),
          ],
          child: AddFeatureScreen(
            initialProjectId: 'project-1',
            captureSeed: const AddFeatureCaptureSeed(
              projectId: 'project-1',
              geometryType: 'Point',
              vertices: <LatLng>[LatLng(33.901, 35.511)],
              gpsAccuracyMeters: 4.7,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Collection form'), findsOneWidget);
      expect(find.text('name *'), findsOneWidget);
      expect(
        find.text('No choices configured for this field.'),
        findsOneWidget,
      );
      expect(find.text('Field'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'project map shows published AI overlay toggle and lazy-loads it',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final project = _projectSummary(
        name: 'South Lebanon Fruit Trees Training Dataset',
      );
      final layer = _publishedAiLayer();
      final fakeAiRepository = FakeAiRepository(
        layers: <AiOutputLayer>[layer],
        layerFeatures: <String, AiLayerFeatureCollection>{
          layer.id: _publishedAiFeatureCollection(layer),
        },
      );

      await tester.pumpWidget(
        _wrapWithScope(
          aiRepository: fakeAiRepository,
          overrides: <Override>[
            authControllerProvider.overrideWith(
              (ref) => _AuthenticatedAuthController(_session(UserRole.viewer)),
            ),
            syncControllerProvider.overrideWith(
              (ref) => _buildSyncController(),
            ),
            mapProjectsProvider.overrideWith(
              (ref) async => <ProjectSummary>[project],
            ),
            projectMapFeaturesProvider.overrideWith(
              (ref, projectId) async => _projectFeatures(),
            ),
            offlineMapPackageProvider.overrideWith((ref) async => null),
          ],
          child: const MapScreen(
            initialProjectId: 'project-1',
            lockProjectSelection: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(fakeAiRepository.layerFeatureFetchCounts[layer.id], isNull);

      await tester.tap(find.byTooltip('Filter'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(FilterChip, 'Show published AI layer'),
        findsOneWidget,
      );

      await tester.tap(
        find.widgetWithText(FilterChip, 'Show published AI layer'),
      );
      await tester.pumpAndSettle();

      expect(fakeAiRepository.layerFeatureFetchCounts[layer.id], 1);
      expect(find.text('Hide published AI layer'), findsOneWidget);
      expect(
        fakeAiRepository.layerFeatureQueries
            .where((query) => query.classLabel == null)
            .length,
        greaterThanOrEqualTo(1),
      );
      expect(find.textContaining('Confidence 1394'), findsNothing);
      expect(find.text('Olives'), findsOneWidget);

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('project map opens focused AI validation task from route', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repository = FakeAiRepository(
      validationTasks: <AiPredictionValidationTask>[
        fakeAiValidationTask(status: 'open', assignedTo: null),
      ],
    );

    await tester.pumpWidget(
      _wrapWithScope(
        aiRepository: repository,
        overrides: <Override>[
          authControllerProvider.overrideWith(
            (ref) =>
                _AuthenticatedAuthController(_session(UserRole.contributor)),
          ),
          syncControllerProvider.overrideWith((ref) => _buildSyncController()),
          mapProjectsProvider.overrideWith(
            (ref) async => <ProjectSummary>[_projectSummary()],
          ),
          projectMapFeaturesProvider.overrideWith(
            (ref, projectId) async => _projectFeatures(),
          ),
          offlineMapPackageProvider.overrideWith((ref) async => null),
        ],
        child: const MapScreen(
          initialProjectId: 'project-1',
          initialFeatureId: 'validation-task-1',
          initialFeatureSource: AppRoutes.focusSourceAiValidationTask,
          lockProjectSelection: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(find.text('AI validation task'), findsOneWidget);
    expect(
      find.text('AI validation task, not official field data.'),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.text('Submit validation'),
      180,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Submit validation'), findsOneWidget);
    expect(find.text('Edit Draft'), findsNothing);
    expect(find.text('Delete Draft'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('project map validation layer is separate and submits evidence', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repository = FakeAiRepository(
      runs: <AiRun>[
        AiRun(
          id: 'run-1',
          projectId: 'project-1',
          status: 'ready_for_review',
          labelField: 'L4_descr',
          scopeType: 'project',
          trainingFeatureCount: 1394,
          eligibleFeatureCount: 1394,
          excludedFeatureCount: 0,
          selectedModel: 'random_forest',
          metadata: const <String, dynamic>{
            'trained_classes': <String>[
              'Olives',
              'Fruit Trees',
              'Citrus Fruit Trees',
            ],
          },
        ),
      ],
      validationTasks: <AiPredictionValidationTask>[
        fakeAiValidationTask(status: 'open', assignedTo: null),
      ],
    );

    await tester.pumpWidget(
      _wrapWithScope(
        aiRepository: repository,
        overrides: <Override>[
          authControllerProvider.overrideWith(
            (ref) =>
                _AuthenticatedAuthController(_session(UserRole.contributor)),
          ),
          syncControllerProvider.overrideWith((ref) => _buildSyncController()),
          mapProjectsProvider.overrideWith(
            (ref) async => <ProjectSummary>[_projectSummary()],
          ),
          projectMapFeaturesProvider.overrideWith(
            (ref, projectId) async => _projectFeatures(),
          ),
          offlineMapPackageProvider.overrideWith((ref) async => null),
        ],
        child: const MapScreen(
          initialProjectId: 'project-1',
          lockProjectSelection: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byTooltip('Filter'));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(FilterChip, 'Show AI validation tasks (1)'),
      findsOneWidget,
    );
    expect(find.text('Show published AI layer'), findsNothing);

    await tester.tap(
      find.widgetWithText(FilterChip, 'Show AI validation tasks (1)'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Hide AI validation tasks'), findsOneWidget);
    expect(find.textContaining('1 validation task'), findsWidgets);

    await tester.tap(find.bySemanticsLabel('AI validation task marker'));
    await tester.pumpAndSettle();

    expect(find.text('AI validation task'), findsOneWidget);
    expect(
      find.text('AI validation task, not official field data.'),
      findsOneWidget,
    );
    expect(find.text('Edit Draft'), findsNothing);
    expect(find.text('Delete Draft'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Submit validation'),
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Submit validation'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Note / evidence'),
      'Checked the AI prediction from the map workflow.',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
    await tester.pumpAndSettle();

    expect(repository.validationSubmitCount, 1);
    expect(repository.validationTasks.single.status, 'submitted');
    expect(repository.validationTasks.single.noSpatialFeatureWrites, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('viewer cannot see validation task map layer', (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrapWithScope(
        aiRepository: FakeAiRepository(
          validationTasks: <AiPredictionValidationTask>[
            fakeAiValidationTask(status: 'open', assignedTo: null),
          ],
        ),
        overrides: <Override>[
          authControllerProvider.overrideWith(
            (ref) => _AuthenticatedAuthController(_session(UserRole.viewer)),
          ),
          syncControllerProvider.overrideWith((ref) => _buildSyncController()),
          mapProjectsProvider.overrideWith(
            (ref) async => <ProjectSummary>[_projectSummary()],
          ),
          projectMapFeaturesProvider.overrideWith(
            (ref, projectId) async => _projectFeatures(),
          ),
          offlineMapPackageProvider.overrideWith((ref) async => null),
        ],
        child: const MapScreen(
          initialProjectId: 'project-1',
          lockProjectSelection: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byTooltip('Filter'));
    await tester.pumpAndSettle();

    expect(find.textContaining('AI validation tasks'), findsNothing);
    expect(find.bySemanticsLabel('AI validation task marker'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'project map hides AI overlay toggle when no layer is published',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _wrapWithScope(
          overrides: <Override>[
            authControllerProvider.overrideWith(
              (ref) => _AuthenticatedAuthController(_session(UserRole.viewer)),
            ),
            syncControllerProvider.overrideWith(
              (ref) => _buildSyncController(),
            ),
            mapProjectsProvider.overrideWith(
              (ref) async => <ProjectSummary>[_projectSummary()],
            ),
            projectMapFeaturesProvider.overrideWith(
              (ref, projectId) async => _projectFeatures(),
            ),
            offlineMapPackageProvider.overrideWith((ref) async => null),
          ],
          child: const MapScreen(
            initialProjectId: 'project-1',
            lockProjectSelection: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byTooltip('Filter'));
      await tester.pumpAndSettle();

      expect(find.text('Show published AI layer'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('project feature browser uses a readable feature title', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrapWithScope(
        overrides: <Override>[
          authControllerProvider.overrideWith(
            (ref) =>
                _AuthenticatedAuthController(_session(UserRole.contributor)),
          ),
          syncControllerProvider.overrideWith((ref) => _buildSyncController()),
          currentLocationServiceProvider.overrideWithValue(
            _FakeCurrentLocationService(
              const CurrentLocationSnapshot(
                position: LatLng(33.8938, 35.5018),
                accuracyMeters: 6,
              ),
            ),
          ),
          mapProjectsProvider.overrideWith(
            (ref) async => <ProjectSummary>[_projectSummary()],
          ),
          projectMapFeaturesProvider.overrideWith(
            (ref, projectId) async => _projectFeatures(),
          ),
          offlineMapPackageProvider.overrideWith(
            (ref) async => _offlinePackage(),
          ),
        ],
        child: const MapScreen(
          initialProjectId: 'project-1',
          lockProjectSelection: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byTooltip('Browse project features'));
    await tester.pumpAndSettle();

    expect(find.text('Mazami'), findsOneWidget);

    await tester.tap(find.text('Mazami'));
    await tester.pumpAndSettle();

    expect(find.text('Mazami'), findsWidgets);
  });

  testWidgets(
    'capture-seeded add feature returns to the project map when backing out of attributes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final project = _projectSummary();
      AddFeatureFlowResult? result;
      late final GoRouter router;

      router = GoRouter(
        routes: <RouteBase>[
          GoRoute(
            path: '/',
            builder: (context, state) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async {
                    result = await context.push<AddFeatureFlowResult>('/add');
                  },
                  child: const Text('Open capture flow'),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/add',
            builder: (context, state) => AddFeatureScreen(
              initialProjectId: 'project-1',
              captureSeed: const AddFeatureCaptureSeed(
                projectId: 'project-1',
                geometryType: 'Point',
                vertices: <LatLng>[LatLng(33.901, 35.511)],
                gpsAccuracyMeters: 4.7,
              ),
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            authControllerProvider.overrideWith(
              (ref) =>
                  _AuthenticatedAuthController(_session(UserRole.contributor)),
            ),
            networkAvailabilityServiceProvider.overrideWithValue(
              const _AlwaysOnlineNetworkAvailability(),
            ),
            projectListProvider.overrideWith(
              (ref, scope) async => <ProjectSummary>[project],
            ),
            projectMapFeaturesProvider.overrideWith(
              (ref, projectId) async => const <MapFeatureSummary>[],
            ),
            localDraftFeaturesProvider.overrideWith(
              (ref) async => const <LocalDraftFeature>[],
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.tap(find.text('Open capture flow'));
      await tester.pumpAndSettle();

      expect(find.text('Collection form'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Back'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Back'));
      await tester.pumpAndSettle();

      expect(find.text('Open capture flow'), findsOneWidget);
      expect(result?.shouldResumeCapture, isTrue);
    },
  );
}
