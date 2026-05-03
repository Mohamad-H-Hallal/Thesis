import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';

TileProvider appNetworkTileProvider({bool silenceExceptions = true}) {
  return CancellableNetworkTileProvider(silenceExceptions: silenceExceptions);
}
