import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../features/projects/domain/project.dart';
import 'local_models.dart';
import 'local_store.dart';

class SqliteLocalStore implements LocalStore {
  Database? _db;
  final Uuid _uuid = const Uuid();
  static const _dbVersion = 4;

  @override
  Future<void> initialize() async {
    if (_db != null) {
      return;
    }

    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, 'gis_collector_offline.db');

    _db = await openDatabase(
      dbPath,
      version: _dbVersion,
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
      },
    );
  }

  Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE projects_cache (
        id TEXT PRIMARY KEY,
        payload_json TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE draft_features (
        id TEXT PRIMARY KEY,
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
        updated_at TEXT NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE draft_photos (
        id TEXT PRIMARY KEY,
        draft_id TEXT NOT NULL,
        file_path TEXT NOT NULL,
        created_at TEXT NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE sync_queue (
        id TEXT PRIMARY KEY,
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

    await db.execute(
      'CREATE INDEX idx_sync_queue_due ON sync_queue(status, next_retry_at);',
    );
    await db.execute(
      'CREATE INDEX idx_offline_map_packages_current_owner ON offline_map_packages(owner_user_id, is_current);',
    );
  }

  Future<Database> get _database async {
    final db = _db;
    if (db == null) {
      throw StateError('LocalStore not initialized.');
    }
    return db;
  }

  @override
  Future<void> dispose() async {
    await _db?.close();
    _db = null;
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
    final db = await _database;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      final batch = txn.batch();
      batch.delete('projects_cache');
      for (final project in projects) {
        batch.insert('projects_cache', {
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
  Future<void> upsertDraft(
    LocalDraftFeature draft, {
    bool enqueueSync = true,
  }) async {
    final db = await _database;

    await db.transaction((txn) async {
      await txn.insert(
        'draft_features',
        draft.toRowMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await txn.delete(
        'draft_photos',
        where: 'draft_id = ?',
        whereArgs: [draft.id],
      );

      for (final photo in draft.photos) {
        await txn.insert('draft_photos', {
          'id': photo.id,
          'draft_id': draft.id,
          'file_path': photo.filePath,
          'created_at': photo.createdAt.toIso8601String(),
        });
      }

      if (enqueueSync) {
        final now = DateTime.now();

        await txn.delete(
          'sync_queue',
          where: 'entity_type = ? AND entity_id = ?',
          whereArgs: ['draft_feature', draft.id],
        );

        final queueItem = SyncQueueItem(
          id: _uuid.v4(),
          entityType: 'draft_feature',
          entityId: draft.id,
          operation: draft.remoteVersion == null
              ? SyncOperationType.create
              : SyncOperationType.update,
          payload: {
            'draft_id': draft.id,
            'project_id': draft.projectId,
            'geometry_type': draft.geometryType,
            'geometry': jsonDecode(draft.geometryJson) as Map<String, dynamic>,
            'attributes':
                jsonDecode(draft.attributesJson) as Map<String, dynamic>,
            'photo_paths': draft.remoteVersion == null
                ? draft.photos.map((p) => p.filePath).toList(growable: false)
                : const <String>[],
            'status': draft.status,
            'local_version': draft.localVersion,
          },
          localVersion: draft.localVersion,
          idempotencyKey: _uuid.v4(),
          attemptCount: 0,
          status: SyncQueueStatus.pending,
          nextRetryAt: now,
          createdAt: now,
          updatedAt: now,
        );

        await txn.insert('sync_queue', queueItem.toRowMap());
      }
    });
  }

  @override
  Future<List<LocalDraftFeature>> getDrafts() async {
    final db = await _database;
    final rows = await db.query('draft_features', orderBy: 'updated_at DESC');

    final drafts = <LocalDraftFeature>[];
    for (final row in rows) {
      final photosRows = await db.query(
        'draft_photos',
        where: 'draft_id = ?',
        whereArgs: [row['id']],
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
  Future<int> getPendingSyncCount() async {
    return (await getSyncQueueStats()).actionable;
  }

  @override
  Future<SyncQueueStats> getSyncQueueStats() async {
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT status, COUNT(*) AS count FROM sync_queue GROUP BY status',
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
    await db.transaction((txn) async {
      await txn.delete('sync_queue', where: 'id = ?', whereArgs: [item.id]);
      final values = <String, Object?>{
        'updated_at': DateTime.now().toIso8601String(),
      };
      if (draftStatus != null) {
        values['status'] = draftStatus;
      }
      if (remoteVersion != null) {
        values['remote_version'] = remoteVersion;
      }

      await txn.update(
        'draft_features',
        values,
        where: 'id = ?',
        whereArgs: [item.entityId],
      );
    });
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
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  @override
  Future<void> markSyncConflict(
    SyncQueueItem item, {
    required String error,
  }) async {
    final db = await _database;
    await db.update(
      'sync_queue',
      {
        'status': SyncQueueStatus.conflict.name,
        'attempt_count': item.attemptCount + 1,
        'next_retry_at': null,
        'last_error': error,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [item.id],
    );
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
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }
}

LocalStore createPlatformLocalStore() => SqliteLocalStore();
