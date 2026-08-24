import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store_web.dart';
import 'package:lebanese_gis_mobile/core/privacy/deleted_account_local_cleanup.dart';

class _MemorySecureStorage extends FlutterSecureStorage {
  _MemorySecureStorage();

  final Map<String, String> values = <String, String>{};

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map<String, String>.from(values);
}

class _TrackingStore extends MemoryLocalStore {
  final List<String> purgedOwners = <String>[];
  String? failOwner;

  @override
  Future<void> purgeAccountData(String ownerUserId) async {
    purgedOwners.add(ownerUserId);
    if (failOwner == ownerUserId) throw StateError('interrupted cleanup');
    await super.purgeAccountData(ownerUserId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'deleted-account cleanup is owner scoped and removes its durable marker',
    () async {
      final storage = _MemorySecureStorage();
      final store = _TrackingStore();
      final cleanup = DeletedAccountLocalCleanup(
        storage: storage,
        localStore: store,
      );

      await cleanup.markAndPurge('owner-a');

      expect(store.purgedOwners, <String>['owner-a']);
      expect(storage.values, isEmpty);
    },
  );

  test(
    'interrupted cleanup keeps and later resumes the exact owner marker',
    () async {
      final storage = _MemorySecureStorage();
      final store = _TrackingStore()..failOwner = 'owner-a';
      final cleanup = DeletedAccountLocalCleanup(
        storage: storage,
        localStore: store,
      );

      await expectLater(cleanup.markAndPurge('owner-a'), throwsStateError);
      expect(
        storage.values,
        contains('${DeletedAccountLocalCleanup.markerPrefix}owner-a'),
      );

      store.failOwner = null;
      expect(await cleanup.resumePending(), <String>['owner-a']);
      expect(storage.values, isEmpty);
    },
  );
}
