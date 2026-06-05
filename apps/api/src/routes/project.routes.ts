const express = require('express');
const router = express.Router();
const projectController = require('../controllers/project.controller');
const aiController = require('../controllers/ai.controller');
const {
  authenticate,
  authorize,
  checkProjectAccess,
  checkProjectAdmin,
  requireProtectedSuperAdmin,
} = require('../middleware/auth');
const {
  projectValidation,
  aiValidation,
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

router.get(
  '/:projectId/ai/readiness',
  uuidValidation('projectId'),
  aiValidation.readiness,
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.getProjectAiReadiness),
);

router.get(
  '/:projectId/ai/settings',
  uuidValidation('projectId'),
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.getProjectAiSettings),
);

router.put(
  '/:projectId/ai/settings',
  uuidValidation('projectId'),
  aiValidation.settings,
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.upsertProjectAiSettings),
);

router.patch(
  '/:projectId/ai/settings',
  uuidValidation('projectId'),
  aiValidation.settings,
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.upsertProjectAiSettings),
);

router.post(
  '/:projectId/ai/runs',
  uuidValidation('projectId'),
  aiValidation.createRun,
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.createProjectAiRun),
);

router.get(
  '/:projectId/ai/runs',
  uuidValidation('projectId'),
  paginationValidation,
  aiValidation.listRuns,
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.listProjectAiRuns),
);

module.exports = router;

export {};
