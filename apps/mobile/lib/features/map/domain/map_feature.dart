class MapFeaturePhoto {
  const MapFeaturePhoto({
    required this.id,
    required this.filePath,
    this.thumbnailPath,
    this.status,
    this.takenAt,
    this.displayOrder,
  });

  final String id;
  final String filePath;
  final String? thumbnailPath;
  final String? status;
  final DateTime? takenAt;
  final int? displayOrder;
}

class MapFeatureSummary {
  const MapFeatureSummary({
    required this.id,
    required this.projectId,
    required this.status,
    required this.geometry,
    required this.attributes,
    this.sourceGeometryType,
    this.collectedBy,
    this.reviewedBy,
    this.reviewNotes,
    this.accuracyMeters,
    this.collectedAt,
    this.submittedAt,
    this.reviewedAt,
    this.photoCount = 0,
    this.photos = const <MapFeaturePhoto>[],
    this.isSummary = false,
    this.isAggregate = false,
    this.clusterCount = 1,
  });

  final String id;
  final String projectId;
  final String status;
  final Map<String, dynamic> geometry;
  final Map<String, dynamic> attributes;
  final String? sourceGeometryType;
  final String? collectedBy;
  final String? reviewedBy;
  final String? reviewNotes;
  final double? accuracyMeters;
  final DateTime? collectedAt;
  final DateTime? submittedAt;
  final DateTime? reviewedAt;
  final int photoCount;
  final List<MapFeaturePhoto> photos;
  final bool isSummary;
  final bool isAggregate;
  final int clusterCount;
}

class ProjectFeatureIdentity {
  const ProjectFeatureIdentity({
    required this.projectId,
    required this.featureId,
  });

  final String projectId;
  final String featureId;

  @override
  bool operator ==(Object other) =>
      other is ProjectFeatureIdentity &&
      other.projectId == projectId &&
      other.featureId == featureId;

  @override
  int get hashCode => Object.hash(projectId, featureId);
}

class ProjectFeatureBrowserQuery {
  const ProjectFeatureBrowserQuery({
    required this.projectId,
    this.search,
    this.status,
    this.geometryType,
    this.featureType,
    this.excludeImportId,
  });

  final String projectId;
  final String? search;
  final String? status;
  final String? geometryType;
  final String? featureType;
  final String? excludeImportId;

  @override
  bool operator ==(Object other) {
    return other is ProjectFeatureBrowserQuery &&
        other.projectId == projectId &&
        other.search == search &&
        other.status == status &&
        other.geometryType == geometryType &&
        other.featureType == featureType &&
        other.excludeImportId == excludeImportId;
  }

  @override
  int get hashCode => Object.hash(
    projectId,
    search,
    status,
    geometryType,
    featureType,
    excludeImportId,
  );
}

class ProjectFeatureCountQuery {
  const ProjectFeatureCountQuery({
    required this.projectId,
    this.search,
    this.statuses,
    this.geometryType,
    this.featureType,
    this.excludeImportId,
  });

  final String projectId;
  final String? search;
  final List<String>? statuses;
  final String? geometryType;
  final String? featureType;
  final String? excludeImportId;

  @override
  bool operator ==(Object other) {
    return other is ProjectFeatureCountQuery &&
        other.projectId == projectId &&
        other.search == search &&
        _sameStatusList(other.statuses, statuses) &&
        other.geometryType == geometryType &&
        other.featureType == featureType &&
        other.excludeImportId == excludeImportId;
  }

  @override
  int get hashCode => Object.hash(
    projectId,
    search,
    statuses == null ? null : Object.hashAll(statuses!),
    geometryType,
    featureType,
    excludeImportId,
  );
}

bool _sameStatusList(List<String>? a, List<String>? b) {
  if (identical(a, b)) {
    return true;
  }
  if (a == null || b == null || a.length != b.length) {
    return false;
  }
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) {
      return false;
    }
  }
  return true;
}

class ProjectMapViewportQuery {
  const ProjectMapViewportQuery({
    required this.projectId,
    required this.minLon,
    required this.minLat,
    required this.maxLon,
    required this.maxLat,
    required this.zoom,
    this.featureType,
  });

  final String projectId;
  final double minLon;
  final double minLat;
  final double maxLon;
  final double maxLat;
  final double zoom;
  final String? featureType;

  @override
  bool operator ==(Object other) {
    return other is ProjectMapViewportQuery &&
        other.projectId == projectId &&
        other.minLon == minLon &&
        other.minLat == minLat &&
        other.maxLon == maxLon &&
        other.maxLat == maxLat &&
        other.zoom == zoom &&
        other.featureType == featureType;
  }

  @override
  int get hashCode =>
      Object.hash(projectId, minLon, minLat, maxLon, maxLat, zoom, featureType);
}
