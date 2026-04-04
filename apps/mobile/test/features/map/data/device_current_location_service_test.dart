import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/features/map/data/device_current_location_service.dart';
import 'package:lebanese_gis_mobile/features/map/domain/current_location_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/location');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'returns a current location snapshot from the platform payload',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'getCurrentLocation');
            return <String, Object?>{
              'latitude': 33.8938,
              'longitude': 35.5018,
              'accuracyMeters': 6.4,
            };
          });

      final service = const DeviceCurrentLocationService(channel: channel);
      final snapshot = await service.fetchCurrentLocation();

      expect(snapshot.position.latitude, closeTo(33.8938, 0.0001));
      expect(snapshot.position.longitude, closeTo(35.5018, 0.0001));
      expect(snapshot.accuracyMeters, closeTo(6.4, 0.0001));
    },
  );

  test('maps permission errors to professional copy', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(
            code: 'LOCATION_PERMISSION_DENIED',
            message:
                'Location permission is needed to center the map on your position.',
          );
        });

    final service = const DeviceCurrentLocationService(channel: channel);

    expect(
      () => service.fetchCurrentLocation(),
      throwsA(
        isA<CurrentLocationFailure>().having(
          (error) => error.message,
          'message',
          'Location permission is needed to center the map on your position.',
        ),
      ),
    );
  });
}
