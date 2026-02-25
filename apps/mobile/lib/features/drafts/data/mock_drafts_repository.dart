import '../domain/draft_item.dart';

class MockDraftsRepository {
  Future<List<DraftItem>> fetchDrafts() async {
    await Future<void>.delayed(const Duration(milliseconds: 550));

    return const [
      DraftItem(
        id: 'd-1',
        projectName: 'Bekaa Orchard Census 2026',
        geometryType: 'Point',
        status: 'draft',
        lastEdited: '2h ago',
      ),
      DraftItem(
        id: 'd-2',
        projectName: 'Mount Lebanon Citrus Survey',
        geometryType: 'Polygon',
        status: 'submitted',
        lastEdited: 'Yesterday',
      ),
      DraftItem(
        id: 'd-3',
        projectName: 'South Region Replanting Program',
        geometryType: 'LineString',
        status: 'rejected',
        lastEdited: '3 days ago',
      ),
    ];
  }
}
