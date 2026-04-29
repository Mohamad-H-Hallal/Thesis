import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/maps/tile_query.dart';

void main() {
  test('buildVisibleTileQueries coarsens zoom to cap tile fanout', () {
    final queries = buildVisibleTileQueries(
      minLon: 35.0,
      minLat: 33.0,
      maxLon: 36.7,
      maxLat: 34.7,
      zoom: 12.5,
      buffer: 0,
      maxTileCount: 12,
    );

    expect(queries, isNotEmpty);
    expect(queries.length, lessThanOrEqualTo(12));
    expect(queries.map((item) => item.z).toSet().length, 1);
    expect(queries.first.z, lessThan(12));
  });
}
