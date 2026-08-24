import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../features/projects/domain/project.dart';
import 'local_database_migration.dart';
import 'local_database_security.dart';
import 'local_photo_cleanup.dart';
import 'local_photo_encryption.dart';
import 'local_photo_security.dart';
import 'local_models.dart';
import 'local_store.dart';

/// Reserved identities used only to preserve pre-owner-schema offline work.
///
/// Authentication user identifiers are UUIDs, so these values can never match
/// a real signed-in account. Quarantined rows remain recoverable without being
/// exposed to any account or sent to the API automatically.
const legacyUnownedOfflineOwnerId = '__legacy_unowned__';
const legacyAmbiguousOfflineProjectId = '__legacy_ambiguous__';

class SqliteLocalStore
    implements LocalStore, DurableDraftPhotoStore, ProtectedDraftPhotoStore {
  SqliteLocalStore({
    required LocalDatabaseKeyManager databaseKeyManager,
    required LocalPhotoKeyManager photoKeyManager,
  }) : _databaseKeyManager = databaseKeyManager,
       _photoKeyManager = photoKeyManager;

  final LocalDatabaseKeyManager _databaseKeyManager;
  final LocalPhotoKeyManager _photoKeyManager;
  final OfflinePhotoCipher _photoCipher = OfflinePhotoCipher();
  Database? _db;
  Uint8List? _photoKeyBytes;
  Future<void>? _initialization;
  final Uuid _uuid = const Uuid();
  String? _offlinePhotoRootPath;
  static const _dbVersion = 9;

  @override
  Future<void> initialize() async {
    if (_db != null) {
      return;
    }
    final currentInitialization = _initialization;
    if (currentInitialization != null) {
      await currentInitialization;
      return;
    }

    final initialization = _openDatabase();
    _initialization = initialization;
    try {
      await initialization;
    } finally {
      if (identical(_initialization, initialization)) {
        _initialization = null;
      }
    }
  }

  Future<void> _openDatabase() async {
    final dir = await getApplicationDocumentsDirectory();
    final offlinePhotoRoot = Directory(p.join(dir.path, 'offline_photos'));
    await offlinePhotoRoot.create(recursive: true);
    _offlinePhotoRootPath = offlinePhotoRoot.path;
    final hasEncryptedPhotos = await _photoTreeHasEncryptedFiles(
      offlinePhotoRoot.path,
    );
    final encodedPhotoKey = await _photoKeyManager.loadOrCreateKey(
      hasEncryptedPhotos: hasEncryptedPhotos,
    );
    _photoKeyBytes = LocalPhotoKeyManager.decodeKey(encodedPhotoKey);
    final dbPath = p.join(dir.path, 'gis_collector_offline.db');
    final databaseState = await inspectLocalDatabaseFile(File(dbPath));
    final databaseKey = await _databaseKeyManager.loadOrCreateKey(
      databaseState,
    );
    await prepareEncryptedLocalDatabase(
      databasePath: dbPath,
      password: databaseKey,
    );

    final db = await openDatabase(
      dbPath,
      password: databaseKey,
      version: _dbVersion,
      onConfigure: (db) async {
        await db.rawQuery('PRAGMA cipher_memory_security = ON');
        await db.rawQuery('PRAGMA secure_delete = ON');
        await db.rawQuery('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await _createSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            "ALTER TABLE draft_features ADD COLUMN geometry_json TEXT NOT NULL DEFAULT '{\"type\":\"Point\",\"coordinates\":[]}'",
          );
          await db.execute('''
            CREATE TABLE IF NOT EXISTS offline_map_packages (
              version TEXT PRIMARY KEY,
              zoom_level_min INTEGER NOT NULL,
              zoom_level_max INTEGER NOT NULL,
              downloaded_at TEXT,
              last_updated_at TEXT NOT NULL,
              tile_count INTEGER,
              size_bytes INTEGER,
              tile_source TEXT,
              is_current INTEGER NOT NULL
            );
          ''');
        }
        if (oldVersion < 3) {
          await db.execute(
            "ALTER TABLE draft_features ADD COLUMN owner_user_id TEXT NOT NULL DEFAULT ''",
          );
        }
        if (oldVersion < 4) {
          await db.execute(
            "ALTER TABLE offline_map_packages ADD COLUMN owner_user_id TEXT NOT NULL DEFAULT ''",
          );
          await db.execute(
            'CREATE UNIQUE INDEX IF NOT EXISTS idx_offline_map_packages_owner_version ON offline_map_packages(owner_user_id, version);',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_offline_map_packages_current_owner ON offline_map_packages(owner_user_id, is_current);',
          );
        }
        if (oldVersion < 5) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS offline_project_packages (
              owner_user_id TEXT NOT NULL,
              project_id TEXT NOT NULL,
              payload_json TEXT NOT NULL,
              package_version TEXT NOT NULL,
              app_resources_version TEXT NOT NULL,
              base_map_version TEXT NOT NULL,
              downloaded_at TEXT NOT NULL,
              refreshed_at TEXT NOT NULL,
              PRIMARY KEY (owner_user_id, project_id)
            );
          ''');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_offline_project_packages_owner ON offline_project_packages(owner_user_id);',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_offline_project_packages_base_map ON offline_project_packages(owner_user_id, base_map_version);',
          );
        }
        if (oldVersion < 6) {
          await _migrateProjectScopedStorage(db);
        }
        if (oldVersion < 7) {
          await _createPendingLocalFileDeletionTable(db);
        }
        if (oldVersion < 8) {
          await _migrateDraftPhotosToOwnedStorage(db);
        }
        if (oldVersion < 9) {
          await _createPendingTemporaryPhotoDeletionTable(db);
          await _quarantineLegacyUnownedRows(db);
          await _migrateDraftPhotosToOwnedStorage(db);
          await _migrateDraftPhotosToEncryptedStorage(db);
        }
      },
    );
    try {
      await _createPendingTemporaryPhotoDeletionTable(db);
      await db.update(
        'sync_queue',
        <String, Object?>{
          'status': SyncQueueStatus.failed.name,
          'next_retry_at': DateTime.now().toIso8601String(),
          'last_error':
              'Previous synchronization was interrupted before confirmation.',
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'status = ?',
        whereArgs: <Object?>[SyncQueueStatus.processing.name],
      );
      final now = DateTime.now().toIso8601String();
      await db.rawUpdate(
        '''
        UPDATE sync_queue
        SET status = ?, next_retry_at = ?, updated_at = ?
        WHERE status = ?
          AND owner_user_id <> ''
          AND owner_user_id <> ?
          AND project_id <> ''
          AND project_id <> ?
          AND project_id <> '__ambiguous__'
        ''',
        <Object?>[
          SyncQueueStatus.failed.name,
          now,
          now,
          SyncQueueStatus.deadLetter.name,
          legacyUnownedOfflineOwnerId,
          legacyAmbiguousOfflineProjectId,
        ],
      );
      await db.transaction((transaction) async {
        await _quarantineLegacyUnownedRows(transaction);
        await _migrateDraftPhotosToOwnedStorage(transaction);
        await _migrateDraftPhotosToEncryptedStorage(transaction);
      });
      await _drainPendingPhotoFileDeletions(db);
      await _drainPendingTemporaryPhotoDeletions(db);
      await _encryptUnreferencedPlaintextPhotos();
      await _assertNoPlaintextPhotoFiles();
      _db = db;
    } catch (_) {
      await db.close();
      rethrow;
    }
  }

  Future<void> _migrateProjectScopedStorage(Database db) async {
    final legacyDraftRows = await db.query('draft_features');
    final legacyPhotoRows = await db.query('draft_photos');
    final legacyQueueRows = await db.query('sync_queue');

    await db.execute('ALTER TABLE draft_features RENAME TO draft_features_v5');
    await db.execute('ALTER TABLE draft_photos RENAME TO draft_photos_v5');
    await db.execute('ALTER TABLE sync_queue RENAME TO sync_queue_v5');
    await db.execute('DROP TABLE projects_cache');

    await _createProjectCacheTable(db);
    await _createDraftTables(db);
    await _createSyncQueueTable(db);

    final draftIdentityById = <String, List<(String, String)>>{};
    for (final row in legacyDraftRows) {
      final draftRow = Map<String, Object?>.from(row);
      final ownerUserId = (draftRow['owner_user_id'] as String?) ?? '';
      final projectId = (draftRow['project_id'] as String?) ?? '';
      final draftId = draftRow['id'] as String;
      await db.insert('draft_features', draftRow);
      draftIdentityById.putIfAbsent(draftId, () => <(String, String)>[]).add((
        ownerUserId,
        projectId,
      ));
    }

    for (final row in legacyPhotoRows) {
      final draftId = row['draft_id'] as String;
      final identities =
          draftIdentityById[draftId] ?? const <(String, String)>[];
      if (identities.length != 1) {
        continue;
      }
      final identity = identities.single;
      await db.insert('draft_photos', <String, Object?>{
        'owner_user_id': identity.$1,
        'project_id': identity.$2,
        ...row,
      });
    }

    for (final row in legacyQueueRows) {
      final queueRow = Map<String, Object?>.from(row);
      Map<String, dynamic> payload;
      try {
        payload =
            jsonDecode(queueRow['payload_json'] as String)
                as Map<String, dynamic>;
      } catch (_) {
        payload = <String, dynamic>{};
      }
      final entityId = queueRow['entity_id'] as String;
      final payloadProjectId = (payload['project_id'] as String?) ?? '';
      final matchingIdentities =
          (draftIdentityById[entityId] ?? const <(String, String)>[])
              .where(
                (identity) =>
                    payloadProjectId.isEmpty || identity.$2 == payloadProjectId,
              )
              .toList(growable: false);
      final identity = matchingIdentities.length == 1
          ? matchingIdentities.single
          : null;
      final ownerUserId =
          (payload['owner_user_id'] as String?) ?? identity?.$1 ?? '';
      final projectId = payloadProjectId.isNotEmpty
          ? payloadProjectId
          : identity?.$2 ?? '__ambiguous__';
      payload['owner_user_id'] = ownerUserId;
      payload['project_id'] = projectId;
      queueRow
        ..['owner_user_id'] = ownerUserId
        ..['project_id'] = projectId
        ..['payload_json'] = jsonEncode(payload);
      if (projectId == '__ambiguous__' || ownerUserId.isEmpty) {
        queueRow
          ..['status'] = SyncQueueStatus.deadLetter.name
          ..['next_retry_at'] = null
          ..['last_error'] =
              'Legacy offline item was quarantined because its project could not be determined safely.';
      }
      await db.insert('sync_queue', queueRow);
    }

    await db.execute('DROP TABLE sync_queue_v5');
    await db.execute('DROP TABLE draft_photos_v5');
    await db.execute('DROP TABLE draft_features_v5');
    await _createProjectScopedIndexes(db);
  }

  Future<void> _quarantineLegacyUnownedRows(DatabaseExecutor db) async {
    final draftRows = await db.query(
      'draft_features',
      columns: const <String>['id', 'owner_user_id', 'project_id'],
      orderBy: 'id, owner_user_id, project_id',
    );
    for (final row in draftRows) {
      final draftId = row['id'];
      final oldOwnerUserId = row['owner_user_id'];
      final oldProjectId = row['project_id'];
      if (draftId is! String ||
          oldOwnerUserId is! String ||
          oldProjectId is! String ||
          draftId.trim().isEmpty) {
        throw const LocalPhotoSecurityException(
          'A legacy offline draft has invalid identity metadata. The database '
          'and files were preserved.',
        );
      }
      final ownerUserId = oldOwnerUserId.trim().isEmpty
          ? legacyUnownedOfflineOwnerId
          : oldOwnerUserId;
      final projectId = oldProjectId.trim().isEmpty
          ? legacyAmbiguousOfflineProjectId
          : oldProjectId;
      if (ownerUserId == oldOwnerUserId && projectId == oldProjectId) {
        continue;
      }

      final updatedDrafts = await db.update(
        'draft_features',
        <String, Object?>{
          'owner_user_id': ownerUserId,
          'project_id': projectId,
        },
        where: 'id = ? AND owner_user_id = ? AND project_id = ?',
        whereArgs: <Object?>[draftId, oldOwnerUserId, oldProjectId],
      );
      if (updatedDrafts != 1) {
        throw const LocalPhotoSecurityException(
          'A legacy offline draft changed during ownership quarantine. The '
          'database and files were preserved.',
        );
      }
    }

    final currentDraftRows = await db.query(
      'draft_features',
      columns: const <String>['id', 'owner_user_id', 'project_id'],
      orderBy: 'id, owner_user_id, project_id',
    );
    final identitiesByDraftId =
        <String, List<({String ownerUserId, String projectId})>>{};
    for (final row in currentDraftRows) {
      final draftId = row['id'];
      final ownerUserId = row['owner_user_id'];
      final projectId = row['project_id'];
      if (draftId is String &&
          ownerUserId is String &&
          projectId is String &&
          draftId.trim().isNotEmpty &&
          ownerUserId.trim().isNotEmpty &&
          projectId.trim().isNotEmpty) {
        identitiesByDraftId
            .putIfAbsent(
              draftId,
              () => <({String ownerUserId, String projectId})>[],
            )
            .add((ownerUserId: ownerUserId, projectId: projectId));
      }
    }

    final photoRows = await db.query(
      'draft_photos',
      columns: const <String>['id', 'owner_user_id', 'project_id', 'draft_id'],
      where: "TRIM(owner_user_id) = '' OR TRIM(project_id) = ''",
      orderBy: 'draft_id, id',
    );
    for (final row in photoRows) {
      final photoId = row['id'];
      final draftId = row['draft_id'];
      final oldOwnerUserId = row['owner_user_id'];
      final oldProjectId = row['project_id'];
      final identities = draftId is String
          ? identitiesByDraftId[draftId] ??
                const <({String ownerUserId, String projectId})>[]
          : const <({String ownerUserId, String projectId})>[];
      if (photoId is! String ||
          draftId is! String ||
          oldOwnerUserId is! String ||
          oldProjectId is! String ||
          identities.length != 1) {
        throw const LocalPhotoSecurityException(
          'A legacy offline photo has ambiguous ownership. The database and '
          'files were preserved.',
        );
      }
      final identity = identities.single;
      final updatedPhotos = await db.update(
        'draft_photos',
        <String, Object?>{
          'owner_user_id': identity.ownerUserId,
          'project_id': identity.projectId,
        },
        where:
            'id = ? AND draft_id = ? AND owner_user_id = ? AND project_id = ?',
        whereArgs: <Object?>[photoId, draftId, oldOwnerUserId, oldProjectId],
      );
      if (updatedPhotos != 1) {
        throw const LocalPhotoSecurityException(
          'A legacy offline photo changed during ownership quarantine. The '
          'database and files were preserved.',
        );
      }
    }

    final queueRows = await db.query(
      'sync_queue',
      columns: const <String>[
        'id',
        'owner_user_id',
        'project_id',
        'entity_id',
        'payload_json',
      ],
      where: "TRIM(owner_user_id) = '' OR TRIM(project_id) = ''",
      orderBy: 'id',
    );
    for (final row in queueRows) {
      final queueId = row['id'];
      final entityId = row['entity_id'];
      final oldOwnerUserId = row['owner_user_id'];
      final oldProjectId = row['project_id'];
      final rawPayloadJson = row['payload_json'];
      if (queueId is! String ||
          entityId is! String ||
          oldOwnerUserId is! String ||
          oldProjectId is! String ||
          rawPayloadJson is! String) {
        throw const LocalPhotoSecurityException(
          'A legacy synchronization item has invalid identity metadata. The '
          'database and files were preserved.',
        );
      }
      final identities =
          identitiesByDraftId[entityId] ??
          const <({String ownerUserId, String projectId})>[];
      final ownerUserId = identities.length == 1
          ? identities.single.ownerUserId
          : legacyUnownedOfflineOwnerId;
      final projectId = identities.length == 1
          ? identities.single.projectId
          : legacyAmbiguousOfflineProjectId;
      Map<String, dynamic> payload;
      try {
        payload = jsonDecode(rawPayloadJson) as Map<String, dynamic>;
      } catch (_) {
        payload = <String, dynamic>{};
      }
      payload
        ..['owner_user_id'] = ownerUserId
        ..['project_id'] = projectId;
      final updatedQueue = await db.update(
        'sync_queue',
        <String, Object?>{
          'owner_user_id': ownerUserId,
          'project_id': projectId,
          'payload_json': jsonEncode(payload),
          'status': SyncQueueStatus.deadLetter.name,
          'next_retry_at': null,
          'last_error':
              'Legacy offline item was quarantined because its original '
              'account identity is unavailable.',
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ? AND owner_user_id = ? AND project_id = ?',
        whereArgs: <Object?>[queueId, oldOwnerUserId, oldProjectId],
      );
      if (updatedQueue != 1) {
        throw const LocalPhotoSecurityException(
          'A legacy synchronization item changed during ownership quarantine. '
          'The database and files were preserved.',
        );
      }
    }
  }

  Future<void> _createSchema(Database db) async {
    await _createProjectCacheTable(db);
    await _createDraftTables(db);
    await _createSyncQueueTable(db);
    await _createPendingLocalFileDeletionTable(db);
    await _createPendingTemporaryPhotoDeletionTable(db);

    await db.execute('''
      CREATE TABLE offline_map_packages (
        owner_user_id TEXT NOT NULL,
        version TEXT NOT NULL,
        zoom_level_min INTEGER NOT NULL,
        zoom_level_max INTEGER NOT NULL,
        downloaded_at TEXT,
        last_updated_at TEXT NOT NULL,
        tile_count INTEGER,
        size_bytes INTEGER,
        tile_source TEXT,
        is_current INTEGER NOT NULL,
        PRIMARY KEY (owner_user_id, version)
      );
    ''');

    await db.execute('''
      CREATE TABLE offline_project_packages (
        owner_user_id TEXT NOT NULL,
        project_id TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        package_version TEXT NOT NULL,
        app_resources_version TEXT NOT NULL,
        base_map_version TEXT NOT NULL,
        downloaded_at TEXT NOT NULL,
        refreshed_at TEXT NOT NULL,
        PRIMARY KEY (owner_user_id, project_id)
      );
    ''');

    await _createProjectScopedIndexes(db);
    await db.execute(
      'CREATE INDEX idx_offline_map_packages_current_owner ON offline_map_packages(owner_user_id, is_current);',
    );
    await db.execute(
      'CREATE INDEX idx_offline_project_packages_owner ON offline_project_packages(owner_user_id);',
    );
    await db.execute(
      'CREATE INDEX idx_offline_project_packages_base_map ON offline_project_packages(owner_user_id, base_map_version);',
    );
  }

  Future<void> _createProjectCacheTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE projects_cache (
        owner_user_id TEXT NOT NULL,
        id TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (owner_user_id, id)
      );
    ''');
  }

  Future<void> _createDraftTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE draft_features (
        id TEXT NOT NULL,
        owner_user_id TEXT NOT NULL,
        project_id TEXT NOT NULL,
        project_name TEXT NOT NULL,
        geometry_type TEXT NOT NULL,
        geometry_json TEXT NOT NULL,
        attributes_json TEXT NOT NULL,
        status TEXT NOT NULL,
        local_version INTEGER NOT NULL,
        remote_version INTEGER,
        collected_offline INTEGER NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (owner_user_id, project_id, id)
      );
    ''');
    await db.execute('''
      CREATE TABLE draft_photos (
        id TEXT NOT NULL,
        owner_user_id TEXT NOT NULL,
        project_id TEXT NOT NULL,
        draft_id TEXT NOT NULL,
        file_path TEXT NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY (owner_user_id, project_id, draft_id, id)
      );
    ''');
  }

  Future<void> _createSyncQueueTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE sync_queue (
        id TEXT PRIMARY KEY,
        owner_user_id TEXT NOT NULL,
        project_id TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        operation TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        local_version INTEGER NOT NULL,
        idempotency_key TEXT NOT NULL,
        attempt_count INTEGER NOT NULL,
        status TEXT NOT NULL,
        next_retry_at TEXT,
        last_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
  }

  Future<void> _createPendingLocalFileDeletionTable(DatabaseExecutor db) async {
    await createPendingLocalPhotoDeletionSchema(db.execute);
  }

  Future<void> _createPendingTemporaryPhotoDeletionTable(
    DatabaseExecutor db,
  ) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_temporary_photo_deletions (
        id TEXT PRIMARY KEY,
        file_path TEXT NOT NULL UNIQUE,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        last_attempt_at TEXT
      )
    ''');
  }

  Future<void> _migrateDraftPhotosToOwnedStorage(DatabaseExecutor db) async {
    final root = _offlinePhotoRootPath;
    if (root == null) {
      return;
    }
    final rows = await db.query(
      'draft_photos',
      columns: const <String>[
        'id',
        'owner_user_id',
        'project_id',
        'draft_id',
        'file_path',
      ],
    );
    final rowsByDraft =
        <
          ({String ownerUserId, String projectId, String draftId}),
          List<Map<String, Object?>>
        >{};
    for (final row in rows) {
      final ownerUserId = row['owner_user_id'];
      final projectId = row['project_id'];
      final draftId = row['draft_id'];
      final filePath = row['file_path'];
      if (ownerUserId is! String ||
          projectId is! String ||
          draftId is! String ||
          filePath is! String ||
          ownerUserId.trim().isEmpty ||
          projectId.trim().isEmpty ||
          draftId.trim().isEmpty ||
          filePath.trim().isEmpty) {
        continue;
      }
      rowsByDraft
          .putIfAbsent((
            ownerUserId: ownerUserId,
            projectId: projectId,
            draftId: draftId,
          ), () => <Map<String, Object?>>[])
          .add(row);
    }

    for (final draftEntry in rowsByDraft.entries) {
      final scope = draftEntry.key;
      final draftRows = draftEntry.value;
      final replacements = <String, String>{};
      final copiedPaths = <String>[];
      var canMigrateDraft = true;
      for (final row in draftRows) {
        final oldPath = row['file_path']! as String;
        if (areOfflineDraftPhotoPathsScoped(
          rootDirectory: root,
          ownerUserId: scope.ownerUserId,
          projectId: scope.projectId,
          draftId: scope.draftId,
          filePaths: <String>[oldPath],
        )) {
          continue;
        }
        final canonicalOldPath = canonicalLocalPhotoPath(oldPath);
        if (replacements.containsKey(canonicalOldPath)) {
          continue;
        }
        try {
          final copiedPath = await _copyDraftPhotoIntoOwnedStorage(
            ownerUserId: scope.ownerUserId,
            projectId: scope.projectId,
            draftId: scope.draftId,
            sourceFilePath: oldPath,
            suggestedFileName: oldPath,
            cleanupDatabase: db,
          );
          replacements[canonicalOldPath] = copiedPath;
          copiedPaths.add(copiedPath);
        } catch (_) {
          canMigrateDraft = false;
          break;
        }
      }
      if (!canMigrateDraft || replacements.isEmpty) {
        if (!canMigrateDraft) {
          await releaseRetainedDraftPhotos(copiedPaths);
        }
        continue;
      }

      final queueUpdates = <({String id, String payloadJson})>[];
      final queueRows = await db.query(
        'sync_queue',
        columns: const <String>['id', 'payload_json'],
        where:
            'owner_user_id = ? AND project_id = ? AND entity_type = ? AND entity_id = ?',
        whereArgs: <Object?>[
          scope.ownerUserId,
          scope.projectId,
          'draft_feature',
          scope.draftId,
        ],
      );
      for (final queueRow in queueRows) {
        final queueId = queueRow['id'];
        final rawPayloadJson = queueRow['payload_json'];
        if (queueId is! String || rawPayloadJson is! String) {
          continue;
        }
        try {
          final payload = jsonDecode(rawPayloadJson) as Map<String, dynamic>;
          final rawPhotoPaths = payload['photo_paths'];
          if (rawPhotoPaths is! List ||
              !rawPhotoPaths.every((path) => path is String)) {
            continue;
          }
          var changed = false;
          final migratedPaths = rawPhotoPaths
              .map((rawPath) {
                final path = rawPath as String;
                final replacement = replacements[canonicalLocalPhotoPath(path)];
                if (replacement != null) {
                  changed = true;
                  return replacement;
                }
                return path;
              })
              .toList(growable: false);
          if (changed) {
            payload['photo_paths'] = migratedPaths;
            queueUpdates.add((id: queueId, payloadJson: jsonEncode(payload)));
          }
        } catch (_) {
          // Leave malformed legacy queue data untouched for server-side or
          // explicit local integrity handling; never guess its association.
        }
      }

      await db.execute('SAVEPOINT migrate_offline_draft_photos');
      try {
        for (final row in draftRows) {
          final oldPath = row['file_path']! as String;
          final replacement = replacements[canonicalLocalPhotoPath(oldPath)];
          if (replacement == null) {
            continue;
          }
          await db.update(
            'draft_photos',
            <String, Object?>{'file_path': replacement},
            where:
                'id = ? AND owner_user_id = ? AND project_id = ? AND draft_id = ? AND file_path = ?',
            whereArgs: <Object?>[
              row['id'],
              scope.ownerUserId,
              scope.projectId,
              scope.draftId,
              oldPath,
            ],
          );
        }
        for (final queueUpdate in queueUpdates) {
          await db.update(
            'sync_queue',
            <String, Object?>{'payload_json': queueUpdate.payloadJson},
            where:
                'id = ? AND owner_user_id = ? AND project_id = ? AND entity_type = ? AND entity_id = ?',
            whereArgs: <Object?>[
              queueUpdate.id,
              scope.ownerUserId,
              scope.projectId,
              'draft_feature',
              scope.draftId,
            ],
          );
        }
        await db.execute('RELEASE SAVEPOINT migrate_offline_draft_photos');
      } catch (_) {
        await db.execute('ROLLBACK TO SAVEPOINT migrate_offline_draft_photos');
        await db.execute('RELEASE SAVEPOINT migrate_offline_draft_photos');
        await releaseRetainedDraftPhotos(copiedPaths);
      }
    }
  }

  Future<void> _migrateDraftPhotosToEncryptedStorage(
    DatabaseExecutor db,
  ) async {
    final root = _offlinePhotoRootPath;
    final keyBytes = _photoKeyBytes;
    if (root == null || keyBytes == null) {
      throw const LocalPhotoSecurityException(
        'Protected offline photo storage is unavailable.',
      );
    }

    final rows = await db.query(
      'draft_photos',
      columns: const <String>[
        'id',
        'owner_user_id',
        'project_id',
        'draft_id',
        'file_path',
      ],
      orderBy: 'owner_user_id, project_id, draft_id, id',
    );
    for (final row in rows) {
      final photoId = row['id'];
      final ownerUserId = row['owner_user_id'];
      final projectId = row['project_id'];
      final draftId = row['draft_id'];
      final oldPath = row['file_path'];
      if (photoId is! String ||
          ownerUserId is! String ||
          projectId is! String ||
          draftId is! String ||
          oldPath is! String ||
          photoId.trim().isEmpty ||
          ownerUserId.trim().isEmpty ||
          projectId.trim().isEmpty ||
          draftId.trim().isEmpty ||
          oldPath.trim().isEmpty) {
        throw const LocalPhotoSecurityException(
          'An offline draft photo has incomplete ownership metadata. The '
          'database and files were preserved.',
        );
      }
      if (!areOfflineDraftPhotoPathsScoped(
        rootDirectory: root,
        ownerUserId: ownerUserId,
        projectId: projectId,
        draftId: draftId,
        filePaths: <String>[oldPath],
      )) {
        throw const LocalPhotoSecurityException(
          'An offline draft photo is outside its exact owner/project/draft '
          'scope. The database and files were preserved.',
        );
      }

      final source = File(oldPath);
      final sourceType = await FileSystemEntity.type(
        source.path,
        followLinks: false,
      );
      if (sourceType == FileSystemEntityType.notFound) {
        throw const LocalPhotoSecurityException(
          'A referenced offline draft photo is missing. The database was '
          'preserved for recovery.',
        );
      }
      if (sourceType != FileSystemEntityType.file) {
        throw const LocalPhotoSecurityException(
          'A referenced offline draft photo is not a regular file. The '
          'database and files were preserved.',
        );
      }
      if (await _photoCipher.isEncryptedFile(source)) {
        if (!_photoCipher.pathClaimsEncryptedFormat(oldPath)) {
          throw const LocalPhotoSecurityException(
            'A referenced encrypted offline photo has an invalid path.',
          );
        }
        await _photoCipher.validate(
          encrypted: source,
          keyBytes: keyBytes,
          authenticationScope: _photoAuthenticationScope(oldPath),
        );
        continue;
      }
      if (_photoCipher.pathClaimsEncryptedFormat(oldPath)) {
        throw const LocalPhotoSecurityException(
          'A referenced offline photo claims encryption but contains '
          'plaintext or invalid data.',
        );
      }

      final mediaType = await _photoCipher.detectPlaintextMediaType(source);
      final encryptedPath = _photoCipher.encryptedPath(
        directoryPath: p.dirname(oldPath),
        fileStem: p.basenameWithoutExtension(oldPath),
        mediaType: mediaType,
      );
      await _photoCipher.prepareEncryptedCopy(
        source: source,
        destination: File(encryptedPath),
        keyBytes: keyBytes,
        authenticationScope: _photoAuthenticationScope(encryptedPath),
        mediaType: mediaType,
      );
      await _replaceQueuedDraftPhotoPath(
        db,
        ownerUserId: ownerUserId,
        projectId: projectId,
        draftId: draftId,
        oldPath: oldPath,
        encryptedPath: encryptedPath,
      );
      final updated = await db.update(
        'draft_photos',
        <String, Object?>{'file_path': encryptedPath},
        where:
            'id = ? AND owner_user_id = ? AND project_id = ? AND draft_id = ? AND file_path = ?',
        whereArgs: <Object?>[photoId, ownerUserId, projectId, draftId, oldPath],
      );
      if (updated != 1) {
        throw const LocalPhotoSecurityException(
          'The offline photo reference changed during encryption. All files '
          'were preserved.',
        );
      }
      await db.insert(
        'pending_local_file_deletions',
        <String, Object?>{
          'id': _uuid.v4(),
          'owner_user_id': ownerUserId,
          'project_id': projectId,
          'draft_id': draftId,
          'file_path': oldPath,
          'attempt_count': 0,
          'created_at': DateTime.now().toIso8601String(),
          'last_attempt_at': null,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  Future<void> _replaceQueuedDraftPhotoPath(
    DatabaseExecutor db, {
    required String ownerUserId,
    required String projectId,
    required String draftId,
    required String oldPath,
    required String encryptedPath,
  }) async {
    final queueRows = await db.query(
      'sync_queue',
      columns: const <String>['id', 'payload_json'],
      where:
          'owner_user_id = ? AND project_id = ? AND entity_type = ? AND entity_id = ?',
      whereArgs: <Object?>[ownerUserId, projectId, 'draft_feature', draftId],
    );
    for (final queueRow in queueRows) {
      final queueId = queueRow['id'];
      final rawPayloadJson = queueRow['payload_json'];
      if (queueId is! String || rawPayloadJson is! String) {
        throw const LocalPhotoSecurityException(
          'An offline synchronization record is malformed. Photo migration '
          'was stopped without switching references.',
        );
      }
      Map<String, dynamic> payload;
      try {
        payload = Map<String, dynamic>.from(jsonDecode(rawPayloadJson) as Map);
      } catch (_) {
        throw const LocalPhotoSecurityException(
          'An offline synchronization payload cannot be verified. Photo '
          'migration was stopped without switching references.',
        );
      }

      var changed = false;
      for (final key in const <String>['photo_paths', 'synced_photo_paths']) {
        final rawPaths = payload[key];
        if (rawPaths == null) {
          continue;
        }
        if (rawPaths is! List || !rawPaths.every((value) => value is String)) {
          throw const LocalPhotoSecurityException(
            'An offline synchronization photo list cannot be verified. Photo '
            'migration was stopped without switching references.',
          );
        }
        payload[key] = rawPaths
            .map((value) {
              final path = value as String;
              if (localPhotoPathsEqual(path, oldPath)) {
                changed = true;
                return encryptedPath;
              }
              return path;
            })
            .toList(growable: false);
      }
      if (!changed) {
        continue;
      }
      final updated = await db.update(
        'sync_queue',
        <String, Object?>{'payload_json': jsonEncode(payload)},
        where:
            'id = ? AND owner_user_id = ? AND project_id = ? AND entity_type = ? AND entity_id = ?',
        whereArgs: <Object?>[
          queueId,
          ownerUserId,
          projectId,
          'draft_feature',
          draftId,
        ],
      );
      if (updated != 1) {
        throw const LocalPhotoSecurityException(
          'An offline synchronization record changed during photo migration.',
        );
      }
    }
  }

  Future<void> _encryptUnreferencedPlaintextPhotos() async {
    final root = _offlinePhotoRootPath;
    final keyBytes = _photoKeyBytes;
    if (root == null || keyBytes == null) {
      throw const LocalPhotoSecurityException(
        'Protected offline photo storage is unavailable.',
      );
    }
    for (final plaintextPath in await _listPlaintextPhotoFiles()) {
      final source = File(plaintextPath);
      final mediaType = await _photoCipher.detectPlaintextMediaType(source);
      final encryptedPath = _photoCipher.encryptedPath(
        directoryPath: p.dirname(plaintextPath),
        fileStem: p.basenameWithoutExtension(plaintextPath),
        mediaType: mediaType,
      );
      await _photoCipher.prepareEncryptedCopy(
        source: source,
        destination: File(encryptedPath),
        keyBytes: keyBytes,
        authenticationScope: _photoAuthenticationScope(encryptedPath),
        mediaType: mediaType,
      );
      final deleted = await tryDeleteLocalPhotoFileWithinDirectory(
        plaintextPath,
        root,
      );
      if (!deleted && await File(plaintextPath).exists()) {
        throw const LocalPhotoSecurityException(
          'A verified plaintext offline photo could not be removed. Protected '
          'storage remains unavailable until cleanup succeeds.',
        );
      }
    }
  }

  Future<bool> _photoTreeHasEncryptedFiles(String root) async {
    var hasEncryptedPhotos = false;
    await for (final entity in Directory(
      root,
    ).list(recursive: true, followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const LocalPhotoSecurityException(
          'Offline photo storage contains a symbolic link.',
        );
      }
      if (type == FileSystemEntityType.file &&
          (_photoCipher.pathClaimsEncryptedFormat(entity.path) ||
              await _photoCipher.isEncryptedFile(File(entity.path)))) {
        hasEncryptedPhotos = true;
      }
    }
    return hasEncryptedPhotos;
  }

  Future<List<String>> _listPlaintextPhotoFiles() async {
    final root = _offlinePhotoRootPath;
    if (root == null) {
      throw const LocalPhotoSecurityException(
        'Protected offline photo storage is unavailable.',
      );
    }
    final plaintextPaths = <String>[];
    await for (final entity in Directory(
      root,
    ).list(recursive: true, followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const LocalPhotoSecurityException(
          'Offline photo storage contains a symbolic link.',
        );
      }
      if (type == FileSystemEntityType.file &&
          !await _photoCipher.isEncryptedFile(File(entity.path))) {
        plaintextPaths.add(p.normalize(p.absolute(entity.path)));
      }
    }
    plaintextPaths.sort();
    return plaintextPaths;
  }

  Future<void> _assertNoPlaintextPhotoFiles() async {
    if ((await _listPlaintextPhotoFiles()).isNotEmpty) {
      throw const LocalPhotoSecurityException(
        'Plaintext offline photo files remain. They were preserved and local '
        'storage was not exposed.',
      );
    }
  }

  String _photoAuthenticationScope(String filePath) {
    final root = _offlinePhotoRootPath;
    if (root == null || !isPathWithinDirectory(filePath, root)) {
      throw const LocalPhotoSecurityException(
        'The offline photo authentication path is outside protected storage.',
      );
    }
    final relativePath = p
        .relative(p.normalize(p.absolute(filePath)), from: root)
        .replaceAll(p.separator, '/');
    if (relativePath.isEmpty ||
        relativePath == '.' ||
        relativePath == '..' ||
        relativePath.startsWith('../')) {
      throw const LocalPhotoSecurityException(
        'The offline photo authentication scope is invalid.',
      );
    }
    return relativePath;
  }

  Future<void> _createSafePhotoDirectory(String directoryPath) async {
    final root = _offlinePhotoRootPath;
    if (root == null || !isPathWithinDirectory(directoryPath, root)) {
      throw const LocalPhotoSecurityException(
        'The offline photo directory is outside protected storage.',
      );
    }
    final relative = p.relative(
      p.normalize(p.absolute(directoryPath)),
      from: p.normalize(p.absolute(root)),
    );
    var current = p.normalize(p.absolute(root));
    for (final segment in p.split(relative)) {
      if (segment.isEmpty || segment == '.') {
        continue;
      }
      if (segment == '..') {
        throw const LocalPhotoSecurityException(
          'The offline photo directory escapes protected storage.',
        );
      }
      current = p.join(current, segment);
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await Directory(current).create();
      } else if (type != FileSystemEntityType.directory) {
        throw const LocalPhotoSecurityException(
          'Offline photo storage contains an unsafe path component.',
        );
      }
    }
  }

  Future<void> _createProjectScopedIndexes(DatabaseExecutor db) async {
    await db.execute(
      'CREATE INDEX idx_projects_cache_owner ON projects_cache(owner_user_id, updated_at);',
    );
    await db.execute(
      'CREATE INDEX idx_draft_features_owner_project ON draft_features(owner_user_id, project_id, updated_at);',
    );
    await db.execute(
      'CREATE INDEX idx_sync_queue_due ON sync_queue(owner_user_id, status, next_retry_at);',
    );
    await db.execute(
      'CREATE INDEX idx_sync_queue_entity ON sync_queue(owner_user_id, project_id, entity_type, entity_id);',
    );
  }

  Future<Database> get _database async {
    await initialize();
    final db = _db;
    if (db == null) {
      throw StateError('LocalStore not initialized.');
    }
    return db;
  }

  @override
  Future<void> dispose() async {
    final initialization = _initialization;
    if (initialization != null) {
      try {
        await initialization;
      } catch (_) {
        // Dispose should still clear partial initialization state.
      }
    }
    await _db?.close();
    _db = null;
    final photoKeyBytes = _photoKeyBytes;
    if (photoKeyBytes != null) {
      photoKeyBytes.fillRange(0, photoKeyBytes.length, 0);
    }
    _photoKeyBytes = null;
    _initialization = null;
  }

  @override
  Future<void> seedIfEmpty({
    required List<ProjectSummary> projects,
    required List<LocalDraftFeature> drafts,
  }) async {
    final db = await _database;
    final projectCount = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM projects_cache'),
    );
    final draftCount = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM draft_features'),
    );

    if ((projectCount ?? 0) == 0) {
      await cacheProjects(projects);
    }

    if ((draftCount ?? 0) == 0) {
      for (final draft in drafts) {
        await upsertDraft(draft, enqueueSync: false);
      }
    }
  }

  @override
  Future<void> cacheProjects(List<ProjectSummary> projects) async {
    await cacheProjectsForOwner(ownerUserId: '', projects: projects);
  }

  @override
  Future<void> cacheProjectsForOwner({
    required String ownerUserId,
    required List<ProjectSummary> projects,
  }) async {
    final db = await _database;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      final batch = txn.batch();
      batch.delete(
        'projects_cache',
        where: 'owner_user_id = ?',
        whereArgs: <Object?>[ownerUserId],
      );
      for (final project in projects) {
        batch.insert('projects_cache', {
          'owner_user_id': ownerUserId,
          'id': project.id,
          'payload_json': jsonEncode(project.toLocalPayload()),
          'updated_at': now,
        });
      }
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<List<ProjectSummary>> getCachedProjects() async {
    final db = await _database;
    final rows = await db.query('projects_cache', orderBy: 'updated_at DESC');

    return rows
        .map(
          (row) => projectSummaryFromPayload(
            jsonDecode(row['payload_json'] as String) as Map<String, dynamic>,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<ProjectSummary>> getCachedProjectsForOwner({
    required String ownerUserId,
  }) async {
    final db = await _database;
    final rows = await db.query(
      'projects_cache',
      where: 'owner_user_id = ?',
      whereArgs: <Object?>[ownerUserId],
      orderBy: 'updated_at DESC',
    );
    return rows
        .map(
          (row) => projectSummaryFromPayload(
            jsonDecode(row['payload_json'] as String) as Map<String, dynamic>,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> upsertDraft(
    LocalDraftFeature draft, {
    bool enqueueSync = true,
  }) async {
    final db = await _database;

    await db.transaction((txn) async {
      final previousQueueRows = enqueueSync
          ? await txn.query(
              'sync_queue',
              columns: const <String>['payload_json'],
              where:
                  'owner_user_id = ? AND project_id = ? AND entity_type = ? AND entity_id = ?',
              whereArgs: <Object?>[
                draft.ownerUserId,
                draft.projectId,
                'draft_feature',
                draft.id,
              ],
              limit: 1,
            )
          : const <Map<String, Object?>>[];
      var hasPhotoSyncState = false;
      final syncedPhotoPaths = <String>{};
      if (previousQueueRows.length == 1) {
        final rawPayload = previousQueueRows.single['payload_json'];
        try {
          final previousPayload =
              jsonDecode(rawPayload as String) as Map<String, dynamic>;
          hasPhotoSyncState = previousPayload.containsKey('synced_photo_paths');
          final rawSyncedPhotoPaths = previousPayload['synced_photo_paths'];
          if (rawSyncedPhotoPaths is List) {
            syncedPhotoPaths.addAll(rawSyncedPhotoPaths.whereType<String>());
          }
        } catch (_) {
          hasPhotoSyncState = false;
          syncedPhotoPaths.clear();
        }
      }
      final currentPhotoPaths = draft.photos
          .map((photo) => photo.filePath)
          .toSet();
      final removedSynchronizedPhoto =
          hasPhotoSyncState && !currentPhotoPaths.containsAll(syncedPhotoPaths);
      final effectiveDraft = removedSynchronizedPhoto
          ? draft.copyWith(status: 'rejected')
          : draft;

      await txn.insert(
        'draft_features',
        effectiveDraft.toRowMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await txn.delete(
        'draft_photos',
        where: 'owner_user_id = ? AND project_id = ? AND draft_id = ?',
        whereArgs: [
          effectiveDraft.ownerUserId,
          effectiveDraft.projectId,
          effectiveDraft.id,
        ],
      );

      for (final photo in effectiveDraft.photos) {
        await txn.insert('draft_photos', {
          'id': photo.id,
          'owner_user_id': effectiveDraft.ownerUserId,
          'project_id': effectiveDraft.projectId,
          'draft_id': effectiveDraft.id,
          'file_path': photo.filePath,
          'created_at': photo.createdAt.toIso8601String(),
        });
      }

      if (enqueueSync) {
        final now = DateTime.now();

        await txn.delete(
          'sync_queue',
          where:
              'owner_user_id = ? AND project_id = ? AND entity_type = ? AND entity_id = ?',
          whereArgs: [
            effectiveDraft.ownerUserId,
            effectiveDraft.projectId,
            'draft_feature',
            effectiveDraft.id,
          ],
        );

        final queueItem = SyncQueueItem(
          id: _uuid.v4(),
          entityType: 'draft_feature',
          entityId: effectiveDraft.id,
          operation: effectiveDraft.remoteVersion == null
              ? SyncOperationType.create
              : SyncOperationType.update,
          payload: {
            'draft_id': effectiveDraft.id,
            'owner_user_id': effectiveDraft.ownerUserId,
            'project_id': effectiveDraft.projectId,
            'geometry_type': effectiveDraft.geometryType,
            'geometry':
                jsonDecode(effectiveDraft.geometryJson) as Map<String, dynamic>,
            'attributes':
                jsonDecode(effectiveDraft.attributesJson)
                    as Map<String, dynamic>,
            'photo_paths': effectiveDraft.remoteVersion == null
                ? effectiveDraft.photos
                      .map((p) => p.filePath)
                      .toList(growable: false)
                : hasPhotoSyncState
                ? effectiveDraft.photos
                      .map((photo) => photo.filePath)
                      .where((path) => !syncedPhotoPaths.contains(path))
                      .toList(growable: false)
                : const <String>[],
            if (hasPhotoSyncState)
              'synced_photo_paths': syncedPhotoPaths.toList(growable: false),
            'status': effectiveDraft.status,
            'local_version': effectiveDraft.localVersion,
            'remote_version': effectiveDraft.remoteVersion,
          },
          ownerUserId: effectiveDraft.ownerUserId,
          projectId: effectiveDraft.projectId,
          localVersion: effectiveDraft.localVersion,
          idempotencyKey: _uuid.v4(),
          attemptCount: 0,
          status: removedSynchronizedPhoto
              ? SyncQueueStatus.conflict
              : SyncQueueStatus.pending,
          nextRetryAt: removedSynchronizedPhoto ? null : now,
          lastError: removedSynchronizedPhoto
              ? 'A photo already synchronized to the server was removed offline. Review this draft online.'
              : null,
          createdAt: now,
          updatedAt: now,
        );

        await txn.insert('sync_queue', queueItem.toRowMap());
      }
    });
    await _drainPendingTemporaryPhotoDeletions(db);
  }

  @override
  Future<List<LocalDraftFeature>> getDrafts() async {
    final db = await _database;
    final rows = await db.query('draft_features', orderBy: 'updated_at DESC');

    final drafts = <LocalDraftFeature>[];
    for (final row in rows) {
      final photosRows = await db.query(
        'draft_photos',
        where: 'owner_user_id = ? AND project_id = ? AND draft_id = ?',
        whereArgs: [row['owner_user_id'], row['project_id'], row['id']],
      );
      final photos = photosRows
          .map(
            (photoRow) => DraftPhoto.fromMap({
              'id': photoRow['id'] as String,
              'file_path': photoRow['file_path'] as String,
              'created_at': photoRow['created_at'] as String,
            }),
          )
          .toList(growable: false);

      drafts.add(
        LocalDraftFeature.fromRowMap(Map<String, dynamic>.from(row), photos),
      );
    }

    return drafts;
  }

  @override
  Future<LocalDraftFeature?> getDraftById(String draftId) async {
    final db = await _database;
    final rows = await db.query(
      'draft_features',
      where: 'id = ?',
      whereArgs: [draftId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }

    final photosRows = await db.query(
      'draft_photos',
      where: 'draft_id = ?',
      whereArgs: [draftId],
    );
    final photos = photosRows
        .map(
          (photoRow) => DraftPhoto.fromMap({
            'id': photoRow['id'] as String,
            'file_path': photoRow['file_path'] as String,
            'created_at': photoRow['created_at'] as String,
          }),
        )
        .toList(growable: false);

    return LocalDraftFeature.fromRowMap(
      Map<String, dynamic>.from(rows.first),
      photos,
    );
  }

  @override
  Future<List<LocalDraftFeature>> getDraftsForOwner({
    required String ownerUserId,
  }) async {
    return _getDraftsWhere(
      where: 'owner_user_id = ?',
      whereArgs: <Object?>[ownerUserId],
    );
  }

  @override
  Future<List<LocalDraftFeature>> getDraftsForProject({
    required String ownerUserId,
    required String projectId,
  }) async {
    return _getDraftsWhere(
      where: 'owner_user_id = ? AND project_id = ?',
      whereArgs: <Object?>[ownerUserId, projectId],
    );
  }

  Future<List<LocalDraftFeature>> _getDraftsWhere({
    required String where,
    required List<Object?> whereArgs,
  }) async {
    final db = await _database;
    final rows = await db.query(
      'draft_features',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'updated_at DESC',
    );
    final drafts = <LocalDraftFeature>[];
    for (final row in rows) {
      final photosRows = await db.query(
        'draft_photos',
        where: 'owner_user_id = ? AND project_id = ? AND draft_id = ?',
        whereArgs: [row['owner_user_id'], row['project_id'], row['id']],
      );
      final photos = photosRows
          .map(
            (photoRow) => DraftPhoto.fromMap(<String, dynamic>{
              'id': photoRow['id'] as String,
              'file_path': photoRow['file_path'] as String,
              'created_at': photoRow['created_at'] as String,
            }),
          )
          .toList(growable: false);
      drafts.add(
        LocalDraftFeature.fromRowMap(Map<String, dynamic>.from(row), photos),
      );
    }
    return drafts;
  }

  @override
  Future<LocalDraftFeature?> getProjectDraft({
    required String ownerUserId,
    required String projectId,
    required String draftId,
  }) async {
    final drafts = await _getDraftsWhere(
      where: 'owner_user_id = ? AND project_id = ? AND id = ?',
      whereArgs: <Object?>[ownerUserId, projectId, draftId],
    );
    return drafts.isEmpty ? null : drafts.first;
  }

  @override
  Future<void> discardDraft(String draftId) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete(
        'sync_queue',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: ['draft_feature', draftId],
      );
      await txn.delete(
        'draft_photos',
        where: 'draft_id = ?',
        whereArgs: [draftId],
      );
      await txn.delete('draft_features', where: 'id = ?', whereArgs: [draftId]);
    });
  }

  @override
  Future<void> discardProjectDraft({
    required String ownerUserId,
    required String projectId,
    required String draftId,
  }) async {
    final db = await _database;
    await _removeProjectDraftBundle(
      db,
      ownerUserId: ownerUserId,
      projectId: projectId,
      draftId: draftId,
    );
  }

  @override
  Future<String> retainDraftPhoto({
    required String ownerUserId,
    required String projectId,
    required String draftId,
    required String photoId,
    required String sourceFilePath,
    String? suggestedFileName,
  }) async {
    await _database;
    return _copyDraftPhotoIntoOwnedStorage(
      ownerUserId: ownerUserId,
      projectId: projectId,
      draftId: draftId,
      sourceFilePath: sourceFilePath,
      suggestedFileName: suggestedFileName,
    );
  }

  Future<String> _copyDraftPhotoIntoOwnedStorage({
    required String ownerUserId,
    required String projectId,
    required String draftId,
    required String sourceFilePath,
    String? suggestedFileName,
    DatabaseExecutor? cleanupDatabase,
  }) async {
    final root = _offlinePhotoRootPath;
    final keyBytes = _photoKeyBytes;
    if (root == null || keyBytes == null) {
      throw StateError('Protected offline photo storage is unavailable.');
    }
    final source = File(sourceFilePath);
    if (!await source.exists()) {
      throw StateError('The selected photo is no longer available.');
    }
    final directoryPath = offlineDraftPhotoDirectoryPath(
      rootDirectory: root,
      ownerUserId: ownerUserId,
      projectId: projectId,
      draftId: draftId,
    );
    if (!isPathWithinDirectory(directoryPath, root)) {
      throw StateError('Offline photo storage scope is invalid.');
    }
    await _createSafePhotoDirectory(directoryPath);
    final mediaType = await _photoCipher.detectPlaintextMediaType(source);
    final destination = _photoCipher.encryptedPath(
      directoryPath: directoryPath,
      fileStem: _uuid.v4(),
      mediaType: mediaType,
    );
    if (!isPathWithinDirectory(destination, directoryPath) ||
        !isPathWithinDirectory(destination, root)) {
      throw StateError('Offline photo destination is invalid.');
    }
    await _photoCipher.prepareEncryptedCopy(
      source: source,
      destination: File(destination),
      keyBytes: keyBytes,
      authenticationScope: _photoAuthenticationScope(destination),
      mediaType: mediaType,
    );
    await _scheduleTemporaryPhotoDeletion(
      source.path,
      database: cleanupDatabase,
    );
    return destination;
  }

  @override
  Future<DecryptedOfflinePhoto> readProtectedDraftPhoto(String filePath) async {
    await _database;
    final keyBytes = _photoKeyBytes;
    if (keyBytes == null) {
      throw StateError('Protected offline photo storage is unavailable.');
    }
    return _photoCipher.decrypt(
      encrypted: File(filePath),
      keyBytes: keyBytes,
      authenticationScope: _photoAuthenticationScope(filePath),
    );
  }

  @override
  Future<void> releaseRetainedDraftPhotos(Iterable<String> filePaths) async {
    final root = _offlinePhotoRootPath;
    if (root == null) {
      return;
    }
    for (final filePath in filePaths.toSet()) {
      await tryDeleteLocalPhotoFileWithinDirectory(filePath, root);
    }
  }

  @override
  Future<void> removeTemporaryPickedPhotoCopies(
    Iterable<String> filePaths,
  ) async {
    try {
      final db = await _database;
      for (final filePath in filePaths.toSet()) {
        await _scheduleTemporaryPhotoDeletion(filePath, database: db);
      }
      await _drainPendingTemporaryPhotoDeletions(db);
    } catch (_) {
      // The durable queue retries cleanup on initialization. Cleanup must not
      // convert a successful upload or local save into a duplicate retry.
    }
  }

  @override
  Future<bool> areRetainedDraftPhotoPathsScoped({
    required String ownerUserId,
    required String projectId,
    required String draftId,
    required Iterable<String> filePaths,
  }) async {
    await _database;
    final root = _offlinePhotoRootPath;
    if (root == null) {
      return false;
    }
    return areOfflineDraftPhotoPathsScoped(
      rootDirectory: root,
      ownerUserId: ownerUserId,
      projectId: projectId,
      draftId: draftId,
      filePaths: filePaths,
    );
  }

  @override
  Future<void> updateDraftStatus(
    String draftId, {
    required String status,
    int? remoteVersion,
  }) async {
    final db = await _database;
    final values = <String, Object?>{
      'status': status,
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (remoteVersion != null) {
      values['remote_version'] = remoteVersion;
    }

    await db.update(
      'draft_features',
      values,
      where: 'id = ?',
      whereArgs: [draftId],
    );
  }

  @override
  Future<void> updateProjectDraftStatus({
    required String ownerUserId,
    required String projectId,
    required String draftId,
    required String status,
    int? remoteVersion,
  }) async {
    final db = await _database;
    final values = <String, Object?>{
      'status': status,
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (remoteVersion != null) {
      values['remote_version'] = remoteVersion;
    }
    await db.update(
      'draft_features',
      values,
      where: 'owner_user_id = ? AND project_id = ? AND id = ?',
      whereArgs: [ownerUserId, projectId, draftId],
    );
  }

  @override
  Future<void> upsertOfflineMapPackage(OfflineMapPackage package) async {
    final db = await _database;
    await db.transaction((txn) async {
      if (package.isCurrent) {
        await txn.update(
          'offline_map_packages',
          {'is_current': 0},
          where: 'owner_user_id = ?',
          whereArgs: [package.ownerUserId],
        );
      }

      await txn.insert(
        'offline_map_packages',
        package.toRowMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  @override
  Future<OfflineMapPackage?> getCurrentOfflineMapPackage({
    required String ownerUserId,
  }) async {
    final db = await _database;
    Future<List<Map<String, Object?>>> loadRows(String targetOwnerUserId) {
      return db.query(
        'offline_map_packages',
        where: 'owner_user_id = ? AND is_current = 1',
        whereArgs: [targetOwnerUserId],
        limit: 1,
        orderBy: 'last_updated_at DESC',
      );
    }

    final rows = await loadRows(ownerUserId);
    if (rows.isNotEmpty) {
      return OfflineMapPackage.fromRowMap(
        Map<String, dynamic>.from(rows.first),
      );
    }
    if (ownerUserId.isEmpty) {
      return null;
    }

    final legacyRows = await loadRows('');
    if (legacyRows.isEmpty) {
      return null;
    }

    final legacyPackage = OfflineMapPackage.fromRowMap(
      Map<String, dynamic>.from(legacyRows.first),
    );
    final migratedPackage = legacyPackage.copyWith(ownerUserId: ownerUserId);
    await upsertOfflineMapPackage(migratedPackage);
    await db.delete(
      'offline_map_packages',
      where: 'owner_user_id = ? AND version = ?',
      whereArgs: ['', legacyPackage.version],
    );
    return migratedPackage;
  }

  @override
  Future<void> upsertOfflineProjectPackage(
    OfflineProjectPackage package,
  ) async {
    final db = await _database;
    await db.insert(
      'offline_project_packages',
      package.toRowMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _mergeCachedProject(package.ownerUserId, package.project);
  }

  Future<void> _mergeCachedProject(
    String ownerUserId,
    ProjectSummary project,
  ) async {
    final cached = await getCachedProjectsForOwner(ownerUserId: ownerUserId);
    final merged = <String, ProjectSummary>{
      for (final item in cached) item.id: item,
      project.id: project,
    };
    await cacheProjectsForOwner(
      ownerUserId: ownerUserId,
      projects: merged.values.toList(growable: false),
    );
  }

  @override
  Future<OfflineProjectPackage?> getOfflineProjectPackage({
    required String ownerUserId,
    required String projectId,
  }) async {
    final db = await _database;
    final rows = await db.query(
      'offline_project_packages',
      where: 'owner_user_id = ? AND project_id = ?',
      whereArgs: [ownerUserId, projectId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return OfflineProjectPackage.fromRowMap(
      Map<String, dynamic>.from(rows.first),
    );
  }

  @override
  Future<List<OfflineProjectPackage>> getOfflineProjectPackages({
    required String ownerUserId,
  }) async {
    final db = await _database;
    final rows = await db.query(
      'offline_project_packages',
      where: 'owner_user_id = ?',
      whereArgs: [ownerUserId],
      orderBy: 'refreshed_at DESC',
    );
    return rows
        .map(
          (row) =>
              OfflineProjectPackage.fromRowMap(Map<String, dynamic>.from(row)),
        )
        .toList(growable: false);
  }

  @override
  Future<void> deleteOfflineProjectPackage({
    required String ownerUserId,
    required String projectId,
  }) async {
    final db = await _database;
    await db.delete(
      'offline_project_packages',
      where: 'owner_user_id = ? AND project_id = ?',
      whereArgs: [ownerUserId, projectId],
    );
  }

  @override
  Future<int> countOfflineProjectPackagesUsingBaseMap({
    required String ownerUserId,
    required String baseMapVersion,
  }) async {
    final db = await _database;
    return Sqflite.firstIntValue(
          await db.rawQuery(
            '''
            SELECT COUNT(*) FROM offline_project_packages
            WHERE owner_user_id = ? AND base_map_version = ?
            ''',
            [ownerUserId, baseMapVersion],
          ),
        ) ??
        0;
  }

  @override
  Future<int> countUnsyncedDraftsForProject({
    required String ownerUserId,
    required String projectId,
  }) async {
    final db = await _database;
    return Sqflite.firstIntValue(
          await db.rawQuery(
            '''
            SELECT COUNT(*)
            FROM draft_features df
            WHERE df.owner_user_id = ?
              AND df.project_id = ?
              AND EXISTS (
                SELECT 1
                FROM sync_queue sq
                WHERE sq.entity_type = 'draft_feature'
                  AND sq.entity_id = df.id
                  AND sq.owner_user_id = df.owner_user_id
                  AND sq.project_id = df.project_id
                  AND sq.status IN ('pending', 'processing', 'failed', 'conflict', 'deadLetter')
              )
            ''',
            [ownerUserId, projectId],
          ),
        ) ??
        0;
  }

  @override
  Future<int> getPendingSyncCount() async {
    return (await getSyncQueueStats()).actionable;
  }

  @override
  Future<SyncQueueStats> getSyncQueueStats() async {
    return _getSyncQueueStatsWhere();
  }

  @override
  Future<SyncQueueStats> getSyncQueueStatsForOwner({
    required String ownerUserId,
  }) async {
    return _getSyncQueueStatsWhere(
      where: 'owner_user_id = ?',
      whereArgs: <Object?>[ownerUserId],
    );
  }

  Future<SyncQueueStats> _getSyncQueueStatsWhere({
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT status, COUNT(*) AS count FROM sync_queue${where == null ? '' : ' WHERE $where'} GROUP BY status',
      whereArgs,
    );

    var pending = 0;
    var processing = 0;
    var failed = 0;
    var conflict = 0;
    var deadLetter = 0;

    for (final row in rows) {
      final status = row['status'] as String;
      final count = row['count'] as int;
      switch (status) {
        case 'pending':
          pending = count;
          break;
        case 'processing':
          processing = count;
          break;
        case 'failed':
          failed = count;
          break;
        case 'conflict':
          conflict = count;
          break;
        case 'deadLetter':
          deadLetter = count;
          break;
      }
    }

    return SyncQueueStats(
      pending: pending,
      processing: processing,
      failed: failed,
      conflict: conflict,
      deadLetter: deadLetter,
    );
  }

  @override
  Future<List<SyncQueueItem>> getDueSyncItems(
    DateTime now, {
    int limit = 20,
  }) async {
    final db = await _database;
    final rows = await db.query(
      'sync_queue',
      where:
          "(status = 'pending' OR status = 'failed') AND (next_retry_at IS NULL OR next_retry_at <= ?)",
      whereArgs: [now.toIso8601String()],
      orderBy: 'created_at ASC',
      limit: limit,
    );

    return rows
        .map((row) => SyncQueueItem.fromRowMap(Map<String, dynamic>.from(row)))
        .toList(growable: false);
  }

  @override
  Future<List<SyncQueueItem>> getDueSyncItemsForOwner(
    String ownerUserId,
    DateTime now, {
    int limit = 20,
  }) async {
    final db = await _database;
    final rows = await db.query(
      'sync_queue',
      where:
          "owner_user_id = ? AND (status = 'pending' OR status = 'failed') AND (next_retry_at IS NULL OR next_retry_at <= ?)",
      whereArgs: [ownerUserId, now.toIso8601String()],
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return rows
        .map((row) => SyncQueueItem.fromRowMap(Map<String, dynamic>.from(row)))
        .toList(growable: false);
  }

  @override
  Future<List<SyncQueueItem>> getSyncItemsForOwner(
    String ownerUserId, {
    int limit = 100,
  }) async {
    final db = await _database;
    final rows = await db.query(
      'sync_queue',
      where: 'owner_user_id = ?',
      whereArgs: <Object?>[ownerUserId],
      orderBy: 'created_at ASC, id ASC',
      limit: limit,
    );
    return rows
        .map((row) => SyncQueueItem.fromRowMap(Map<String, dynamic>.from(row)))
        .toList(growable: false);
  }

  @override
  Future<void> enqueueSyncItem(SyncQueueItem item) async {
    final db = await _database;
    await db.insert('sync_queue', item.toRowMap());
  }

  @override
  Future<void> markSyncProcessing(String queueId) async {
    final db = await _database;
    await db.update(
      'sync_queue',
      {
        'status': SyncQueueStatus.processing.name,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [queueId],
    );
  }

  @override
  Future<void> markSyncSuccess(
    SyncQueueItem item, {
    int? remoteVersion,
    String? draftStatus,
  }) async {
    final db = await _database;
    await _removeProjectDraftBundle(
      db,
      ownerUserId: item.ownerUserId,
      projectId: item.projectId,
      draftId: item.entityId,
      guardedItem: item,
      successfulRemoteVersion: remoteVersion,
    );
  }

  @override
  Future<void> discardRejectedSyncItem(
    SyncQueueItem item, {
    bool includeSupersedingRevision = false,
  }) async {
    final db = await _database;
    await _removeProjectDraftBundle(
      db,
      ownerUserId: item.ownerUserId,
      projectId: item.projectId,
      draftId: item.entityId,
      guardedItem: includeSupersedingRevision ? null : item,
    );
  }

  @override
  Future<int> discardRejectedSyncItemsForOwner(String ownerUserId) async {
    final db = await _database;
    final discardedCount = await db.transaction((txn) async {
      final queueRows = await txn.query(
        'sync_queue',
        columns: const <String>['id'],
        where: 'owner_user_id = ?',
        whereArgs: <Object?>[ownerUserId],
      );
      final photoRows = await txn.query(
        'draft_photos',
        columns: const <String>['project_id', 'draft_id', 'file_path'],
        where: 'owner_user_id = ?',
        whereArgs: <Object?>[ownerUserId],
      );
      final createdAt = DateTime.now().toIso8601String();
      for (final photoRow in photoRows) {
        final projectId = photoRow['project_id'];
        final draftId = photoRow['draft_id'];
        final filePath = photoRow['file_path'];
        if (projectId is! String ||
            draftId is! String ||
            filePath is! String ||
            filePath.trim().isEmpty) {
          continue;
        }
        await txn.insert(
          'pending_local_file_deletions',
          <String, Object?>{
            'id': _uuid.v4(),
            'owner_user_id': ownerUserId,
            'project_id': projectId,
            'draft_id': draftId,
            'file_path': filePath,
            'attempt_count': 0,
            'created_at': createdAt,
            'last_attempt_at': null,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await txn.delete(
        'sync_queue',
        where: 'owner_user_id = ?',
        whereArgs: <Object?>[ownerUserId],
      );
      await txn.delete(
        'draft_photos',
        where: 'owner_user_id = ?',
        whereArgs: <Object?>[ownerUserId],
      );
      await txn.delete(
        'draft_features',
        where: 'owner_user_id = ?',
        whereArgs: <Object?>[ownerUserId],
      );
      return queueRows.length;
    });
    await _drainPendingPhotoFileDeletions(db, ownerUserId: ownerUserId);
    return discardedCount;
  }

  @override
  Future<void> purgeAccountData(String ownerUserId) async {
    if (ownerUserId.trim().isEmpty) {
      throw ArgumentError.value(ownerUserId, 'ownerUserId');
    }
    await discardRejectedSyncItemsForOwner(ownerUserId);
    final db = await _database;
    await db.transaction((txn) async {
      for (final table in <String>[
        'projects_cache',
        'offline_map_packages',
        'offline_project_packages',
      ]) {
        await txn.delete(
          table,
          where: 'owner_user_id = ?',
          whereArgs: <Object?>[ownerUserId],
        );
      }
    });
  }

  Future<void> _removeProjectDraftBundle(
    Database db, {
    required String ownerUserId,
    required String projectId,
    required String draftId,
    SyncQueueItem? guardedItem,
    int? successfulRemoteVersion,
  }) async {
    await db.transaction((txn) async {
      if (guardedItem != null) {
        final matchingQueueRows = await txn.query(
          'sync_queue',
          columns: const <String>['id'],
          where:
              'id = ? AND owner_user_id = ? AND project_id = ? AND entity_type = ? AND entity_id = ? AND operation = ? AND local_version = ? AND idempotency_key = ?',
          whereArgs: <Object?>[
            guardedItem.id,
            ownerUserId,
            projectId,
            guardedItem.entityType,
            draftId,
            guardedItem.operation.name,
            guardedItem.localVersion,
            guardedItem.idempotencyKey,
          ],
          limit: 1,
        );
        if (matchingQueueRows.isEmpty) {
          if (successfulRemoteVersion != null &&
              await _tryRebaseSuccessfulRevision(
                txn,
                item: guardedItem,
                remoteVersion: successfulRemoteVersion,
              )) {
            return;
          }
          return;
        }
        final matchingDraftRows = await txn.query(
          'draft_features',
          columns: const <String>['local_version', 'remote_version'],
          where: 'owner_user_id = ? AND project_id = ? AND id = ?',
          whereArgs: <Object?>[ownerUserId, projectId, draftId],
          limit: 1,
        );
        if (matchingDraftRows.isNotEmpty &&
            matchingDraftRows.first['local_version'] !=
                guardedItem.localVersion) {
          if (successfulRemoteVersion != null &&
              await _tryRebaseSuccessfulRevision(
                txn,
                item: guardedItem,
                remoteVersion: successfulRemoteVersion,
              )) {
            return;
          }
          return;
        }
      }

      final photoRows = await txn.query(
        'draft_photos',
        columns: const <String>['file_path'],
        where: 'owner_user_id = ? AND project_id = ? AND draft_id = ?',
        whereArgs: <Object?>[ownerUserId, projectId, draftId],
      );
      final createdAt = DateTime.now().toIso8601String();
      for (final photoRow in photoRows) {
        final filePath = (photoRow['file_path'] as String?)?.trim() ?? '';
        if (filePath.isEmpty) {
          continue;
        }
        await txn.insert(
          'pending_local_file_deletions',
          <String, Object?>{
            'id': _uuid.v4(),
            'owner_user_id': ownerUserId,
            'project_id': projectId,
            'draft_id': draftId,
            'file_path': filePath,
            'attempt_count': 0,
            'created_at': createdAt,
            'last_attempt_at': null,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }

      await txn.delete(
        'sync_queue',
        where: guardedItem == null
            ? 'owner_user_id = ? AND project_id = ? AND entity_type = ? AND entity_id = ?'
            : 'id = ? AND owner_user_id = ? AND project_id = ? AND entity_type = ? AND entity_id = ? AND operation = ? AND local_version = ? AND idempotency_key = ?',
        whereArgs: guardedItem == null
            ? <Object?>[ownerUserId, projectId, 'draft_feature', draftId]
            : <Object?>[
                guardedItem.id,
                ownerUserId,
                projectId,
                guardedItem.entityType,
                draftId,
                guardedItem.operation.name,
                guardedItem.localVersion,
                guardedItem.idempotencyKey,
              ],
      );
      await txn.delete(
        'draft_photos',
        where: 'owner_user_id = ? AND project_id = ? AND draft_id = ?',
        whereArgs: <Object?>[ownerUserId, projectId, draftId],
      );
      await txn.delete(
        'draft_features',
        where: 'owner_user_id = ? AND project_id = ? AND id = ?',
        whereArgs: <Object?>[ownerUserId, projectId, draftId],
      );
    });
    await _drainPendingPhotoFileDeletions(
      db,
      ownerUserId: ownerUserId,
      projectId: projectId,
      draftId: draftId,
    );
  }

  Future<bool> _tryRebaseSuccessfulRevision(
    DatabaseExecutor txn, {
    required SyncQueueItem item,
    required int remoteVersion,
  }) async {
    if (item.operation != SyncOperationType.create &&
        item.operation != SyncOperationType.update) {
      return false;
    }

    final draftRows = await txn.query(
      'draft_features',
      columns: const <String>['local_version', 'remote_version'],
      where: 'owner_user_id = ? AND project_id = ? AND id = ?',
      whereArgs: <Object?>[item.ownerUserId, item.projectId, item.entityId],
      limit: 1,
    );
    if (draftRows.isEmpty) {
      return false;
    }
    final currentLocalVersion = draftRows.first['local_version'] as int?;
    if (currentLocalVersion == null ||
        currentLocalVersion <= item.localVersion) {
      return false;
    }
    final currentRemoteVersion = draftRows.first['remote_version'] as int?;
    final expectedRemoteVersion = item.payload['remote_version'];
    if ((item.operation == SyncOperationType.create &&
            currentRemoteVersion != null) ||
        (item.operation == SyncOperationType.update &&
            (expectedRemoteVersion is! int ||
                currentRemoteVersion != expectedRemoteVersion))) {
      return false;
    }

    final queueRows = await txn.query(
      'sync_queue',
      where:
          'owner_user_id = ? AND project_id = ? AND entity_type = ? AND entity_id = ? AND operation = ? AND local_version = ?',
      whereArgs: <Object?>[
        item.ownerUserId,
        item.projectId,
        item.entityType,
        item.entityId,
        item.operation.name,
        currentLocalVersion,
      ],
      limit: 2,
    );
    if (queueRows.length != 1) {
      return false;
    }
    final replacement = SyncQueueItem.fromRowMap(
      Map<String, dynamic>.from(queueRows.single),
    );
    if (replacement.payload['draft_id'] != item.entityId ||
        replacement.payload['owner_user_id'] != item.ownerUserId ||
        replacement.payload['project_id'] != item.projectId ||
        replacement.payload['local_version'] != currentLocalVersion) {
      return false;
    }

    final acknowledgedPaths = <String>{};
    for (final key in const <String>['synced_photo_paths', 'photo_paths']) {
      final rawPaths = item.payload[key];
      if (rawPaths is List) {
        acknowledgedPaths.addAll(rawPaths.whereType<String>());
      }
    }
    final photoRows = await txn.query(
      'draft_photos',
      columns: const <String>['file_path'],
      where: 'owner_user_id = ? AND project_id = ? AND draft_id = ?',
      whereArgs: <Object?>[item.ownerUserId, item.projectId, item.entityId],
      orderBy: 'id ASC',
    );
    final currentPhotoPaths = photoRows
        .map((row) => row['file_path'] as String?)
        .whereType<String>()
        .toList(growable: false);
    final removedSynchronizedPhoto = !currentPhotoPaths.toSet().containsAll(
      acknowledgedPaths,
    );
    final pendingPhotoPaths = currentPhotoPaths
        .where((path) => !acknowledgedPaths.contains(path))
        .toList(growable: false);
    final rebasedPayload = Map<String, dynamic>.from(replacement.payload)
      ..['photo_paths'] = pendingPhotoPaths
      ..['synced_photo_paths'] = acknowledgedPaths.toList(growable: false)
      ..['remote_version'] = remoteVersion;
    if (removedSynchronizedPhoto) {
      rebasedPayload['status'] = 'rejected';
    }
    final now = DateTime.now().toIso8601String();

    final updatedDrafts = await txn.update(
      'draft_features',
      <String, Object?>{
        'remote_version': remoteVersion,
        if (removedSynchronizedPhoto) 'status': 'rejected',
      },
      where: item.operation == SyncOperationType.create
          ? 'owner_user_id = ? AND project_id = ? AND id = ? AND local_version = ? AND remote_version IS NULL'
          : 'owner_user_id = ? AND project_id = ? AND id = ? AND local_version = ? AND remote_version = ?',
      whereArgs: <Object?>[
        item.ownerUserId,
        item.projectId,
        item.entityId,
        currentLocalVersion,
        if (item.operation == SyncOperationType.update) expectedRemoteVersion,
      ],
    );
    final updatedQueue = await txn.update(
      'sync_queue',
      <String, Object?>{
        'operation': SyncOperationType.update.name,
        'payload_json': jsonEncode(rebasedPayload),
        'attempt_count': 0,
        'status': removedSynchronizedPhoto
            ? SyncQueueStatus.conflict.name
            : SyncQueueStatus.pending.name,
        'next_retry_at': removedSynchronizedPhoto ? null : now,
        'last_error': removedSynchronizedPhoto
            ? 'A photo accepted by the server was removed by a newer offline edit. Review this draft online.'
            : null,
        'updated_at': now,
      },
      where:
          'id = ? AND owner_user_id = ? AND project_id = ? AND entity_type = ? AND entity_id = ? AND operation = ? AND local_version = ? AND idempotency_key = ?',
      whereArgs: <Object?>[
        replacement.id,
        replacement.ownerUserId,
        replacement.projectId,
        replacement.entityType,
        replacement.entityId,
        item.operation.name,
        replacement.localVersion,
        replacement.idempotencyKey,
      ],
    );
    if (updatedDrafts != 1 || updatedQueue != 1) {
      throw StateError('Could not atomically rebase a synchronized draft.');
    }
    return true;
  }

  Future<void> _scheduleTemporaryPhotoDeletion(
    String rawPath, {
    DatabaseExecutor? database,
  }) async {
    final root = await _temporaryPhotoRootContaining(rawPath);
    if (root == null ||
        !await _isSafeTemporaryPhotoFile(rawPath, root, allowMissing: false)) {
      return;
    }
    final db = database ?? await _database;
    await db.insert(
      'pending_temporary_photo_deletions',
      <String, Object?>{
        'id': _uuid.v4(),
        'file_path': p.normalize(p.absolute(rawPath)),
        'attempt_count': 0,
        'created_at': DateTime.now().toIso8601String(),
        'last_attempt_at': null,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> _drainPendingTemporaryPhotoDeletions(DatabaseExecutor db) async {
    final rows = await db.query(
      'pending_temporary_photo_deletions',
      orderBy: 'created_at, id',
    );
    for (final row in rows) {
      final id = row['id'];
      final filePath = row['file_path'];
      final attemptCount = row['attempt_count'];
      if (id is! String || filePath is! String || attemptCount is! int) {
        continue;
      }
      var deleted = false;
      try {
        final root = await _temporaryPhotoRootContaining(filePath);
        if (root != null &&
            await _isSafeTemporaryPhotoFile(
              filePath,
              root,
              allowMissing: true,
            )) {
          final type = await FileSystemEntity.type(
            filePath,
            followLinks: false,
          );
          if (type == FileSystemEntityType.notFound) {
            deleted = true;
          } else {
            await File(filePath).delete();
            deleted =
                await FileSystemEntity.type(filePath, followLinks: false) ==
                FileSystemEntityType.notFound;
          }
        }
      } catch (_) {
        deleted = false;
      }

      if (deleted) {
        await db.delete(
          'pending_temporary_photo_deletions',
          where: 'id = ? AND file_path = ?',
          whereArgs: <Object?>[id, filePath],
        );
      } else {
        await db.update(
          'pending_temporary_photo_deletions',
          <String, Object?>{
            'attempt_count': attemptCount + 1,
            'last_attempt_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ? AND file_path = ?',
          whereArgs: <Object?>[id, filePath],
        );
      }
    }
  }

  Future<String?> _temporaryPhotoRootContaining(String rawPath) async {
    final roots = <String>{};
    try {
      roots.add((await getTemporaryDirectory()).path);
    } catch (_) {
      // Unsupported platform directory.
    }
    try {
      roots.add((await getApplicationCacheDirectory()).path);
    } catch (_) {
      // Unsupported platform directory.
    }
    for (final root in roots) {
      if (isPathWithinDirectory(rawPath, root)) {
        return root;
      }
    }
    return null;
  }

  Future<bool> _isSafeTemporaryPhotoFile(
    String rawPath,
    String rawRoot, {
    required bool allowMissing,
  }) async {
    if (!isPathWithinDirectory(rawPath, rawRoot)) {
      return false;
    }
    final root = p.normalize(p.absolute(rawRoot));
    final rootType = await FileSystemEntity.type(root, followLinks: false);
    if (rootType != FileSystemEntityType.directory) {
      return false;
    }
    final relative = p.relative(p.normalize(p.absolute(rawPath)), from: root);
    final segments = p.split(relative);
    var current = root;
    for (var index = 0; index < segments.length; index += 1) {
      final segment = segments[index];
      if (segment.isEmpty || segment == '.' || segment == '..') {
        return false;
      }
      current = p.join(current, segment);
      final type = await FileSystemEntity.type(current, followLinks: false);
      final isLast = index == segments.length - 1;
      if (isLast) {
        return type == FileSystemEntityType.file ||
            (allowMissing && type == FileSystemEntityType.notFound);
      }
      if (type != FileSystemEntityType.directory) {
        return false;
      }
    }
    return false;
  }

  Future<void> _drainPendingPhotoFileDeletions(
    DatabaseExecutor db, {
    String? ownerUserId,
    String? projectId,
    String? draftId,
  }) async {
    final hasExactScope =
        ownerUserId != null && projectId != null && draftId != null;
    final hasOwnerScope =
        ownerUserId != null && projectId == null && draftId == null;
    List<Map<String, Object?>> rows;
    try {
      rows = await db.query(
        'pending_local_file_deletions',
        where: hasExactScope
            ? 'owner_user_id = ? AND project_id = ? AND draft_id = ?'
            : hasOwnerScope
            ? 'owner_user_id = ?'
            : null,
        whereArgs: hasExactScope
            ? <Object?>[ownerUserId, projectId, draftId]
            : hasOwnerScope
            ? <Object?>[ownerUserId]
            : null,
        orderBy: 'created_at ASC',
      );
    } catch (_) {
      return;
    }

    final deletions = <PendingLocalPhotoDeletion>[];
    for (final row in rows) {
      final id = row['id'];
      final rowOwnerUserId = row['owner_user_id'];
      final rowProjectId = row['project_id'];
      final rowDraftId = row['draft_id'];
      final filePath = row['file_path'];
      final attemptCount = row['attempt_count'];
      if (id is! String ||
          rowOwnerUserId is! String ||
          rowProjectId is! String ||
          rowDraftId is! String ||
          filePath is! String ||
          attemptCount is! int) {
        continue;
      }
      deletions.add(
        PendingLocalPhotoDeletion(
          id: id,
          ownerUserId: rowOwnerUserId,
          projectId: rowProjectId,
          draftId: rowDraftId,
          filePath: filePath,
          attemptCount: attemptCount,
        ),
      );
    }

    await processPendingLocalPhotoDeletions(
      deletions,
      decide: (deletion) async {
        final root = _offlinePhotoRootPath;
        if (root == null) {
          return LocalPhotoDeletionDecision.acknowledgeWithoutDelete;
        }
        final expectedDirectory = offlineDraftPhotoDirectoryPath(
          rootDirectory: root,
          ownerUserId: deletion.ownerUserId,
          projectId: deletion.projectId,
          draftId: deletion.draftId,
        );
        if (!isPathWithinDirectory(deletion.filePath, expectedDirectory)) {
          return LocalPhotoDeletionDecision.acknowledgeWithoutDelete;
        }
        final liveRows = await db.query(
          'draft_photos',
          columns: const <String>['file_path'],
        );
        final isStillReferenced = liveRows.any((row) {
          final livePath = row['file_path'];
          return livePath is String &&
              localPhotoPathsEqual(livePath, deletion.filePath);
        });
        return isStillReferenced
            ? LocalPhotoDeletionDecision.defer
            : LocalPhotoDeletionDecision.delete;
      },
      deleteFile: (filePath) {
        final root = _offlinePhotoRootPath;
        return root == null
            ? Future<bool>.value(false)
            : tryDeleteLocalPhotoFileWithinDirectory(filePath, root);
      },
      acknowledge: (deletion) async {
        await db.delete(
          'pending_local_file_deletions',
          where:
              'id = ? AND owner_user_id = ? AND project_id = ? AND draft_id = ?',
          whereArgs: <Object?>[
            deletion.id,
            deletion.ownerUserId,
            deletion.projectId,
            deletion.draftId,
          ],
        );
      },
      recordFailure: (deletion) async {
        await db.update(
          'pending_local_file_deletions',
          <String, Object?>{
            'attempt_count': deletion.attemptCount + 1,
            'last_attempt_at': DateTime.now().toIso8601String(),
          },
          where:
              'id = ? AND owner_user_id = ? AND project_id = ? AND draft_id = ?',
          whereArgs: <Object?>[
            deletion.id,
            deletion.ownerUserId,
            deletion.projectId,
            deletion.draftId,
          ],
        );
      },
    );
  }

  @override
  Future<void> markSyncFailure(
    SyncQueueItem item, {
    required String error,
    required DateTime nextRetryAt,
  }) async {
    final db = await _database;
    await db.update(
      'sync_queue',
      {
        'status': SyncQueueStatus.failed.name,
        'attempt_count': item.attemptCount + 1,
        'next_retry_at': nextRetryAt.toIso8601String(),
        'last_error': error,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where:
          'id = ? AND owner_user_id = ? AND project_id = ? AND entity_type = ? AND entity_id = ? AND operation = ? AND local_version = ? AND idempotency_key = ?',
      whereArgs: <Object?>[
        item.id,
        item.ownerUserId,
        item.projectId,
        item.entityType,
        item.entityId,
        item.operation.name,
        item.localVersion,
        item.idempotencyKey,
      ],
    );
  }

  @override
  Future<void> markSyncConflict(
    SyncQueueItem item, {
    required String error,
    int? remoteVersion,
  }) async {
    final db = await _database;
    await db.transaction((txn) async {
      final updatedQueue = await txn.update(
        'sync_queue',
        {
          'status': SyncQueueStatus.conflict.name,
          'attempt_count': item.attemptCount + 1,
          'next_retry_at': null,
          'last_error': error,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where:
            'id = ? AND owner_user_id = ? AND project_id = ? AND entity_type = ? AND entity_id = ? AND operation = ? AND local_version = ? AND idempotency_key = ?',
        whereArgs: <Object?>[
          item.id,
          item.ownerUserId,
          item.projectId,
          item.entityType,
          item.entityId,
          item.operation.name,
          item.localVersion,
          item.idempotencyKey,
        ],
      );
      if (updatedQueue != 1) {
        return;
      }
      await txn.update(
        'draft_features',
        <String, Object?>{
          'status': 'rejected',
          'remote_version': ?remoteVersion,
        },
        where:
            'owner_user_id = ? AND project_id = ? AND id = ? AND local_version = ?',
        whereArgs: <Object?>[
          item.ownerUserId,
          item.projectId,
          item.entityId,
          item.localVersion,
        ],
      );
    });
  }

  @override
  Future<void> markSyncDeadLetter(
    SyncQueueItem item, {
    required String error,
  }) async {
    final db = await _database;
    await db.update(
      'sync_queue',
      {
        'status': SyncQueueStatus.deadLetter.name,
        'attempt_count': item.attemptCount + 1,
        'next_retry_at': null,
        'last_error': error,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where:
          'id = ? AND owner_user_id = ? AND project_id = ? AND entity_type = ? AND entity_id = ? AND operation = ? AND local_version = ? AND idempotency_key = ?',
      whereArgs: <Object?>[
        item.id,
        item.ownerUserId,
        item.projectId,
        item.entityType,
        item.entityId,
        item.operation.name,
        item.localVersion,
        item.idempotencyKey,
      ],
    );
  }
}

LocalStore createPlatformLocalStore({
  required LocalDatabaseKeyManager databaseKeyManager,
  required LocalPhotoKeyManager photoKeyManager,
}) => SqliteLocalStore(
  databaseKeyManager: databaseKeyManager,
  photoKeyManager: photoKeyManager,
);
