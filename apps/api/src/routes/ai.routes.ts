const express = require('express');
const aiController = require('../controllers/ai.controller');
const { authenticate, requireProtectedSuperAdmin } = require('../middleware/auth');
const {
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
  '/runs/:runId/logs',
  uuidValidation('runId'),
  paginationValidation,
  validate,
  asyncHandler(aiController.listAiRunLogs),
);

module.exports = router;

export {};
