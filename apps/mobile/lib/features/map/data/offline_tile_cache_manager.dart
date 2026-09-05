import 'dart:io';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';
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

class OfflineDownloadCanceledException implements Exception {
  const OfflineDownloadCanceledException();

  @override
  String toString() => 'Offline download canceled.';
}

class OfflineTileDownloadInterruptedException implements Exception {
  const OfflineTileDownloadInterruptedException();

  @override
  String toString() =>
      'Offline map download paused because the network connection was interrupted. Saved map images remain on this phone. Try again to resume.';
}

class OfflinePackageIntegrityException implements Exception {
  const OfflinePackageIntegrityException(this.message);

  final String message;

  @override
  String toString() => message;
}

({int tileCount, int uncompressedBytes}) _extractVerifiedOfflinePackage(
  Map<String, Object?> input,
) {
  final archivePath = input['archivePath']! as String;
  final outputPath = input['outputPath']! as String;
  final packageVersion = input['packageVersion']! as String;
  final expectedTileCount = input['tileCount']! as int;
  final zoomMin = input['zoomMin']! as int;
  final zoomMax = input['zoomMax']! as int;
  final maximumUncompressedBytes = input['maximumUncompressedBytes']! as int;
  final stream = InputFileStream(archivePath);
  final archive = ZipDecoder().decodeStream(stream);
  var tileCount = 0;
  var uncompressedBytes = 0;
  Map<String, dynamic>? manifest;
  try {
    for (final entry in archive) {
      final name = entry.name;
      final normalized = p.posix.normalize(name);
      if (entry.isSymbolicLink ||
          name.contains('\\') ||
          p.posix.isAbsolute(name) ||
          normalized != name ||
          normalized.startsWith('../')) {
        throw const OfflinePackageIntegrityException(
          'The offline package contains an unsafe path.',
        );
      }
      if (entry.isDirectory) continue;
      if (name == 'manifest.json') {
        if (entry.size > 256 * 1024 || manifest != null) {
          throw const OfflinePackageIntegrityException(
            'The offline package manifest is invalid.',
          );
        }
        final decoded = jsonDecode(utf8.decode(entry.readBytes()!));
        if (decoded is! Map) {
          throw const OfflinePackageIntegrityException(
            'The offline package manifest is invalid.',
          );
        }
        manifest = Map<String, dynamic>.from(decoded);
        continue;
      }

      final match = RegExp(
        r'^tiles/(\d{1,2})/(\d+)/(\d+)\.tile$',
      ).firstMatch(name);
      if (match == null || entry.size < 8 || entry.size > 5 * 1024 * 1024) {
        throw const OfflinePackageIntegrityException(
          'The offline package contains an invalid tile entry.',
        );
      }
      final z = int.parse(match.group(1)!);
      final x = int.parse(match.group(2)!);
      final y = int.parse(match.group(3)!);
      final scale = 1 << z;
      int longitudeToX(double longitude) =>
          (((longitude + 180) / 360) * scale).floor();
      int latitudeToY(double latitude) {
        final radians = latitude * math.pi / 180;
        return ((1 -
                    math.log(math.tan(radians) + 1 / math.cos(radians)) /
                        math.pi) /
                2 *
                scale)
            .floor();
      }

      final minX = longitudeToX(35.094);
      final maxX = longitudeToX(36.645);
      final minY = latitudeToY(34.695);
      final maxY = latitudeToY(33.045);
      if (z < zoomMin ||
          z > zoomMax ||
          x < 0 ||
          x >= scale ||
          y < 0 ||
          y >= scale ||
          x < minX ||
          x > maxX ||
          y < minY ||
          y > maxY) {
        throw const OfflinePackageIntegrityException(
          'The offline package contains invalid tile coordinates.',
        );
      }
      tileCount += 1;
      uncompressedBytes += entry.size;
      if (tileCount > expectedTileCount ||
          uncompressedBytes > maximumUncompressedBytes) {
        throw const OfflinePackageIntegrityException(
          'The offline package exceeds its reviewed limits.',
        );
      }
      final relative = name.substring('tiles/'.length);
      final destination = p.joinAll(<String>[
        outputPath,
        ...p.posix.split(relative),
      ]);
      final destinationFile = File(destination);
      destinationFile.parent.createSync(recursive: true);
      final output = OutputFileStream(destination, bufferSize: 256 * 1024);
      try {
        entry.writeContent(output, freeMemory: true);
      } finally {
        output.closeSync();
      }
      final signature = destinationFile.openSync()..setPositionSync(0);
      try {
        final header = signature.readSync(12);
        final isPng =
            header.length >= 8 &&
            header[0] == 0x89 &&
            header[1] == 0x50 &&
            header[2] == 0x4e &&
            header[3] == 0x47;
        final isJpeg =
            header.length >= 3 &&
            header[0] == 0xff &&
            header[1] == 0xd8 &&
            header[2] == 0xff;
        final isWebp =
            header.length >= 12 &&
            ascii.decode(header.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
            ascii.decode(header.sublist(8, 12), allowInvalid: true) == 'WEBP';
        if (!isPng && !isJpeg && !isWebp) {
          throw const OfflinePackageIntegrityException(
            'The offline package contains an unsupported tile image.',
          );
        }
      } finally {
        signature.closeSync();
      }
    }
  } finally {
    archive.clear();
    stream.closeSync();
  }

  if (tileCount != expectedTileCount ||
      manifest?['schema_version'] != 1 ||
      manifest?['package_version'] != packageVersion ||
      manifest?['tile_count'] != expectedTileCount ||
      manifest?['zoom_min'] != zoomMin ||
      manifest?['zoom_max'] != zoomMax ||
      manifest?['tile_scheme'] != 'xyz' ||
      manifest?['dataset_code'] != 'copernicus_sentinel2_osm_labels') {
    throw const OfflinePackageIntegrityException(
      'The offline package manifest does not match the published metadata.',
    );
  }
  return (tileCount: tileCount, uncompressedBytes: uncompressedBytes);
}

Future<({int tileCount, int uncompressedBytes})> _extractPackageInIsolate(
  Map<String, Object?> input,
) => Isolate.run(() => _extractVerifiedOfflinePackage(input));

class OfflineBasemapLicenseRequiredException implements Exception {
  const OfflineBasemapLicenseRequiredException(this.message);

  final String message;

  @override
  String toString() => message;
}

class OfflineDownloadCancelToken {
  static const String _cancelMessage = 'Offline download canceled.';

  final Set<CancelToken> _dioTokens = <CancelToken>{};
  bool _isCanceled = false;

  bool get isCanceled => _isCanceled;

  void cancel() {
    if (_isCanceled) {
      return;
    }
    _isCanceled = true;
    for (final token in List<CancelToken>.of(_dioTokens)) {
      if (!token.isCancelled) {
        token.cancel(_cancelMessage);
      }
    }
    _dioTokens.clear();
  }

  void throwIfCanceled() {
    if (_isCanceled) {
      throw const OfflineDownloadCanceledException();
    }
  }

  CancelToken attachDioToken() {
    final token = CancelToken();
    if (_isCanceled) {
      token.cancel(_cancelMessage);
    } else {
      _dioTokens.add(token);
    }
    return token;
  }

  void detachDioToken(CancelToken token) {
    _dioTokens.remove(token);
  }
}

class OfflineTileCacheManager {
  OfflineTileCacheManager({
    required LocalStore localStore,
    ApiClient? apiClient,
    Directory? rootDirectory,
    bool? licensedEsriOfflineBasemapEnabled,
  }) : _apiClient = apiClient,
       _rootDir = rootDirectory,
       _localStore = localStore,
       _dio = Dio(
         BaseOptions(
           responseType: ResponseType.bytes,
           connectTimeout: const Duration(seconds: 12),
           receiveTimeout: const Duration(seconds: 18),
           headers: <String, String>{'User-Agent': AppEnv.mapProviderUserAgent},
         ),
       );

  final LocalStore _localStore;
  final ApiClient? _apiClient;
  final Dio _dio;
  static const int _tileDownloadConcurrency = 8;
  static const int _tileNetworkFailureAbortThreshold =
      _tileDownloadConcurrency * 3;
  static const Duration _progressMinInterval = Duration(milliseconds: 250);

  Directory? _rootDir;
  File? _transparentTile;

  Future<void> initialize() async {
    if (_rootDir != null && _transparentTile != null) {
      return;
    }

    final appDir = _rootDir == null
        ? await getApplicationDocumentsDirectory()
        : null;
    final root = _rootDir ?? Directory(p.join(appDir!.path, 'offline_tiles'));
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
    final styleDir = await _resolveStyleRootDirectory(
      package: package,
      basemapStyle: basemapStyle,
      migrateLegacyTiles: true,
    );
    return p.join(styleDir.path, '{z}', '{x}', '{y}.tile');
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
    final dir = await _resolveStyleRootDirectory(
      package: package,
      basemapStyle: basemapStyle,
      migrateLegacyTiles: true,
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

  int expectedLebanonContributionTileCount({
    required OfflineMapPackage package,
  }) {
    if (package.isProviderNeutralPackageReady && (package.tileCount ?? 0) > 0) {
      return package.tileCount!;
    }
    final minZoom = _contributionMinZoom(package);
    final maxZoom = _contributionMaxZoom(package);
    return _countTilesForBounds(
      bounds: LebanonMapConfig.bounds,
      minZoom: minZoom,
      maxZoom: maxZoom,
    );
  }

  Future<bool> hasCompleteLebanonContributionBaseMap({
    required OfflineMapPackage package,
    LebanonBasemapStyle basemapStyle = LebanonBasemapStyle.satellite,
  }) async {
    await initialize();
    final expected = expectedLebanonContributionTileCount(package: package);
    if (expected == 0) {
      return false;
    }
    final actual = await _countCachedTiles(
      package: package,
      basemapStyle: basemapStyle,
    );
    return actual == expected &&
        await _packageMarkerMatches(package, basemapStyle);
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

  Future<OfflineTileDownloadSummary> cacheLebanonContributionBaseMap({
    required OfflineMapPackage package,
    LebanonBasemapStyle basemapStyle = LebanonBasemapStyle.satellite,
    void Function(OfflineTileDownloadProgress progress)? onProgress,
    OfflineDownloadCancelToken? cancelToken,
  }) async {
    if (basemapStyle != LebanonBasemapStyle.satellite ||
        !package.isProviderNeutralPackageReady) {
      throw const OfflineBasemapLicenseRequiredException(
        'No verified TerraLeb offline imagery package is currently available.',
      );
    }
    return _downloadProviderNeutralPackage(
      package: package,
      basemapStyle: basemapStyle,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  int _contributionMinZoom(OfflineMapPackage package) {
    return math.max(package.zoomLevelMin, 7);
  }

  int _contributionMaxZoom(OfflineMapPackage package) {
    final minZoom = _contributionMinZoom(package);
    final maxZoom = math.min(package.zoomLevelMax, 15);
    return math.max(minZoom, maxZoom);
  }

  int _countTilesForBounds({
    required LatLngBounds bounds,
    required int minZoom,
    required int maxZoom,
  }) {
    var count = 0;
    for (var zoom = minZoom; zoom <= maxZoom; zoom += 1) {
      final xRange = _tileRangeX(bounds, zoom);
      final yRange = _tileRangeY(bounds, zoom);
      count += (xRange.$2 - xRange.$1 + 1) * (yRange.$2 - yRange.$1 + 1);
    }
    return count;
  }

  Future<int> _countCachedTiles({
    required OfflineMapPackage package,
    required LebanonBasemapStyle basemapStyle,
  }) async {
    final dir = await _resolveStyleRootDirectory(
      package: package,
      basemapStyle: basemapStyle,
      migrateLegacyTiles: true,
    );
    if (!await dir.exists()) {
      return 0;
    }

    var tileCount = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.endsWith('.tile')) {
        tileCount += 1;
      }
    }
    return tileCount;
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
    OfflineDownloadCancelToken? cancelToken,
  }) async {
    _assertOfflineDownloadLicensed(basemapStyle);
    await initialize();
    cancelToken?.throwIfCanceled();

    var requested = 0;
    var downloaded = 0;
    var skipped = 0;
    var failed = 0;
    var sizeBytes = 0;
    final effectiveMinZoom = math.max(0, minZoom);
    final effectiveMaxZoom = math.max(effectiveMinZoom, maxZoom);
    final totalRequested = _countTilesForBounds(
      bounds: bounds,
      minZoom: effectiveMinZoom,
      maxZoom: effectiveMaxZoom,
    );
    var lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
    var networkFailureBurst = 0;

    void reportProgress({bool force = false}) {
      final progressCallback = onProgress;
      if (progressCallback == null) {
        return;
      }
      final now = DateTime.now();
      if (!force &&
          requested < totalRequested &&
          now.difference(lastProgressAt) < _progressMinInterval) {
        return;
      }
      lastProgressAt = now;
      progressCallback(
        OfflineTileDownloadProgress(
          requestedTiles: totalRequested,
          completedTiles: requested,
          downloadedTiles: downloaded,
          skippedTiles: skipped,
          failedTiles: failed,
        ),
      );
    }

    Future<void> processTile(({int z, int x, int y}) tile) async {
      try {
        cancelToken?.throwIfCanceled();
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
          networkFailureBurst = 0;
        } else {
          final created = await _downloadTile(
            basemapStyle: basemapStyle,
            z: tile.z,
            x: tile.x,
            y: tile.y,
            destination: file,
            cancelToken: cancelToken,
          );
          if (created != null) {
            downloaded += 1;
            sizeBytes += created;
            networkFailureBurst = 0;
          } else {
            failed += 1;
          }
        }
      } on OfflineDownloadCanceledException {
        rethrow;
      } on DioException catch (error) {
        if (error.type == DioExceptionType.cancel) {
          throw const OfflineDownloadCanceledException();
        }
        if (_isNetworkInterruption(error)) {
          failed += 1;
          networkFailureBurst += 1;
          if (networkFailureBurst >= _tileNetworkFailureAbortThreshold) {
            throw const OfflineTileDownloadInterruptedException();
          }
          return;
        }
        failed += 1;
      } on OfflineTileDownloadInterruptedException {
        rethrow;
      } catch (_) {
        failed += 1;
      } finally {
        if (cancelToken?.isCanceled != true) {
          requested += 1;
          reportProgress();
        }
      }
    }

    final batch = <Future<void>>[];
    Future<void> flushBatch() async {
      if (batch.isEmpty) {
        return;
      }
      await Future.wait(batch);
      batch.clear();
      await Future<void>.delayed(Duration.zero);
    }

    try {
      for (var zoom = effectiveMinZoom; zoom <= effectiveMaxZoom; zoom += 1) {
        final xRange = _tileRangeX(bounds, zoom);
        final yRange = _tileRangeY(bounds, zoom);
        for (var x = xRange.$1; x <= xRange.$2; x += 1) {
          for (var y = yRange.$1; y <= yRange.$2; y += 1) {
            cancelToken?.throwIfCanceled();
            batch.add(processTile((z: zoom, x: x, y: y)));
            if (batch.length >= _tileDownloadConcurrency) {
              await flushBatch();
            }
          }
        }
      }
      await flushBatch();
      reportProgress(force: true);
    } on OfflineDownloadCanceledException {
      await refreshStats(
        package.copyWith(downloadedAt: DateTime.now()),
        basemapStyle: basemapStyle,
      );
      rethrow;
    } on OfflineTileDownloadInterruptedException {
      await refreshStats(
        package.copyWith(downloadedAt: DateTime.now()),
        basemapStyle: basemapStyle,
      );
      rethrow;
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

  void _assertOfflineDownloadLicensed(LebanonBasemapStyle basemapStyle) {
    throw const OfflineBasemapLicenseRequiredException(
      'Direct provider tile downloads are disabled. Use the verified TerraLeb offline package.',
    );
  }

  Future<OfflineTileDownloadSummary> _downloadProviderNeutralPackage({
    required OfflineMapPackage package,
    required LebanonBasemapStyle basemapStyle,
    void Function(OfflineTileDownloadProgress progress)? onProgress,
    OfflineDownloadCancelToken? cancelToken,
  }) async {
    final apiClient = _apiClient;
    final expectedSize = package.artifactSizeBytes ?? package.sizeBytes;
    final expectedTiles = package.tileCount;
    final expectedSha256 = package.artifactSha256?.toLowerCase();
    final downloadPath = package.downloadPath;
    if (apiClient == null ||
        expectedSize == null ||
        expectedSize <= 0 ||
        expectedSize > 5 * 1024 * 1024 * 1024 ||
        expectedTiles == null ||
        expectedTiles <= 0 ||
        expectedSha256 == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedSha256) ||
        downloadPath == null ||
        !downloadPath.startsWith('/offline-map/')) {
      throw const OfflinePackageIntegrityException(
        'The published offline package metadata is incomplete.',
      );
    }
    await initialize();
    cancelToken?.throwIfCanceled();
    final ownerSegment = _safeFileSegment(package.ownerUserId, 'account');
    final versionSegment = _safeFileSegment(package.version, 'package version');
    final activeDirectory = _scopedStyleRootDirectory(
      package: package,
      basemapStyle: basemapStyle,
    );
    final stagingDirectory = Directory('${activeDirectory.path}.staging');
    final backupDirectory = Directory('${activeDirectory.path}.backup');
    final downloadDirectory = Directory(
      p.join(_rootDir!.path, ownerSegment, '.packages'),
    );
    final partialFile = File(
      p.join(
        downloadDirectory.path,
        '$versionSegment-$expectedSha256.zip.partial',
      ),
    );
    await downloadDirectory.create(recursive: true);

    if (await backupDirectory.exists() && !await activeDirectory.exists()) {
      await backupDirectory.rename(activeDirectory.path);
    } else if (await backupDirectory.exists()) {
      await backupDirectory.delete(recursive: true);
    }
    if (await _packageMarkerMatches(package, basemapStyle)) {
      return OfflineTileDownloadSummary(
        requestedTiles: expectedTiles,
        downloadedTiles: 0,
        skippedTiles: expectedTiles,
        failedTiles: 0,
        sizeBytes: expectedSize,
      );
    }

    var existingBytes = await partialFile.exists()
        ? await partialFile.length()
        : 0;
    if (existingBytes > expectedSize) {
      await partialFile.delete();
      existingBytes = 0;
    }

    Future<Response<dynamic>> downloadFrom(int offset) async {
      final dioCancelToken = cancelToken?.attachDioToken();
      try {
        return await apiClient.dio.download(
          '${AppEnv.apiVersionPrefix}$downloadPath',
          partialFile.path,
          deleteOnError: false,
          cancelToken: dioCancelToken,
          options: Options(
            headers: <String, dynamic>{
              if (offset > 0) 'Range': 'bytes=$offset-',
            },
          ),
          fileAccessMode: offset > 0
              ? FileAccessMode.append
              : FileAccessMode.write,
          onReceiveProgress: (received, total) {
            final completedBytes = (offset + received).clamp(0, expectedSize);
            final approximateTiles =
                ((completedBytes / expectedSize) * expectedTiles).floor();
            onProgress?.call(
              OfflineTileDownloadProgress(
                requestedTiles: expectedTiles,
                completedTiles: approximateTiles.clamp(0, expectedTiles),
                downloadedTiles: approximateTiles.clamp(0, expectedTiles),
                skippedTiles: 0,
                failedTiles: 0,
              ),
            );
          },
        );
      } finally {
        if (dioCancelToken != null) cancelToken?.detachDioToken(dioCancelToken);
      }
    }

    try {
      if (existingBytes < expectedSize) {
        cancelToken?.throwIfCanceled();
        var response = await downloadFrom(existingBytes);
        if (existingBytes > 0 && response.statusCode != 206) {
          await partialFile.delete();
          existingBytes = 0;
          response = await downloadFrom(0);
        }
        if (response.statusCode != 200 && response.statusCode != 206) {
          throw const OfflineTileDownloadInterruptedException();
        }
      }
      cancelToken?.throwIfCanceled();
      if (!await partialFile.exists() ||
          await partialFile.length() != expectedSize) {
        throw const OfflineTileDownloadInterruptedException();
      }
      final actualSha256 = (await sha256.bind(partialFile.openRead()).first)
          .toString();
      if (actualSha256 != expectedSha256) {
        await partialFile.delete();
        throw const OfflinePackageIntegrityException(
          'The downloaded offline package failed checksum validation.',
        );
      }

      if (await stagingDirectory.exists()) {
        await stagingDirectory.delete(recursive: true);
      }
      await stagingDirectory.create(recursive: true);
      final extractionInput = <String, Object?>{
        'archivePath': partialFile.path,
        'outputPath': stagingDirectory.path,
        'packageVersion': package.version,
        'tileCount': expectedTiles,
        'zoomMin': package.zoomLevelMin,
        'zoomMax': package.zoomLevelMax,
        'maximumUncompressedBytes': math.min(
          20 * 1024 * 1024 * 1024,
          math.max(expectedSize * 3, expectedSize + 256 * 1024 * 1024),
        ),
      };
      final extraction = await _extractPackageInIsolate(extractionInput);
      await File(p.join(stagingDirectory.path, '.package.json')).writeAsString(
        jsonEncode(<String, Object?>{
          'schema_version': 1,
          'owner_user_id': package.ownerUserId,
          'package_version': package.version,
          'artifact_sha256': expectedSha256,
          'tile_count': extraction.tileCount,
          'uncompressed_bytes': extraction.uncompressedBytes,
        }),
        flush: true,
      );

      if (await activeDirectory.exists()) {
        await activeDirectory.rename(backupDirectory.path);
      }
      try {
        await stagingDirectory.rename(activeDirectory.path);
      } catch (_) {
        if (!await activeDirectory.exists() && await backupDirectory.exists()) {
          await backupDirectory.rename(activeDirectory.path);
        }
        rethrow;
      }
      if (await backupDirectory.exists()) {
        await backupDirectory.delete(recursive: true);
      }
      await partialFile.delete();
      onProgress?.call(
        OfflineTileDownloadProgress(
          requestedTiles: expectedTiles,
          completedTiles: expectedTiles,
          downloadedTiles: expectedTiles,
          skippedTiles: 0,
          failedTiles: 0,
        ),
      );
      await _localStore.upsertOfflineMapPackage(
        package.copyWith(
          downloadedAt: DateTime.now(),
          tileCount: expectedTiles,
          artifactSizeBytes: expectedSize,
        ),
      );
      return OfflineTileDownloadSummary(
        requestedTiles: expectedTiles,
        downloadedTiles: expectedTiles,
        skippedTiles: 0,
        failedTiles: 0,
        sizeBytes: expectedSize,
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) {
        throw const OfflineDownloadCanceledException();
      }
      throw const OfflineTileDownloadInterruptedException();
    } on OfflinePackageIntegrityException {
      if (await stagingDirectory.exists()) {
        try {
          await stagingDirectory.delete(recursive: true);
        } catch (_) {}
      }
      if (await partialFile.exists()) {
        try {
          await partialFile.delete();
        } catch (_) {}
      }
      rethrow;
    } on FileSystemException {
      if (await stagingDirectory.exists()) {
        try {
          await stagingDirectory.delete(recursive: true);
        } catch (_) {}
      }
      throw StateError(
        'The offline package could not be saved. Free device storage and try again.',
      );
    }
  }

  Future<bool> _packageMarkerMatches(
    OfflineMapPackage package,
    LebanonBasemapStyle basemapStyle,
  ) async {
    if (!package.isProviderNeutralPackageReady) return false;
    final directory = _scopedStyleRootDirectory(
      package: package,
      basemapStyle: basemapStyle,
    );
    final marker = File(p.join(directory.path, '.package.json'));
    if (!await marker.exists()) return false;
    try {
      final decoded = jsonDecode(await marker.readAsString());
      return decoded is Map &&
          decoded['owner_user_id'] == package.ownerUserId &&
          decoded['package_version'] == package.version &&
          decoded['artifact_sha256'] == package.artifactSha256 &&
          decoded['tile_count'] == package.tileCount;
    } catch (_) {
      return false;
    }
  }

  Future<OfflineMapPackage> refreshStats(
    OfflineMapPackage package, {
    LebanonBasemapStyle basemapStyle = LebanonBasemapStyle.satellite,
  }) async {
    await initialize();
    final dir = await _resolveStyleRootDirectory(
      package: package,
      basemapStyle: basemapStyle,
      migrateLegacyTiles: true,
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
      if (entity is! File || !entity.path.endsWith('.tile')) {
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
    final dir = await _resolveStyleRootDirectory(
      package: package,
      basemapStyle: basemapStyle,
      migrateLegacyTiles: true,
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
    final dir = await _resolveStyleRootDirectory(
      package: package,
      basemapStyle: basemapStyle,
      migrateLegacyTiles: true,
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
    OfflineDownloadCancelToken? cancelToken,
  }) async {
    cancelToken?.throwIfCanceled();
    await destination.parent.create(recursive: true);
    final url = LebanonMapConfig.basemapUrlTemplate(
      basemapStyle,
    ).replaceAll('{z}', '$z').replaceAll('{x}', '$x').replaceAll('{y}', '$y');

    final dioCancelToken = cancelToken?.attachDioToken();
    try {
      final response = await _dio.get<List<int>>(
        url,
        cancelToken: dioCancelToken,
      );
      cancelToken?.throwIfCanceled();
      final bytes = Uint8List.fromList(response.data ?? const <int>[]);
      if (bytes.isEmpty) {
        return null;
      }
      await destination.writeAsBytes(bytes, flush: true);
      cancelToken?.throwIfCanceled();
      return bytes.length;
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) {
        throw const OfflineDownloadCanceledException();
      }
      rethrow;
    } finally {
      if (dioCancelToken != null) {
        cancelToken?.detachDioToken(dioCancelToken);
      }
    }
  }

  bool _isNetworkInterruption(DioException error) {
    return error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.unknown;
  }

  Future<String> _tilePath({
    required OfflineMapPackage package,
    required LebanonBasemapStyle basemapStyle,
    required int z,
    required int x,
    required int y,
  }) async {
    await initialize();
    final styleDir = await _resolveStyleRootDirectory(
      package: package,
      basemapStyle: basemapStyle,
      migrateLegacyTiles: true,
    );
    return p.join(styleDir.path, '$z', '$x', '$y.tile');
  }

  Future<Directory> _resolveStyleRootDirectory({
    required OfflineMapPackage package,
    required LebanonBasemapStyle basemapStyle,
    bool migrateLegacyTiles = false,
  }) async {
    await initialize();
    final scoped = _scopedStyleRootDirectory(
      package: package,
      basemapStyle: basemapStyle,
    );
    if (package.ownerUserId.trim().isEmpty) {
      return scoped;
    }

    final legacy = _legacyStyleRootDirectory(
      package: package,
      basemapStyle: basemapStyle,
    );
    if (migrateLegacyTiles && !await scoped.exists() && await legacy.exists()) {
      await scoped.parent.create(recursive: true);
      await legacy.rename(scoped.path);
      return scoped;
    }

    if (await scoped.exists()) {
      return scoped;
    }
    if (await legacy.exists()) {
      return legacy;
    }
    return scoped;
  }

  Directory _scopedStyleRootDirectory({
    required OfflineMapPackage package,
    required LebanonBasemapStyle basemapStyle,
  }) {
    final ownerSegment = package.ownerUserId.trim().isEmpty
        ? ''
        : _safeFileSegment(package.ownerUserId, 'account');
    final segments = <String>[_rootDir!.path];
    if (ownerSegment.isNotEmpty) {
      segments.add(ownerSegment);
    }
    segments
      ..add(_safeFileSegment(package.version, 'package version'))
      ..add(basemapStyle.name);
    return Directory(p.joinAll(segments));
  }

  Directory _legacyStyleRootDirectory({
    required OfflineMapPackage package,
    required LebanonBasemapStyle basemapStyle,
  }) {
    return Directory(
      p.join(
        _rootDir!.path,
        _safeFileSegment(package.version, 'package version'),
        basemapStyle.name,
      ),
    );
  }

  String _safeFileSegment(String value, String label) {
    final normalized = value.trim();
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(normalized)) {
      throw OfflinePackageIntegrityException('The offline $label is invalid.');
    }
    return normalized;
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
