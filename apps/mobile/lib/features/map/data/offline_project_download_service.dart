import 'dart:convert';

import '../../../core/network/network_availability_base.dart';
import '../../../core/offline/local_models.dart';
import '../../../core/offline/local_store.dart';
import '../../projects/domain/project.dart';
import '../../projects/domain/projects_repository.dart';
import '../domain/lebanon_map.dart';
import 'offline_tile_cache_manager.dart';

class OfflineProjectDownloadProgress {
  const OfflineProjectDownloadProgress({
    required this.label,
    this.completedUnits,
    this.totalUnits,
  });

  final String label;
  final int? completedUnits;
  final int? totalUnits;

  double? get value {
    final completed = completedUnits;
    final total = totalUnits;
    if (completed == null || total == null || total <= 0) {
      return null;
    }
    return completed.clamp(0, total) / total;
  }
}

class OfflineProjectDownloadResult {
  const OfflineProjectDownloadResult({
    required this.projectPackage,
    required this.mapPackage,
    required this.projectPackageChanged,
    required this.baseMapDownloaded,
    required this.baseMapAlreadyComplete,
    this.tileSummary,
    this.baseMapUnavailableReason,
  });

  final OfflineProjectPackage projectPackage;
  final OfflineMapPackage mapPackage;
  final bool projectPackageChanged;
  final bool baseMapDownloaded;
  final bool baseMapAlreadyComplete;
  final OfflineTileDownloadSummary? tileSummary;
  final String? baseMapUnavailableReason;
}

class OfflineProjectDownloadService {
  OfflineProjectDownloadService({
    required ProjectsRepository projectsRepository,
    required LocalStore localStore,
    required OfflineTileCacheManager tileCacheManager,
    required NetworkAvailabilityService networkAvailability,
  }) : _projectsRepository = projectsRepository,
       _localStore = localStore,
       _tileCacheManager = tileCacheManager,
       _networkAvailability = networkAvailability;

  final ProjectsRepository _projectsRepository;
  final LocalStore _localStore;
  final OfflineTileCacheManager _tileCacheManager;
  final NetworkAvailabilityService _networkAvailability;

  Future<OfflineProjectDownloadResult> downloadProject({
    required ProjectSummary project,
    required OfflineMapPackage mapPackage,
    required String ownerUserId,
    void Function(OfflineProjectDownloadProgress progress)? onProgress,
    OfflineDownloadCancelToken? cancelToken,
  }) async {
    cancelToken?.throwIfCanceled();
    final isOnline = await _networkAvailability.isOnline();
    cancelToken?.throwIfCanceled();
    if (!isOnline) {
      throw StateError(
        'Connect to the internet to download or refresh offline resources.',
      );
    }

    onProgress?.call(
      const OfflineProjectDownloadProgress(
        label: 'Checking project package for updates...',
        completedUnits: 0,
        totalUnits: 2,
      ),
    );

    final remoteProjectPackage = await _projectsRepository.fetchOfflinePackage(
      projectId: project.id,
      ownerUserId: ownerUserId,
    );
    cancelToken?.throwIfCanceled();
    final existingProjectPackage = await _localStore.getOfflineProjectPackage(
      ownerUserId: ownerUserId,
      projectId: project.id,
    );
    cancelToken?.throwIfCanceled();
    final projectChanged = !_sameProjectPackage(
      existingProjectPackage,
      remoteProjectPackage,
    );

    final effectiveProjectPackage =
        projectChanged || existingProjectPackage == null
        ? remoteProjectPackage
        : existingProjectPackage;
    if (projectChanged) {
      await _localStore.upsertOfflineProjectPackage(remoteProjectPackage);
    }
    cancelToken?.throwIfCanceled();

    onProgress?.call(
      OfflineProjectDownloadProgress(
        label: projectChanged
            ? 'Project form, permissions, and lookup values saved.'
            : 'Project package is already up to date.',
        completedUnits: 1,
        totalUnits: 2,
      ),
    );

    final satellitePackage = mapPackage.copyWith(
      ownerUserId: ownerUserId,
      isCurrent: true,
    );
    if (!satellitePackage.isProviderNeutralPackageReady) {
      onProgress?.call(
        const OfflineProjectDownloadProgress(
          label:
              'Project data saved. No verified offline imagery package is published yet.',
          completedUnits: 2,
          totalUnits: 2,
        ),
      );
      return OfflineProjectDownloadResult(
        projectPackage: effectiveProjectPackage,
        mapPackage: satellitePackage,
        projectPackageChanged: projectChanged,
        baseMapDownloaded: false,
        baseMapAlreadyComplete: false,
        baseMapUnavailableReason:
            'No verified TerraLeb offline imagery package is published yet.',
      );
    }
    final hasCompleteSatelliteMap = await _tileCacheManager
        .hasCompleteLebanonContributionBaseMap(
          package: satellitePackage,
          basemapStyle: LebanonBasemapStyle.satellite,
        );
    cancelToken?.throwIfCanceled();
    final needsBaseMapDownload =
        !hasCompleteSatelliteMap || satellitePackage.downloadedAt == null;

    OfflineTileDownloadSummary? tileSummary;
    if (needsBaseMapDownload) {
      tileSummary = await _tileCacheManager.cacheLebanonContributionBaseMap(
        package: satellitePackage,
        basemapStyle: LebanonBasemapStyle.satellite,
        cancelToken: cancelToken,
        onProgress: (progress) {
          onProgress?.call(
            OfflineProjectDownloadProgress(
              label:
                  'Saving Lebanon offline imagery ${progress.completedTiles}/${progress.requestedTiles}${progress.skippedTiles > 0 ? ' - already saved' : ''}',
              completedUnits: progress.completedTiles,
              totalUnits: progress.requestedTiles,
            ),
          );
        },
      );
    }
    cancelToken?.throwIfCanceled();

    final refreshedMapPackage = await _tileCacheManager.refreshStats(
      satellitePackage,
      basemapStyle: LebanonBasemapStyle.satellite,
    );
    cancelToken?.throwIfCanceled();

    onProgress?.call(
      OfflineProjectDownloadProgress(
        label: needsBaseMapDownload
            ? 'Offline imagery saved. ${satellitePackage.sourceResolutionMeters?.toStringAsFixed(0) ?? '10'} m orientation imagery; ${satellitePackage.sourceAttribution ?? 'Copernicus and OpenStreetMap sources'}.'
            : 'Offline imagery is already up to date.',
        completedUnits: 2,
        totalUnits: 2,
      ),
    );

    return OfflineProjectDownloadResult(
      projectPackage: effectiveProjectPackage,
      mapPackage: refreshedMapPackage,
      projectPackageChanged: projectChanged,
      baseMapDownloaded: tileSummary != null,
      baseMapAlreadyComplete: !needsBaseMapDownload,
      tileSummary: tileSummary,
    );
  }

  bool _sameProjectPackage(
    OfflineProjectPackage? existing,
    OfflineProjectPackage next,
  ) {
    if (existing == null) {
      return false;
    }
    return existing.packageVersion == next.packageVersion &&
        existing.appResourcesVersion == next.appResourcesVersion &&
        existing.baseMapVersion == next.baseMapVersion &&
        jsonEncode(existing.project.toLocalPayload()) ==
            jsonEncode(next.project.toLocalPayload());
  }
}
