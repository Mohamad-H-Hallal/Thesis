import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/offline/local_database_security.dart';
import 'package:lebanese_gis_mobile/core/security/secure_string_store.dart';

class _MemorySecureStringStore implements SecureStringStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  group('inspectLocalDatabaseFile', () {
    late Directory tempDirectory;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp(
        'local-database-security-',
      );
    });

    tearDown(() async {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    test('recognizes missing, plaintext, and unknown database files', () async {
      final database = File('${tempDirectory.path}/offline.db');
      expect(
        await inspectLocalDatabaseFile(database),
        LocalDatabaseFileState.missing,
      );

      await database.writeAsBytes(<int>[
        ...utf8.encode('SQLite format 3\u0000'),
        ...List<int>.filled(32, 0),
      ]);
      expect(
        await inspectLocalDatabaseFile(database),
        LocalDatabaseFileState.plaintext,
      );

      await database.writeAsBytes(List<int>.generate(64, (index) => index + 1));
      expect(
        await inspectLocalDatabaseFile(database),
        LocalDatabaseFileState.encryptedOrUnknown,
      );

      await database.writeAsBytes(const <int>[]);
      expect(
        await inspectLocalDatabaseFile(database),
        LocalDatabaseFileState.encryptedOrUnknown,
      );
    });
  });

  group('LocalDatabaseKeyManager', () {
    test(
      'creates and persists one canonical 256-bit installation key',
      () async {
        final storage = _MemorySecureStringStore();
        final manager = LocalDatabaseKeyManager(
          storage,
          randomBytes: (length) =>
              Uint8List.fromList(List<int>.generate(length, (index) => index)),
        );

        final first = await manager.loadOrCreateKey(
          LocalDatabaseFileState.plaintext,
        );
        final second = await manager.loadOrCreateKey(
          LocalDatabaseFileState.encryptedOrUnknown,
        );

        expect(second, first);
        expect(LocalDatabaseKeyManager.decodeKey(first), hasLength(32));
        expect(
          storage.values[LocalDatabaseKeyManager.databaseKeyFormatStorageKey],
          LocalDatabaseKeyManager.databaseKeyFormatVersion,
        );
      },
    );

    test('restores a valid key and repairs a missing format marker', () async {
      final storage = _MemorySecureStringStore();
      final key = base64Url.encode(List<int>.filled(32, 7)).replaceAll('=', '');
      storage.values[LocalDatabaseKeyManager.databaseKeyStorageKey] = key;

      final restored = await LocalDatabaseKeyManager(
        storage,
      ).loadOrCreateKey(LocalDatabaseFileState.encryptedOrUnknown);

      expect(restored, key);
      expect(
        storage.values[LocalDatabaseKeyManager.databaseKeyFormatStorageKey],
        LocalDatabaseKeyManager.databaseKeyFormatVersion,
      );
    });

    test('fails closed when an encrypted or unknown database has no key', () {
      final manager = LocalDatabaseKeyManager(_MemorySecureStringStore());

      expect(
        () =>
            manager.loadOrCreateKey(LocalDatabaseFileState.encryptedOrUnknown),
        throwsA(isA<LocalDatabaseSecurityException>()),
      );
    });

    test('fails closed when a format marker exists without its key', () {
      final storage = _MemorySecureStringStore()
        ..values[LocalDatabaseKeyManager.databaseKeyFormatStorageKey] =
            LocalDatabaseKeyManager.databaseKeyFormatVersion;
      final manager = LocalDatabaseKeyManager(storage);

      expect(
        () => manager.loadOrCreateKey(LocalDatabaseFileState.missing),
        throwsA(isA<LocalDatabaseSecurityException>()),
      );
    });

    test('fails closed for malformed or unsupported stored key material', () {
      final malformedStorage = _MemorySecureStringStore()
        ..values[LocalDatabaseKeyManager.databaseKeyStorageKey] = 'not-a-key';
      final unsupportedStorage = _MemorySecureStringStore()
        ..values[LocalDatabaseKeyManager.databaseKeyStorageKey] = base64Url
            .encode(List<int>.filled(32, 1))
            .replaceAll('=', '')
        ..values[LocalDatabaseKeyManager.databaseKeyFormatStorageKey] = '2';

      expect(
        () => LocalDatabaseKeyManager(
          malformedStorage,
        ).loadOrCreateKey(LocalDatabaseFileState.plaintext),
        throwsA(isA<LocalDatabaseSecurityException>()),
      );
      expect(
        () => LocalDatabaseKeyManager(
          unsupportedStorage,
        ).loadOrCreateKey(LocalDatabaseFileState.plaintext),
        throwsA(isA<LocalDatabaseSecurityException>()),
      );
    });

    test('rejects a random source that does not return 256 bits', () {
      final manager = LocalDatabaseKeyManager(
        _MemorySecureStringStore(),
        randomBytes: (_) => Uint8List(31),
      );

      expect(
        () => manager.loadOrCreateKey(LocalDatabaseFileState.missing),
        throwsA(isA<LocalDatabaseSecurityException>()),
      );
    });
  });
}
