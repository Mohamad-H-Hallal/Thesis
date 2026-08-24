import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/painting.dart';

import '../offline/local_store.dart';

class DeletedAccountLocalCleanup {
  DeletedAccountLocalCleanup({
    required FlutterSecureStorage storage,
    required LocalStore localStore,
  }) : _storage = storage,
       _localStore = localStore;

  final FlutterSecureStorage _storage;
  final LocalStore _localStore;

  static const markerPrefix = 'pending_deleted_account_cleanup:';

  Future<void> markAndPurge(String ownerUserId) async {
    final owner = ownerUserId.trim();
    if (owner.isEmpty || owner == '__restoring_session__') {
      return;
    }
    final key = '$markerPrefix$owner';
    await _storage.write(
      key: key,
      value: DateTime.now().toUtc().toIso8601String(),
    );
    await _localStore.purgeAccountData(owner);
    _clearMemoryImages();
    await _storage.delete(key: key);
  }

  Future<List<String>> resumePending() async {
    final values = await _storage.readAll();
    final owners = values.keys
        .where((key) => key.startsWith(markerPrefix))
        .map((key) => key.substring(markerPrefix.length).trim())
        .where((owner) => owner.isNotEmpty)
        .toList(growable: false);
    final completed = <String>[];
    for (final owner in owners) {
      try {
        await _localStore.purgeAccountData(owner);
        _clearMemoryImages();
        await _storage.delete(key: '$markerPrefix$owner');
        completed.add(owner);
      } catch (_) {
        // Keep the durable marker so the exact owner-scoped cleanup resumes.
      }
    }
    return completed;
  }

  void _clearMemoryImages() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  }
}
