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

class LocalDraftFeature {
  const LocalDraftFeature({
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.geometryType,
    required this.attributesJson,
    required this.photos,
    required this.status,
    required this.localVersion,
    this.remoteVersion,
    required this.updatedAt,
    this.collectedOffline = true,
  });

  final String id;
  final String projectId;
  final String projectName;
  final String geometryType;
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
      'project_id': projectId,
      'project_name': projectName,
      'geometry_type': geometryType,
      'attributes_json': attributesJson,
      'status': status,
      'local_version': localVersion,
      'remote_version': remoteVersion,
      'collected_offline': collectedOffline ? 1 : 0,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  LocalDraftFeature copyWith({
    String? projectName,
    String? geometryType,
    String? attributesJson,
    String? status,
    int? localVersion,
    int? remoteVersion,
    DateTime? updatedAt,
    List<DraftPhoto>? photos,
  }) {
    return LocalDraftFeature(
      id: id,
      projectId: projectId,
      projectName: projectName ?? this.projectName,
      geometryType: geometryType ?? this.geometryType,
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
      projectId: row['project_id'] as String,
      projectName: row['project_name'] as String,
      geometryType: row['geometry_type'] as String,
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
      'currentUserAssignmentRole': currentUserAssignmentRole?.name,
      'currentUserAssignmentStatus': currentUserAssignmentStatus?.name,
    };
  }
}

ProjectSummary projectSummaryFromPayload(Map<String, dynamic> payload) {
  final rawAssignments = (payload['assignments'] as List?) ?? const <dynamic>[];
  final rawAllowedGeometry =
      (payload['allowedGeometryTypes'] as List?) ?? const <dynamic>[];

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
    allowedGeometryTypes: rawAllowedGeometry.cast<String>().toList(
      growable: false,
    ),
    maxGpsAccuracyMeters: ((payload['maxGpsAccuracyMeters'] as num?) ?? 25)
        .toDouble(),
    visibleToViewers: (payload['visibleToViewers'] as bool?) ?? false,
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
