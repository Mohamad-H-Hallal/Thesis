import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/features/map/data/offline_download_foreground_service.dart';
import 'package:lebanese_gis_mobile/main.dart';

void main() {
  test('foreground task integration is disabled on web', () {
    expect(
      OfflineDownloadForegroundService.isAvailableOnPlatform(isWeb: true),
      isFalse,
    );
    expect(
      OfflineDownloadForegroundService.isAvailableOnPlatform(isWeb: false),
      isTrue,
    );
  });

  test('web app does not install the native foreground-task wrapper', () {
    const child = SizedBox(key: ValueKey<String>('web-app'));

    final wrapped = wrapForegroundTaskForPlatform(child: child, isWeb: true);

    expect(wrapped, same(child));
  });
}
