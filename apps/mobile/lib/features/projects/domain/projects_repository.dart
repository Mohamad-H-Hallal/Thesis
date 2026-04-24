import '../../auth/domain/auth_models.dart';
import '../../../core/pagination/paginated_result.dart';
import 'project.dart';

abstract class ProjectsRepository {
  Future<List<ProjectSummary>> fetchProjects({
    required String userId,
    required UserRole role,
    required ProjectViewScope scope,
  });

  Future<PaginatedResult<ProjectSummary>> fetchProjectsPage({
    required String userId,
    required UserRole role,
    required ProjectViewScope scope,
    String? query,
    String? status,
    String? categoryId,
    int page = 1,
    int limit = 20,
  });

  Future<ProjectSummary?> byId({
    required String id,
    required String userId,
    required UserRole role,
  });

  Future<ProjectSummary> updateViewerVisibility({
    required String projectId,
    required bool visibleToViewers,
  });

  Future<ProjectSummary> updateContributorVisibility({
    required String projectId,
    required bool visibleToContributors,
  });

  Future<void> requestProjectAccess({required String projectId});

  Future<void> cancelProjectAccessRequest({required String projectId});
}
