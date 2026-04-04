import 'package:latlong2/latlong.dart';

LatLng? geometryFocusPoint(Map<String, dynamic> geometry) {
  final type = geometry['type'] as String?;
  switch (type) {
    case 'Point':
      final values = _decodeCoordinatePair(geometry['coordinates']);
      return values == null ? null : LatLng(values.$2, values.$1);
    case 'LineString':
      final points = lineGeometryPoints(geometry);
      return points.isEmpty ? null : points.first;
    case 'Polygon':
      final points = polygonGeometryPoints(geometry);
      return points.isEmpty ? null : points.first;
    default:
      return null;
  }
}

List<LatLng> lineGeometryPoints(Map<String, dynamic> geometry) {
  if (geometry['type'] != 'LineString') {
    return const <LatLng>[];
  }
  final coordinates = geometry['coordinates'];
  if (coordinates is! List) {
    return const <LatLng>[];
  }
  return coordinates
      .map(_decodeCoordinatePair)
      .whereType<(double, double)>()
      .map((pair) => LatLng(pair.$2, pair.$1))
      .toList(growable: false);
}

List<LatLng> polygonGeometryPoints(Map<String, dynamic> geometry) {
  if (geometry['type'] != 'Polygon') {
    return const <LatLng>[];
  }
  final coordinates = geometry['coordinates'];
  if (coordinates is! List || coordinates.isEmpty) {
    return const <LatLng>[];
  }
  final firstRing = coordinates.first;
  if (firstRing is! List) {
    return const <LatLng>[];
  }
  return firstRing
      .map(_decodeCoordinatePair)
      .whereType<(double, double)>()
      .map((pair) => LatLng(pair.$2, pair.$1))
      .toList(growable: false);
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
