import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';

import 'local_database_security.dart';

const String minimumSupportedSqlCipherVersion = '4.17.0';

const Set<String> _minimumApplicationTables = <String>{
  'projects_cache',
  'draft_features',
  'draft_photos',
  'sync_queue',
};

const List<String> _databaseSidecarSuffixes = <String>[
  '-journal',
  '-wal',
  '-shm',
];

Future<void> prepareEncryptedLocalDatabase({
  required String databasePath,
  required String password,
}) async {
  final main = File(databasePath);
  final encryptedTemp = File('$databasePath.cipher.tmp');
  final plaintextBackup = File('$databasePath.plaintext.bak');

  final mainState = await inspectLocalDatabaseFile(main);
  final tempExists = await encryptedTemp.exists();
  final backupExists = await plaintextBackup.exists();

  if (mainState == LocalDatabaseFileState.missing) {
    if (backupExists) {
      final backupState = await inspectLocalDatabaseFile(plaintextBackup);
      if (backupState != LocalDatabaseFileState.plaintext) {
        throw const LocalDatabaseSecurityException(
          'An interrupted offline database migration has an invalid backup. '
          'All migration files were preserved.',
        );
      }

      if (tempExists) {
        final sourceSnapshot = await _readPlaintextSnapshot(
          plaintextBackup.path,
        );
        final tempIsValid = await _isValidEncryptedDatabase(
          encryptedTemp.path,
          password,
          expected: sourceSnapshot,
        );
        if (tempIsValid) {
          await _renameDatabaseSet(encryptedTemp.path, main.path);
          await _validateEncryptedDatabase(
            main.path,
            password,
            expected: sourceSnapshot,
          );
          await _deleteDatabaseSet(plaintextBackup.path);
          return;
        }
      }

      if (tempExists) {
        await _deleteDatabaseSet(encryptedTemp.path);
      }
      await _renameDatabaseSet(plaintextBackup.path, main.path);
      await prepareEncryptedLocalDatabase(
        databasePath: databasePath,
        password: password,
      );
      return;
    }

    if (tempExists) {
      final tempIsValid = await _isValidEncryptedDatabase(
        encryptedTemp.path,
        password,
        requireMinimumApplicationSchema: true,
      );
      if (!tempIsValid) {
        throw const LocalDatabaseSecurityException(
          'An interrupted offline database migration could not be verified. '
          'The migration file was preserved.',
        );
      }
      await _renameDatabaseSet(encryptedTemp.path, main.path);
      await _validateEncryptedDatabase(main.path, password);
    }
    return;
  }

  if (mainState == LocalDatabaseFileState.encryptedOrUnknown) {
    _DatabaseSnapshot? backupSnapshot;
    if (backupExists) {
      backupSnapshot = await _readPlaintextSnapshot(plaintextBackup.path);
    }
    await _validateEncryptedDatabase(
      main.path,
      password,
      expected: backupSnapshot,
    );
    if (tempExists) {
      await _deleteDatabaseSet(encryptedTemp.path);
    }
    if (backupExists) {
      await _deleteDatabaseSet(plaintextBackup.path);
    }
    return;
  }

  if (backupExists) {
    throw const LocalDatabaseSecurityException(
      'Conflicting offline database migration files were found. All files '
      'were preserved.',
    );
  }

  final sourceSnapshot = await _readPlaintextSnapshot(main.path);
  if (tempExists) {
    final tempIsValid = await _isValidEncryptedDatabase(
      encryptedTemp.path,
      password,
      expected: sourceSnapshot,
    );
    if (tempIsValid) {
      await _promoteEncryptedDatabase(
        mainPath: main.path,
        encryptedTempPath: encryptedTemp.path,
        plaintextBackupPath: plaintextBackup.path,
        password: password,
        expected: sourceSnapshot,
      );
      return;
    }
    await _deleteDatabaseSet(encryptedTemp.path);
  }

  await _exportPlaintextDatabase(
    plaintextPath: main.path,
    encryptedPath: encryptedTemp.path,
    password: password,
    sourceSnapshot: sourceSnapshot,
  );
  await _promoteEncryptedDatabase(
    mainPath: main.path,
    encryptedTempPath: encryptedTemp.path,
    plaintextBackupPath: plaintextBackup.path,
    password: password,
    expected: sourceSnapshot,
  );
}

