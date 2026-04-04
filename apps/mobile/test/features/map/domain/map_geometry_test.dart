import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:lebanese_gis_mobile/features/map/domain/map_geometry.dart';

void main() {
  test(
    'geometryFocusPoint returns the first point for point, line, and polygon',
    () {
      expect(
        geometryFocusPoint(<String, dynamic>{
          'type': 'Point',
          'coordinates': <double>[35.5, 33.9],
        }),
        const LatLng(33.9, 35.5),
      );

      expect(
        geometryFocusPoint(<String, dynamic>{
          'type': 'LineString',
          'coordinates': const [
            <double>[35.6, 34.0],
            <double>[35.7, 34.1],
          ],
        }),
        const LatLng(34.0, 35.6),
      );

      expect(
        geometryFocusPoint(<String, dynamic>{
          'type': 'Polygon',
          'coordinates': const [
            [
              <double>[35.4, 33.8],
              <double>[35.5, 33.8],
              <double>[35.5, 33.9],
            ],
          ],
        }),
        const LatLng(33.8, 35.4),
      );
    },
  );

  test(
    'lineGeometryPoints and polygonGeometryPoints ignore malformed coordinates',
    () {
      expect(
        lineGeometryPoints(<String, dynamic>{
          'type': 'LineString',
          'coordinates': const [
            <double>[35.6, 34.0],
            'bad-coordinate',
            <double>[35.7, 34.1],
          ],
        }),
        const <LatLng>[LatLng(34.0, 35.6), LatLng(34.1, 35.7)],
      );

      expect(
        polygonGeometryPoints(<String, dynamic>{
          'type': 'Polygon',
          'coordinates': const [
            [
              <double>[35.4, 33.8],
              <double>[35.5, 33.8],
              'bad-coordinate',
            ],
          ],
        }),
        const <LatLng>[LatLng(33.8, 35.4), LatLng(33.8, 35.5)],
      );
    },
  );

  test('returns empty values for unsupported or malformed geometry', () {
    expect(
      geometryFocusPoint(const <String, dynamic>{'type': 'Unknown'}),
      isNull,
    );
    expect(
      lineGeometryPoints(const <String, dynamic>{'type': 'LineString'}),
      isEmpty,
    );
    expect(
      polygonGeometryPoints(const <String, dynamic>{'type': 'Polygon'}),
      isEmpty,
    );
  });
}
