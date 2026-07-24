import 'package:flutter_map/flutter_map.dart';

TileProvider appNetworkTileProvider({bool silenceExceptions = true}) {
  return NetworkTileProvider(silenceExceptions: silenceExceptions);
}
