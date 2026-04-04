import 'package:latlong2/latlong.dart';

class CurrentLocationFailure implements Exception {
  const CurrentLocationFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

class CurrentLocationSnapshot {
  const CurrentLocationSnapshot({required this.position, this.accuracyMeters});

  final LatLng position;
  final double? accuracyMeters;
}

abstract class CurrentLocationService {
  Future<CurrentLocationSnapshot> fetchCurrentLocation();
}
