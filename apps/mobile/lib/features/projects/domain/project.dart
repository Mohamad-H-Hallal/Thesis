enum ProjectAssignmentRole { admin, reviewer, contributor, viewer }

enum ProjectAssignmentStatus { pending, approved, rejected }

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

enum CollectionFieldType { text, multiline, number, select, boolean, date }

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
    return CollectionFormFieldSchema(
      key: map['key'] as String,
      label: map['label'] as String,
      type: CollectionFieldType.values.byName(map['type'] as String),
      required: (map['required'] as bool?) ?? false,
      options: ((map['options'] as List?) ?? const <dynamic>[])
          .cast<String>()
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
      version: (map['version'] as String?) ?? 'v0.0',
      fields: rawFields
          .map(
            (field) => CollectionFormFieldSchema.fromMap(
              Map<String, dynamic>.from(field as Map),
            ),
          )
          .toList(growable: false),
    );
  }
}

class ProjectSummary {
  const ProjectSummary({
    required this.id,
    required this.name,
    required this.category,
    required this.status,
    required this.assignedCollectors,
    required this.pendingReviews,
    required this.description,
    this.assignments = const <ProjectAssignment>[],
    this.collectionFormSchema = CollectionFormSchema.empty,
    this.requiresPhotos = false,
    this.minPhotos = 0,
    this.maxPhotos = 5,
    this.allowedGeometryTypes = const <String>['Point'],
    this.maxGpsAccuracyMeters = 25,
  });

  final String id;
  final String name;
  final String category;
  final String status;
  final int assignedCollectors;
  final int pendingReviews;
  final String description;
  final List<ProjectAssignment> assignments;
  final CollectionFormSchema collectionFormSchema;
  final bool requiresPhotos;
  final int minPhotos;
  final int maxPhotos;
  final List<String> allowedGeometryTypes;
  final double maxGpsAccuracyMeters;

  bool isAssignedTo(String userId, {bool approvedOnly = true}) {
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
