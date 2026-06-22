const express = require('express');
const aiController = require('../controllers/ai.controller');
const { authenticate } = require('../middleware/auth');
const {
  aiValidation,
  validate,
  paginationValidation,
} = require('../middleware/validation');
const { asyncHandler } = require('../middleware/error');

const router = express.Router();

router.use(authenticate);

router.get(
  '/ai-validation-tasks',
  paginationValidation,
  aiValidation.listPredictionValidationTasks,
  validate,
  asyncHandler(aiController.listMyAiValidationTasks),
);

module.exports = router;

export {};
