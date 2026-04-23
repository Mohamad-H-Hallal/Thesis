import 'dart:convert';

import '../../features/drafts/domain/draft_item.dart';
import '../../features/projects/domain/project.dart';

enum SyncOperationType { create, update, delete }

enum SyncQueueStatus { pending, processing, failed, conflict, deadLetter }

class SyncQueueStats {
  const SyncQueueStats({
    required this.pending,
    required this.processing,
    required this.failed,
    required this.conflict,
    required this.deadLetter,
  });

  final int pending;
  final int processing;
  final int failed;
  final int conflict;
  final int deadLetter;

  int get actionable => pending + processing + failed;
  int get blocked => conflict + deadLetter;
}

class DraftPhoto {
  const DraftPhoto({
    required this.id,
    required this.filePath,
    required this.createdAt,
  });

  final String id;
  final String filePath;
  final DateTime createdAt;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'file_path': filePath,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory DraftPhoto.fromMap(Map<String, dynamic> map) {
    return DraftPhoto(
      id: map['id'] as String,
      filePath: map['file_path'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}

class OfflineMapPackage {
  const OfflineMapPackage({
    required this.ownerUserId,
    required this.version,
    required this.zoomLevelMin,
    required this.zoomLevelMax,
    this.downloadedAt,
    required this.lastUpdatedAt,
    this.tileCount,
    this.sizeBytes,
    this.tileSource,
    required this.isCurrent,
  });

  final String ownerUserId;
  final String version;
  final int zoomLevelMin;
  final int zoomLevelMax;
  final DateTime? downloadedAt;
  final DateTime lastUpdatedAt;
  final int? tileCount;
  final int? sizeBytes;
  final String? tileSource;
  final bool isCurrent;

  OfflineMapPackage copyWith({
    String? ownerUserId,
    String? version,
    int? zoomLevelMin,
    int? zoomLevelMax,
    DateTime? downloadedAt,
    DateTime? lastUpdatedAt,
    int? tileCount,
    int? sizeBytes,
    String? tileSource,
    bool? isCurrent,
  }) {
    return OfflineMapPackage(
      ownerUserId: ownerUserId ?? this.ownerUserId,
      version: version ?? this.version,
      zoomLevelMin: zoomLevelMin ?? this.zoomLevelMin,
      zoomLevelMax: zoomLevelMax ?? this.zoomLevelMax,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      lastUpdatedAt: lastUpdatedAt ?? this.lastUpdatedAt,
      tileCount: tileCount ?? this.tileCount,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      tileSource: tileSource ?? this.tileSource,
      isCurrent: isCurrent ?? this.isCurrent,
    );
  }

  Map<String, dynamic> toRowMap() {
    return {
      'owner_user_id': ownerUserId,
      'version': version,
      'zoom_level_min': zoomLevelMin,
      'zoom_level_max': zoomLevelMax,
      'downloaded_at': downloadedAt?.toIso8601String(),
      'last_updated_at': lastUpdatedAt.toIso8601String(),
      'tile_count': tileCount,
      'size_bytes': sizeBytes,
      'tile_source': tileSource,
      'is_current': isCurrent ? 1 : 0,
    };
  }

  factory OfflineMapPackage.fromRowMap(Map<String, dynamic> row) {
    return OfflineMapPackage(
      ownerUserId: row['owner_user_id'] as String? ?? '',
      version: row['version'] as String,
      zoomLevelMin: row['zoom_level_min'] as int,
      zoomLevelMax: row['zoom_level_max'] as int,
      downloadedAt: row['downloaded_at'] == null
          ? null
          : DateTime.parse(row['downloaded_at'] as String),
      lastUpdatedAt: DateTime.parse(row['last_updated_at'] as String),
      tileCount: row['tile_count'] as int?,
      sizeBytes: row['size_bytes'] as int?,
      tileSource: row['tile_source'] as String?,
      isCurrent: (row['is_current'] as int) == 1,
    );
  }
}

class LocalDraftFeature {
  const LocalDraftFeature({
    required this.id,
    required this.ownerUserId,
    required this.projectId,
    required this.projectName,
    required this.geometryType,
    required this.geometryJson,
    required this.attributesJson,
    required this.photos,
    required this.status,
    required this.localVersion,
    this.remoteVersion,
    required this.updatedAt,
    this.collectedOffline = true,
  });

  final String id;
  final String ownerUserId;
  final String projectId;
  final String projectName;
  final String geometryType;
  final String geometryJson;
  final String attributesJson;
  final List<DraftPhoto> photos;
  final String status;
  final int localVersion;
  final int? remoteVersion;
  final DateTime updatedAt;
  final bool collectedOffline;

  DraftItem toDraftItem() {
    return DraftItem(
      id: id,
      projectName: projectName,
      geometryType: geometryType,
      status: status,
      lastEdited: _humanizeRelative(updatedAt),
    );
  }

  Map<String, dynamic> toRowMap() {
    return {
      'id': id,
      'owner_user_id': ownerUserId,
      'project_id': projectId,
      'project_name': projectName,
      'geometry_type': geometryType,
      'geometry_json': geometryJson,
      'attributes_json': attributesJson,
      'status': status,
      'local_version': localVersion,
      'remote_version': remoteVersion,
      'collected_offline': collectedOffline ? 1 : 0,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  LocalDraftFeature copyWith({
    String? ownerUserId,
    String? projectName,
    String? geometryType,
    String? geometryJson,
    String? attributesJson,
    String? status,
    int? localVersion,
    int? remoteVersion,
    DateTime? updatedAt,
    List<DraftPhoto>? photos,
  }) {
    return LocalDraftFeature(
      id: id,
      ownerUserId: ownerUserId ?? this.ownerUserId,
      projectId: projectId,
      projectName: projectName ?? this.projectName,
      geometryType: geometryType ?? this.geometryType,
      geometryJson: geometryJson ?? this.geometryJson,
      attributesJson: attributesJson ?? this.attributesJson,
      photos: photos ?? this.photos,
      status: status ?? this.status,
      localVersion: localVersion ?? this.localVersion,
      remoteVersion: remoteVersion ?? this.remoteVersion,
      updatedAt: updatedAt ?? this.updatedAt,
      collectedOffline: collectedOffline,
    );
  }

  factory LocalDraftFeature.fromRowMap(
    Map<String, dynamic> row,
    List<DraftPhoto> photos,
  ) {
    return LocalDraftFeature(
      id: row['id'] as String,
      ownerUserId: row['owner_user_id'] as String? ?? '',
      projectId: row['project_id'] as String,
      projectName: row['project_name'] as String,
      geometryType: row['geometry_type'] as String,
      geometryJson:
          row['geometry_json'] as String? ??
          '{"type":"Point","coordinates":[]}',
      attributesJson: row['attributes_json'] as String,
      photos: photos,
      status: row['status'] as String,
      localVersion: row['local_version'] as int,
      remoteVersion: row['remote_version'] as int?,
      collectedOffline: (row['collected_offline'] as int) == 1,
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }

  static String _humanizeRelative(DateTime updatedAt) {
    final now = DateTime.now();
    final delta = now.difference(updatedAt);

    if (delta.inMinutes < 1) {
      return 'just now';
    }
    if (delta.inHours < 1) {
      return '${delta.inMinutes}m ago';
    }
    if (delta.inDays < 1) {
      return '${delta.inHours}h ago';
    }
    if (delta.inDays < 7) {
      return '${delta.inDays}d ago';
    }
    return '${updatedAt.year}-${updatedAt.month.toString().padLeft(2, '0')}-${updatedAt.day.toString().padLeft(2, '0')}';
  }
}

class SyncQueueItem {
  const SyncQueueItem({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.payload,
    required this.localVersion,
    required this.idempotencyKey,
    required this.attemptCount,
    required this.status,
    this.nextRetryAt,
    this.lastError,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String entityType;
  final String entityId;
  final SyncOperationType operation;
  final Map<String, dynamic> payload;
  final int localVersion;
  final String idempotencyKey;
  final int attemptCount;
  final SyncQueueStatus status;
  final DateTime? nextRetryAt;
  final String? lastError;
  final DateTime createdAt;
  final DateTime updatedAt;

  SyncQueueItem copyWith({
    int? attemptCount,
    SyncQueueStatus? status,
    DateTime? nextRetryAt,
    String? lastError,
    DateTime? updatedAt,
  }) {
    return SyncQueueItem(
      id: id,
      entityType: entityType,
      entityId: entityId,
      operation: operation,
      payload: payload,
      localVersion: localVersion,
      idempotencyKey: idempotencyKey,
      attemptCount: attemptCount ?? this.attemptCount,
      status: status ?? this.status,
      nextRetryAt: nextRetryAt ?? this.nextRetryAt,
      lastError: lastError ?? this.lastError,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toRowMap() {
    return {
      'id': id,
      'entity_type': entityType,
      'entity_id': entityId,
      'operation': operation.name,
      'payload_json': jsonEncode(payload),
      'local_version': localVersion,
      'idempotency_key': idempotencyKey,
      'attempt_count': attemptCount,
      'status': status.name,
      'next_retry_at': nextRetryAt?.toIso8601String(),
      'last_error': lastError,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory SyncQueueItem.fromRowMap(Map<String, dynamic> row) {
    return SyncQueueItem(
      id: row['id'] as String,
      entityType: row['entity_type'] as String,
      entityId: row['entity_id'] as String,
      operation: SyncOperationType.values.byName(row['operation'] as String),
      payload:
          jsonDecode(row['payload_json'] as String) as Map<String, dynamic>,
      localVersion: row['local_version'] as int,
      idempotencyKey: row['idempotency_key'] as String,
      attemptCount: row['attempt_count'] as int,
      status: SyncQueueStatus.values.byName(row['status'] as String),
      nextRetryAt: row['next_retry_at'] != null
          ? DateTime.parse(row['next_retry_at'] as String)
          : null,
      lastError: row['last_error'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }
}

extension ProjectSummaryLocalMapper on ProjectSummary {
  Map<String, dynamic> toLocalPayload() {
    return {
      'id': id,
      'name': name,
      'category': category,
      'status': status,
      'approvedFeatures': approvedFeatures,
      'assignedCollectors': assignedCollectors,
      'pendingReviews': pendingReviews,
      'description': description,
      'assignments': assignments
          .map((assignment) => assignment.toMap())
          .toList(growable: false),
      'collectionFormSchema': collectionFormSchema.toMap(),
      'requiresPhotos': requiresPhotos,
      'minPhotos': minPhotos,
      'maxPhotos': maxPhotos,
      'allowedGeometryTypes': allowedGeometryTypes,
      'maxGpsAccuracyMeters': maxGpsAccuracyMeters,
      'visibleToViewers': visibleToViewers,
      'visibleToContributors': visibleToContributors,
      'currentUserAssignmentRole': currentUserAssignmentRole?.name,
      'currentUserAssignmentStatus': currentUserAssignmentStatus?.name,
    };
  }
}

ProjectSummary projectSummaryFromPayload(Map<String, dynamic> payload) {
  final rawAssignments = (payload['assignments'] as List?) ?? const <dynamic>[];
  return ProjectSummary(
    id: payload['id'] as String,
    name: payload['name'] as String,
    category: payload['category'] as String,
    status: payload['status'] as String,
    approvedFeatures: ((payload['approvedFeatures'] as num?) ?? 0).toInt(),
    assignedCollectors: ((payload['assignedCollectors'] as num?) ?? 0).toInt(),
    pendingReviews: ((payload['pendingReviews'] as num?) ?? 0).toInt(),
    description: payload['description'] as String,
    assignments: rawAssignments
        .map(
          (assignment) => ProjectAssignment.fromMap(
            Map<String, dynamic>.from(assignment as Map),
          ),
        )
        .toList(growable: false),
    collectionFormSchema: payload['collectionFormSchema'] == null
        ? CollectionFormSchema.empty
        : CollectionFormSchema.fromMap(
            Map<String, dynamic>.from(payload['collectionFormSchema'] as Map),
          ),
    requiresPhotos: (payload['requiresPhotos'] as bool?) ?? false,
    minPhotos: ((payload['minPhotos'] as num?) ?? 0).toInt(),
    maxPhotos: ((payload['maxPhotos'] as num?) ?? 5).toInt(),
    allowedGeometryTypes: defaultProjectGeometryTypes,
    maxGpsAccuracyMeters: ((payload['maxGpsAccuracyMeters'] as num?) ?? 25)
        .toDouble(),
    visibleToViewers: (payload['visibleToViewers'] as bool?) ?? false,
    visibleToContributors: (payload['visibleToContributors'] as bool?) ?? true,
    currentUserAssignmentRole: (payload['currentUserAssignmentRole'] as String?)
        ?.let(ProjectAssignmentRole.values.byName),
    currentUserAssignmentStatus:
        (payload['currentUserAssignmentStatus'] as String?)?.let(
          ProjectAssignmentStatus.values.byName,
        ),
  );
}

extension _NullableEnumMapper on String? {
  T? let<T>(T Function(String value) mapper) {
    final value = this;
    if (value == null || value.isEmpty) {
      return null;
    }
    return mapper(value);
  }
}
