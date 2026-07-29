import 'dart:convert';
import 'dart:io';

import 'package:lebanese_gis_mobile/core/offline/local_photo_cleanup.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

const historicalFixtureOwnerId = '10000000-0000-4000-8000-000000000001';
const historicalFixtureProjectId = '20000000-0000-4000-8000-000000000002';
const historicalFixtureDraftId = '30000000-0000-4000-8000-000000000003';
const historicalFixturePhotoId = '40000000-0000-4000-8000-000000000004';
const historicalFixtureQueueId = '50000000-0000-4000-8000-000000000005';
const historicalFixtureTimestamp = '2026-04-01T12:00:00.000Z';

final class HistoricalLocalDatabaseFixture {
  const HistoricalLocalDatabaseFixture({
    required this.version,
    required this.plaintextPhotoPath,
    required this.expectedOwnerUserId,
  });

  final int version;
  final String plaintextPhotoPath;
  final String expectedOwnerUserId;
}

/// Creates an independent snapshot of the actual schema first shipped at each
/// local database version. These statements intentionally do not import or
/// reuse the current production schema builders, so the device migration test
/// detects accidental incompatibility with a historical release.
Future<HistoricalLocalDatabaseFixture> createHistoricalLocalDatabaseFixture({
  required Database database,
  required int version,
  required String offlinePhotoRoot,
  required String legacyUnownedOwnerId,
  String? legacyPhotoRoot,
}) async {
  if (version < 1 || version > 8) {
    throw ArgumentError.value(version, 'version', 'must be from 1 through 8');
  }
  if (version <= 5) {
    await _createPreScopedSchema(database, version);
  } else {
    await _createScopedSchema(database, version);
  }

  final expectedOwnerUserId = version <= 2
      ? legacyUnownedOwnerId
      : historicalFixtureOwnerId;
  final photoDirectory = version >= 8
      ? Directory(
          offlineDraftPhotoDirectoryPath(
            rootDirectory: offlinePhotoRoot,
            ownerUserId: expectedOwnerUserId,
            projectId: historicalFixtureProjectId,
            draftId: historicalFixtureDraftId,
          ),
        )
      : Directory(legacyPhotoRoot ?? offlinePhotoRoot);
  await photoDirectory.create(recursive: true);
  final photo = File(
    '${photoDirectory.path}${Platform.pathSeparator}'
    'historical-v$version.jpg',
  );
  await photo.writeAsBytes(<int>[
    0xff,
    0xd8,
    0xff,
    ...List<int>.generate(1024, (index) => (index + version) % 251),
    0xff,
    0xd9,
  ], flush: true);

  final projectRow = <String, Object?>{
    if (version >= 6) 'owner_user_id': historicalFixtureOwnerId,
    'id': historicalFixtureProjectId,
    'payload_json': jsonEncode(<String, Object?>{
      'id': historicalFixtureProjectId,
      'name': 'Historical project v$version',
    }),
    'updated_at': historicalFixtureTimestamp,
  };
  await database.insert('projects_cache', projectRow);

  final draftRow = <String, Object?>{
    'id': historicalFixtureDraftId,
    if (version >= 3) 'owner_user_id': historicalFixtureOwnerId,
    'project_id': historicalFixtureProjectId,
    'project_name': 'Historical project v$version',
    'geometry_type': 'Point',
    if (version >= 2)
      'geometry_json': '{"type":"Point","coordinates":[35.5,33.8]}',
    'attributes_json': '{"fixture_version":$version}',
    'status': 'draft',
    'local_version': version,
    'remote_version': null,
    'collected_offline': 1,
    'updated_at': historicalFixtureTimestamp,
  };
  await database.insert('draft_features', draftRow);
  await database.insert('draft_photos', <String, Object?>{
    'id': historicalFixturePhotoId,
    if (version >= 6) 'owner_user_id': historicalFixtureOwnerId,
    if (version >= 6) 'project_id': historicalFixtureProjectId,
    'draft_id': historicalFixtureDraftId,
    'file_path': photo.path,
    'created_at': historicalFixtureTimestamp,
  });

  final payload = <String, Object?>{
    'draft_id': historicalFixtureDraftId,
    'project_id': historicalFixtureProjectId,
    if (version >= 3) 'owner_user_id': historicalFixtureOwnerId,
    'geometry_type': 'Point',
    'attributes': <String, Object?>{'fixture_version': version},
    'photo_paths': <String>[photo.path],
    'status': 'draft',
    'local_version': version,
  };
  await database.insert('sync_queue', <String, Object?>{
    'id': historicalFixtureQueueId,
    if (version >= 6) 'owner_user_id': historicalFixtureOwnerId,
    if (version >= 6) 'project_id': historicalFixtureProjectId,
    'entity_type': 'draft_feature',
    'entity_id': historicalFixtureDraftId,
    'operation': 'create',
    'payload_json': jsonEncode(payload),
    'local_version': version,
    'idempotency_key': 'historical-idempotency-v$version',
    'attempt_count': 0,
    'status': 'pending',
    'next_retry_at': historicalFixtureTimestamp,
    'last_error': null,
    'created_at': historicalFixtureTimestamp,
    'updated_at': historicalFixtureTimestamp,
  });

  if (version >= 2) {
    await database.insert('offline_map_packages', <String, Object?>{
      if (version >= 4) 'owner_user_id': historicalFixtureOwnerId,
      'version': 'base-map-v$version',
      'zoom_level_min': 6,
      'zoom_level_max': 12,
      'downloaded_at': historicalFixtureTimestamp,
      'last_updated_at': historicalFixtureTimestamp,
      'tile_count': 2,
      'size_bytes': 128,
      'tile_source': 'fixture',
      'is_current': 1,
    });
  }
  if (version >= 5) {
    await database.insert('offline_project_packages', <String, Object?>{
      'owner_user_id': historicalFixtureOwnerId,
      'project_id': historicalFixtureProjectId,
      'payload_json': '{"fixture":true}',
      'package_version': 'fixture-v$version',
      'app_resources_version': 'fixture-resources',
      'base_map_version': 'base-map-v$version',
      'downloaded_at': historicalFixtureTimestamp,
      'refreshed_at': historicalFixtureTimestamp,
    });
  }

  return HistoricalLocalDatabaseFixture(
    version: version,
    plaintextPhotoPath: photo.path,
    expectedOwnerUserId: expectedOwnerUserId,
  );
}

