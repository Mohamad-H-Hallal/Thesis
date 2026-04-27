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
  static const categories = '/app/categories';
  static const adminCreation = '/app/admin-create';
  static const contributorRequests = '/app/contributor-requests';
  static const projects = '/app/projects';
  static const assignedProjects = '/app/assigned-projects';
  static const assignments = '/app/assignments';
  static const drafts = '/app/drafts';
  static const submissions = '/app/submissions';
  static const reviewQueue = '/app/review-queue';
  static const imports = '/app/imports';
  static const exports = '/app/exports';
  static const notifications = '/app/notifications';
  static const profile = '/app/profile';
  static const addFeature = '/app/add-feature';

  static const categoryCreate = '/app/categories/new';
  static String categoryEdit(String id) => '/app/categories/$id/edit';
  static const projectCreate = '/app/projects/new';
  static String projectEdit(String id) => '/app/projects/$id/edit';
  static String projectAssignments(String id) =>
      '/app/projects/$id/assignments';
  static String projectDetails(String id) => '/app/projects/$id';
  static String projectReviewQueue(String id) => '/app/projects/$id/reviews';
  static String projectApprovedReviews(String id) =>
      '/app/projects/$id/approved-reviews';
  static String projectImports(String id) => '/app/projects/$id/imports';
  static String projectExports(String id) => '/app/projects/$id/exports';
  static String importDetails(String id) => '/app/imports/$id';
  static String importReview(String id) => '/app/imports/$id/review';
  static String importMap(String id, {required String projectId}) {
    final uri = Uri(
      path: '/app/imports/$id/map',
      queryParameters: {'projectId': projectId},
    );
    return uri.toString();
  }

  static String addFeatureForProject(String projectId) {
    final uri = Uri(
      path: addFeature,
      queryParameters: {'projectId': projectId},
    );
    return uri.toString();
  }

  static String editDraftFeature({
    required String projectId,
    required String featureId,
  }) {
    final uri = Uri(
      path: addFeature,
      queryParameters: {'projectId': projectId, 'featureId': featureId},
    );
    return uri.toString();
  }

  static String mapForProject(
    String projectId, {
    String? featureId,
    bool startCapture = false,
  }) {
    final queryParameters = <String, String>{};
    if (featureId != null) {
      queryParameters['featureId'] = featureId;
    }
    if (startCapture) {
      queryParameters['startCapture'] = '1';
    }
    final uri = Uri(
      path: '/app/projects/$projectId/map',
      queryParameters: queryParameters.isEmpty ? null : queryParameters,
    );
    return uri.toString();
  }
}
