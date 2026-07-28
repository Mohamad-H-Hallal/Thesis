import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import 'local_photo_security.dart';

export 'local_photo_security.dart' show LocalPhotoKeyManager;

const String encryptedOfflinePhotoSuffix = '.tlphoto';
const String encryptedOfflinePhotoTemporarySuffix = '.tmp';

typedef LocalPhotoEncryptionException = LocalPhotoSecurityException;

const List<int> _photoFileMagic = <int>[
  0x54,
  0x4c,
  0x50,
  0x48,
  0x4f,
  0x54,
  0x4f,
  0x00,
];
const int _photoFileFormatVersion = 1;
const int _nonceLength = 12;
const int _macLength = 16;
const int _headerLength = 8 + 1 + 1 + _nonceLength;

enum OfflinePhotoMediaType {
  jpeg(code: 1, extension: '.jpg', mimeType: 'image/jpeg'),
  png(code: 2, extension: '.png', mimeType: 'image/png'),
  heic(code: 3, extension: '.heic', mimeType: 'image/heic'),
  heif(code: 4, extension: '.heif', mimeType: 'image/heif');

  const OfflinePhotoMediaType({
    required this.code,
    required this.extension,
    required this.mimeType,
  });

  final int code;
  final String extension;
  final String mimeType;
}