Future<void> _createPreScopedSchema(Database database, int version) async {
  await database.execute('''
    CREATE TABLE projects_cache (
      id TEXT PRIMARY KEY,
      payload_json TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');
  await database.execute('''
    CREATE TABLE draft_features (
      id TEXT PRIMARY KEY,
      ${version >= 3 ? 'owner_user_id TEXT NOT NULL,' : ''}
      project_id TEXT NOT NULL,
      project_name TEXT NOT NULL,
      geometry_type TEXT NOT NULL,
      ${version >= 2 ? 'geometry_json TEXT NOT NULL,' : ''}
      attributes_json TEXT NOT NULL,
      status TEXT NOT NULL,
      local_version INTEGER NOT NULL,
      remote_version INTEGER,
      collected_offline INTEGER NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');
  await database.execute('''
    CREATE TABLE draft_photos (
      id TEXT PRIMARY KEY,
      draft_id TEXT NOT NULL,
      file_path TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
  ''');
  await database.execute('''
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
    )
  ''');
  await database.execute(
    'CREATE INDEX idx_sync_queue_due '
    'ON sync_queue(status, next_retry_at)',
  );
  if (version >= 2) {
    await database.execute('''
      CREATE TABLE offline_map_packages (
        ${version >= 4 ? 'owner_user_id TEXT NOT NULL,' : ''}
        version TEXT NOT NULL,
        zoom_level_min INTEGER NOT NULL,
        zoom_level_max INTEGER NOT NULL,
        downloaded_at TEXT,
        last_updated_at TEXT NOT NULL,
        tile_count INTEGER,
        size_bytes INTEGER,
        tile_source TEXT,
        is_current INTEGER NOT NULL,
        PRIMARY KEY (${version >= 4 ? 'owner_user_id, version' : 'version'})
      )
    ''');
  }
  if (version >= 4) {
    await database.execute(
      'CREATE INDEX idx_offline_map_packages_current_owner '
      'ON offline_map_packages(owner_user_id, is_current)',
    );
  }
  if (version >= 5) {
    await database.execute('''
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
      )
    ''');
    await database.execute(
      'CREATE INDEX idx_offline_project_packages_owner '
      'ON offline_project_packages(owner_user_id)',
    );
    await database.execute(
      'CREATE INDEX idx_offline_project_packages_base_map '
      'ON offline_project_packages(owner_user_id, base_map_version)',
    );
  }
}

Future<void> _createScopedSchema(Database database, int version) async {
  await database.execute('''
    CREATE TABLE projects_cache (
      owner_user_id TEXT NOT NULL,
      id TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (owner_user_id, id)
    )
  ''');
  await database.execute('''
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
    )
  ''');
  await database.execute('''
    CREATE TABLE draft_photos (
      id TEXT NOT NULL,
      owner_user_id TEXT NOT NULL,
      project_id TEXT NOT NULL,
      draft_id TEXT NOT NULL,
      file_path TEXT NOT NULL,
      created_at TEXT NOT NULL,
      PRIMARY KEY (owner_user_id, project_id, draft_id, id)
    )
  ''');
  await database.execute('''
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
    )
  ''');
  await database.execute('''
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
    )
  ''');
  await database.execute('''
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
    )
  ''');
  await database.execute(
    'CREATE INDEX idx_projects_cache_owner '
    'ON projects_cache(owner_user_id, updated_at)',
  );
  await database.execute(
    'CREATE INDEX idx_draft_features_owner_project '
    'ON draft_features(owner_user_id, project_id, updated_at)',
  );
  await database.execute(
    'CREATE INDEX idx_sync_queue_due '
    'ON sync_queue(owner_user_id, status, next_retry_at)',
  );
  await database.execute(
    'CREATE INDEX idx_sync_queue_entity '
    'ON sync_queue(owner_user_id, project_id, entity_type, entity_id)',
  );
  await database.execute(
    'CREATE INDEX idx_offline_map_packages_current_owner '
    'ON offline_map_packages(owner_user_id, is_current)',
  );
  await database.execute(
    'CREATE INDEX idx_offline_project_packages_owner '
    'ON offline_project_packages(owner_user_id)',
  );
  await database.execute(
    'CREATE INDEX idx_offline_project_packages_base_map '
    'ON offline_project_packages(owner_user_id, base_map_version)',
  );
  if (version >= 7) {
    await database.execute('''
      CREATE TABLE pending_local_file_deletions (
        id TEXT PRIMARY KEY,
        owner_user_id TEXT NOT NULL,
        project_id TEXT NOT NULL,
        draft_id TEXT NOT NULL,
        file_path TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        last_attempt_at TEXT,
        UNIQUE (owner_user_id, project_id, draft_id, file_path)
      )
    ''');
    await database.execute(
      'CREATE INDEX idx_pending_local_file_deletions_scope '
      'ON pending_local_file_deletions('
      'owner_user_id, project_id, draft_id)',
    );
  }
}
