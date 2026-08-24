enum ProjectAssignmentRole { admin, contributor }

enum ProjectAssignmentStatus { pending, approved, rejected }

enum ProjectViewScope { public, assigned, all }

class ProjectListQuery {
  const ProjectListQuery({
    required this.scope,
    this.query,
    this.status,
    this.categoryId,
  });

  final ProjectViewScope scope;
  final String? query;
  final String? status;
  final String? categoryId;

  @override
  bool operator ==(Object other) {
    return other is ProjectListQuery &&
        other.scope == scope &&
        other.query == query &&
        other.status == status &&
        other.categoryId == categoryId;
  }

  @override
  int get hashCode => Object.hash(scope, query, status, categoryId);
}

extension ProjectViewScopeX on ProjectViewScope {
  String get apiValue {
    switch (this) {
      case ProjectViewScope.public:
        return 'public';
      case ProjectViewScope.assigned:
        return 'assigned';
      case ProjectViewScope.all:
        return 'all';
    }
  }
}

class ProjectAssignment {
  const ProjectAssignment({
    required this.userId,
    required this.role,
    required this.status,
    required this.assignedAt,
  });

  final String userId;
  final ProjectAssignmentRole role;
  final ProjectAssignmentStatus status;
  final DateTime assignedAt;

  bool get isApproved => status == ProjectAssignmentStatus.approved;

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'role': role.name,
      'status': status.name,
      'assignedAt': assignedAt.toIso8601String(),
    };
  }

  factory ProjectAssignment.fromMap(Map<String, dynamic> map) {
    return ProjectAssignment(
      userId: map['userId'] as String,
      role: ProjectAssignmentRole.values.byName(map['role'] as String),
      status: ProjectAssignmentStatus.values.byName(map['status'] as String),
      assignedAt: DateTime.parse(map['assignedAt'] as String),
    );
  }
}

enum CollectionFieldType {
  text,
  multiline,
  number,
  select,
  boolean,
  date,
  email,
  lebaneseMobile,
}

const List<String> defaultProjectGeometryTypes = <String>[
  'Point',
  'LineString',
  'Polygon',
];

class CollectionFormFieldSchema {
  const CollectionFormFieldSchema({
    required this.key,
    required this.label,
    required this.type,
    this.required = false,
    this.options = const <String>[],
    this.hint,
    this.min,
    this.max,
    this.unit,
  });

  final String key;
  final String label;
  final CollectionFieldType type;
  final bool required;
  final List<String> options;
  final String? hint;
  final num? min;
  final num? max;
  final String? unit;

  Map<String, dynamic> toMap() {
    return {
      'key': key,
      'label': label,
      'type': type.name,
      'required': required,
      'options': options,
      'hint': hint,
      'min': min,
      'max': max,
      'unit': unit,
    };
  }

  factory CollectionFormFieldSchema.fromMap(Map<String, dynamic> map) {
    final key = (map['key'] as String?)?.trim() ?? '';
    final label = (map['label'] as String?)?.trim();
    final rawType = (map['type'] as String?)?.trim();
    final normalizedType = CollectionFieldType.values.firstWhere(
      (candidate) => candidate.name == rawType,
      orElse: () {
        if (rawType == 'email') {
          return CollectionFieldType.email;
        }
        if (rawType == 'phone' ||
            rawType == 'mobile' ||
            rawType == 'telephone' ||
            rawType == 'lebanese_mobile') {
          return CollectionFieldType.lebaneseMobile;
        }
        if (rawType == 'textarea') {
          return CollectionFieldType.multiline;
        }
        if (rawType == 'float' || rawType == 'int') {
          return CollectionFieldType.number;
        }
        return CollectionFieldType.text;
      },
    );

    return CollectionFormFieldSchema(
      key: key,
      label: label?.isNotEmpty == true
          ? label!
          : key.isNotEmpty
          ? key
          : 'Field',
      type: normalizedType,
      required: (map['required'] as bool?) ?? false,
      options: ((map['options'] as List?) ?? const <dynamic>[])
          .map((value) => value.toString().trim())
          .where((value) => value.isNotEmpty)
          .toList(growable: false),
      hint: map['hint'] as String?,
      min: map['min'] as num?,
      max: map['max'] as num?,
      unit: map['unit'] as String?,
    );
  }
}

class CollectionFormSchema {
  const CollectionFormSchema({required this.version, required this.fields});

