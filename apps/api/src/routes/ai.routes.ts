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
router.use(requireProtectedSuperAdmin);

router.get(
  '/runs/:runId',
  uuidValidation('runId'),
  validate,
  asyncHandler(aiController.getAiRun),
);

router.get(
  '/runs/:runId/metrics',
  uuidValidation('runId'),
  validate,
  asyncHandler(aiController.listAiRunMetrics),
);

router.get(
  '/runs/:runId/layers',
  uuidValidation('runId'),
  validate,
  asyncHandler(aiController.listAiRunLayers),
);

router.get(
  '/layers/:layerId/features',
  uuidValidation('layerId'),
  validate,
  asyncHandler(aiController.getAiLayerFeatures),
);

router.get(
  '/runs/:runId/reviews',
  uuidValidation('runId'),
  validate,
  asyncHandler(aiController.listAiRunReviews),
);

router.post(
  '/runs/:runId/review',
  uuidValidation('runId'),
  aiValidation.reviewRun,
  validate,
  asyncHandler(aiController.reviewAiRun),
);

router.get(
  '/runs/:runId/logs',
  uuidValidation('runId'),
  paginationValidation,
  validate,
  asyncHandler(aiController.listAiRunLogs),
);

module.exports = router;

export {};
