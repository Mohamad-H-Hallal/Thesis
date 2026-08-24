import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/offline/local_models.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store_web.dart';
import 'package:lebanese_gis_mobile/features/map/data/offline_tile_cache_manager.dart';
import 'package:lebanese_gis_mobile/features/map/domain/lebanon_map.dart';

void main() {
  test(
    'public OSM and unapproved Esri sources cannot be bulk downloaded',
    () async {
      final store = MemoryLocalStore();
      await store.initialize();
      addTearDown(store.dispose);
      final manager = OfflineTileCacheManager(
        localStore: store,
        licensedEsriOfflineBasemapEnabled: false,
      );
      final package = OfflineMapPackage(
        ownerUserId: 'owner-1',
        version: 'base-v1',
        zoomLevelMin: 7,
        zoomLevelMax: 8,
        lastUpdatedAt: DateTime.utc(2026, 8, 12),
        isCurrent: true,
      );

      for (final style in LebanonBasemapStyle.values) {
        expect(
          () => manager.cacheRegion(
            package: package,
            basemapStyle: style,
            bounds: LatLngBounds(
              LebanonMapConfig.southWest,
              LebanonMapConfig.northEast,
            ),
            minZoom: 7,
            maxZoom: 7,
          ),
          throwsA(isA<OfflineBasemapLicenseRequiredException>()),
        );
      }
    },
  );
}
