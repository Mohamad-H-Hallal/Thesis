import '../../auth/domain/auth_models.dart';
import '../domain/project.dart';
import '../domain/projects_repository.dart';

class MockProjectsRepository implements ProjectsRepository {
  @override
  Future<List<ProjectSummary>> fetchAssignedProjects({
    required String userId,
    required UserRole role,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final all = _allProjects();

    // Assignment-aware filtering for field operations.
    if (role == UserRole.admin || role == UserRole.reviewer) {
      return all;
    }

    return all
        .where((project) => project.isAssignedTo(userId))
        .toList(growable: false);
  }

  @override
  Future<ProjectSummary?> byId({
    required String id,
    required String userId,
    required UserRole role,
  }) async {
    final all = await fetchAssignedProjects(userId: userId, role: role);
    for (final project in all) {
      if (project.id == id) {
        return project;
      }
    }
    return null;
  }

  List<ProjectSummary> _allProjects() {
    return <ProjectSummary>[
      ProjectSummary(
        id: 'proj-1',
        name: 'Bekaa Orchard Census 2026',
        category: 'Agriculture',
        status: 'active',
        assignedCollectors: 14,
        pendingReviews: 6,
        description:
            'Seasonal fruit tree geo-survey for productivity planning.',
        requiresPhotos: true,
        minPhotos: 2,
        maxPhotos: 6,
        allowedGeometryTypes: const <String>['Point', 'Polygon'],
        maxGpsAccuracyMeters: 12,
        assignments: <ProjectAssignment>[
          ProjectAssignment(
            userId: 'user-1',
            role: ProjectAssignmentRole.contributor,
            status: ProjectAssignmentStatus.approved,
            assignedAt: DateTime(2026, 2, 1),
          ),
          ProjectAssignment(
            userId: 'reviewer-1',
            role: ProjectAssignmentRole.reviewer,
            status: ProjectAssignmentStatus.approved,
            assignedAt: DateTime(2026, 2, 1),
          ),
        ],
        collectionFormSchema: const CollectionFormSchema(
          version: 'v0.3-bekaa',
          fields: <CollectionFormFieldSchema>[
            CollectionFormFieldSchema(
              key: 'tree_species',
              label: 'Tree Species',
              type: CollectionFieldType.select,
              required: true,
              options: <String>['Olive', 'Citrus', 'Apple', 'Grape'],
            ),
            CollectionFormFieldSchema(
              key: 'age_years',
              label: 'Estimated Age (Years)',
              type: CollectionFieldType.number,
              required: true,
              min: 0,
              max: 150,
            ),
            CollectionFormFieldSchema(
              key: 'health_status',
              label: 'Health Status',
              type: CollectionFieldType.select,
              required: true,
              options: <String>['Good', 'Fair', 'Poor'],
            ),
            CollectionFormFieldSchema(
              key: 'irrigated',
              label: 'Irrigated',
              type: CollectionFieldType.boolean,
            ),
            CollectionFormFieldSchema(
              key: 'notes',
              label: 'Collector Notes',
              type: CollectionFieldType.multiline,
              hint: 'Optional contextual notes for reviewers.',
            ),
          ],
        ),
      ),
      ProjectSummary(
        id: 'proj-2',
        name: 'Mount Lebanon Citrus Survey',
        category: 'Environmental',
        status: 'paused',
        assignedCollectors: 8,
        pendingReviews: 2,
        description:
            'Citrus health and irrigation baseline with photo evidence.',
        requiresPhotos: true,
        minPhotos: 1,
        maxPhotos: 4,
        allowedGeometryTypes: const <String>['Point'],
        maxGpsAccuracyMeters: 15,
        assignments: <ProjectAssignment>[
          ProjectAssignment(
            userId: 'user-1',
            role: ProjectAssignmentRole.contributor,
            status: ProjectAssignmentStatus.approved,
            assignedAt: DateTime(2026, 2, 3),
          ),
        ],
        collectionFormSchema: const CollectionFormSchema(
          version: 'v0.2-citrus',
          fields: <CollectionFormFieldSchema>[
            CollectionFormFieldSchema(
              key: 'citrus_type',
              label: 'Citrus Type',
              type: CollectionFieldType.select,
              required: true,
              options: <String>['Orange', 'Lemon', 'Mandarin', 'Grapefruit'],
            ),
            CollectionFormFieldSchema(
              key: 'canopy_diameter_m',
              label: 'Canopy Diameter (m)',
              type: CollectionFieldType.number,
              required: true,
              min: 0.3,
              max: 25,
              unit: 'm',
            ),
            CollectionFormFieldSchema(
              key: 'disease_signs',
              label: 'Disease Signs',
              type: CollectionFieldType.boolean,
            ),
          ],
        ),
      ),
      ProjectSummary(
        id: 'proj-3',
        name: 'South Region Replanting Program',
        category: 'Agriculture',
        status: 'draft',
        assignedCollectors: 5,
        pendingReviews: 0,
        description: 'New planting zones and mortality tracking by village.',
        requiresPhotos: false,
        minPhotos: 0,
        maxPhotos: 3,
        allowedGeometryTypes: const <String>['Polygon'],
        maxGpsAccuracyMeters: 20,
        assignments: <ProjectAssignment>[
          ProjectAssignment(
            userId: 'user-2',
            role: ProjectAssignmentRole.contributor,
            status: ProjectAssignmentStatus.approved,
            assignedAt: DateTime(2026, 2, 5),
          ),
        ],
        collectionFormSchema: const CollectionFormSchema(
          version: 'v0.1-replanting',
          fields: <CollectionFormFieldSchema>[
            CollectionFormFieldSchema(
              key: 'plot_code',
              label: 'Plot Code',
              type: CollectionFieldType.text,
              required: true,
            ),
            CollectionFormFieldSchema(
              key: 'seedling_count',
              label: 'Seedling Count',
              type: CollectionFieldType.number,
              required: true,
              min: 1,
              max: 5000,
            ),
            CollectionFormFieldSchema(
              key: 'planned_planting_date',
              label: 'Planned Planting Date',
              type: CollectionFieldType.date,
            ),
          ],
        ),
      ),
    ];
  }
}
