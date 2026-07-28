import 'local_database_security.dart';
import 'local_store.dart';
import 'local_store_factory_impl.dart';

LocalStore createLocalStore({
  required LocalDatabaseKeyManager databaseKeyManager,
}) => createLocalStoreImpl(databaseKeyManager: databaseKeyManager);
