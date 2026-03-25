const express = require('express');
const assignmentController = require('../controllers/assignment.controller');
const photoController = require('../controllers/photo.controller');
const {
  categoryController,
  notificationController,
  settingsController,
  userController,
} = require('../controllers/misc.controller');
const { authenticate, authorize, checkProjectAdmin } = require('../middleware/auth');
const {
  assignmentValidation,
  categoryValidation,
  userValidation,
  validate,
  paginationValidation,
  uuidValidation,
} = require('../middleware/validation');
const { asyncHandler } = require('../middleware/error');
const { uploadCategoryIcon, uploadMultiple } = require('../config/upload');
import { auditAction, auditDynamicAction } from '../middleware/audit';

// ============================================================================
// ASSIGNMENT ROUTES
// ============================================================================
const assignmentRouter = express.Router();
assignmentRouter.use(authenticate);

// Get my assignments
assignmentRouter.get('/', asyncHandler(assignmentController.getMyAssignments));

// Get assignment workload for admins
assignmentRouter.get(
  '/managed',
  authorize('admin'),
  paginationValidation,
  validate,
  asyncHandler(assignmentController.getManagedAssignments),
);

// Get project assignments (project admin only)
assignmentRouter.get(
  '/project/:projectId',
  uuidValidation('projectId'),
  validate,
  checkProjectAdmin,
  asyncHandler(assignmentController.getProjectAssignments),
);

// Create assignment (project admin only)
assignmentRouter.post(
  '/',
  authorize('admin'),
  auditAction({
    actionType: 'create',
    entityType: 'project_assignment',
    resolveEntityId: (_req, _res, body) => body?.data?.id ?? null,
  }),
  assignmentValidation.create,
  validate,
  asyncHandler(assignmentController.createAssignment),
);

// Request to join project
assignmentRouter.post(
  '/join/:projectId',
  uuidValidation('projectId'),
  auditAction({
    actionType: 'create',
    entityType: 'project_assignment',
    resolveEntityId: (_req, _res, body) => body?.data?.id ?? null,
  }),
  validate,
  asyncHandler(assignmentController.requestJoinProject),
);

// Approve/reject assignment (project admin only)
assignmentRouter.put(
  '/:assignmentId',
  uuidValidation('assignmentId'),
  authorize('admin'),
  auditDynamicAction({
    entityType: 'project_assignment',
    resolveEntityId: (req) => req.params.assignmentId ?? null,
    resolveActionType: (req) => {
      if (req.body?.status === 'approved') {
        return 'approve';
      }
      if (req.body?.status === 'rejected') {
        return 'reject';
      }
      return null;
    },
    resolveNewValues: (req) => ({ status: req.body?.status }),
  }),
  assignmentValidation.update,
  validate,
  asyncHandler(assignmentController.updateAssignmentStatus),
);

// Remove assignment (project admin only)
assignmentRouter.delete(
  '/:assignmentId',
  uuidValidation('assignmentId'),
  authorize('admin'),
  auditAction({
    actionType: 'delete',
    entityType: 'project_assignment',
    resolveEntityId: (req) => req.params.assignmentId ?? null,
  }),
  validate,
  asyncHandler(assignmentController.removeAssignment),
);

// ============================================================================
// PHOTO ROUTES
// ============================================================================
const photoRouter = express.Router();
photoRouter.use(authenticate);

// Upload photo(s) to feature
photoRouter.post(
  '/feature/:featureId',
  uuidValidation('featureId'),
  validate,
  uploadMultiple,
  asyncHandler(photoController.uploadPhotos),
);

// Get photos for a feature
photoRouter.get(
  '/feature/:featureId',
  uuidValidation('featureId'),
  validate,
  asyncHandler(photoController.getFeaturePhotos),
);

// Get single photo (file)
photoRouter.get(
  '/:photoId',
  uuidValidation('photoId'),
  validate,
  asyncHandler(photoController.getPhoto),
);

// Delete photo
photoRouter.delete(
  '/:photoId',
  uuidValidation('photoId'),
  validate,
  asyncHandler(photoController.deletePhoto),
);

// Update photo order
photoRouter.put(
  '/:photoId/order',
  uuidValidation('photoId'),
  validate,
  asyncHandler(photoController.updatePhotoOrder),
);

// ============================================================================
// CATEGORY ROUTES
// ============================================================================
const categoryRouter = express.Router();
categoryRouter.use(authenticate);

// Get all categories
categoryRouter.get('/', asyncHandler(categoryController.getAll));

// Get single category
categoryRouter.get(
  '/:categoryId',
  uuidValidation('categoryId'),
  validate,
  asyncHandler(categoryController.getOne),
);

// Create category (admin only)
categoryRouter.post(
  '/',
  authorize('admin'),
  auditAction({
    actionType: 'create',
    entityType: 'project_category',
    resolveEntityId: (_req, _res, body) => body?.data?.id ?? null,
  }),
  categoryValidation.create,
  validate,
  asyncHandler(categoryController.create),
);

categoryRouter.post(
  '/icon',
  authorize('admin'),
  uploadCategoryIcon,
  asyncHandler(categoryController.uploadIcon),
);

// Update category (admin only)
categoryRouter.put(
  '/:categoryId',
  authorize('admin'),
  auditAction({
    actionType: 'update',
    entityType: 'project_category',
    resolveEntityId: (req) => req.params.categoryId ?? null,
  }),
  categoryValidation.update,
  validate,
  asyncHandler(categoryController.update),
);

