import 'package:latlong2/latlong.dart';

LatLng? geometryFocusPoint(Map<String, dynamic> geometry) {
  final points = geometryPoints(geometry);
  return points.isEmpty ? null : points.first;
}

LatLng? geometryPointsCenter(List<LatLng> points) {
  if (points.isEmpty) {
    return null;
  }
  final latitude =
      points.fold<double>(0, (sum, point) => sum + point.latitude) /
      points.length;
  final longitude =
      points.fold<double>(0, (sum, point) => sum + point.longitude) /
      points.length;
  return LatLng(latitude, longitude);
}

bool geometryPointsCollapseToSingleLocation(List<LatLng> points) {
  if (points.length <= 1) {
    return true;
  }
  final first = points.first;
  return points.every(
    (point) =>
        (point.latitude - first.latitude).abs() < 0.0000001 &&
        (point.longitude - first.longitude).abs() < 0.0000001,
  );
}

List<LatLng> geometryPoints(Map<String, dynamic> geometry) {
  switch (_geometryType(geometry)) {
    case 'point':
      final values = _decodeCoordinatePair(geometry['coordinates']);
      return values == null
          ? const <LatLng>[]
          : <LatLng>[LatLng(values.$2, values.$1)];
    case 'multipoint':
    case 'linestring':
      return _coordinateListToLatLngs(geometry['coordinates']);
    case 'multilinestring':
      return _flattenCoordinateGroups(geometry['coordinates']);
    case 'polygon':
      return _firstRingToLatLngs(geometry['coordinates']);
    case 'multipolygon':
      return _flattenPolygonGroups(geometry['coordinates']);
    case 'geometrycollection':
      final geometries = geometry['geometries'];
      if (geometries is! List) {
        return const <LatLng>[];
      }
      return geometries
          .whereType<Map>()
          .expand((item) => geometryPoints(Map<String, dynamic>.from(item)))
          .toList(growable: false);
    default:
      return const <LatLng>[];
  }
}

List<LatLng> lineGeometryPoints(Map<String, dynamic> geometry) {
  final type = _geometryType(geometry);
  if (type != 'linestring' && type != 'multilinestring') {
    return const <LatLng>[];
  }
  return geometryPoints(geometry);
}

List<LatLng> polygonGeometryPoints(Map<String, dynamic> geometry) {
  final type = _geometryType(geometry);
  if (type != 'polygon' && type != 'multipolygon') {
    return const <LatLng>[];
  }
  return geometryPoints(geometry);
}

String _geometryType(Map<String, dynamic> geometry) =>
    geometry['type']?.toString().trim().toLowerCase() ?? '';

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
