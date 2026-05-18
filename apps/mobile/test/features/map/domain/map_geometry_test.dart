import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/features/map/domain/map_geometry.dart';

void main() {
  test(
    'geometryPoints decodes point, line, polygon, and multi geometry bounds',
    () {
      expect(
        geometryPoints(const <String, dynamic>{
          'type': 'Point',
          'coordinates': <double>[35.5, 33.9],
        }).single.latitude,
        33.9,
      );

      expect(
        geometryPoints(const <String, dynamic>{
          'type': 'LineString',
          'coordinates': <List<double>>[
            <double>[35.5, 33.9],
            <double>[35.6, 34.0],
          ],
        }),
        hasLength(2),
      );

      expect(
        geometryPoints(const <String, dynamic>{
          'type': 'Polygon',
          'coordinates': <List<List<double>>>[
            <List<double>>[
              <double>[35.5, 33.9],
              <double>[35.6, 33.9],
              <double>[35.6, 34.0],
              <double>[35.5, 33.9],
            ],
          ],
        }),
        hasLength(4),
      );

      expect(
        geometryPoints(const <String, dynamic>{
          'type': 'MultiPolygon',
          'coordinates': <List<List<List<double>>>>[
            <List<List<double>>>[
              <List<double>>[
                <double>[35.1, 33.1],
                <double>[35.2, 33.1],
                <double>[35.2, 33.2],
                <double>[35.1, 33.1],
              ],
            ],
            <List<List<double>>>[
              <List<double>>[
                <double>[35.3, 33.3],
                <double>[35.4, 33.3],
                <double>[35.4, 33.4],
                <double>[35.3, 33.3],
              ],
            ],
          ],
        }),
        hasLength(8),
      );
    },
  );

  test('geometryPoints accepts lowercase types and geometry collections', () {
    final points = geometryPoints(const <String, dynamic>{
      'type': 'geometrycollection',
      'geometries': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'point',
          'coordinates': <double>[35.5, 33.9],
        },
        <String, dynamic>{
          'type': 'multilinestring',
          'coordinates': <List<List<double>>>[
            <List<double>>[
              <double>[35.6, 34.0],
              <double>[35.7, 34.1],
            ],
          ],
        },
      ],
    });

    expect(points, hasLength(3));
    expect(points.first.longitude, 35.5);
    expect(points.last.latitude, 34.1);
  });

  test('geometryPointsCenter supports collapsed geometry focus fallback', () {
    final points = geometryPoints(const <String, dynamic>{
      'type': 'LineString',
      'coordinates': <List<double>>[
        <double>[35.5, 33.9],
        <double>[35.5, 33.9],
      ],
    });

    expect(geometryPointsCollapseToSingleLocation(points), isTrue);
    expect(geometryPointsCenter(points)?.latitude, 33.9);
    expect(geometryPointsCenter(points)?.longitude, 35.5);
  });
}
