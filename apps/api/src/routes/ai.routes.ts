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

router.patch(
  '/uncertainty-areas/:id/assign',
  uuidValidation('id'),
  aiValidation.assignUncertaintyArea,
  validate,
  authorize('admin'),
  asyncHandler(aiController.assignUncertaintyArea),
);

router.patch(
  '/uncertainty-areas/:id/status',
  uuidValidation('id'),
  aiValidation.updateUncertaintyAreaStatus,
  validate,
  authorize('admin'),
  asyncHandler(aiController.updateUncertaintyAreaStatus),
);

router.post(
  '/uncertainty-areas/:id/submit-validation',
  uuidValidation('id'),
  aiValidation.submitUncertaintyValidation,
  validate,
  asyncHandler(aiController.submitUncertaintyValidation),
);

router.get(
  '/uncertainty-areas/:id',
  uuidValidation('id'),
  validate,
  asyncHandler(aiController.getUncertaintyArea),
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
