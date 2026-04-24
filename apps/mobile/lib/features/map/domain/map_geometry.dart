import 'package:latlong2/latlong.dart';

LatLng? geometryFocusPoint(Map<String, dynamic> geometry) {
  final points = geometryPoints(geometry);
  return points.isEmpty ? null : points.first;
}

List<LatLng> geometryPoints(Map<String, dynamic> geometry) {
  switch (geometry['type']) {
    case 'Point':
      final values = _decodeCoordinatePair(geometry['coordinates']);
      return values == null
          ? const <LatLng>[]
          : <LatLng>[LatLng(values.$2, values.$1)];
    case 'MultiPoint':
    case 'LineString':
      return _coordinateListToLatLngs(geometry['coordinates']);
    case 'MultiLineString':
      return _flattenCoordinateGroups(geometry['coordinates']);
    case 'Polygon':
      return _firstRingToLatLngs(geometry['coordinates']);
    case 'MultiPolygon':
      return _flattenPolygonGroups(geometry['coordinates']);
    default:
      return const <LatLng>[];
  }
}

List<LatLng> lineGeometryPoints(Map<String, dynamic> geometry) {
  final type = geometry['type'];
  if (type != 'LineString' && type != 'MultiLineString') {
    return const <LatLng>[];
  }
  return geometryPoints(geometry);
}

List<LatLng> polygonGeometryPoints(Map<String, dynamic> geometry) {
  final type = geometry['type'];
  if (type != 'Polygon' && type != 'MultiPolygon') {
    return const <LatLng>[];
  }
  return geometryPoints(geometry);
}

List<LatLng> _coordinateListToLatLngs(Object? raw) {
  if (raw is! List) {
    return const <LatLng>[];
  }
  return raw
      .map(_decodeCoordinatePair)
      .whereType<(double, double)>()
      .map((pair) => LatLng(pair.$2, pair.$1))
      .toList(growable: false);
}

List<LatLng> _flattenCoordinateGroups(Object? raw) {
  if (raw is! List) {
    return const <LatLng>[];
  }
  final points = <LatLng>[];
  for (final group in raw) {
    points.addAll(_coordinateListToLatLngs(group));
  }
  return points;
}

List<LatLng> _firstRingToLatLngs(Object? raw) {
  if (raw is! List || raw.isEmpty) {
    return const <LatLng>[];
  }
  return _coordinateListToLatLngs(raw.first);
}

List<LatLng> _flattenPolygonGroups(Object? raw) {
  if (raw is! List) {
    return const <LatLng>[];
  }
  final points = <LatLng>[];
  for (final polygon in raw) {
    points.addAll(_firstRingToLatLngs(polygon));
  }
  return points;
}

(double, double)? _decodeCoordinatePair(Object? raw) {
  if (raw is! List || raw.length < 2) {
    return null;
  }
  final lon = raw[0];
  final lat = raw[1];
  if (lon is! num || lat is! num) {
    return null;
  }
  return (lon.toDouble(), lat.toDouble());
}
