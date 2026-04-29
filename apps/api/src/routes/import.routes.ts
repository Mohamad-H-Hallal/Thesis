const express = require('express');
const router = express.Router();
const rateLimit = require('express-rate-limit');
const importController = require('../controllers/import.controller');
const { authenticate } = require('../middleware/auth');
const {
  importValidation,
  validate,
  paginationValidation,
  uuidValidation,
  bboxValidation,
  tileParamValidation,
} = require('../middleware/validation');
const { asyncHandler } = require('../middleware/error');
const { uploadImportFile } = require('../config/upload');
import { auditAction, auditDynamicAction } from '../middleware/audit';
import { validateEnv } from '../config/env';

const env = validateEnv();

const importReadLimiter = rateLimit({
  windowMs: env.RATE_LIMIT_WINDOW_MS,
  max: env.RATE_LIMIT_MAP_READ_MAX_REQUESTS,
  message: 'Too many import read requests, please slow down',
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => req.user?.id ?? req.ip,
});

router.use(authenticate);

router.get(
  '/',
  importReadLimiter,
  importValidation.list,
  paginationValidation,
  validate,
  asyncHandler(importController.listImports),
);

router.post(
  '/project/:projectId/upload',
  uuidValidation('projectId'),
  auditAction({
    actionType: 'create',
    entityType: 'gis_import_job',
    resolveEntityId: (_req, _res, body) => body?.data?.id ?? null,
  }),
  validate,
  uploadImportFile,
  asyncHandler(importController.uploadImport),
);

router.get(
  '/:importId',
  importReadLimiter,
  uuidValidation('importId'),
  validate,
  asyncHandler(importController.getImportDetails),
);

router.get(
  '/:importId/map',
  importReadLimiter,
  uuidValidation('importId'),
  bboxValidation,
  validate,
  asyncHandler(importController.getImportMapData),
);

router.get(
  '/:importId/tiles/:z/:x/:y',
  importReadLimiter,
  uuidValidation('importId'),
  tileParamValidation,
  validate,
  asyncHandler(importController.getImportMapTileData),
);

router.get(
  '/:importId/download',
  importReadLimiter,
  uuidValidation('importId'),
  validate,
  asyncHandler(importController.downloadImport),
);

router.get(
  '/:importId/comments',
  importReadLimiter,
  uuidValidation('importId'),
  validate,
  asyncHandler(importController.listImportComments),
);

router.get(
  '/:importId/features/:featureId',
  importReadLimiter,
  uuidValidation('importId'),
  uuidValidation('featureId'),
  validate,
  asyncHandler(importController.getImportFeatureDetails),
);

router.post(
  '/:importId/comments',
  auditDynamicAction({
    entityType: 'gis_import_job',
    resolveEntityId: (req) => req.params.importId ?? null,
    resolveActionType: () => 'comment',
    resolveNewValues: (req) => ({
      comment: req.body?.comment,
      feature_id: req.body?.feature_id,
    }),
  }),
  importValidation.comment,
  validate,
  asyncHandler(importController.addImportComment),
);

router.get(
  '/:importId/features',
  importReadLimiter,
  uuidValidation('importId'),
  importValidation.listFeatures,
  paginationValidation,
  validate,
  asyncHandler(importController.listImportFeatures),
);

router.post(
  '/:importId/review',
  auditDynamicAction({
    entityType: 'gis_import_job',
    resolveEntityId: (req) => req.params.importId ?? null,
    resolveActionType: (req) =>
      req.body?.status === 'approved'
        ? 'approve'
        : req.body?.status === 'rejected'
          ? 'reject'
          : null,
    resolveNewValues: (req) => ({
      status: req.body?.status,
      reason: req.body?.reason,
      feature_ids: req.body?.feature_ids,
    }),
  }),
  importValidation.review,
  validate,
  asyncHandler(importController.reviewImport),
);

module.exports = router;

export {};
