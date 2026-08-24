import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/features/map/domain/app_tile_provider.dart';

void main() {
  test('uses the built-in cancellable network tile provider', () async {
    final provider = appNetworkTileProvider(silenceExceptions: false);
    addTearDown(provider.dispose);

    expect(provider, isA<NetworkTileProvider>());
    final networkProvider = provider as NetworkTileProvider;
    expect(networkProvider.silenceExceptions, isFalse);
    expect(networkProvider.abortObsoleteRequests, isTrue);
    expect(
      networkProvider.headers['User-Agent'],
      isNot('flutter_map (unknown)'),
    );
    expect(networkProvider.headers['User-Agent'], isNotEmpty);
  });
}
