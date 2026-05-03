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
  });

  final String id;
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

class ProjectMapViewportQuery {
  const ProjectMapViewportQuery({
    required this.projectId,
    required this.minLon,
    required this.minLat,
    required this.maxLon,
    required this.maxLat,
    required this.zoom,
  });

  final String projectId;
  final double minLon;
  final double minLat;
  final double maxLon;
  final double maxLat;
  final double zoom;

  @override
  bool operator ==(Object other) {
    return other is ProjectMapViewportQuery &&
        other.projectId == projectId &&
        other.minLon == minLon &&
        other.minLat == minLat &&
        other.maxLon == maxLon &&
        other.maxLat == maxLat &&
        other.zoom == zoom;
  }

  @override
  int get hashCode => Object.hash(
    projectId,
    minLon,
    minLat,
    maxLon,
    maxLat,
    zoom,
  );
}
