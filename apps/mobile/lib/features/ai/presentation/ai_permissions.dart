import '../../auth/domain/auth_models.dart';
import '../../projects/domain/project.dart';

bool canManageProjectAi({
  required AppUser? user,
  required ProjectSummary project,
}) {
  return user?.isSuperAdmin == true;
}
