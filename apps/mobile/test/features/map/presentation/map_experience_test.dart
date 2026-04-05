import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/core/offline/local_models.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_controller.dart';
import 'package:lebanese_gis_mobile/core/sync/sync_engine.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_repository.dart';
import 'package:lebanese_gis_mobile/features/auth/presentation/controllers/auth_controller.dart';
import 'package:lebanese_gis_mobile/features/map/domain/current_location_service.dart';
import 'package:lebanese_gis_mobile/features/map/domain/map_feature.dart';
import 'package:lebanese_gis_mobile/features/map/presentation/screens/add_feature_screen.dart';
import 'package:lebanese_gis_mobile/features/map/presentation/screens/map_screen.dart';
import 'package:lebanese_gis_mobile/features/map/presentation/widgets/project_quick_map_card.dart';
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

class _FakeLocalStore implements LocalStore {
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
  Future<List<LocalDraftFeature>> getDrafts() async =>
      const <LocalDraftFeature>[];

  @override
  Future<List<SyncQueueItem>> getDueSyncItems(
    DateTime now, {
    int limit = 20,
  }) async => const <SyncQueueItem>[];

  @override
  Future<OfflineMapPackage?> getCurrentOfflineMapPackage() async => null;

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
}) {
  return ProjectSummary(
    id: id,
    name: name,
    category: 'Fruit Trees',
    status: 'active',
    assignedCollectors: 2,
    pendingReviews: 1,
    approvedFeatures: 4,
    description: 'Lebanon field collection project.',
    currentUserAssignmentRole: ProjectAssignmentRole.contributor,
    currentUserAssignmentStatus: ProjectAssignmentStatus.approved,
    visibleToViewers: true,
    allowedGeometryTypes: const <String>['Point', 'LineString', 'Polygon'],
    collectionFormSchema: const CollectionFormSchema(
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
      status: 'approved',
      geometry: <String, dynamic>{
        'type': 'Point',
        'coordinates': <double>[35.5018, 33.8938],
      },
      attributes: <String, dynamic>{'tree_type': 'Olive'},
      collectedBy: 'Rana',
      photoCount: 2,
    ),
    MapFeatureSummary(
      id: 'feature-line-002',
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

Widget _wrapWithScope({
  required List<Override> overrides,
  required Widget child,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  testWidgets(
    'quick map preview shows the project-scoped preview entry points',
    (tester) async {
      var openedFullscreen = false;

      await tester.pumpWidget(
        _wrapWithScope(
          overrides: <Override>[
            projectMapFeaturesProvider.overrideWith(
              (ref, projectId) async => _projectFeatures(),
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

      expect(find.text('Quick Map'), findsOneWidget);
      expect(
        find.text(
          'Lebanon-only preview with project features and place labels.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Open full map'));
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

      expect(find.text('Features (2)'), findsOneWidget);
      expect(find.text('Offline'), findsNothing);
      expect(find.text('Lebanon workspace'), findsNothing);
      expect(find.text('Search visible features'), findsOneWidget);
      expect(find.byTooltip('Offline map'), findsOneWidget);
      expect(find.byTooltip('Map style'), findsOneWidget);

      final projectTitle = tester.widget<Text>(
        find.text('Valley Parking Rehabilitation and Orchard Inventory').first,
      );
      expect(projectTitle.maxLines, 1);
      expect(projectTitle.overflow, TextOverflow.ellipsis);

      await tester.tap(find.byTooltip('Show quick filters'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilterChip, 'All pins'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'Pending review'), findsOneWidget);
      expect(find.text('Street view'), findsOneWidget);

      await tester.tap(find.byTooltip('Current location'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(locationService.callCount, 1);
      expect(find.text('GPS 6m'), findsWidgets);

      await tester.tap(find.byTooltip('Hide quick filters'));
      await tester.pumpAndSettle();

      expect(find.text('Search visible features'), findsOneWidget);

      await tester.tap(find.byTooltip('Show quick filters'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(FilterChip, 'Pending review'));
      await tester.tap(find.widgetWithText(FilterChip, 'Pending review'));
      await tester.pumpAndSettle();

      expect(find.text('Features (1)'), findsOneWidget);
      expect(find.text('Pending review'), findsOneWidget);

      await tester.tap(find.text('Features (1)'));
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
      await tester.tap(find.text('Satellite').last);
      await tester.pumpAndSettle();

      expect(find.text('Satellite'), findsWidgets);

      await tester.tap(find.byTooltip('Offline map'));
      await tester.pumpAndSettle();

      expect(find.text('Offline map'), findsOneWidget);
      expect(find.byTooltip('Close offline map'), findsOneWidget);
      expect(
        find.textContaining('current satellite map on this device'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Only areas saved here will stay visible'),
        findsOneWidget,
      );
      expect(find.text('Save Lebanon overview'), findsOneWidget);
      expect(find.text('Save this view'), findsOneWidget);
      expect(find.textContaining('Save the current'), findsOneWidget);

      await tester.tap(find.byTooltip('Close offline map'));
      await tester.pumpAndSettle();

      expect(find.text('Offline map'), findsNothing);
    },
  );

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
      expect(find.text('GPS 5m'), findsOneWidget);
    },
  );
}
