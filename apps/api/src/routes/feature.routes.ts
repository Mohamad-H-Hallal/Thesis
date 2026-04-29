const express = require('express');
const router = express.Router();
const rateLimit = require('express-rate-limit');
const featureController = require('../controllers/feature.controller');
const { authenticate } = require('../middleware/auth');
const {
  featureValidation,
  validate,
  paginationValidation,
  bboxValidation,
  bboxPaginationValidation,
  tileParamValidation,
  tileFeatureQueryValidation,
  uuidValidation,
} = require('../middleware/validation');
const { asyncHandler } = require('../middleware/error');
import { auditAction, auditDynamicAction } from '../middleware/audit';
import { validateEnv } from '../config/env';

const env = validateEnv();

const featureReadLimiter = rateLimit({
  windowMs: env.RATE_LIMIT_WINDOW_MS,
  max: env.RATE_LIMIT_MAP_READ_MAX_REQUESTS,
  message: 'Too many map read requests, please slow down',
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => req.user?.id ?? req.ip,
});

// All routes require authentication
router.use(authenticate);

// Get all features (with filters)
router.get(
  '/',
  featureReadLimiter,
  paginationValidation,
  validate,
  asyncHandler(featureController.getAllFeatures)
);

// Spatial query: Find features nearby
router.get('/nearby', featureReadLimiter, asyncHandler(featureController.findFeaturesNearby));

// Spatial query: BBOX for map rendering
router.get('/bbox', featureReadLimiter, bboxValidation, bboxPaginationValidation, validate, asyncHandler(featureController.findFeaturesByBbox));

// Spatial query: XYZ tile delivery for map rendering
router.get('/tiles/:z/:x/:y', featureReadLimiter, tileParamValidation, tileFeatureQueryValidation, validate, asyncHandler(featureController.findFeaturesTile));

// Create new feature
router.post(
  '/',
  auditAction({
    actionType: 'create',
    entityType: 'spatial_feature',
    resolveEntityId: (_req, _res, body) => body?.data?.id ?? null,
  }),
  featureValidation.create,
  validate,
  asyncHandler(featureController.createFeature)
);

// Batch create features (offline sync)
router.post('/batch', asyncHandler(featureController.batchCreateFeatures));

// Get single feature
router.get(
  '/:featureId',
  featureReadLimiter,
  uuidValidation('featureId'),
  validate,
  asyncHandler(featureController.getFeature)
);

// Update feature
router.put(
  '/:featureId',
  uuidValidation('featureId'),
  auditAction({
    actionType: 'update',
    entityType: 'spatial_feature',
    resolveEntityId: (req) => req.params.featureId ?? null,
  }),
  featureValidation.update,
  validate,
  asyncHandler(featureController.updateFeature)
);

// Delete feature
router.delete(
  '/:featureId',
  uuidValidation('featureId'),
  auditAction({
    actionType: 'delete',
    entityType: 'spatial_feature',
    resolveEntityId: (req) => req.params.featureId ?? null,
  }),
  validate,
  asyncHandler(featureController.deleteFeature)
);

// Submit feature for review
router.post(
  '/:featureId/submit',
  uuidValidation('featureId'),
  auditAction({
    actionType: 'update',
    entityType: 'spatial_feature',
    resolveEntityId: (req) => req.params.featureId ?? null,
    resolveNewValues: () => ({ status: 'pending_review' }),
  }),
  validate,
  asyncHandler(featureController.submitFeature)
);

// Review feature (approve/reject) - admin or project admin only
router.post(
  '/:featureId/review',
  uuidValidation('featureId'),
  auditDynamicAction({
    entityType: 'spatial_feature',
    resolveEntityId: (req) => req.params.featureId ?? null,
    resolveActionType: (req) => {
      if (req.body?.status === 'approved') {
        return 'approve';
      }
      if (req.body?.status === 'rejected') {
        return 'reject';
      }
      return null;
    },
    resolveNewValues: (req) => ({
      status: req.body?.status,
      review_notes: req.body?.review_notes,
    }),
  }),
  featureValidation.review,
  validate,
  asyncHandler(featureController.reviewFeature)
);

module.exports = router;

export {};
