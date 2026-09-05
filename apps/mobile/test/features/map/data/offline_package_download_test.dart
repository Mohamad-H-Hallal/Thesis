import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/core/offline/local_models.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store_web.dart';
import 'package:lebanese_gis_mobile/features/map/data/offline_tile_cache_manager.dart';
import 'package:lebanese_gis_mobile/features/map/domain/lebanon_map.dart';

class _PackageAdapter implements HttpClientAdapter {
  _PackageAdapter(this.bytes);

  final Uint8List bytes;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromBytes(
      bytes,
      options.headers['Range'] == null ? 200 : 206,
      headers: <String, List<String>>{
        Headers.contentLengthHeader: <String>[bytes.length.toString()],
        Headers.contentTypeHeader: <String>['application/zip'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Uint8List _packageBytes() {
  const png = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        'manifest.json',
        '{"schema_version":1,"package_version":"lb-v1","tile_count":1,'
            '"zoom_min":7,"zoom_max":7,"tile_scheme":"xyz",'
            '"dataset_code":"copernicus_sentinel2_osm_labels"}',
      ),
    )
    ..addFile(ArchiveFile('tiles/7/76/51.tile', png.length, png));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  test(
    'downloads, validates, and atomically installs an account-scoped package',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'terraleb-offline-package-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final bytes = _packageBytes();
      final dio = Dio()..httpClientAdapter = _PackageAdapter(bytes);
      final store = MemoryLocalStore();
      await store.initialize();
      addTearDown(store.dispose);
      final manager = OfflineTileCacheManager(
        localStore: store,
        apiClient: ApiClient(dio: dio),
        rootDirectory: temp,
      );
      final package = OfflineMapPackage(
        ownerUserId: 'user-1',
        version: 'lb-v1',
        zoomLevelMin: 7,
        zoomLevelMax: 7,
        tileCount: 1,
        sizeBytes: bytes.length,
        artifactSizeBytes: bytes.length,
        tileSource: 'copernicus_sentinel2_osm_labels',
        artifactSha256: sha256.convert(bytes).toString(),
        artifactContentType: 'application/zip',
        downloadPath: '/offline-map/current/download',
        lastUpdatedAt: DateTime.utc(2026, 8, 26),
        isCurrent: true,
      );

      final result = await manager.cacheLebanonContributionBaseMap(
        package: package,
      );
      final template = await manager.localTileTemplate(
        package: package,
        basemapStyle: LebanonBasemapStyle.satellite,
      );

      expect(result.downloadedTiles, 1);
      expect(
        await File(
          template
              .replaceAll('{z}', '7')
              .replaceAll('{x}', '76')
              .replaceAll('{y}', '51'),
        ).exists(),
        isTrue,
      );
      expect(
        await manager.hasCompleteLebanonContributionBaseMap(package: package),
        isTrue,
      );
      expect(Directory('${temp.path}/user-2').existsSync(), isFalse);
    },
  );

  test('rejects a package whose published checksum is wrong', () async {
    final temp = await Directory.systemTemp.createTemp(
      'terraleb-offline-package-bad-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final bytes = _packageBytes();
    final store = MemoryLocalStore();
    await store.initialize();
    addTearDown(store.dispose);
    final manager = OfflineTileCacheManager(
      localStore: store,
      apiClient: ApiClient(
        dio: Dio()..httpClientAdapter = _PackageAdapter(bytes),
      ),
      rootDirectory: temp,
    );
    final package = OfflineMapPackage(
      ownerUserId: 'user-1',
      version: 'lb-v1',
      zoomLevelMin: 7,
      zoomLevelMax: 7,
      tileCount: 1,
      sizeBytes: bytes.length,
      artifactSizeBytes: bytes.length,
      tileSource: 'copernicus_sentinel2_osm_labels',
      artifactSha256:
          '0000000000000000000000000000000000000000000000000000000000000000',
      artifactContentType: 'application/zip',
      downloadPath: '/offline-map/current/download',
      lastUpdatedAt: DateTime.utc(2026, 8, 26),
      isCurrent: true,
    );

    await expectLater(
      manager.cacheLebanonContributionBaseMap(package: package),
      throwsA(isA<OfflinePackageIntegrityException>()),
    );
    expect(
      await manager.hasCachedTiles(
        package: package,
        basemapStyle: LebanonBasemapStyle.satellite,
      ),
      isFalse,
    );
  });
}
