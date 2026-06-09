import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/config/app_env.dart';

void main() {
  test('environment getters stay runtime-safe', () {
    expect(() => AppEnv.flavor, returnsNormally);
    expect(() => AppEnv.apiBaseUrl, returnsNormally);
    expect(() => AppEnv.apiVersionPrefix, returnsNormally);
    expect(() => AppEnv.useMockAuth, returnsNormally);
    expect(() => AppEnv.useMockData, returnsNormally);
    expect(() => AppEnv.pushNotificationsRequested, returnsNormally);
    expect(() => AppEnv.androidPushNotificationsRequested, returnsNormally);
    expect(() => AppEnv.iosPushNotificationsRequested, returnsNormally);
  });

  test('push notifications are opt-in for dev builds', () {
    expect(AppEnv.flavor, AppFlavor.dev);
    expect(AppEnv.pushNotificationsRequested, isFalse);
    expect(AppEnv.androidPushNotificationsRequested, isFalse);
    expect(AppEnv.iosPushNotificationsRequested, isFalse);
  });
}
