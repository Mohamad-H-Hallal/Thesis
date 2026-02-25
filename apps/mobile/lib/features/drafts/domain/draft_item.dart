class DraftItem {
  const DraftItem({
    required this.id,
    required this.projectName,
    required this.geometryType,
    required this.status,
    required this.lastEdited,
  });

  final String id;
  final String projectName;
  final String geometryType;
  final String status;
  final String lastEdited;
}
