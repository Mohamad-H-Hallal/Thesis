import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/network_availability_base.dart';
import 'package:lebanese_gis_mobile/core/offline/local_models.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store_web.dart';
import 'package:lebanese_gis_mobile/core/pagination/paginated_result.dart';
import 'package:lebanese_gis_mobile/features/auth/domain/auth_models.dart';
import 'package:lebanese_gis_mobile/features/map/data/offline_project_download_service.dart';
import 'package:lebanese_gis_mobile/features/map/data/offline_tile_cache_manager.dart';
import 'package:lebanese_gis_mobile/features/map/domain/lebanon_map.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/project.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/projects_repository.dart';

class _AlwaysOnline implements NetworkAvailabilityService {
  const _AlwaysOnline();

  @override
  Stream<bool> get onOnlineStatusChanged => const Stream<bool>.empty();

  @override
  Future<bool> isOnline() async => true;
}

class _RecordingProjectsRepository implements ProjectsRepository {
  _RecordingProjectsRepository(this.projects);

  final Map<String, ProjectSummary> projects;
  final List<String> offlinePackageRequests = <String>[];

  @override
  Future<OfflineProjectPackage> fetchOfflinePackage({
    required String projectId,
    required String ownerUserId,
  }) async {
    offlinePackageRequests.add(projectId);
    final now = DateTime.utc(2026, 7, 22, 10);
    return OfflineProjectPackage(
      ownerUserId: ownerUserId,
      project: projects[projectId]!,
      packageVersion: '$projectId-package-v1',
      appResourcesVersion: '$projectId-resources-v1',
      baseMapVersion: 'shared-base-v1',
      downloadedAt: now,
      refreshedAt: now,
    );
  }

  @override
  Future<ProjectSummary?> byId({
    required String id,
    required String userId,
    required UserRole role,
  }) async => projects[id];

  @override
  Future<List<ProjectSummary>> fetchProjects({
    required String userId,
    required UserRole role,
    required ProjectViewScope scope,
  }) async => projects.values.toList(growable: false);

  @override
  Future<PaginatedResult<ProjectSummary>> fetchProjectsPage({
    required String userId,
    required UserRole role,
    required ProjectViewScope scope,
    String? query,
    String? status,
    String? categoryId,
    int page = 1,
    int limit = 20,
  }) async {
    final items = projects.values.toList(growable: false);
    return PaginatedResult<ProjectSummary>(
      items: items,
      page: page,
      limit: limit,
      total: items.length,
      hasMore: false,
    );
  }

  @override
  Future<void> cancelProjectAccessRequest({required String projectId}) async {}

  @override
  Future<void> requestProjectAccess({required String projectId}) async {}

  @override
  Future<ProjectSummary> updateContributorVisibility({
    required String projectId,
    required bool visibleToContributors,
  }) async => projects[projectId]!;

  @override
  Future<ProjectSummary> updateViewerVisibility({
    required String projectId,
    required bool visibleToViewers,
  }) async => projects[projectId]!;
}

class _FakeTileCacheManager extends OfflineTileCacheManager {
  _FakeTileCacheManager({required this.store})
    : super(localStore: store, licensedEsriOfflineBasemapEnabled: true);

  final LocalStore store;
  final Set<String> completeVersions = <String>{};
  int baseMapDownloadCount = 0;

  @override
  Future<bool> hasCompleteLebanonContributionBaseMap({
    required OfflineMapPackage package,
    LebanonBasemapStyle basemapStyle = LebanonBasemapStyle.satellite,
  }) async => completeVersions.contains(package.version);

  @override
  Future<OfflineTileDownloadSummary> cacheLebanonContributionBaseMap({
    required OfflineMapPackage package,
    LebanonBasemapStyle basemapStyle = LebanonBasemapStyle.satellite,
    void Function(OfflineTileDownloadProgress progress)? onProgress,
    OfflineDownloadCancelToken? cancelToken,
  }) async {
    baseMapDownloadCount += 1;
    completeVersions.add(package.version);
    return const OfflineTileDownloadSummary(
      requestedTiles: 10,
      downloadedTiles: 10,
      skippedTiles: 0,
      failedTiles: 0,
      sizeBytes: 1024,
    );
  }

  @override
  Future<OfflineMapPackage> refreshStats(
    OfflineMapPackage package, {
    LebanonBasemapStyle basemapStyle = LebanonBasemapStyle.satellite,
  }) async {
    final refreshed = package.copyWith(
      downloadedAt: DateTime.utc(2026, 7, 22, 10),
      tileCount: 10,
      sizeBytes: 1024,
    );
    await store.upsertOfflineMapPackage(refreshed);
    return refreshed;
  }
}