Future<void> _exportPlaintextDatabase({
  required String plaintextPath,
  required String encryptedPath,
  required String password,
  required _DatabaseSnapshot sourceSnapshot,
}) async {
  await _deleteDatabaseSet(encryptedPath);
  final encrypted = await openDatabase(
    encryptedPath,
    password: password,
    singleInstance: false,
  );
  var attached = false;
  try {
    await encrypted.rawQuery('PRAGMA cipher_memory_security = ON');
    await encrypted.execute("ATTACH DATABASE ? AS plaintext KEY ''", <Object?>[
      plaintextPath,
    ]);
    attached = true;
    await encrypted.rawQuery("SELECT sqlcipher_export('main', 'plaintext')");
    await encrypted.rawQuery(
      'PRAGMA user_version = ${sourceSnapshot.userVersion}',
    );
    await encrypted.execute('DETACH DATABASE plaintext');
    attached = false;
  } catch (_) {
    if (attached) {
      try {
        await encrypted.execute('DETACH DATABASE plaintext');
      } catch (_) {
        // The plaintext source and partial encrypted output remain recoverable.
      }
    }
    throw const LocalDatabaseSecurityException(
      'The plaintext offline database could not be copied into its encrypted '
      'replacement. The plaintext source was preserved.',
    );
  } finally {
    await encrypted.close();
  }

  await _validateEncryptedDatabase(
    encryptedPath,
    password,
    expected: sourceSnapshot,
  );
}

Future<void> _promoteEncryptedDatabase({
  required String mainPath,
  required String encryptedTempPath,
  required String plaintextBackupPath,
  required String password,
  required _DatabaseSnapshot expected,
}) async {
  await _renameDatabaseSet(mainPath, plaintextBackupPath);
  try {
    await _renameDatabaseSet(encryptedTempPath, mainPath);
    await _validateEncryptedDatabase(mainPath, password, expected: expected);
  } catch (_) {
    if (await File(mainPath).exists()) {
      try {
        await _renameDatabaseSet(mainPath, encryptedTempPath);
      } catch (_) {
        // Preserve every candidate if rollback itself cannot be completed.
      }
    }
    if (!await File(mainPath).exists() &&
        await File(plaintextBackupPath).exists()) {
      await _renameDatabaseSet(plaintextBackupPath, mainPath);
    }
    rethrow;
  }
  await _deleteDatabaseSet(plaintextBackupPath);
}

Future<_DatabaseSnapshot> _readPlaintextSnapshot(String path) async {
  final state = await inspectLocalDatabaseFile(File(path));
  if (state != LocalDatabaseFileState.plaintext) {
    throw const LocalDatabaseSecurityException(
      'The source offline database is not a valid plaintext SQLite file.',
    );
  }

  final database = await openDatabase(path, singleInstance: false);
  try {
    await _requireSqliteIntegrity(database);
    return await _readDatabaseSnapshot(database);
  } catch (_) {
    throw const LocalDatabaseSecurityException(
      'The plaintext offline database failed its integrity checks. It was '
      'preserved without migration.',
    );
  } finally {
    await database.close();
  }
}

Future<void> _validateEncryptedDatabase(
  String path,
  String password, {
  _DatabaseSnapshot? expected,
  bool requireMinimumApplicationSchema = false,
}) async {
  final state = await inspectLocalDatabaseFile(File(path));
  if (state != LocalDatabaseFileState.encryptedOrUnknown) {
    throw const LocalDatabaseSecurityException(
      'The encrypted offline database still has a plaintext SQLite header.',
    );
  }

  Database? database;
  try {
    database = await openDatabase(
      path,
      password: password,
      singleInstance: false,
    );
    final cipherVersionRows = await database.rawQuery('PRAGMA cipher_version');
    final cipherVersion = _firstPragmaValue(cipherVersionRows);
    if (cipherVersion == null ||
        !isSqlCipherVersionAllowed(cipherVersion.toString())) {
      throw const LocalDatabaseSecurityException(
        'The bundled SQLCipher version is below the tested security minimum.',
      );
    }

    final cipherErrors = await database.rawQuery(
      'PRAGMA cipher_integrity_check',
    );
    if (cipherErrors.isNotEmpty) {
      throw const LocalDatabaseSecurityException(
        'The encrypted offline database failed its cipher integrity check.',
      );
    }
    await _requireSqliteIntegrity(database);

    final actual = await _readDatabaseSnapshot(database);
    if (requireMinimumApplicationSchema &&
        !actual.rowCounts.keys.toSet().containsAll(_minimumApplicationTables)) {
      throw const LocalDatabaseSecurityException(
        'The recovered encrypted database does not contain the application '
        'schema.',
      );
    }
    if (expected != null && actual != expected) {
      throw const LocalDatabaseSecurityException(
        'The encrypted offline database does not match its plaintext source.',
      );
    }
  } on LocalDatabaseSecurityException {
    rethrow;
  } catch (_) {
    throw const LocalDatabaseSecurityException(
      'The encrypted offline database could not be opened with its existing '
      'key. All database files were preserved.',
    );
  } finally {
    await database?.close();
  }
}

