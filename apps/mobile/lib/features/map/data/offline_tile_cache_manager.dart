import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/offline/local_models.dart';
import '../../../core/offline/local_store.dart';
import '../domain/lebanon_map.dart';

class OfflineTileDownloadSummary {
  const OfflineTileDownloadSummary({
    required this.requestedTiles,
    required this.downloadedTiles,
    required this.skippedTiles,
    required this.failedTiles,
    required this.sizeBytes,
  });

  final int requestedTiles;
  final int downloadedTiles;
  final int skippedTiles;
  final int failedTiles;
  final int sizeBytes;
}

class OfflineTileDownloadProgress {
  const OfflineTileDownloadProgress({
    required this.requestedTiles,
    required this.completedTiles,
    required this.downloadedTiles,
    required this.skippedTiles,
    required this.failedTiles,
  });

  final int requestedTiles;
  final int completedTiles;
  final int downloadedTiles;
  final int skippedTiles;
  final int failedTiles;
}

class OfflineTileCacheManager {
  OfflineTileCacheManager({required LocalStore localStore})
    : _localStore = localStore,
      _dio = Dio(
        BaseOptions(
          responseType: ResponseType.bytes,
          connectTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 18),
          headers: const <String, String>{'User-Agent': 'lb.gov.gis_collector'},
        ),
      );

  final LocalStore _localStore;
  final Dio _dio;

  Directory? _rootDir;
  File? _transparentTile;

  Future<void> initialize() async {
    if (_rootDir != null && _transparentTile != null) {
      return;
    }

    final appDir = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(appDir.path, 'offline_tiles'));
    await root.create(recursive: true);
    final transparent = File(p.join(root.path, 'transparent.png'));
    if (!await transparent.exists()) {
      await transparent.writeAsBytes(_transparentPngBytes, flush: true);
    }

    _rootDir = root;
    _transparentTile = transparent;
  }

  Future<String> localTileTemplate({
    required OfflineMapPackage package,
    required LebanonBasemapStyle basemapStyle,
  }) async {
    await initialize();
    return p.join(
      _rootDir!.path,
      package.version,
      basemapStyle.name,
      '{z}',
      '{x}',
      '{y}.tile',
    );
  }

  Future<String> transparentFallbackPath() async {
    await initialize();
    return _transparentTile!.path;
  }

  Future<bool> hasCachedTiles({
    required OfflineMapPackage package,
    required LebanonBasemapStyle basemapStyle,
  }) async {
    await initialize();
    final dir = Directory(
      p.join(_rootDir!.path, package.version, basemapStyle.name),
    );
    if (!await dir.exists()) {
      return false;
    }

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.endsWith('.tile')) {
        return true;
      }
    }
    return false;
  }

  Future<OfflineTileDownloadSummary> cacheLebanonOverview({
    required OfflineMapPackage package,
    LebanonBasemapStyle basemapStyle = LebanonBasemapStyle.satellite,
    void Function(OfflineTileDownloadProgress progress)? onProgress,
  }) async {
    final minZoom = math.max(package.zoomLevelMin, 7);
    final maxZoom = math.min(package.zoomLevelMax, minZoom + 1);
    return cacheRegion(
      package: package,
      basemapStyle: basemapStyle,
      bounds: LebanonMapConfig.bounds,
      minZoom: minZoom,
      maxZoom: maxZoom,
      onProgress: onProgress,
    );
  }

  Future<OfflineTileDownloadSummary> cacheVisibleRegion({
    required OfflineMapPackage package,
    required LebanonBasemapStyle basemapStyle,
    required LatLngBounds bounds,
    required double currentZoom,
    void Function(OfflineTileDownloadProgress progress)? onProgress,
  }) async {
    final targetZoom = currentZoom.floor();
    final minZoom = targetZoom <= package.zoomLevelMin
        ? package.zoomLevelMin
        : targetZoom - 1;
    final maxZoom = math.min(package.zoomLevelMax, targetZoom + 1);
    return cacheRegion(
      package: package,
      basemapStyle: basemapStyle,
      bounds: _clampBounds(bounds),
      minZoom: math.max(package.zoomLevelMin, minZoom),
      maxZoom: maxZoom,
      onProgress: onProgress,
    );
  }

  Future<OfflineTileDownloadSummary> cacheRegion({
    required OfflineMapPackage package,
    required LebanonBasemapStyle basemapStyle,
    required LatLngBounds bounds,
    required int minZoom,
    required int maxZoom,
    void Function(OfflineTileDownloadProgress progress)? onProgress,
  }) async {
    await initialize();

    final tiles = <({int z, int x, int y})>[];
    for (var zoom = minZoom; zoom <= maxZoom; zoom += 1) {
      final xRange = _tileRangeX(bounds, zoom);
      final yRange = _tileRangeY(bounds, zoom);
      for (var x = xRange.$1; x <= xRange.$2; x += 1) {
        for (var y = yRange.$1; y <= yRange.$2; y += 1) {
          tiles.add((z: zoom, x: x, y: y));
        }
      }
    }

    var requested = 0;
    var downloaded = 0;
    var skipped = 0;
    var failed = 0;
    var sizeBytes = 0;
    final totalRequested = tiles.length;

    for (final tile in tiles) {
      requested += 1;
      final path = await _tilePath(
        package: package,
        basemapStyle: basemapStyle,
        z: tile.z,
        x: tile.x,
        y: tile.y,
      );
      final file = File(path);
      if (await file.exists()) {
        skipped += 1;
      } else {
        try {
          final created = await _downloadTile(
            basemapStyle: basemapStyle,
            z: tile.z,
            x: tile.x,
            y: tile.y,
            destination: file,
          );
          if (created != null) {
            downloaded += 1;
            sizeBytes += created;
          } else {
            failed += 1;
          }
        } catch (_) {
          failed += 1;
        }
      }
      onProgress?.call(
        OfflineTileDownloadProgress(
          requestedTiles: totalRequested,
          completedTiles: requested,
          downloadedTiles: downloaded,
          skippedTiles: skipped,
          failedTiles: failed,
        ),
      );
    }

    final updatedPackage = await refreshStats(
      package.copyWith(downloadedAt: DateTime.now()),
      basemapStyle: basemapStyle,
    );

    await _localStore.upsertOfflineMapPackage(updatedPackage);

    return OfflineTileDownloadSummary(
      requestedTiles: requested,
      downloadedTiles: downloaded,
      skippedTiles: skipped,
      failedTiles: failed,
      sizeBytes: sizeBytes,
    );
  }

  Future<OfflineMapPackage> refreshStats(
    OfflineMapPackage package, {
    LebanonBasemapStyle basemapStyle = LebanonBasemapStyle.satellite,
  }) async {
    await initialize();
    final dir = Directory(
      p.join(_rootDir!.path, package.version, basemapStyle.name),
    );

    if (!await dir.exists()) {
      final updated = package.copyWith(
        tileCount: 0,
        sizeBytes: 0,
        downloadedAt: null,
      );
      await _localStore.upsertOfflineMapPackage(updated);
      return updated;
    }

    var tileCount = 0;
    var totalSize = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is! File) {
        continue;
      }
      tileCount += 1;
      totalSize += await entity.length();
    }

    final updated = package.copyWith(
      tileCount: tileCount,
      sizeBytes: totalSize,
      downloadedAt: tileCount == 0
          ? null
          : (package.downloadedAt ?? DateTime.now()),
    );
    await _localStore.upsertOfflineMapPackage(updated);
    return updated;
  }

  Future<OfflineMapPackage> clearCachedTiles({
    required OfflineMapPackage package,
    required LebanonBasemapStyle basemapStyle,
  }) async {
    await initialize();
    final dir = _styleRootDirectory(
      package: package,
      basemapStyle: basemapStyle,
    );
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    return refreshStats(package, basemapStyle: basemapStyle);
  }

  Future<OfflineTileDownloadSummary> refreshCachedTiles({
    required OfflineMapPackage package,
    required LebanonBasemapStyle basemapStyle,
    void Function(OfflineTileDownloadProgress progress)? onProgress,
  }) async {
    await initialize();
    final dir = _styleRootDirectory(
      package: package,
      basemapStyle: basemapStyle,
    );
    if (!await dir.exists()) {
      final updated = await refreshStats(package, basemapStyle: basemapStyle);
      await _localStore.upsertOfflineMapPackage(updated);
      return const OfflineTileDownloadSummary(
        requestedTiles: 0,
        downloadedTiles: 0,
        skippedTiles: 0,
        failedTiles: 0,
        sizeBytes: 0,
      );
    }

    final tiles = <({int z, int x, int y, File file})>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.tile')) {
        continue;
      }
      final relativePath = p.relative(entity.path, from: dir.path);
      final parts = p.split(relativePath);
      if (parts.length != 3) {
        continue;
      }
      final z = int.tryParse(parts[0]);
      final x = int.tryParse(parts[1]);
      final y = int.tryParse(p.basenameWithoutExtension(parts[2]));
      if (z == null || x == null || y == null) {
        continue;
      }
      tiles.add((z: z, x: x, y: y, file: entity));
    }

    var completed = 0;
    var downloaded = 0;
    var failed = 0;
    var sizeBytes = 0;
    final totalRequested = tiles.length;

    for (final tile in tiles) {
      try {
        final created = await _downloadTile(
          basemapStyle: basemapStyle,
          z: tile.z,
          x: tile.x,
          y: tile.y,
          destination: tile.file,
        );
        if (created != null) {
          downloaded += 1;
          sizeBytes += created;
        } else {
          failed += 1;
        }
      } catch (_) {
        failed += 1;
      }
      completed += 1;
      onProgress?.call(
        OfflineTileDownloadProgress(
          requestedTiles: totalRequested,
          completedTiles: completed,
          downloadedTiles: downloaded,
          skippedTiles: 0,
          failedTiles: failed,
        ),
      );
    }

    final updatedPackage = await refreshStats(
      package.copyWith(downloadedAt: DateTime.now()),
      basemapStyle: basemapStyle,
    );
    await _localStore.upsertOfflineMapPackage(updatedPackage);

    return OfflineTileDownloadSummary(
      requestedTiles: totalRequested,
      downloadedTiles: downloaded,
      skippedTiles: 0,
      failedTiles: failed,
      sizeBytes: sizeBytes,
    );
  }

  Future<int?> _downloadTile({
    required LebanonBasemapStyle basemapStyle,
    required int z,
    required int x,
    required int y,
    required File destination,
  }) async {
    await destination.parent.create(recursive: true);
    final url = LebanonMapConfig.basemapUrlTemplate(
      basemapStyle,
    ).replaceAll('{z}', '$z').replaceAll('{x}', '$x').replaceAll('{y}', '$y');

    final response = await _dio.get<List<int>>(url);
    final bytes = Uint8List.fromList(response.data ?? const <int>[]);
    if (bytes.isEmpty) {
      return null;
    }
    await destination.writeAsBytes(bytes, flush: true);
    return bytes.length;
  }

  Future<String> _tilePath({
    required OfflineMapPackage package,
    required LebanonBasemapStyle basemapStyle,
    required int z,
    required int x,
    required int y,
  }) async {
    await initialize();
    return p.join(
      _rootDir!.path,
      package.version,
      basemapStyle.name,
      '$z',
      '$x',
      '$y.tile',
    );
  }

  Directory _styleRootDirectory({
    required OfflineMapPackage package,
    required LebanonBasemapStyle basemapStyle,
  }) {
    return Directory(
      p.join(_rootDir!.path, package.version, basemapStyle.name),
    );
  }

  LatLngBounds _clampBounds(LatLngBounds bounds) {
    return LatLngBounds(
      LatLng(
        math.max(bounds.south, LebanonMapConfig.bounds.south),
        math.max(bounds.west, LebanonMapConfig.bounds.west),
      ),
      LatLng(
        math.min(bounds.north, LebanonMapConfig.bounds.north),
        math.min(bounds.east, LebanonMapConfig.bounds.east),
      ),
    );
  }

  (int, int) _tileRangeX(LatLngBounds bounds, int zoom) {
    final minX = _longitudeToTileX(bounds.west, zoom);
    final maxX = _longitudeToTileX(bounds.east, zoom);
    return (math.min(minX, maxX), math.max(minX, maxX));
  }

  (int, int) _tileRangeY(LatLngBounds bounds, int zoom) {
    final minY = _latitudeToTileY(bounds.north, zoom);
    final maxY = _latitudeToTileY(bounds.south, zoom);
    return (math.min(minY, maxY), math.max(minY, maxY));
  }

  int _longitudeToTileX(double lon, int zoom) {
    final scale = 1 << zoom;
    return (((lon + 180.0) / 360.0) * scale).floor().clamp(0, scale - 1);
  }

  int _latitudeToTileY(double lat, int zoom) {
    final clippedLat = lat.clamp(-85.05112878, 85.05112878);
    final latRad = clippedLat * math.pi / 180.0;
    final scale = 1 << zoom;
    final value =
        (1.0 - math.log(math.tan(latRad) + (1 / math.cos(latRad))) / math.pi) /
        2.0 *
        scale;
    return value.floor().clamp(0, scale - 1);
  }
}

const List<int> _transparentPngBytes = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];
