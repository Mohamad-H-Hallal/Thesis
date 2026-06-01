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
    case 'multipoint':
      return pointGeometryPoints(geometry);
    case 'linestring':
    case 'multilinestring':
      return lineGeometryPoints(geometry);
    case 'polygon':
    case 'multipolygon':
      return polygonGeometryPoints(geometry);
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

bool isPointGeometry(Map<String, dynamic> geometry) {
  final type = _geometryType(geometry);
  return type == 'point' || type == 'multipoint';
}

bool isLineGeometry(Map<String, dynamic> geometry) {
  final type = _geometryType(geometry);
  return type == 'linestring' || type == 'multilinestring';
}

bool isPolygonGeometry(Map<String, dynamic> geometry) {
  final type = _geometryType(geometry);
  return type == 'polygon' || type == 'multipolygon';
}

List<LatLng> pointGeometryPoints(Map<String, dynamic> geometry) {
  switch (_geometryType(geometry)) {
    case 'point':
      final values = _decodeCoordinatePair(geometry['coordinates']);
      return values == null
          ? const <LatLng>[]
          : <LatLng>[LatLng(values.$2, values.$1)];
    case 'multipoint':
      return _coordinateListToLatLngs(geometry['coordinates']);
    default:
      return const <LatLng>[];
  }
}

List<LatLng> lineGeometryPoints(Map<String, dynamic> geometry) {
  return lineGeometrySegments(
    geometry,
  ).expand((segment) => segment).toList(growable: false);
}

List<List<LatLng>> lineGeometrySegments(Map<String, dynamic> geometry) {
  switch (_geometryType(geometry)) {
    case 'linestring':
      final points = _coordinateListToLatLngs(geometry['coordinates']);
      return points.isEmpty ? const <List<LatLng>>[] : <List<LatLng>>[points];
    case 'multilinestring':
      final coordinates = geometry['coordinates'];
      if (coordinates is! List) {
        return const <List<LatLng>>[];
      }
      return coordinates
          .map(_coordinateListToLatLngs)
          .where((points) => points.isNotEmpty)
          .toList(growable: false);
    default:
      return const <List<LatLng>>[];
  }
}

List<LatLng> polygonGeometryPoints(Map<String, dynamic> geometry) {
  return polygonGeometrySegments(
    geometry,
  ).expand((segment) => segment).toList(growable: false);
}

List<List<LatLng>> polygonGeometrySegments(Map<String, dynamic> geometry) {
  switch (_geometryType(geometry)) {
    case 'polygon':
      final points = _firstRingToLatLngs(geometry['coordinates']);
      return points.isEmpty ? const <List<LatLng>>[] : <List<LatLng>>[points];
    case 'multipolygon':
      final coordinates = geometry['coordinates'];
      if (coordinates is! List) {
        return const <List<LatLng>>[];
      }
      return coordinates
          .map(_firstRingToLatLngs)
          .where((points) => points.isNotEmpty)
          .toList(growable: false);
    default:
      return const <List<LatLng>>[];
  }
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

List<LatLng> _firstRingToLatLngs(Object? raw) {
  if (raw is! List || raw.isEmpty) {
    return const <LatLng>[];
  }
  return _coordinateListToLatLngs(raw.first);
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
