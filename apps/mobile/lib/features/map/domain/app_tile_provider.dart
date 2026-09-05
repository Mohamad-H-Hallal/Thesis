import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/app_env.dart';
import '../../../core/network/api_client.dart';

enum MapProviderAvailability { ready, degraded }

final ValueNotifier<MapProviderAvailability> mapProviderAvailability =
    ValueNotifier<MapProviderAvailability>(MapProviderAvailability.ready);

class AuthenticatedMapHttpClient extends http.BaseClient {
  AuthenticatedMapHttpClient({
    required ApiClient apiClient,
    http.Client? externalClient,
  }) : _apiClient = apiClient,
       _externalClient = externalClient ?? http.Client();

  final ApiClient _apiClient;
  final http.Client _externalClient;

  bool _isTerraLebMapRequest(Uri uri) {
    final api = Uri.parse(AppEnv.apiBaseUrl);
    final expectedPath = '${AppEnv.apiVersionPrefix}/maps/';
    return uri.scheme == api.scheme &&
        uri.host == api.host &&
        uri.port == api.port &&
        uri.path.startsWith(expectedPath);
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!_isTerraLebMapRequest(request.url)) {
      request.headers.remove('Authorization');
      return _externalClient.send(request);
    }

    try {
      final response = await _apiClient.dio.get<ResponseBody>(
        request.url.toString(),
        options: Options(
          responseType: ResponseType.stream,
          headers: <String, dynamic>{
            for (final entry in request.headers.entries)
              if (entry.key.toLowerCase() != 'authorization' &&
                  entry.key.toLowerCase() != 'host')
                entry.key: entry.value,
          },
        ),
      );
      mapProviderAvailability.value = MapProviderAvailability.ready;
      final body = response.data;
      return http.StreamedResponse(
        body?.stream.cast<List<int>>() ?? const Stream<List<int>>.empty(),
        response.statusCode ?? 200,
        contentLength: int.tryParse(
          response.headers.value(Headers.contentLengthHeader) ?? '',
        ),
        headers: <String, String>{
          for (final entry in response.headers.map.entries)
            entry.key: entry.value.join(','),
        },
        request: request,
      );
    } on DioException catch (error) {
      mapProviderAvailability.value = MapProviderAvailability.degraded;
      final response = error.response;
      final body = response?.data;
      final stream = body is ResponseBody
          ? body.stream.cast<List<int>>()
          : const Stream<List<int>>.empty();
      return http.StreamedResponse(
        stream,
        response?.statusCode ?? 503,
        headers: <String, String>{
          if (response != null)
            for (final entry in response.headers.map.entries)
              entry.key: entry.value.join(','),
        },
        request: request,
      );
    }
  }

  @override
  void close() {
    _externalClient.close();
    super.close();
  }
}

TileProvider appNetworkTileProvider({
  required ApiClient apiClient,
  bool silenceExceptions = true,
}) {
  return NetworkTileProvider(
    silenceExceptions: silenceExceptions,
    headers: <String, String>{'User-Agent': AppEnv.mapProviderUserAgent},
    httpClient: AuthenticatedMapHttpClient(apiClient: apiClient),
  );
}
