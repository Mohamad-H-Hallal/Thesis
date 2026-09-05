import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lebanese_gis_mobile/core/config/app_env.dart';
import 'package:lebanese_gis_mobile/core/network/api_client.dart';
import 'package:lebanese_gis_mobile/features/map/domain/app_tile_provider.dart';

class _RecordingHttpClient extends http.BaseClient {
  http.BaseRequest? request;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    this.request = request;
    return http.StreamedResponse(Stream<List<int>>.value(<int>[1]), 200);
  }
}

class _RecordingDioAdapter implements HttpClientAdapter {
  RequestOptions? request;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody.fromBytes(
      <int>[1, 2, 3],
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['image/jpeg'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('uses the built-in cancellable network tile provider', () async {
    final provider = appNetworkTileProvider(
      apiClient: ApiClient(dio: Dio()),
      silenceExceptions: false,
    );
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

  test('never forwards authorization to an external map host', () async {
    final external = _RecordingHttpClient();
    final client = AuthenticatedMapHttpClient(
      apiClient: ApiClient(dio: Dio()),
      externalClient: external,
    );
    addTearDown(client.close);
    final request = http.Request(
      'GET',
      Uri.parse('https://tile.openstreetmap.org/10/613/409.png'),
    )..headers['Authorization'] = 'Bearer must-not-leave';

    await client.send(request);

    expect(external.request?.headers['Authorization'], isNull);
  });

  test('uses the centralized API client for TerraLeb proxy tiles', () async {
    final adapter = _RecordingDioAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:3000'))
      ..httpClientAdapter = adapter
      ..options.headers['Authorization'] = 'Bearer current-session';
    final client = AuthenticatedMapHttpClient(apiClient: ApiClient(dio: dio));
    addTearDown(client.close);

    final response = await client.send(
      http.Request(
        'GET',
        Uri.parse(
          '${AppEnv.apiBaseUrl}${AppEnv.apiVersionPrefix}/maps/tiles/imagery/10/409/613',
        ),
      ),
    );

    expect(response.statusCode, 200);
    expect(adapter.request?.headers['Authorization'], 'Bearer current-session');
    expect(mapProviderAvailability.value, MapProviderAvailability.ready);
  });
}
