import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/config/app_env.dart';

void main() {
  test('environment getters stay runtime-safe', () {
    expect(() => AppEnv.flavor, returnsNormally);
    expect(() => AppEnv.apiBaseUrl, returnsNormally);
    expect(() => AppEnv.apiVersionPrefix, returnsNormally);
    const mockAuthRaw = String.fromEnvironment(
      'USE_MOCK_AUTH',
      defaultValue: '',
    );
    final mockAuthEnabled = switch (mockAuthRaw.trim().toLowerCase()) {
      '1' || 'true' || 'yes' => true,
      _ => false,
    };
    if (AppEnv.flavor == AppFlavor.prod && mockAuthEnabled) {
      expect(() => AppEnv.useMockAuth, throwsStateError);
    } else {
      expect(() => AppEnv.useMockAuth, returnsNormally);
    }
    expect(() => AppEnv.useMockData, returnsNormally);
    expect(() => AppEnv.pushNotificationsRequested, returnsNormally);
    expect(() => AppEnv.androidPushNotificationsRequested, returnsNormally);
    expect(() => AppEnv.iosPushNotificationsRequested, returnsNormally);
  });
}