class DecryptedOfflinePhoto {
  const DecryptedOfflinePhoto({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String fileName;
  final String mimeType;
}

class OfflinePhotoCipher {
  OfflinePhotoCipher({Cipher? algorithm})
    : _algorithm = algorithm ?? AesGcm.with256bits();

  final Cipher _algorithm;

  Future<bool> isEncryptedFile(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return false;
    }
    if (type != FileSystemEntityType.file) {
      throw const LocalPhotoSecurityException(
        'Offline photo storage contains an unsafe filesystem object.',
      );
    }
    final handle = await file.open(mode: FileMode.read);
    try {
      final prefix = await handle.read(_photoFileMagic.length);
      return _bytesEqual(prefix, _photoFileMagic);
    } finally {
      await handle.close();
    }
  }

  bool pathClaimsEncryptedFormat(String path) =>
      path.toLowerCase().endsWith(encryptedOfflinePhotoSuffix);

  Future<OfflinePhotoMediaType> detectPlaintextMediaType(File source) async {
    final type = await FileSystemEntity.type(source.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw const LocalPhotoSecurityException(
        'The selected offline photo is no longer available.',
      );
    }
    if (type != FileSystemEntityType.file) {
      throw const LocalPhotoSecurityException(
        'The selected offline photo is not a regular file.',
      );
    }
    final handle = await source.open(mode: FileMode.read);
    try {
      final prefix = await handle.read(32);
      if (prefix.length >= 3 &&
          prefix[0] == 0xff &&
          prefix[1] == 0xd8 &&
          prefix[2] == 0xff) {
        return OfflinePhotoMediaType.jpeg;
      }
      if (prefix.length >= 8 &&
          _bytesEqual(prefix.sublist(0, 8), const <int>[
            0x89,
            0x50,
            0x4e,
            0x47,
            0x0d,
            0x0a,
            0x1a,
            0x0a,
          ])) {
        return OfflinePhotoMediaType.png;
      }
      if (prefix.length >= 12 &&
          String.fromCharCodes(prefix.sublist(4, 8)) == 'ftyp') {
        final brand = String.fromCharCodes(prefix.sublist(8, 12));
        if (const <String>{'heic', 'heix', 'hevc', 'hevx'}.contains(brand)) {
          return OfflinePhotoMediaType.heic;
        }
        if (const <String>{'heif', 'mif1', 'msf1'}.contains(brand)) {
          return OfflinePhotoMediaType.heif;
        }
      }
    } finally {
      await handle.close();
    }
    throw const LocalPhotoSecurityException(
      'The selected offline photo is not a supported JPEG, PNG, HEIC, or HEIF '
      'image.',
    );
  }

  String encryptedPath({
    required String directoryPath,
    required String fileStem,
    required OfflinePhotoMediaType mediaType,
  }) {
    return p.join(
      directoryPath,
      '$fileStem${mediaType.extension}$encryptedOfflinePhotoSuffix',
    );
  }

  Future<void> prepareEncryptedCopy({
    required File source,
    required File destination,
    required Uint8List keyBytes,
    required String authenticationScope,
    OfflinePhotoMediaType? mediaType,
  }) async {
    final detectedMediaType =
        mediaType ?? await detectPlaintextMediaType(source);
    final temporary = File(
      '${destination.path}$encryptedOfflinePhotoTemporarySuffix',
    );

    if (await destination.exists()) {
      await _requireRegularFile(destination);
      if (await _encryptedMatchesPlaintext(
        encrypted: destination,
        plaintext: source,
        keyBytes: keyBytes,
        authenticationScope: authenticationScope,
      )) {
        if (await temporary.exists()) {
          await _requireRegularFile(temporary);
          await temporary.delete();
        }
        return;
      }
      throw const LocalPhotoSecurityException(
        'A conflicting encrypted offline photo was preserved for support '
        'review.',
      );
    }

    if (await temporary.exists()) {
      await _requireRegularFile(temporary);
      final validTemporary = await _encryptedMatchesPlaintext(
        encrypted: temporary,
        plaintext: source,
        keyBytes: keyBytes,
        authenticationScope: authenticationScope,
      );
      if (validTemporary) {
        await temporary.rename(destination.path);
        return;
      }
      await temporary.delete();
    }

    await _encrypt(
      source: source,
      destination: temporary,
      keyBytes: keyBytes,
      mediaType: detectedMediaType,
      authenticationScope: authenticationScope,
    );
    if (!await _encryptedMatchesPlaintext(
      encrypted: temporary,
      plaintext: source,
      keyBytes: keyBytes,
      authenticationScope: authenticationScope,
    )) {
      throw const LocalPhotoSecurityException(
        'The encrypted offline photo did not match its plaintext source. Both '
        'files were preserved.',
      );
    }
    await temporary.rename(destination.path);
  }

  Future<DecryptedOfflinePhoto> decrypt({
    required File encrypted,
    required Uint8List keyBytes,
    required String authenticationScope,
  }) async {
    final parsed = await _readEncryptedFile(encrypted);
    final output = BytesBuilder(copy: false);
    try {
      await for (final chunk in _decryptStream(
        encrypted,
        parsed: parsed,
        keyBytes: keyBytes,
        authenticationScope: authenticationScope,
      )) {
        output.add(chunk);
      }
    } on LocalPhotoSecurityException {
      rethrow;
    } catch (_) {
      throw const LocalPhotoSecurityException(
        'The offline photo failed authenticated decryption. The encrypted file '
        'was preserved.',
      );
    }
    final bytes = output.takeBytes();
    if (bytes.isEmpty) {
      throw const LocalPhotoSecurityException(
        'The decrypted offline photo is empty. The encrypted file was '
        'preserved.',
      );
    }
    return DecryptedOfflinePhoto(
      bytes: bytes,
      fileName: p.basenameWithoutExtension(encrypted.path),
      mimeType: parsed.mediaType.mimeType,
    );
  }

  Future<void> validate({
    required File encrypted,
    required Uint8List keyBytes,
    required String authenticationScope,
  }) async {
    final parsed = await _readEncryptedFile(encrypted);
    try {
      await for (final _ in _decryptStream(
        encrypted,
        parsed: parsed,
        keyBytes: keyBytes,
        authenticationScope: authenticationScope,
      )) {}
    } on LocalPhotoSecurityException {
      rethrow;
    } catch (_) {
      throw const LocalPhotoSecurityException(
        'The offline photo failed authenticated validation. The encrypted file '
        'was preserved.',
      );
    }
  }

  Future<void> _encrypt({
    required File source,
    required File destination,
    required Uint8List keyBytes,
    required OfflinePhotoMediaType mediaType,
    required String authenticationScope,
  }) async {
    final nonce = _algorithm.newNonce();
    if (nonce.length != _nonceLength) {
      throw const LocalPhotoSecurityException(
        'The photo cipher generated an unsupported nonce length.',
      );
    }
    final header = Uint8List.fromList(<int>[
      ..._photoFileMagic,
      _photoFileFormatVersion,
      mediaType.code,
      ...nonce,
    ]);
    await destination.create(exclusive: true);
    final output = await destination.open(mode: FileMode.writeOnly);
    try {
      await output.writeFrom(header);
      Mac? authenticationCode;
      final encryptedStream = _algorithm.encryptStream(
        source.openRead(),
        secretKey: SecretKeyData(keyBytes),
        nonce: nonce,
        aad: _authenticatedData(header, authenticationScope),
        onMac: (mac) => authenticationCode = mac,
      );
      await for (final chunk in encryptedStream) {
        await output.writeFrom(chunk);
      }
      final mac = authenticationCode;
      if (mac == null || mac.bytes.length != _macLength) {
        throw const LocalPhotoSecurityException(
          'The photo cipher did not produce a valid authentication code.',
        );
      }
      await output.writeFrom(mac.bytes);
      await output.flush();
    } finally {
      await output.close();
    }
  }

  Future<bool> _encryptedMatchesPlaintext({
    required File encrypted,
    required File plaintext,
    required Uint8List keyBytes,
    required String authenticationScope,
  }) async {
    try {
      final parsed = await _readEncryptedFile(encrypted);
      final digests = await Future.wait(<Future<hashes.Digest>>[
        hashes.sha256.bind(plaintext.openRead()).first,
        hashes.sha256
            .bind(
              _decryptStream(
                encrypted,
                parsed: parsed,
                keyBytes: keyBytes,
                authenticationScope: authenticationScope,
              ),
            )
            .first,
      ]);
      return digests[0] == digests[1];
    } catch (_) {
      return false;
    }
  }

  Stream<List<int>> _decryptStream(
    File encrypted, {
    required _ParsedPhotoFile parsed,
    required Uint8List keyBytes,
    required String authenticationScope,
  }) {
    return _algorithm.decryptStream(
      encrypted.openRead(_headerLength, parsed.ciphertextEnd),
      secretKey: SecretKeyData(keyBytes),
      nonce: parsed.nonce,
      mac: Mac(parsed.mac),
      aad: _authenticatedData(parsed.header, authenticationScope),
    );
  }

  Future<_ParsedPhotoFile> _readEncryptedFile(File encrypted) async {
    final type = await FileSystemEntity.type(
      encrypted.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      throw const LocalPhotoSecurityException(
        'The encrypted offline photo is missing.',
      );
    }
    if (type != FileSystemEntityType.file) {
      throw const LocalPhotoSecurityException(
        'The encrypted offline photo is not a regular file.',
      );
    }
    final handle = await encrypted.open(mode: FileMode.read);
    try {
      final length = await handle.length();
      if (length <= _headerLength + _macLength) {
        throw const LocalPhotoSecurityException(
          'The encrypted offline photo is truncated.',
        );
      }
      final header = await handle.read(_headerLength);
      if (header.length != _headerLength ||
          !_bytesEqual(
            header.sublist(0, _photoFileMagic.length),
            _photoFileMagic,
          ) ||
          header[_photoFileMagic.length] != _photoFileFormatVersion) {
        throw const LocalPhotoSecurityException(
          'The offline photo encryption format is invalid or unsupported.',
        );
      }
      final mediaTypeCode = header[_photoFileMagic.length + 1];
      final matchingMediaTypes = OfflinePhotoMediaType.values.where(
        (candidate) => candidate.code == mediaTypeCode,
      );
      if (matchingMediaTypes.length != 1) {
        throw const LocalPhotoSecurityException(
          'The encrypted offline photo media type is unsupported.',
        );
      }
      final ciphertextEnd = length - _macLength;
      await handle.setPosition(ciphertextEnd);
      final mac = await handle.read(_macLength);
      if (mac.length != _macLength) {
        throw const LocalPhotoSecurityException(
          'The encrypted offline photo authentication code is truncated.',
        );
      }
      return _ParsedPhotoFile(
        header: Uint8List.fromList(header),
        nonce: Uint8List.fromList(header.sublist(10, _headerLength)),
        mac: Uint8List.fromList(mac),
        mediaType: matchingMediaTypes.single,
        ciphertextEnd: ciphertextEnd,
      );
    } finally {
      await handle.close();
    }
  }

  Uint8List _authenticatedData(List<int> header, String rawScope) {
    final scope = rawScope.trim().replaceAll(r'\', '/');
    if (scope.isEmpty ||
        scope == '.' ||
        scope == '..' ||
        scope.startsWith('../') ||
        scope.contains('/../') ||
        scope.startsWith('/')) {
      throw const LocalPhotoSecurityException(
        'The offline photo authentication scope is invalid.',
      );
    }
    return Uint8List.fromList(<int>[...header, ...utf8.encode(scope)]);
  }

  Future<void> _requireRegularFile(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw const LocalPhotoSecurityException(
        'Offline photo storage contains an unsafe filesystem object.',
      );
    }
  }
}

class _ParsedPhotoFile {
  const _ParsedPhotoFile({
    required this.header,
    required this.nonce,
    required this.mac,
    required this.mediaType,
    required this.ciphertextEnd,
  });

  final Uint8List header;
  final Uint8List nonce;
  final Uint8List mac;
  final OfflinePhotoMediaType mediaType;
  final int ciphertextEnd;
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}
