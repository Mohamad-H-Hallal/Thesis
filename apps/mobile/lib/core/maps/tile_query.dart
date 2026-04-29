import 'dart:math' as math;

class GeoTileQuery {
  const GeoTileQuery({
    required this.z,
    required this.x,
    required this.y,
  });

  final int z;
  final int x;
  final int y;

  @override
  bool operator ==(Object other) {
    return other is GeoTileQuery &&
        other.z == z &&
        other.x == x &&
        other.y == y;
  }

  @override
  int get hashCode => Object.hash(z, x, y);
}

List<GeoTileQuery> buildVisibleTileQueries({
  required double minLon,
  required double minLat,
  required double maxLon,
  required double maxLat,
  required double zoom,
  int buffer = 1,
  int minZoom = 7,
  int maxZoom = 14,
  int maxTileCount = 12,
}) {
  var tileZoom = zoom.floor().clamp(minZoom, maxZoom);
  final normalizedMinLat = _clampLatitude(minLat);
  final normalizedMaxLat = _clampLatitude(maxLat);
  final normalizedMinLon = minLon.clamp(-180.0, 180.0).toDouble();
  final normalizedMaxLon = maxLon.clamp(-180.0, 180.0).toDouble();
  late int minTileX;
  late int maxTileX;
  late int minTileY;
  late int maxTileY;

  while (true) {
    final n = 1 << tileZoom;

    int clampX(int value) => value.clamp(0, n - 1);
    int clampY(int value) => value.clamp(0, n - 1);

    minTileX = clampX(_lonToTileX(normalizedMinLon, tileZoom) - buffer);
    maxTileX = clampX(_lonToTileX(normalizedMaxLon, tileZoom) + buffer);
    minTileY = clampY(_latToTileY(normalizedMaxLat, tileZoom) - buffer);
    maxTileY = clampY(_latToTileY(normalizedMinLat, tileZoom) + buffer);

    final tileCount = (maxTileX - minTileX + 1) * (maxTileY - minTileY + 1);
    if (tileCount <= maxTileCount || tileZoom <= minZoom) {
      break;
    }
    tileZoom -= 1;
  }

  final queries = <GeoTileQuery>[];
  for (var x = minTileX; x <= maxTileX; x++) {
    for (var y = minTileY; y <= maxTileY; y++) {
      queries.add(GeoTileQuery(z: tileZoom, x: x, y: y));
    }
  }
  return queries;
}

double _clampLatitude(double latitude) =>
    latitude.clamp(-85.05112878, 85.05112878).toDouble();

int _lonToTileX(double lon, int zoom) {
  final n = 1 << zoom;
  final normalized = ((lon + 180.0) / 360.0) * n;
  return normalized.floor();
}

int _latToTileY(double lat, int zoom) {
  final latRad = lat * math.pi / 180.0;
  final n = 1 << zoom;
  final mercator =
      (1.0 - math.log(math.tan(latRad) + (1 / math.cos(latRad))) / math.pi) /
      2.0;
  return (mercator * n).floor();
}
