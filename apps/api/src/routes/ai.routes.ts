const express = require('express');
const aiController = require('../controllers/ai.controller');
const { authenticate, authorize, requireProtectedSuperAdmin } = require('../middleware/auth');
const {
  aiValidation,
  validate,
  paginationValidation,
  uuidValidation,
} = require('../middleware/validation');
const { asyncHandler } = require('../middleware/error');
const { aiJobRateLimit } = require('../middleware/workloadRateLimit');

const router = express.Router();

router.post(
  '/runs/:runId/callback',
  uuidValidation('runId'),
  validate,
  asyncHandler(aiController.handleAiRunCallback),
);

router.use(authenticate);

router.get(
  '/runs/:runId',
  uuidValidation('runId'),
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.getAiRun),
);

router.get(
  '/runs/:runId/metrics',
  uuidValidation('runId'),
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.listAiRunMetrics),
);

router.get(
  '/runs/:runId/layers',
  uuidValidation('runId'),
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.listAiRunLayers),
);

router.get(
  '/layers/:layerId/features',
  uuidValidation('layerId'),
  validate,
  asyncHandler(aiController.getAiLayerFeatures),
);

router.get(
  '/layers/:layerId/predictions',
  uuidValidation('layerId'),
  validate,
  asyncHandler(aiController.getAiLayerPredictions),
);

router.post(
  '/layers/:layerId/publish',
  aiJobRateLimit,
  uuidValidation('layerId'),
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.publishAiLayer),
);

router.post(
  '/layers/:layerId/unpublish',
  aiJobRateLimit,
  uuidValidation('layerId'),
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.unpublishAiLayer),
);

router.patch(
  '/prediction-validation-tasks/:taskId/assign',
  uuidValidation('taskId'),
  aiValidation.assignPredictionValidationTask,
  validate,
  authorize('admin'),
  asyncHandler(aiController.assignAiPredictionValidationTask),
);

router.patch(
  '/prediction-validation-tasks/:taskId/status',
  uuidValidation('taskId'),
  aiValidation.updatePredictionValidationTaskStatus,
  validate,
  authorize('admin'),
  asyncHandler(aiController.updateAiPredictionValidationTaskStatus),
);

router.post(
  '/prediction-validation-tasks/:taskId/review',
  uuidValidation('taskId'),
  aiValidation.reviewPredictionValidationTask,
  validate,
  authorize('admin'),
  asyncHandler(aiController.reviewAiPredictionValidationTask),
);

router.post(
  '/prediction-validation-tasks/:taskId/submissions',
  uuidValidation('taskId'),
  aiValidation.submitPredictionValidation,
  validate,
  asyncHandler(aiController.submitAiPredictionValidation),
);

router.get(
  '/prediction-validation-tasks/:taskId',
  uuidValidation('taskId'),
  validate,
  asyncHandler(aiController.getAiPredictionValidationTask),
);

router.get(
  '/runs/:runId/reviews',
  uuidValidation('runId'),
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.listAiRunReviews),
);

router.post(
  '/runs/:runId/review',
  aiJobRateLimit,
  uuidValidation('runId'),
  aiValidation.reviewRun,
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.reviewAiRun),
);

router.get(
  '/runs/:runId/logs',
  uuidValidation('runId'),
  paginationValidation,
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.listAiRunLogs),
);

module.exports = router;

export {};
