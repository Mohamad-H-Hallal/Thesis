import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../domain/current_location_service.dart';

class DeviceCurrentLocationService implements CurrentLocationService {
  const DeviceCurrentLocationService({
    MethodChannel channel = const MethodChannel(_channelName),
  }) : _channel = channel;

  static const String _channelName = 'lb.gov.gis_collector/location';

  final MethodChannel _channel;

  @override
  Future<CurrentLocationSnapshot> fetchCurrentLocation() async {
    try {
      final payload = await _channel.invokeMapMethod<String, Object?>(
        'getCurrentLocation',
      );
      if (payload == null) {
        throw const CurrentLocationFailure(
          'Current location is unavailable right now.',
        );
      }

      final latitude = (payload['latitude'] as num?)?.toDouble();
      final longitude = (payload['longitude'] as num?)?.toDouble();
      if (latitude == null || longitude == null) {
        throw const CurrentLocationFailure(
          'Current location is unavailable right now.',
        );
      }

      final accuracyMeters = (payload['accuracyMeters'] as num?)?.toDouble();
      return CurrentLocationSnapshot(
        position: LatLng(latitude, longitude),
        accuracyMeters: accuracyMeters,
      );
    } on PlatformException catch (error) {
      throw CurrentLocationFailure(_messageForPlatformError(error));
    } on MissingPluginException {
      throw const CurrentLocationFailure(
        'Current location is available only on the Android field app runtime.',
      );
    }
  }

  String _messageForPlatformError(PlatformException error) {
    switch (error.code) {
      case 'LOCATION_SERVICE_DISABLED':
        return 'Location services are turned off on this device.';
      case 'LOCATION_PERMISSION_DENIED':
        return 'Location permission is needed to center the map on your position.';
      case 'LOCATION_PERMISSION_DENIED_FOREVER':
        return 'Location permission has been permanently denied for this app.';
      case 'LOCATION_UNAVAILABLE':
        return 'Current location is unavailable right now.';
      case 'LOCATION_BUSY':
        return 'Location is already being requested. Please wait a moment.';
      default:
        return error.message?.trim().isNotEmpty == true
            ? error.message!
            : 'Current location is unavailable right now.';
    }
  }
}