Future<bool> _isValidEncryptedDatabase(
  String path,
  String password, {
  _DatabaseSnapshot? expected,
  bool requireMinimumApplicationSchema = false,
}) async {
  try {
    await _validateEncryptedDatabase(
      path,
      password,
      expected: expected,
      requireMinimumApplicationSchema: requireMinimumApplicationSchema,
    );
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _requireSqliteIntegrity(Database database) async {
  final rows = await database.rawQuery('PRAGMA integrity_check');
  if (rows.length != 1 ||
      _firstPragmaValue(rows)?.toString().toLowerCase() != 'ok') {
    throw const LocalDatabaseSecurityException(
      'The offline database failed its SQLite integrity check.',
    );
  }
}

Future<_DatabaseSnapshot> _readDatabaseSnapshot(Database database) async {
  final versionRows = await database.rawQuery('PRAGMA user_version');
  final userVersion = _firstPragmaValue(versionRows);
  if (userVersion is! int) {
    throw const LocalDatabaseSecurityException(
      'The offline database schema version could not be read.',
    );
  }

  final tableRows = await database.rawQuery('''
    SELECT name
    FROM sqlite_master
    WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
    ORDER BY name
  ''');
  final rowCounts = <String, int>{};
  final tableDigests = <String, String>{};
  for (final row in tableRows) {
    final tableName = row['name'];
    if (tableName is! String || tableName.isEmpty) {
      throw const LocalDatabaseSecurityException(
        'The offline database contains an invalid table name.',
      );
    }
    final quotedTableName = tableName.replaceAll('"', '""');
    final rows = await database.rawQuery('SELECT * FROM "$quotedTableName"');
    rowCounts[tableName] = rows.length;
    tableDigests[tableName] = _digestRows(rows);
  }

  final schemaRows = await database.rawQuery('''
    SELECT type, name, tbl_name, sql
    FROM sqlite_master
    WHERE name NOT LIKE 'sqlite_%'
    ORDER BY type, name, tbl_name
  ''');
  return _DatabaseSnapshot(
    userVersion: userVersion,
    schemaDigest: _digestRows(schemaRows),
    rowCounts: rowCounts,
    tableDigests: tableDigests,
  );
}

Object? _firstPragmaValue(List<Map<String, Object?>> rows) {
  if (rows.isEmpty || rows.first.isEmpty) {
    return null;
  }
  return rows.first.values.first;
}

String _digestRows(List<Map<String, Object?>> rows) {
  final rowDigests = rows.map(_digestRow).toList()..sort(_compareByteLists);
  final combined = BytesBuilder(copy: false);
  for (final digest in rowDigests) {
    combined.add(digest);
  }
  return sha256.convert(combined.takeBytes()).toString();
}

Uint8List _digestRow(Map<String, Object?> row) {
  final encoded = BytesBuilder(copy: false);
  final columnNames = row.keys.toList()..sort();
  for (final columnName in columnNames) {
    _appendDigestField(encoded, 0x43, utf8.encode(columnName));
    final value = row[columnName];
    switch (value) {
      case null:
        _appendDigestField(encoded, 0x4e, const <int>[]);
      case int():
        _appendDigestField(encoded, 0x49, utf8.encode(value.toString()));
      case double():
        final bytes = ByteData(8)..setFloat64(0, value, Endian.big);
        _appendDigestField(encoded, 0x44, bytes.buffer.asUint8List());
      case String():
        _appendDigestField(encoded, 0x53, utf8.encode(value));
      case List<int>():
        _appendDigestField(encoded, 0x42, value);
      default:
        throw const LocalDatabaseSecurityException(
          'The offline database contains a value that cannot be verified.',
        );
    }
  }
  return Uint8List.fromList(sha256.convert(encoded.takeBytes()).bytes);
}

void _appendDigestField(BytesBuilder target, int type, List<int> value) {
  final length = ByteData(8)..setUint64(0, value.length, Endian.big);
  target
    ..addByte(type)
    ..add(length.buffer.asUint8List())
    ..add(value);
}

int _compareByteLists(Uint8List left, Uint8List right) {
  for (var index = 0; index < left.length; index += 1) {
    final comparison = left[index].compareTo(right[index]);
    if (comparison != 0) {
      return comparison;
    }
  }
  return left.length.compareTo(right.length);
}

bool isSqlCipherVersionAllowed(String rawVersion) {
  final actual = _parseVersion(rawVersion);
  final minimum = _parseVersion(minimumSupportedSqlCipherVersion);
  if (actual == null || minimum == null) {
    return false;
  }
  for (var index = 0; index < minimum.length; index += 1) {
    if (actual[index] > minimum[index]) {
      return true;
    }
    if (actual[index] < minimum[index]) {
      return false;
    }
  }
  return true;
}

List<int>? _parseVersion(String rawVersion) {
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(rawVersion.trim());
  if (match == null) {
    return null;
  }
  return <int>[
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  ];
}

Future<void> _renameDatabaseSet(String sourcePath, String targetPath) async {
  _requireSiblingDatabasePaths(sourcePath, targetPath);
  final sourceCandidates = <String>[
    sourcePath,
    for (final suffix in _databaseSidecarSuffixes) '$sourcePath$suffix',
  ];
  final targetCandidates = <String>[
    targetPath,
    for (final suffix in _databaseSidecarSuffixes) '$targetPath$suffix',
  ];
  if (!await File(sourcePath).exists()) {
    throw const LocalDatabaseSecurityException(
      'An offline database file transition could not be completed safely.',
    );
  }

  for (final target in targetCandidates) {
    if (await File(target).exists()) {
      throw const LocalDatabaseSecurityException(
        'Conflicting offline database destination files were found.',
      );
    }
  }

  for (var index = 0; index < sourceCandidates.length; index += 1) {
    final source = File(sourceCandidates[index]);
    if (await source.exists()) {
      await source.rename(targetCandidates[index]);
    }
  }
}

Future<void> _deleteDatabaseSet(String databasePath) async {
  final parent = p.dirname(p.normalize(p.absolute(databasePath)));
  final candidates = <String>[
    databasePath,
    for (final suffix in _databaseSidecarSuffixes) '$databasePath$suffix',
  ];
  for (final candidate in candidates) {
    final normalized = p.normalize(p.absolute(candidate));
    if (p.dirname(normalized) != parent) {
      throw const LocalDatabaseSecurityException(
        'Refusing to clean a database artifact outside its directory.',
      );
    }
    final file = File(normalized);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

void _requireSiblingDatabasePaths(String sourcePath, String targetPath) {
  final sourceParent = p.dirname(p.normalize(p.absolute(sourcePath)));
  final targetParent = p.dirname(p.normalize(p.absolute(targetPath)));
  if (sourceParent != targetParent) {
    throw const LocalDatabaseSecurityException(
      'Offline database migration files must remain in one directory.',
    );
  }
}

class _DatabaseSnapshot {
  const _DatabaseSnapshot({
    required this.userVersion,
    required this.schemaDigest,
    required this.rowCounts,
    required this.tableDigests,
  });

  final int userVersion;
  final String schemaDigest;
  final Map<String, int> rowCounts;
  final Map<String, String> tableDigests;

  @override
  bool operator ==(Object other) =>
      other is _DatabaseSnapshot &&
      other.userVersion == userVersion &&
      other.schemaDigest == schemaDigest &&
      _mapsEqual(other.rowCounts, rowCounts) &&
      _mapsEqual(other.tableDigests, tableDigests);

  @override
  int get hashCode => Object.hash(
    userVersion,
    schemaDigest,
    Object.hashAll(
      rowCounts.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
    Object.hashAll(
      tableDigests.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );
}

bool _mapsEqual<K, V>(Map<K, V> left, Map<K, V> right) {
  if (left.length != right.length) {
    return false;
  }
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}
