import '../../auth/domain/auth_models.dart';
import 'project.dart';

abstract class ProjectsRepository {
  Future<List<ProjectSummary>> fetchAssignedProjects({
    required String userId,
    required UserRole role,
  });

  Future<ProjectSummary?> byId({
    required String id,
    required String userId,
    required UserRole role,
  });
}
