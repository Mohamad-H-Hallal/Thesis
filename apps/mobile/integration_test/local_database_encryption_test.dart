import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lebanese_gis_mobile/core/offline/local_database_migration.dart';
import 'package:lebanese_gis_mobile/core/offline/local_database_security.dart';
import 'package:lebanese_gis_mobile/core/offline/local_photo_security.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store_mobile.dart';
import 'package:lebanese_gis_mobile/core/security/secure_string_store.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

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
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'SQLCipher migrates plaintext without row loss and rejects a wrong key',
    (tester) async {
      final tempDirectory = await getTemporaryDirectory();
      final path = p.join(tempDirectory.path, 'sqlcipher-migration-test.db');
      await _deleteDatabaseArtifacts(path);
      addTearDown(() => _deleteDatabaseArtifacts(path));

      final plaintext = await openDatabase(
        path,
        version: 3,
        singleInstance: false,
        onCreate: (database, version) async {
          await database.execute(
            'CREATE TABLE migration_test (id INTEGER PRIMARY KEY, value TEXT)',
          );
          await database.insert('migration_test', <String, Object?>{
            'id': 1,
            'value': 'preserved offline value',
          });
        },
      );
      await plaintext.close();

      expect(
        await inspectLocalDatabaseFile(File(path)),
        LocalDatabaseFileState.plaintext,
      );

      const password = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';
      await prepareEncryptedLocalDatabase(
        databasePath: path,
        password: password,
      );

      expect(
        await inspectLocalDatabaseFile(File(path)),
        LocalDatabaseFileState.encryptedOrUnknown,
      );
      expect(await File('$path.cipher.tmp').exists(), isFalse);
      expect(await File('$path.plaintext.bak').exists(), isFalse);

      final encrypted = await openDatabase(
        path,
        password: password,
        singleInstance: false,
      );
      expect(await encrypted.query('migration_test'), <Map<String, Object?>>[
        <String, Object?>{'id': 1, 'value': 'preserved offline value'},
      ]);
      expect(
        Sqflite.firstIntValue(await encrypted.rawQuery('PRAGMA user_version')),
        3,
      );
      final cipherVersion = (await encrypted.rawQuery(
        'PRAGMA cipher_version',
      )).single.values.single;
      expect(isSqlCipherVersionAllowed('$cipherVersion'), isTrue);
      await encrypted.close();

      await prepareEncryptedLocalDatabase(
        databasePath: path,
        password: password,
      );

      await expectLater(
        openDatabase(path, password: 'wrong-key', singleInstance: false),
        throwsA(isA<DatabaseException>()),
      );

      final preservedAfterWrongKey = await openDatabase(
        path,
        password: password,
        singleInstance: false,
      );
      expect(
        await preservedAfterWrongKey.query('migration_test'),
        hasLength(1),
      );
      await preservedAfterWrongKey.close();
    },
  );

  testWidgets(
    'plaintext schema versions 1 through 8 preserve typed row content',
    (tester) async {
      final tempDirectory = await getTemporaryDirectory();
      const password = 'schema-version-matrix-key';

      for (var version = 1; version <= 8; version += 1) {
        final path = p.join(
          tempDirectory.path,
          'sqlcipher-schema-v$version-test.db',
        );
        await _deleteDatabaseArtifacts(path);
        addTearDown(() => _deleteDatabaseArtifacts(path));

        final plaintext = await openDatabase(
          path,
          version: version,
          singleInstance: false,
          onCreate: (database, createdVersion) async {
            await database.execute('''
              CREATE TABLE migration_matrix (
                id INTEGER PRIMARY KEY,
                text_value TEXT NOT NULL,
                integer_value INTEGER NOT NULL,
                real_value REAL NOT NULL,
                blob_value BLOB NOT NULL,
                nullable_value TEXT
              )
            ''');
            await database.insert('migration_matrix', <String, Object?>{
              'id': createdVersion,
              'text_value': 'schema-$createdVersion',
              'integer_value': createdVersion * 100,
              'real_value': createdVersion + 0.25,
              'blob_value': Uint8List.fromList(<int>[0, createdVersion, 255]),
              'nullable_value': null,
            });
          },
        );
        await plaintext.close();

        await prepareEncryptedLocalDatabase(
          databasePath: path,
          password: password,
        );

        final encrypted = await openDatabase(
          path,
          password: password,
          singleInstance: false,
        );
        expect(
          Sqflite.firstIntValue(
            await encrypted.rawQuery('PRAGMA user_version'),
          ),
          version,
        );
        final row = (await encrypted.query('migration_matrix')).single;
        expect(row['id'], version);
        expect(row['text_value'], 'schema-$version');
        expect(row['integer_value'], version * 100);
        expect(row['real_value'], version + 0.25);
        expect(List<int>.from(row['blob_value']! as List<int>), <int>[
          0,
          version,
          255,
        ]);
        expect(row['nullable_value'], isNull);
        await encrypted.close();
      }
    },
  );

  testWidgets('new local store creates an encrypted schema', (tester) async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final path = p.join(documentsDirectory.path, 'gis_collector_offline.db');
    await _deleteDatabaseArtifacts(path);
    addTearDown(() => _deleteDatabaseArtifacts(path));

    final keyStorage = _MemorySecureStringStore();
    final store = SqliteLocalStore(
      databaseKeyManager: LocalDatabaseKeyManager(keyStorage),
      photoKeyManager: LocalPhotoKeyManager(keyStorage),
    );
    await store.initialize();
    await store.dispose();

    expect(
      await inspectLocalDatabaseFile(File(path)),
      LocalDatabaseFileState.encryptedOrUnknown,
    );
    final key =
        keyStorage.values[LocalDatabaseKeyManager.databaseKeyStorageKey];
    expect(key, isNotEmpty);

    final encrypted = await openDatabase(
      path,
      password: key,
      singleInstance: false,
    );
    await encrypted.insert('projects_cache', <String, Object?>{
      'owner_user_id': 'integration-owner',
      'id': 'integration-project',
      'payload_json': '{"id":"integration-project"}',
      'updated_at': '2026-07-28T00:00:00.000Z',
    });
    final plaintextPath = '$path.current-schema-plaintext';
    await _deleteDatabaseArtifacts(plaintextPath);
    await encrypted.execute('ATTACH DATABASE ? AS plaintext KEY ?', <Object?>[
      plaintextPath,
      '',
    ]);
    await encrypted.rawQuery("SELECT sqlcipher_export('plaintext')");
    await encrypted.rawQuery('PRAGMA plaintext.user_version = 8');
    await encrypted.execute('DETACH DATABASE plaintext');
    await encrypted.close();

    await _deleteDatabaseArtifacts(path);
    await File(plaintextPath).rename(path);
    expect(
      await inspectLocalDatabaseFile(File(path)),
      LocalDatabaseFileState.plaintext,
    );

    final upgradedStore = SqliteLocalStore(
      databaseKeyManager: LocalDatabaseKeyManager(keyStorage),
      photoKeyManager: LocalPhotoKeyManager(keyStorage),
    );
    await upgradedStore.initialize();
    await upgradedStore.dispose();

    expect(
      await inspectLocalDatabaseFile(File(path)),
      LocalDatabaseFileState.encryptedOrUnknown,
    );
    expect(await File('$path.cipher.tmp').exists(), isFalse);
    expect(await File('$path.plaintext.bak').exists(), isFalse);

    final reopened = await openDatabase(
      path,
      password: key,
      singleInstance: false,
    );
    expect(
      await reopened.query(
        'projects_cache',
        where: 'owner_user_id = ? AND id = ?',
        whereArgs: <Object?>['integration-owner', 'integration-project'],
      ),
      hasLength(1),
    );
    await reopened.close();
  });

  testWidgets(
    'interrupted migration promotes a verified temp over its plaintext backup',
    (tester) async {
      final tempDirectory = await getTemporaryDirectory();
      final path = p.join(tempDirectory.path, 'sqlcipher-recovery-test.db');
      final backupPath = '$path.plaintext.bak';
      final encryptedTempPath = '$path.cipher.tmp';
      await _deleteDatabaseArtifacts(path);
      addTearDown(() => _deleteDatabaseArtifacts(path));

      await _createRecoveryFixture(backupPath);
      await _createRecoveryFixture(encryptedTempPath, password: 'recovery-key');

      await prepareEncryptedLocalDatabase(
        databasePath: path,
        password: 'recovery-key',
      );

      expect(
        await inspectLocalDatabaseFile(File(path)),
        LocalDatabaseFileState.encryptedOrUnknown,
      );
      expect(await File(backupPath).exists(), isFalse);
      expect(await File(encryptedTempPath).exists(), isFalse);

      final recovered = await openDatabase(
        path,
        password: 'recovery-key',
        singleInstance: false,
      );
      expect(await recovered.query('recovery_test'), hasLength(1));
      await recovered.close();
    },
  );

  testWidgets(
    'interrupted migration restores its backup when temp is invalid',
    (tester) async {
      final tempDirectory = await getTemporaryDirectory();
      final path = p.join(
        tempDirectory.path,
        'sqlcipher-invalid-temp-recovery-test.db',
      );
      final backupPath = '$path.plaintext.bak';
      final encryptedTempPath = '$path.cipher.tmp';
      await _deleteDatabaseArtifacts(path);
      addTearDown(() => _deleteDatabaseArtifacts(path));

      await _createRecoveryFixture(backupPath);
      await File(
        encryptedTempPath,
      ).writeAsBytes(List<int>.generate(64, (index) => index + 1));

      await prepareEncryptedLocalDatabase(
        databasePath: path,
        password: 'recovery-key',
      );

      expect(
        await inspectLocalDatabaseFile(File(path)),
        LocalDatabaseFileState.encryptedOrUnknown,
      );
      expect(await File(backupPath).exists(), isFalse);
      expect(await File(encryptedTempPath).exists(), isFalse);

      final recovered = await openDatabase(
        path,
        password: 'recovery-key',
        singleInstance: false,
      );
      expect(await recovered.query('recovery_test'), hasLength(1));
      await recovered.close();
    },
  );

  testWidgets('conflicting encrypted main and plaintext backup are preserved', (
    tester,
  ) async {
    final tempDirectory = await getTemporaryDirectory();
    final path = p.join(
      tempDirectory.path,
      'sqlcipher-conflicting-backup-test.db',
    );
    final backupPath = '$path.plaintext.bak';
    await _deleteDatabaseArtifacts(path);
    addTearDown(() => _deleteDatabaseArtifacts(path));

    await _createRecoveryFixture(
      path,
      password: 'recovery-key',
      value: 'encrypted-main',
    );
    await _createRecoveryFixture(backupPath, value: 'plaintext-backup');

    await expectLater(
      prepareEncryptedLocalDatabase(
        databasePath: path,
        password: 'recovery-key',
      ),
      throwsA(isA<LocalDatabaseSecurityException>()),
    );

    expect(await File(path).exists(), isTrue);
    expect(await File(backupPath).exists(), isTrue);

    final encrypted = await openDatabase(
      path,
      password: 'recovery-key',
      singleInstance: false,
    );
    expect(
      (await encrypted.query('recovery_test')).single['value'],
      'encrypted-main',
    );
    await encrypted.close();
  });
}

