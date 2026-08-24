import 'package:flutter_map/flutter_map.dart';

import '../../../core/config/app_env.dart';

TileProvider appNetworkTileProvider({bool silenceExceptions = true}) {
  return NetworkTileProvider(
    silenceExceptions: silenceExceptions,
    headers: <String, String>{'User-Agent': AppEnv.mapProviderUserAgent},
  );
}
