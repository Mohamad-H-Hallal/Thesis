class AppRoutes {
  const AppRoutes._();

  static const splash = '/splash';
  static const login = '/login';
  static const signup = '/signup';
  static const forgotPassword = '/forgot-password';
  static const resetPassword = '/reset-password';

  static const app = '/app';
  static const projects = '/app/projects';
  static const assignedProjects = '/app/assigned-projects';
  static const map = '/app/map';
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

  static String mapForProject(String projectId) {
    final uri = Uri(path: map, queryParameters: {'projectId': projectId});
    return uri.toString();
  }
}
