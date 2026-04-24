import '../../auth/domain/auth_models.dart';
import '../../../core/pagination/paginated_result.dart';
import '../domain/project.dart';
import '../domain/projects_repository.dart';

class MockProjectsRepository implements ProjectsRepository {
  @override
  Future<List<ProjectSummary>> fetchProjects({
    required String userId,
    required UserRole role,
    required ProjectViewScope scope,
  }) async {
    final page = await fetchProjectsPage(
      userId: userId,
      role: role,
      scope: scope,
      limit: 100,
    );
    return page.items;
  }

  @override
  Future<PaginatedResult<ProjectSummary>> fetchProjectsPage({
    required String userId,
    required UserRole role,
    required ProjectViewScope scope,
    String? query,
    String? status,
    String? categoryId,
    int page = 1,
    int limit = 20,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final all = _allProjects();

    Iterable<ProjectSummary> filtered = all;

    if (role == UserRole.admin && scope == ProjectViewScope.all) {
      filtered = all;
    } else if (scope == ProjectViewScope.public || role == UserRole.viewer) {
      filtered = all.where((project) {
        final isPublished = const <String>['draft', 'active', 'paused', 'completed']
            .contains(project.status);
        if (!isPublished) {
          return false;
        }
        if (role == UserRole.viewer) {
          return project.visibleToViewers;
        }
        return project.visibleToContributors;
      });
    } else {
      filtered = all.where((project) => project.isAssignedTo(userId));
    }

    final items = filtered
        .map((project) => _withCurrentUserAssignment(project, userId: userId))
        .where((project) {
          if (status?.trim().isNotEmpty ?? false) {
            if (project.status != status) {
              return false;
            }
          }
          if (categoryId?.trim().isNotEmpty ?? false) {
            if (project.categoryId != categoryId) {
              return false;
            }
          }
          if (query?.trim().isNotEmpty ?? false) {
            final normalized = query!.trim().toLowerCase();
            return project.name.toLowerCase().contains(normalized) ||
                project.category.toLowerCase().contains(normalized) ||
                project.description.toLowerCase().contains(normalized);
          }
          return true;
        })
        .toList(growable: false);
    final start = (page - 1) * limit;
    final end = (start + limit).clamp(0, items.length);
    final pageItems = start >= items.length
        ? const <ProjectSummary>[]
        : items.sublist(start, end);
    return PaginatedResult<ProjectSummary>(
      items: pageItems,
      page: page,
      limit: limit,
      total: items.length,
      hasMore: end < items.length,
    );
  }

  @override
  Future<ProjectSummary?> byId({
    required String id,
    required String userId,
    required UserRole role,
  }) async {
    for (final scope in _allowedScopesForRole(role)) {
      final all = await fetchProjects(userId: userId, role: role, scope: scope);
      for (final project in all) {
        if (project.id == id) {
          return project;
        }
      }
    }
    return null;
  }

  List<ProjectViewScope> _allowedScopesForRole(UserRole role) {
    switch (role) {
      case UserRole.admin:
        return const <ProjectViewScope>[
          ProjectViewScope.all,
          ProjectViewScope.public,
        ];
      case UserRole.viewer:
        return const <ProjectViewScope>[ProjectViewScope.public];
      case UserRole.contributor:
        return const <ProjectViewScope>[
          ProjectViewScope.assigned,
          ProjectViewScope.public,
        ];
    }
  }

  ProjectSummary _withCurrentUserAssignment(
    ProjectSummary project, {
    required String userId,
  }) {
    ProjectAssignment? currentAssignment;
    for (final assignment in project.assignments) {
      if (assignment.userId == userId) {
        currentAssignment = assignment;
        break;
      }
    }

    return ProjectSummary(
      id: project.id,
      name: project.name,
      category: project.category,
      status: project.status,
      assignedCollectors: project.assignedCollectors,
      pendingReviews: project.pendingReviews,
      description: project.description,
      assignments: project.assignments,
      collectionFormSchema: project.collectionFormSchema,
      requiresPhotos: project.requiresPhotos,
      minPhotos: project.minPhotos,
      maxPhotos: project.maxPhotos,
      allowedGeometryTypes: project.allowedGeometryTypes,
      maxGpsAccuracyMeters: project.maxGpsAccuracyMeters,
      visibleToViewers: project.visibleToViewers,
      visibleToContributors: project.visibleToContributors,
      currentUserAssignmentRole: currentAssignment?.role,
      currentUserAssignmentStatus: currentAssignment?.status,
    );
  }

  @override
  Future<ProjectSummary> updateViewerVisibility({
    required String projectId,
    required bool visibleToViewers,
  }) async {
    final project = _allProjects().firstWhere((item) => item.id == projectId);
    return ProjectSummary(
      id: project.id,
      name: project.name,
      category: project.category,
      status: project.status,
      assignedCollectors: project.assignedCollectors,
      pendingReviews: project.pendingReviews,
      description: project.description,
      assignments: project.assignments,
      collectionFormSchema: project.collectionFormSchema,
      requiresPhotos: project.requiresPhotos,
      minPhotos: project.minPhotos,
      maxPhotos: project.maxPhotos,
      allowedGeometryTypes: project.allowedGeometryTypes,
      maxGpsAccuracyMeters: project.maxGpsAccuracyMeters,
      visibleToViewers: visibleToViewers,
      visibleToContributors: project.visibleToContributors,
      currentUserAssignmentRole: project.currentUserAssignmentRole,
      currentUserAssignmentStatus: project.currentUserAssignmentStatus,
    );
  }

  @override
  Future<ProjectSummary> updateContributorVisibility({
    required String projectId,
    required bool visibleToContributors,
  }) async {
    final project = _allProjects().firstWhere((item) => item.id == projectId);
    return ProjectSummary(
      id: project.id,
      name: project.name,
      category: project.category,
      status: project.status,
      assignedCollectors: project.assignedCollectors,
      pendingReviews: project.pendingReviews,
      description: project.description,
      assignments: project.assignments,
      collectionFormSchema: project.collectionFormSchema,
      requiresPhotos: project.requiresPhotos,
      minPhotos: project.minPhotos,
      maxPhotos: project.maxPhotos,
      allowedGeometryTypes: project.allowedGeometryTypes,
      maxGpsAccuracyMeters: project.maxGpsAccuracyMeters,
      visibleToViewers: project.visibleToViewers,
      visibleToContributors: visibleToContributors,
      currentUserAssignmentRole: project.currentUserAssignmentRole,
      currentUserAssignmentStatus: project.currentUserAssignmentStatus,
    );
  }

  @override
  Future<void> requestProjectAccess({required String projectId}) async {}

  @override
  Future<void> cancelProjectAccessRequest({required String projectId}) async {}

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
        allowedGeometryTypes: defaultProjectGeometryTypes,
        maxGpsAccuracyMeters: 12,
        visibleToViewers: true,
        visibleToContributors: true,
        assignments: <ProjectAssignment>[
          ProjectAssignment(
            userId: 'user-1',
            role: ProjectAssignmentRole.contributor,
            status: ProjectAssignmentStatus.approved,
            assignedAt: DateTime(2026, 2, 1),
          ),
          ProjectAssignment(
            userId: 'admin-1',
            role: ProjectAssignmentRole.admin,
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
              hint: 'Optional contextual notes for project admins.',
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
        allowedGeometryTypes: defaultProjectGeometryTypes,
        maxGpsAccuracyMeters: 15,
        visibleToViewers: false,
        visibleToContributors: false,
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
        allowedGeometryTypes: defaultProjectGeometryTypes,
        maxGpsAccuracyMeters: 20,
        visibleToViewers: false,
        visibleToContributors: true,
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
