import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/offline/local_photo_encryption.dart';
import 'package:lebanese_gis_mobile/core/offline/local_photo_security.dart';
import 'package:lebanese_gis_mobile/core/security/secure_string_store.dart';
import 'package:path/path.dart' as p;

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
  group('LocalPhotoKeyManager', () {
    test('creates and restores a distinct canonical 256-bit key', () async {
      final storage = _MemorySecureStringStore();
      final manager = LocalPhotoKeyManager(
        storage,
        randomBytes: (length) =>
            Uint8List.fromList(List<int>.generate(length, (index) => index)),
      );

      final first = await manager.loadOrCreateKey(hasEncryptedPhotos: false);
      final restored = await manager.loadOrCreateKey(hasEncryptedPhotos: true);

      expect(restored, first);
      expect(LocalPhotoKeyManager.decodeKey(first), hasLength(32));
      expect(
        storage.values[LocalPhotoKeyManager.photoKeyFormatStorageKey],
        LocalPhotoKeyManager.photoKeyFormatVersion,
      );
    });

    test('fails closed for missing, malformed, or unsupported key state', () {
      final missingStorage = _MemorySecureStringStore();
      final malformedStorage = _MemorySecureStringStore()
        ..values[LocalPhotoKeyManager.photoKeyStorageKey] = 'not-a-key';
      final unsupportedStorage = _MemorySecureStringStore()
        ..values[LocalPhotoKeyManager.photoKeyStorageKey] = base64Url
            .encode(List<int>.filled(32, 1))
            .replaceAll('=', '')
        ..values[LocalPhotoKeyManager.photoKeyFormatStorageKey] = '2';

      expect(
        () => LocalPhotoKeyManager(
          missingStorage,
        ).loadOrCreateKey(hasEncryptedPhotos: true),
        throwsA(isA<LocalPhotoSecurityException>()),
      );
      expect(
        () => LocalPhotoKeyManager(
          malformedStorage,
        ).loadOrCreateKey(hasEncryptedPhotos: false),
        throwsA(isA<LocalPhotoSecurityException>()),
      );
      expect(
        () => LocalPhotoKeyManager(
          unsupportedStorage,
        ).loadOrCreateKey(hasEncryptedPhotos: false),
        throwsA(isA<LocalPhotoSecurityException>()),
      );
    });

    test('rejects a random source that does not return 256 bits', () {
      final manager = LocalPhotoKeyManager(
        _MemorySecureStringStore(),
        randomBytes: (_) => Uint8List(31),
      );

      expect(
        () => manager.loadOrCreateKey(hasEncryptedPhotos: false),
        throwsA(isA<LocalPhotoSecurityException>()),
      );
    });
  });

  group('OfflinePhotoCipher', () {
    late Directory directory;
    late OfflinePhotoCipher cipher;
    late Uint8List keyBytes;
    late File plaintext;
    late File encrypted;
    const authenticationScope = 'owner/project/draft/photo.jpg.tlphoto';
    final jpegBytes = Uint8List.fromList(<int>[
      0xff,
      0xd8,
      0xff,
      ...List<int>.generate(4096, (index) => index % 251),
      0xff,
      0xd9,
    ]);

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'offline-photo-encryption-',
      );
      cipher = OfflinePhotoCipher();
      keyBytes = Uint8List.fromList(
        List<int>.generate(32, (index) => index + 1),
      );
      final photoDirectory = Directory(
        p.join(directory.path, 'owner', 'project', 'draft'),
      );
      await photoDirectory.create(recursive: true);
      plaintext = File(p.join(photoDirectory.path, 'source.jpg'));
      encrypted = File(p.join(photoDirectory.path, 'photo.jpg.tlphoto'));
      await plaintext.writeAsBytes(jpegBytes, flush: true);
    });

    tearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    test('encrypts with AES-GCM and decrypts only in memory', () async {
      expect(
        await cipher.detectPlaintextMediaType(plaintext),
        OfflinePhotoMediaType.jpeg,
      );

      await cipher.prepareEncryptedCopy(
        source: plaintext,
        destination: encrypted,
        keyBytes: keyBytes,
        authenticationScope: authenticationScope,
      );

      expect(await plaintext.readAsBytes(), jpegBytes);
      expect(await cipher.isEncryptedFile(encrypted), isTrue);
      expect(
        (await encrypted
            .openRead(0, 8)
            .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk))),
        isNot(jpegBytes.take(8).toList()),
      );
      final decrypted = await cipher.decrypt(
        encrypted: encrypted,
        keyBytes: keyBytes,
        authenticationScope: authenticationScope,
      );
      expect(decrypted.bytes, jpegBytes);
      expect(decrypted.fileName, 'photo.jpg');
      expect(decrypted.mimeType, 'image/jpeg');

      await cipher.prepareEncryptedCopy(
        source: plaintext,
        destination: encrypted,
        keyBytes: keyBytes,
        authenticationScope: authenticationScope,
      );
      final decryptedAgain = await cipher.decrypt(
        encrypted: encrypted,
        keyBytes: keyBytes,
        authenticationScope: authenticationScope,
      );
      expect(decryptedAgain.bytes, jpegBytes);
    });

    test('rejects tampering, a wrong key, and a path swap', () async {
      await cipher.prepareEncryptedCopy(
        source: plaintext,
        destination: encrypted,
        keyBytes: keyBytes,
        authenticationScope: authenticationScope,
      );

      await expectLater(
        cipher.decrypt(
          encrypted: encrypted,
          keyBytes: Uint8List.fromList(List<int>.filled(32, 9)),
          authenticationScope: authenticationScope,
        ),
        throwsA(isA<LocalPhotoSecurityException>()),
      );

      final moved = File(p.join(encrypted.parent.path, 'moved.jpg.tlphoto'));
      await encrypted.copy(moved.path);
      await expectLater(
        cipher.decrypt(
          encrypted: moved,
          keyBytes: keyBytes,
          authenticationScope: 'owner/project/draft/moved.jpg.tlphoto',
        ),
        throwsA(isA<LocalPhotoSecurityException>()),
      );

      final bytes = await encrypted.readAsBytes();
      bytes[bytes.length ~/ 2] ^= 0x01;
      await encrypted.writeAsBytes(bytes, flush: true);
      await expectLater(
        cipher.decrypt(
          encrypted: encrypted,
          keyBytes: keyBytes,
          authenticationScope: authenticationScope,
        ),
        throwsA(isA<LocalPhotoSecurityException>()),
      );
    });

    test('resumes a verified temporary file after interruption', () async {
      await cipher.prepareEncryptedCopy(
        source: plaintext,
        destination: encrypted,
        keyBytes: keyBytes,
        authenticationScope: authenticationScope,
      );
      final temporary = File(
        '${encrypted.path}$encryptedOfflinePhotoTemporarySuffix',
      );
      await encrypted.rename(temporary.path);

      await cipher.prepareEncryptedCopy(
        source: plaintext,
        destination: encrypted,
        keyBytes: keyBytes,
        authenticationScope: authenticationScope,
      );

      expect(await encrypted.exists(), isTrue);
      expect(await temporary.exists(), isFalse);
      final recovered = await cipher.decrypt(
        encrypted: encrypted,
        keyBytes: keyBytes,
        authenticationScope: authenticationScope,
      );
      expect(recovered.bytes, jpegBytes);
    });

    test('rejects invalid image signatures before encryption', () async {
      await plaintext.writeAsBytes(utf8.encode('not an image'), flush: true);

      await expectLater(
        cipher.prepareEncryptedCopy(
          source: plaintext,
          destination: encrypted,
          keyBytes: keyBytes,
          authenticationScope: authenticationScope,
        ),
        throwsA(isA<LocalPhotoSecurityException>()),
      );
      expect(await encrypted.exists(), isFalse);
      expect(await plaintext.exists(), isTrue);
    });
  });
}