  final String version;
  final List<CollectionFormFieldSchema> fields;

  static const CollectionFormSchema empty = CollectionFormSchema(
    version: 'v0.0',
    fields: <CollectionFormFieldSchema>[],
  );

  Map<String, dynamic> toMap() {
    return {
      'version': version,
      'fields': fields.map((field) => field.toMap()).toList(growable: false),
    };
  }

  factory CollectionFormSchema.fromMap(Map<String, dynamic> map) {
    final rawFields = (map['fields'] as List?) ?? const <dynamic>[];
    return CollectionFormSchema(
      version:
          _schemaVersionFrom(map['version']) ??
          _schemaVersionFrom(map['schemaVersion']) ??
          'v0.0',
      fields: rawFields
          .whereType<Map>()
          .map(
            (field) => CollectionFormFieldSchema.fromMap(
              Map<String, dynamic>.from(field),
            ),
          )
          .toList(growable: false),
    );
  }
}

String? _schemaVersionFrom(dynamic value) {
  if (value is String) {
    final normalized = value.trim();
    return normalized.isEmpty ? null : normalized;
  }
  if (value is num) {
    return value.toString();
  }
  return null;
}

class ProjectSummary {
  const ProjectSummary({
    required this.id,
    required this.name,
    required this.category,
    this.categoryId,
    this.version = 1,
    required this.status,
    this.approvedFeatures = 0,
    this.rejectedFeatures = 0,
    this.draftFeatures = 0,
    required this.assignedCollectors,
    required this.pendingReviews,
    this.pendingAssignmentRequests = 0,
    this.rejectedAssignmentRequests = 0,
    this.publishedAiLayerCount = 0,
    this.publishedAiRunId,
    this.publishedAiLayerName,
    this.publishedAiLayerPublishedAt,
    required this.description,
    this.objectives,
    this.startDate,
    this.endDate,
    this.assignments = const <ProjectAssignment>[],
    this.collectionFormSchema = CollectionFormSchema.empty,
    this.requiresPhotos = false,
    this.minPhotos = 0,
    this.maxPhotos = 5,
    this.allowedGeometryTypes = defaultProjectGeometryTypes,
    this.maxGpsAccuracyMeters = 25,
    this.visibleToViewers = false,
    this.visibleToContributors = true,
    this.currentUserAssignmentRole,
    this.currentUserAssignmentStatus,
  });

  final String id;
  final String name;
  final String category;
  final String? categoryId;
  final int version;
  final String status;
  final int approvedFeatures;
  final int rejectedFeatures;
  final int draftFeatures;
  final int assignedCollectors;
  final int pendingReviews;
  final int pendingAssignmentRequests;
  final int rejectedAssignmentRequests;
  final int publishedAiLayerCount;
  final String? publishedAiRunId;
  final String? publishedAiLayerName;
  final DateTime? publishedAiLayerPublishedAt;
  final String description;
  final String? objectives;
  final DateTime? startDate;
  final DateTime? endDate;
  final List<ProjectAssignment> assignments;
  final CollectionFormSchema collectionFormSchema;
  final bool requiresPhotos;
  final int minPhotos;
  final int maxPhotos;
  final List<String> allowedGeometryTypes;
  final double maxGpsAccuracyMeters;
  final bool visibleToViewers;
  final bool visibleToContributors;
  final ProjectAssignmentRole? currentUserAssignmentRole;
  final ProjectAssignmentStatus? currentUserAssignmentStatus;

  bool get hasApprovedCurrentUserAssignment =>
      currentUserAssignmentStatus == ProjectAssignmentStatus.approved;

  String get visibilitySummaryLabel {
    if (visibleToViewers && visibleToContributors) {
      return 'Visible to all';
    }
    if (visibleToViewers) {
      return 'Viewer visible';
    }
    if (visibleToContributors) {
      return 'Contributor visible';
    }
    return 'Restricted';
  }

  bool isAssignedTo(String userId, {bool approvedOnly = true}) {
    if (hasApprovedCurrentUserAssignment && approvedOnly) {
      return true;
    }
    if (currentUserAssignmentStatus != null && !approvedOnly) {
      return true;
    }
    for (final assignment in assignments) {
      if (assignment.userId != userId) {
        continue;
      }
      if (!approvedOnly) {
        return true;
      }
      if (assignment.isApproved) {
        return true;
      }
    }
    return false;
  }
}
