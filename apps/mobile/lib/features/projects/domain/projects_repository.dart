import '../../auth/domain/auth_models.dart';
import 'project.dart';

abstract class ProjectsRepository {
  Future<List<ProjectSummary>> fetchProjects({
    required String userId,
    required UserRole role,
    required ProjectViewScope scope,
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

  Future<void> requestProjectAccess({required String projectId});
}
