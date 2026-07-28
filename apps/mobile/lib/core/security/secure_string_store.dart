import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SecureStringStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

class FlutterSecureStringStore implements SecureStringStore {
  const FlutterSecureStringStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}
