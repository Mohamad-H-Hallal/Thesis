const express = require('express');
const aiController = require('../controllers/ai.controller');
const { authenticate, requireProtectedSuperAdmin } = require('../middleware/auth');
const {
  aiValidation,
  validate,
  paginationValidation,
  uuidValidation,
} = require('../middleware/validation');
const { asyncHandler } = require('../middleware/error');

const router = express.Router();

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
  uuidValidation('layerId'),
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.publishAiLayer),
);

router.post(
  '/layers/:layerId/unpublish',
  uuidValidation('layerId'),
  validate,
  requireProtectedSuperAdmin,
  asyncHandler(aiController.unpublishAiLayer),
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
