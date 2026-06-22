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
const { uploadMultiple } = require('../config/upload');
import { auditAction } from '../middleware/audit';

// All routes require authentication
router.use(authenticate);

// Get all projects (filtered by user access)
router.get('/', paginationValidation, validate, asyncHandler(projectController.getAllProjects));

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
  asyncHandler(projectController.createProject),
);

// Get single project
router.get(
  '/:projectId',
  uuidValidation('projectId'),
  validate,
  checkProjectAccess,
  asyncHandler(projectController.getProject),
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
  asyncHandler(projectController.updateProject),
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
  asyncHandler(projectController.deleteProject),
);

// Get project statistics
router.get(
  '/:projectId/stats',
  uuidValidation('projectId'),
  validate,
  checkProjectAccess,
  asyncHandler(projectController.getProjectStats),
);

router.get(
  '/:projectId/offline-package',
  uuidValidation('projectId'),
  validate,
  checkProjectAccess,
  asyncHandler(projectController.getProjectOfflinePackage),
);

// Get project features
router.get(
  '/:projectId/features',
  uuidValidation('projectId'),
  paginationValidation,
  validate,
  checkProjectAccess,
  asyncHandler(projectController.getProjectFeatures),
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
  '/:projectId/ai/published-layers',
  uuidValidation('projectId'),
  validate,
  checkProjectAccess,
  asyncHandler(aiController.listProjectPublishedAiLayers),
);

router.get(
  '/:projectId/ai/published-predictions',
  uuidValidation('projectId'),
  validate,
  checkProjectAccess,
  asyncHandler(aiController.listProjectPublishedAiPredictions),
);

router.get(
  '/:projectId/ai/runs/:runId/validation-summary',
  uuidValidation('projectId'),
  uuidValidation('runId'),
  validate,
  checkProjectAccess,
  asyncHandler(aiController.getProjectAiRunValidationSummary),
);

router.get(
  '/:projectId/ai/runs/:runId/validations',
  uuidValidation('projectId'),
  uuidValidation('runId'),
  paginationValidation,
  validate,
  authorize('admin'),
  asyncHandler(aiController.listProjectAiRunValidations),
);

router.get(
  '/:projectId/ai/runs/:runId/predictions/:predictionId',
  uuidValidation('projectId'),
  uuidValidation('runId'),
  uuidValidation('predictionId'),
  validate,
  checkProjectAccess,
  asyncHandler(aiController.getProjectAiPredictionDetails),
);

router.post(
  '/:projectId/ai/predictions/:predictionId/validation-photos',
  uuidValidation('projectId'),
  uuidValidation('predictionId'),
  validate,
  checkProjectAccess,
  uploadMultiple,
  asyncHandler(aiController.uploadProjectAiPredictionValidationPhotos),
);

router.post(
  '/:projectId/ai/predictions/:predictionId/validations',
  uuidValidation('projectId'),
  uuidValidation('predictionId'),
  aiValidation.submitPredictionFeatureValidation,
  validate,
  checkProjectAccess,
  asyncHandler(aiController.submitProjectAiPredictionValidation),
);

router.get(
  '/:projectId/ai/predictions/:predictionId/my-validation',
  uuidValidation('projectId'),
  uuidValidation('predictionId'),
  validate,
  checkProjectAccess,
  asyncHandler(aiController.getMyProjectAiPredictionValidation),
);

router.get(
  '/:projectId/ai/predictions/:predictionId/validations',
  uuidValidation('projectId'),
  uuidValidation('predictionId'),
  validate,
  authorize('admin'),
  asyncHandler(aiController.listProjectAiPredictionValidations),
);

router.post(
  '/:projectId/ai/predictions/:predictionId/admin-review',
  uuidValidation('projectId'),
  uuidValidation('predictionId'),
  aiValidation.reviewPredictionFeature,
  validate,
  authorize('admin'),
  asyncHandler(aiController.reviewProjectAiPrediction),
);

router.get(
  '/:projectId/ai/prediction-validation-tasks',
  uuidValidation('projectId'),
  paginationValidation,
  aiValidation.listPredictionValidationTasks,
  validate,
  authorize('admin'),
  asyncHandler(aiController.listProjectAiPredictionValidationTasks),
);

router.post(
  '/:projectId/ai/prediction-validation-tasks/generate',
  uuidValidation('projectId'),
  aiValidation.generatePredictionValidationTasks,
  validate,
  authorize('admin'),
  asyncHandler(aiController.generateProjectAiPredictionValidationTasks),
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

router.get(
  '/:projectId/ai/runs/:runId',
  uuidValidation('projectId'),
  uuidValidation('runId'),
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.getProjectAiRun),
);

router.get(
  '/:projectId/ai/runs/:runId/status',
  uuidValidation('projectId'),
  uuidValidation('runId'),
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.getProjectAiRunStatus),
);

router.post(
  '/:projectId/ai/runs/:runId/publish',
  uuidValidation('projectId'),
  uuidValidation('runId'),
  validate,
  authorize('admin'),
  asyncHandler(aiController.publishProjectAiRun),
);

router.post(
  '/:projectId/ai/runs/:runId/unpublish',
  uuidValidation('projectId'),
  uuidValidation('runId'),
  validate,
  authorize('admin'),
  asyncHandler(aiController.unpublishProjectAiRun),
);

router.post(
  '/:projectId/ai/runs/:runId/cancel',
  uuidValidation('projectId'),
  uuidValidation('runId'),
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.cancelProjectAiRun),
);

router.post(
  '/:projectId/ai/runs/:runId/resume',
  uuidValidation('projectId'),
  uuidValidation('runId'),
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.resumeProjectAiRun),
);

router.post(
  '/:projectId/ai/runs/:runId/retrain-check',
  uuidValidation('projectId'),
  uuidValidation('runId'),
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.retrainCheckProjectAiRun),
);

router.post(
  '/:projectId/ai/retrain-check',
  uuidValidation('projectId'),
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.retrainCheckProjectAiRun),
);

module.exports = router;

export {};
