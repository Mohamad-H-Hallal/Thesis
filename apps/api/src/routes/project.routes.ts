const express = require('express');
const router = express.Router();
const projectController = require('../controllers/project.controller');
const {
  authenticate,
  authorize,
  checkProjectAccess,
  checkProjectAdmin,
} = require('../middleware/auth');
const {
  projectValidation,
  validate,
  paginationValidation,
  uuidValidation,
} = require('../middleware/validation');
const { asyncHandler } = require('../middleware/error');
import { auditAction } from '../middleware/audit';

// All routes require authentication
router.use(authenticate);

// Get all projects (filtered by user access)
router.get(
  '/',
  paginationValidation,
  validate,
  asyncHandler(projectController.getAllProjects)
);

// Create new project (admin only)
router.post(
  '/',
  authorize('admin'),
  auditAction({
    actionType: 'create',
    entityType: 'project',
    resolveEntityId: (_req, _res, body) => body?.data?.id ?? null,
  }),
  projectValidation.create,
  validate,
  asyncHandler(projectController.createProject)
);

// Get single project
router.get(
  '/:projectId',
  uuidValidation('projectId'),
  validate,
  checkProjectAccess,
  asyncHandler(projectController.getProject)
);

// Update project (admin or project admin)
router.put(
  '/:projectId',
  uuidValidation('projectId'),
  checkProjectAdmin,
  auditAction({
    actionType: 'update',
    entityType: 'project',
    resolveEntityId: (req) => req.params.projectId ?? null,
  }),
  projectValidation.update,
  validate,
  asyncHandler(projectController.updateProject)
);

// Delete/Archive project (admin or project admin)
router.delete(
  '/:projectId',
  uuidValidation('projectId'),
  validate,
  checkProjectAdmin,
  auditAction({
    actionType: 'delete',
    entityType: 'project',
    resolveEntityId: (req) => req.params.projectId ?? null,
    resolveNewValues: () => ({ status: 'archived' }),
  }),
  asyncHandler(projectController.deleteProject)
);

// Get project statistics
router.get(
  '/:projectId/stats',
  uuidValidation('projectId'),
  validate,
  checkProjectAccess,
  asyncHandler(projectController.getProjectStats)
);

// Get project features
router.get(
  '/:projectId/features',
  uuidValidation('projectId'),
  paginationValidation,
  validate,
  checkProjectAccess,
  asyncHandler(projectController.getProjectFeatures)
);

module.exports = router;

export {};
