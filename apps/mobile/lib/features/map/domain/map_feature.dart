class MapFeatureSummary {
  const MapFeatureSummary({
    required this.id,
    required this.status,
    required this.geometry,
    this.collectedBy,
    this.reviewedBy,
    this.photoCount = 0,
  });

  final String id;
  final String status;
  final Map<String, dynamic> geometry;
  final String? collectedBy;
  final String? reviewedBy;
  final int photoCount;
}
