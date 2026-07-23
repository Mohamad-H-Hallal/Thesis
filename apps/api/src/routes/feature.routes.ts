const express = require('express');
const router = express.Router();
const featureController = require('../controllers/feature.controller');
const offlineSyncController = require('../controllers/offlineSync.controller');
const { authenticate } = require('../middleware/auth');
const { uploadOfflineFeatureBundle } = require('../config/upload');
const {
  offlineBundleRateLimit,
  offlineSyncRateLimit,
} = require('../middleware/offlineSyncRateLimit');
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

// All routes require authentication
router.use(authenticate);

// Synchronize one project-scoped offline contribution and its attachments as
// one idempotent operation. Keep this above the dynamic feature-id routes.
router.post(
  '/offline-sync',
  offlineBundleRateLimit,
  asyncHandler(offlineSyncController.preauthorizeOfflineFeatureBundle),
  uploadOfflineFeatureBundle,
  auditDynamicAction({
    entityType: 'spatial_feature',
    resolveEntityId: (_req, _res, body) => body?.data?.id ?? null,
    resolveActionType: (_req, res) =>
      res.locals.offlineSyncAudit?.operation === 'create' ? 'create' : 'update',
    resolveNewValues: (_req, res) => res.locals.offlineSyncAudit ?? null,
  }),
  asyncHandler(offlineSyncController.syncOfflineFeatureBundle),
);

// Get all features (with filters)
router.get('/', paginationValidation, validate, asyncHandler(featureController.getAllFeatures));

// Spatial query: Find features nearby
router.get('/nearby', asyncHandler(featureController.findFeaturesNearby));

// Spatial query: BBOX for map rendering
router.get(
  '/bbox',
  bboxValidation,
  bboxPaginationValidation,
  validate,
  asyncHandler(featureController.findFeaturesByBbox),
);

// Spatial query: XYZ tile delivery for map rendering
router.get(
  '/tiles/:z/:x/:y',
  tileParamValidation,
  tileFeatureQueryValidation,
  validate,
  asyncHandler(featureController.findFeaturesTile),
);

// Create new feature
router.post(
  '/',
  offlineSyncRateLimit,
  auditAction({
    actionType: 'create',
    entityType: 'spatial_feature',
    resolveEntityId: (_req, _res, body) => body?.data?.id ?? null,
  }),
  featureValidation.create,
  validate,
  asyncHandler(featureController.createFeature),
);

// Batch create features (offline sync)
router.post(
  '/batch',
  offlineSyncRateLimit,
  featureValidation.batchCreate,
  validate,
  asyncHandler(featureController.batchCreateFeatures),
);

// Get single feature
router.get(
  '/:featureId',
  uuidValidation('featureId'),
  validate,
  asyncHandler(featureController.getFeature),
);

// Update feature
router.put(
  '/:featureId',
  uuidValidation('featureId'),
  offlineSyncRateLimit,
  auditAction({
    actionType: 'update',
    entityType: 'spatial_feature',
    resolveEntityId: (req) => req.params.featureId ?? null,
  }),
  featureValidation.update,
  validate,
  asyncHandler(featureController.updateFeature),
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
  asyncHandler(featureController.deleteFeature),
);

// Submit feature for review
router.post(
  '/:featureId/submit',
  uuidValidation('featureId'),
  offlineSyncRateLimit,
  auditAction({
    actionType: 'update',
    entityType: 'spatial_feature',
    resolveEntityId: (req) => req.params.featureId ?? null,
    resolveNewValues: () => ({ status: 'pending_review' }),
  }),
  validate,
  asyncHandler(featureController.submitFeature),
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
  asyncHandler(featureController.reviewFeature),
);

module.exports = router;

export {};
