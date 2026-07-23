import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

const Uuid _offlinePhotoScopeUuid = Uuid();

/// Produces a deterministic, filesystem-safe opaque segment for one local
/// owner/project/draft identity. Hashing the complete value as a UUID v5 keeps
/// dot segments and path separators from ever becoming directory syntax.
String safeOfflinePhotoScopeSegment(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError('Offline photo scope cannot be empty.');
  }
  return _offlinePhotoScopeUuid.v5(
    Namespace.url.value,
    'lebanese-gis-offline-photo-scope:$normalized',
  );
}

String offlineDraftPhotoDirectoryPath({
  required String rootDirectory,
  required String ownerUserId,
  required String projectId,
  required String draftId,
}) {
  final root = rootDirectory.trim();
  if (root.isEmpty) {
    throw ArgumentError('Offline photo root cannot be empty.');
  }
  return p.join(
    root,
    safeOfflinePhotoScopeSegment(ownerUserId),
    safeOfflinePhotoScopeSegment(projectId),
    safeOfflinePhotoScopeSegment(draftId),
  );
}

bool areOfflineDraftPhotoPathsScoped({
  required String rootDirectory,
  required String ownerUserId,
  required String projectId,
  required String draftId,
  required Iterable<String> filePaths,
}) {
  final root = rootDirectory.trim();
  if (root.isEmpty) {
    return false;
  }
  String draftDirectory;
  try {
    draftDirectory = offlineDraftPhotoDirectoryPath(
      rootDirectory: root,
      ownerUserId: ownerUserId,
      projectId: projectId,
      draftId: draftId,
    );
  } catch (_) {
    return false;
  }
  if (!isPathWithinDirectory(draftDirectory, root)) {
    return false;
  }
  for (final filePath in filePaths) {
    if (filePath.trim().isEmpty ||
        !isPathWithinDirectory(filePath, draftDirectory)) {
      return false;
    }
  }
  return true;
}

const String pendingLocalFileDeletionsTableSql = '''
  CREATE TABLE IF NOT EXISTS pending_local_file_deletions (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    project_id TEXT NOT NULL,
    draft_id TEXT NOT NULL,
    file_path TEXT NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    last_attempt_at TEXT,
    UNIQUE (owner_user_id, project_id, draft_id, file_path)
  );
''';

const String pendingLocalFileDeletionsIndexSql =
    'CREATE INDEX IF NOT EXISTS idx_pending_local_file_deletions_scope ON pending_local_file_deletions(owner_user_id, project_id, draft_id);';

typedef LocalPhotoCleanupSqlExecutor = Future<void> Function(String sql);

Future<void> createPendingLocalPhotoDeletionSchema(
  LocalPhotoCleanupSqlExecutor execute,
) async {
  await execute(pendingLocalFileDeletionsTableSql);
  await execute(pendingLocalFileDeletionsIndexSql);
}

class PendingLocalPhotoDeletion {
  const PendingLocalPhotoDeletion({
    required this.id,
    required this.ownerUserId,
    required this.projectId,
    required this.draftId,
    required this.filePath,
    required this.attemptCount,
  });

  final String id;
  final String ownerUserId;
  final String projectId;
  final String draftId;
  final String filePath;
  final int attemptCount;
}

typedef LocalPhotoDeleteAttempt = Future<bool> Function(String filePath);
typedef LocalPhotoDeletionUpdate =
    Future<void> Function(PendingLocalPhotoDeletion deletion);
typedef LocalPhotoDeletionDecisionReader =
    Future<LocalPhotoDeletionDecision> Function(
      PendingLocalPhotoDeletion deletion,
    );

enum LocalPhotoDeletionDecision { delete, defer, acknowledgeWithoutDelete }

/// Tries each durable cleanup task once.
///
/// A task is acknowledged only after the file is gone. Failed deletions and
/// failed acknowledgements remain durable so a later application start can
/// safely repeat the cleanup. Neither failures nor paths are logged here.
Future<void> processPendingLocalPhotoDeletions(
  Iterable<PendingLocalPhotoDeletion> deletions, {
  LocalPhotoDeleteAttempt deleteFile = tryDeleteLocalPhotoFile,
  LocalPhotoDeletionDecisionReader? decide,
  required LocalPhotoDeletionUpdate acknowledge,
  required LocalPhotoDeletionUpdate recordFailure,
}) async {
  for (final deletion in deletions) {
    var decision = LocalPhotoDeletionDecision.delete;
    if (decide != null) {
      try {
        decision = await decide(deletion);
      } catch (_) {
        decision = LocalPhotoDeletionDecision.defer;
      }
    }
    if (decision == LocalPhotoDeletionDecision.acknowledgeWithoutDelete) {
      try {
        await acknowledge(deletion);
      } catch (_) {
        // The durable row remains and acknowledgement can be retried.
      }
      continue;
    }
    if (decision == LocalPhotoDeletionDecision.defer) {
      try {
        await recordFailure(deletion);
      } catch (_) {
        // The durable row remains and the shared reference is checked again.
      }
      continue;
    }
    var deleted = false;
    try {
      deleted = await deleteFile(deletion.filePath);
    } catch (_) {
      deleted = false;
    }

    try {
      if (deleted) {
        await acknowledge(deletion);
      } else {
        await recordFailure(deletion);
      }
    } catch (_) {
      // The durable row remains. If the file was already deleted, the next
      // pass treats the missing file as success and repeats acknowledgement.
    }
  }
}

String canonicalLocalPhotoPath(String rawPath) {
  final normalized = p.normalize(p.absolute(rawPath.trim()));
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

bool localPhotoPathsEqual(String left, String right) =>
    canonicalLocalPhotoPath(left) == canonicalLocalPhotoPath(right);

bool isPathWithinDirectory(String rawPath, String rawDirectory) {
  final path = canonicalLocalPhotoPath(rawPath);
  final directory = canonicalLocalPhotoPath(rawDirectory);
  if (path == directory) {
    return false;
  }
  return path.startsWith('$directory${p.separator}');
}

Future<bool> tryDeleteLocalPhotoFileWithinDirectory(
  String rawPath,
  String rawDirectory,
) async {
  if (!isPathWithinDirectory(rawPath, rawDirectory)) {
    return false;
  }
  return tryDeleteLocalPhotoFile(rawPath);
}

Future<bool> tryDeleteLocalPhotoFile(String rawPath) async {
  final path = rawPath.trim();
  if (path.isEmpty) {
    return true;
  }
  try {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> deleteLocalPhotoFiles(Iterable<String> paths) async {
  for (final rawPath in paths.toSet()) {
    await tryDeleteLocalPhotoFile(rawPath);
  }
}
