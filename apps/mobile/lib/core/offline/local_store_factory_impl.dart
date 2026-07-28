import 'local_database_security.dart';
import 'local_store.dart';
import 'local_store_mobile.dart' if (dart.library.html) 'local_store_web.dart';

LocalStore createLocalStoreImpl({
  required LocalDatabaseKeyManager databaseKeyManager,
}) => createPlatformLocalStore(databaseKeyManager: databaseKeyManager);
