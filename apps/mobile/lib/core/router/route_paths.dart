class AppRoutes {
  const AppRoutes._();

  static const splash = '/splash';
  static const login = '/login';
  static const signup = '/signup';
  static const forgotPassword = '/forgot-password';
  static const resetPassword = '/reset-password';

  static const app = '/app';
  static const dashboard = '/app/dashboard';
  static const users = '/app/users';
  static const adminCreation = '/app/admin-create';
  static const contributorRequests = '/app/contributor-requests';
  static const projects = '/app/projects';
  static const assignedProjects = '/app/assigned-projects';
  static const assignments = '/app/assignments';
  static const drafts = '/app/drafts';
  static const submissions = '/app/submissions';
  static const reviewQueue = '/app/review-queue';
  static const exports = '/app/exports';
  static const notifications = '/app/notifications';
  static const profile = '/app/profile';
  static const addFeature = '/app/add-feature';

  static String projectDetails(String id) => '/app/projects/$id';

  static String addFeatureForProject(String projectId) {
    final uri = Uri(
      path: addFeature,
      queryParameters: {'projectId': projectId},
    );
    return uri.toString();
  }

  static String mapForProject(String projectId) => '/app/projects/$projectId/map';
}
