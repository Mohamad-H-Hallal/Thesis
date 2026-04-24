class ReviewQueueQuery {
  const ReviewQueueQuery({required this.status, this.projectId});

  final String status;
  final String? projectId;

  @override
  bool operator ==(Object other) {
    return other is ReviewQueueQuery &&
        other.status == status &&
        other.projectId == projectId;
  }

  @override
  int get hashCode => Object.hash(status, projectId);
}

class ReviewQueueItem {
  const ReviewQueueItem({
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.geometryType,
    required this.status,
    required this.collectedBy,
    required this.collectedAt,
    required this.photoCount,
  });

  final String id;
  final String projectId;
  final String projectName;
  final String geometryType;
  final String status;
  final String? collectedBy;
  final DateTime? collectedAt;
  final int photoCount;
}
