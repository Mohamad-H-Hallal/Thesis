import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/offline/local_store_web.dart';
import 'package:lebanese_gis_mobile/features/projects/domain/project.dart';

void main() {
  test('memory local store initializes itself on first use', () async {
    final store = MemoryLocalStore();

    expect(await store.getCachedProjects(), isEmpty);

    await store.cacheProjects(const <ProjectSummary>[
      ProjectSummary(
        id: 'p1',
        name: 'Runtime Project',
        category: 'Green',
        status: 'active',
        assignedCollectors: 0,
        pendingReviews: 0,
        description: 'Auto-init validation',
      ),
    ]);

    final projects = await store.getCachedProjects();
    expect(projects, hasLength(1));
    expect(projects.first.name, 'Runtime Project');
  });
}
