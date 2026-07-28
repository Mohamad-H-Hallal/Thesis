import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../security/secure_string_store.dart';

enum LocalDatabaseFileState { missing, plaintext, encryptedOrUnknown }

class LocalDatabaseSecurityException implements Exception {
  const LocalDatabaseSecurityException(this.message);

  final String message;

  @override
  String toString() => 'LocalDatabaseSecurityException: $message';
}

typedef SecureRandomBytes = Uint8List Function(int length);

class LocalDatabaseKeyManager {
  LocalDatabaseKeyManager(this._storage, {SecureRandomBytes? randomBytes})
    : _randomBytes = randomBytes ?? _generateSecureRandomBytes;

  static const databaseKeyStorageKey = 'offline_database_key_v1';
  static const databaseKeyFormatStorageKey = 'offline_database_key_format';
  static const databaseKeyFormatVersion = '1';
  static const databaseKeyByteLength = 32;

  final SecureStringStore _storage;
  final SecureRandomBytes _randomBytes;

  Future<String> loadOrCreateKey(LocalDatabaseFileState databaseState) async {
    final storedKey = await _storage.read(databaseKeyStorageKey);
    final storedFormat = await _storage.read(databaseKeyFormatStorageKey);

    if (storedFormat != null && storedFormat != databaseKeyFormatVersion) {
      throw const LocalDatabaseSecurityException(
        'The offline database key format is not supported by this app version.',
      );
    }

    if (storedKey != null) {
      _decodeAndValidateKey(storedKey);
      if (storedFormat == null) {
        await _storage.write(
          databaseKeyFormatStorageKey,
          databaseKeyFormatVersion,
        );
      }
      return storedKey;
    }

    if (storedFormat != null) {
      throw const LocalDatabaseSecurityException(
        'The offline database key is missing. Local data was preserved.',
      );
    }

    if (databaseState == LocalDatabaseFileState.encryptedOrUnknown) {
      throw const LocalDatabaseSecurityException(
        'The offline database cannot be identified without its existing key. '
        'Local data was preserved.',
      );
    }

    final bytes = _randomBytes(databaseKeyByteLength);
    if (bytes.length != databaseKeyByteLength) {
      throw const LocalDatabaseSecurityException(
        'Secure key generation returned an invalid key length.',
      );
    }
    final key = _encodeKey(bytes);
    await _storage.write(databaseKeyStorageKey, key);
    await _storage.write(databaseKeyFormatStorageKey, databaseKeyFormatVersion);
    return key;
  }

  static Uint8List decodeKey(String encodedKey) =>
      _decodeAndValidateKey(encodedKey);

  static Uint8List _decodeAndValidateKey(String encodedKey) {
    try {
      final paddingLength = (4 - encodedKey.length % 4) % 4;
      final padded = '$encodedKey${'=' * paddingLength}';
      final decoded = Uint8List.fromList(base64Url.decode(padded));
      if (decoded.length != databaseKeyByteLength ||
          _encodeKey(decoded) != encodedKey) {
        throw const FormatException('Invalid database key.');
      }
      return decoded;
    } on FormatException {
      throw const LocalDatabaseSecurityException(
        'The stored offline database key is malformed. Local data was '
        'preserved.',
      );
    }
  }

  static String _encodeKey(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List _generateSecureRandomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}

const List<int> _sqliteHeader = <int>[
  0x53,
  0x51,
  0x4c,
  0x69,
  0x74,
  0x65,
  0x20,
  0x66,
  0x6f,
  0x72,
  0x6d,
  0x61,
  0x74,
  0x20,
  0x33,
  0x00,
];

Future<LocalDatabaseFileState> inspectLocalDatabaseFile(File database) async {
  if (!await database.exists()) {
    return LocalDatabaseFileState.missing;
  }

  final handle = await database.open(mode: FileMode.read);
  try {
    final header = await handle.read(_sqliteHeader.length);
    if (header.length != _sqliteHeader.length) {
      return LocalDatabaseFileState.encryptedOrUnknown;
    }
    for (var index = 0; index < _sqliteHeader.length; index += 1) {
      if (header[index] != _sqliteHeader[index]) {
        return LocalDatabaseFileState.encryptedOrUnknown;
      }
    }
    return LocalDatabaseFileState.plaintext;
  } finally {
    await handle.close();
  }
}
