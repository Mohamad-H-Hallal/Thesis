import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../security/secure_string_store.dart';

class LocalPhotoSecurityException implements Exception {
  const LocalPhotoSecurityException(this.message);

  final String message;

  @override
  String toString() => 'LocalPhotoSecurityException: $message';
}

typedef PhotoSecureRandomBytes = Uint8List Function(int length);

class LocalPhotoKeyManager {
  LocalPhotoKeyManager(this._storage, {PhotoSecureRandomBytes? randomBytes})
    : _randomBytes = randomBytes ?? _generateSecureRandomBytes;

  static const photoKeyStorageKey = 'offline_photo_key_v1';
  static const photoKeyFormatStorageKey = 'offline_photo_key_format';
  static const photoKeyFormatVersion = '1';
  static const photoKeyByteLength = 32;

  final SecureStringStore _storage;
  final PhotoSecureRandomBytes _randomBytes;

  Future<String> loadOrCreateKey({required bool hasEncryptedPhotos}) async {
    final storedKey = await _storage.read(photoKeyStorageKey);
    final storedFormat = await _storage.read(photoKeyFormatStorageKey);

    if (storedFormat != null && storedFormat != photoKeyFormatVersion) {
      throw const LocalPhotoSecurityException(
        'The offline photo key format is not supported by this app version.',
      );
    }

    if (storedKey != null) {
      _decodeAndValidateKey(storedKey);
      if (storedFormat == null) {
        await _storage.write(photoKeyFormatStorageKey, photoKeyFormatVersion);
      }
      return storedKey;
    }

    if (storedFormat != null || hasEncryptedPhotos) {
      throw const LocalPhotoSecurityException(
        'The offline photo encryption key is missing. Local photos were '
        'preserved.',
      );
    }

    final bytes = _randomBytes(photoKeyByteLength);
    if (bytes.length != photoKeyByteLength) {
      throw const LocalPhotoSecurityException(
        'Secure photo key generation returned an invalid key length.',
      );
    }
    final key = _encodeKey(bytes);
    await _storage.write(photoKeyStorageKey, key);
    await _storage.write(photoKeyFormatStorageKey, photoKeyFormatVersion);
    return key;
  }

  static Uint8List decodeKey(String encodedKey) =>
      _decodeAndValidateKey(encodedKey);

  static Uint8List _decodeAndValidateKey(String encodedKey) {
    try {
      final paddingLength = (4 - encodedKey.length % 4) % 4;
      final padded = '$encodedKey${'=' * paddingLength}';
      final decoded = Uint8List.fromList(base64Url.decode(padded));
      if (decoded.length != photoKeyByteLength ||
          _encodeKey(decoded) != encodedKey) {
        throw const FormatException('Invalid photo key.');
      }
      return decoded;
    } on FormatException {
      throw const LocalPhotoSecurityException(
        'The stored offline photo key is malformed. Local photos were '
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