ProjectSummary _project(String id) => ProjectSummary(
  id: id,
  name: 'Project $id',
  category: 'Field work',
  status: 'active',
  assignedCollectors: 1,
  pendingReviews: 0,
  description: 'Project $id resources',
  visibleToContributors: true,
  currentUserAssignmentRole: ProjectAssignmentRole.contributor,
  currentUserAssignmentStatus: ProjectAssignmentStatus.approved,
);

void main() {
  test(
    'keeps the project package usable when offline imagery rights are not approved',
    () async {
      final store = MemoryLocalStore();
      await store.initialize();
      addTearDown(store.dispose);
      final repository = _RecordingProjectsRepository(<String, ProjectSummary>{
        'project-a': _project('project-a'),
      });
      final service = OfflineProjectDownloadService(
        projectsRepository: repository,
        localStore: store,
        tileCacheManager: OfflineTileCacheManager(
          localStore: store,
          licensedEsriOfflineBasemapEnabled: false,
        ),
        networkAvailability: const _AlwaysOnline(),
      );

      final result = await service.downloadProject(
        project: repository.projects['project-a']!,
        mapPackage: OfflineMapPackage(
          ownerUserId: '',
          version: 'shared-base-v1',
          zoomLevelMin: 7,
          zoomLevelMax: 15,
          lastUpdatedAt: DateTime.utc(2026, 8, 12),
          isCurrent: true,
        ),
        ownerUserId: 'contributor-1',
      );

      expect(result.projectPackageChanged, isTrue);
      expect(result.baseMapDownloaded, isFalse);
      expect(result.baseMapUnavailableReason, contains('offline-use rights'));
      expect(
        await store.getOfflineProjectPackage(
          ownerUserId: 'contributor-1',
          projectId: 'project-a',
        ),
        isNotNull,
      );
    },
  );

  test(
    'downloads only the selected project and reuses a valid shared base map',
    () async {
      final store = MemoryLocalStore();
      await store.initialize();
      addTearDown(store.dispose);
      final repository = _RecordingProjectsRepository(<String, ProjectSummary>{
        'project-a': _project('project-a'),
        'project-b': _project('project-b'),
        'project-c': _project('project-c'),
      });
      final tiles = _FakeTileCacheManager(store: store);
      final service = OfflineProjectDownloadService(
        projectsRepository: repository,
        localStore: store,
        tileCacheManager: tiles,
        networkAvailability: const _AlwaysOnline(),
      );
      final initialMapPackage = OfflineMapPackage(
        ownerUserId: '',
        version: 'shared-base-v1',
        zoomLevelMin: 7,
        zoomLevelMax: 15,
        lastUpdatedAt: DateTime.utc(2026, 7, 22),
        isCurrent: true,
      );

      final firstA = await service.downloadProject(
        project: repository.projects['project-a']!,
        mapPackage: initialMapPackage,
        ownerUserId: 'contributor-1',
      );
      expect(firstA.baseMapDownloaded, isTrue);
      expect(
        (await store.getOfflineProjectPackages(
          ownerUserId: 'contributor-1',
        )).map((item) => item.projectId),
        <String>['project-a'],
      );

      final secondA = await service.downloadProject(
        project: repository.projects['project-a']!,
        mapPackage: firstA.mapPackage,
        ownerUserId: 'contributor-1',
      );
      expect(secondA.projectPackageChanged, isFalse);
      expect(secondA.baseMapAlreadyComplete, isTrue);

      final firstB = await service.downloadProject(
        project: repository.projects['project-b']!,
        mapPackage: secondA.mapPackage,
        ownerUserId: 'contributor-1',
      );
      expect(firstB.baseMapAlreadyComplete, isTrue);
      expect(tiles.baseMapDownloadCount, 1);
      expect(repository.offlinePackageRequests, <String>[
        'project-a',
        'project-a',
        'project-b',
      ]);
      final packages = await store.getOfflineProjectPackages(
        ownerUserId: 'contributor-1',
      );
      expect(packages.map((item) => item.projectId).toSet(), <String>{
        'project-a',
        'project-b',
      });
      expect(
        await store.getOfflineProjectPackage(
          ownerUserId: 'contributor-1',
          projectId: 'project-c',
        ),
        isNull,
      );
    },
  );
}