// Delete category (admin only)
categoryRouter.delete(
  '/:categoryId',
  uuidValidation('categoryId'),
  authorize('admin'),
  auditAction({
    actionType: 'delete',
    entityType: 'project_category',
    resolveEntityId: (req) => req.params.categoryId ?? null,
  }),
  validate,
  asyncHandler(categoryController.delete),
);

// ============================================================================
// NOTIFICATION ROUTES
// ============================================================================
const notificationRouter = express.Router();
notificationRouter.use(authenticate);

// Get all notifications
notificationRouter.get(
  '/',
  paginationValidation,
  validate,
  asyncHandler(notificationController.getAll),
);

// Get unread count
notificationRouter.get('/unread/count', asyncHandler(notificationController.getUnreadCount));

// Mark notification as read
notificationRouter.put(
  '/:notificationId/read',
  uuidValidation('notificationId'),
  validate,
  asyncHandler(notificationController.markAsRead),
);

// Mark all as read
notificationRouter.put('/read-all', asyncHandler(notificationController.markAllAsRead));

// Delete notification
notificationRouter.delete(
  '/:notificationId',
  uuidValidation('notificationId'),
  validate,
  asyncHandler(notificationController.delete),
);

// ============================================================================
// SETTINGS ROUTES
// ============================================================================
const settingsRouter = express.Router();
settingsRouter.use(authenticate);

settingsRouter.get('/support', asyncHandler(settingsController.getSupport));
settingsRouter.put(
  '/support',
  authorize('admin'),
  asyncHandler(settingsController.updateSupport),
);

// ============================================================================
// USER MANAGEMENT ROUTES (Admin only)
// ============================================================================
const userRouter = express.Router();
userRouter.use(authenticate);
userRouter.use(authorize('admin'));

// Get all users
userRouter.get('/', paginationValidation, validate, asyncHandler(userController.getAll));

// Get contributor requests by workflow state
userRouter.get(
  '/contributor-requests',
  paginationValidation,
  validate,
  asyncHandler(userController.getContributorRequests),
);

// Create admin user (protected super admin only)
userRouter.post(
  '/admin',
  auditAction({
    actionType: 'create',
    entityType: 'user',
    resolveEntityId: (_req, _res, body) => body?.data?.id ?? null,
  }),
  userValidation.createAdmin,
  validate,
  asyncHandler(userController.createAdmin),
);

// Get single user
userRouter.get('/:userId', uuidValidation('userId'), validate, asyncHandler(userController.getOne));

// Update user
userRouter.put(
  '/:userId',
  uuidValidation('userId'),
  userValidation.adminUpdate,
  auditAction({
    actionType: 'update',
    entityType: 'user',
    resolveEntityId: (req) => req.params.userId ?? null,
  }),
  validate,
  asyncHandler(userController.updateUser),
);

// Promote/revert admin role (protected super admin only)
userRouter.post(
  '/:userId/toggle-admin-role',
  uuidValidation('userId'),
  validate,
  asyncHandler(userController.toggleAdminRole),
);

// Deactivate user
userRouter.post(
  '/:userId/deactivate',
  uuidValidation('userId'),
  auditAction({
    actionType: 'update',
    entityType: 'user',
    resolveEntityId: (req) => req.params.userId ?? null,
    resolveNewValues: () => ({ is_active: false }),
  }),
  validate,
  asyncHandler(userController.deactivate),
);

// Block user account
userRouter.post(
  '/:userId/block',
  uuidValidation('userId'),
  auditAction({
    actionType: 'update',
    entityType: 'user',
    resolveEntityId: (req) => req.params.userId ?? null,
    resolveNewValues: () => ({ is_active: false, account_state: 'blocked' }),
  }),
  validate,
  asyncHandler(userController.blockUser),
);

// Unblock user account
userRouter.post(
  '/:userId/unblock',
  uuidValidation('userId'),
  auditAction({
    actionType: 'update',
    entityType: 'user',
    resolveEntityId: (req) => req.params.userId ?? null,
    resolveNewValues: () => ({ is_active: true, account_state: 'active' }),
  }),
  validate,
  asyncHandler(userController.unblockUser),
);

// Approve contributor request
userRouter.post(
  '/:userId/approve-contributor',
  uuidValidation('userId'),
  auditAction({
    actionType: 'approve',
    entityType: 'user',
    resolveEntityId: (req) => req.params.userId ?? null,
    resolveNewValues: () => ({
      role: 'contributor',
      is_active: true,
      account_state: 'active',
    }),
  }),
  validate,
  asyncHandler(userController.approveContributor),
);

// Reject contributor request
userRouter.post(
  '/:userId/reject-contributor',
  uuidValidation('userId'),
  auditAction({
    actionType: 'reject',
    entityType: 'user',
    resolveEntityId: (req) => req.params.userId ?? null,
    resolveNewValues: () => ({
      role: 'contributor',
      is_active: false,
      account_state: 'rejected',
    }),
  }),
  validate,
  asyncHandler(userController.rejectContributor),
);

// Get user stats
userRouter.get(
  '/:userId/stats',
  uuidValidation('userId'),
  validate,
  asyncHandler(userController.getUserStats),
);

module.exports = {
  assignmentRouter,
  photoRouter,
  categoryRouter,
  notificationRouter,
  settingsRouter,
  userRouter,
};

export {};
