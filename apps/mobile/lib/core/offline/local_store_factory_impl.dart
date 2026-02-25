import 'local_store.dart';
import 'local_store_mobile.dart' if (dart.library.html) 'local_store_web.dart';

LocalStore createLocalStoreImpl() => createPlatformLocalStore();