Future<void> _createRecoveryFixture(
  String path, {
  String? password,
  String value = 'recoverable',
}) async {
  final database = await openDatabase(
    path,
    password: password,
    version: 2,
    singleInstance: false,
    onCreate: (database, version) async {
      for (final table in <String>[
        'projects_cache',
        'draft_features',
        'draft_photos',
        'sync_queue',
      ]) {
        await database.execute('CREATE TABLE $table (id TEXT PRIMARY KEY)');
      }
      await database.execute(
        'CREATE TABLE recovery_test (id INTEGER PRIMARY KEY, value TEXT)',
      );
      await database.insert('recovery_test', <String, Object?>{
        'id': 1,
        'value': value,
      });
    },
  );
  await database.close();
}

Future<void> _deleteDatabaseArtifacts(String path) async {
  for (final candidate in <String>[
    path,
    '$path-journal',
    '$path-wal',
    '$path-shm',
    '$path.cipher.tmp',
    '$path.cipher.tmp-journal',
    '$path.cipher.tmp-wal',
    '$path.cipher.tmp-shm',
    '$path.plaintext.bak',
    '$path.plaintext.bak-journal',
    '$path.plaintext.bak-wal',
    '$path.plaintext.bak-shm',
  ]) {
    final file = File(candidate);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
