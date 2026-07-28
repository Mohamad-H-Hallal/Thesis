const express = require('express');
const router = express.Router();
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

router.use(authenticate);

router.get(
  '/',
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
  asyncHandler(importController.preauthorizeImportUpload),
  uploadImportFile,
  asyncHandler(importController.uploadImport),
);

router.get(
  '/:importId',
  uuidValidation('importId'),
  validate,
  asyncHandler(importController.getImportDetails),
);

router.get(
  '/:importId/map',
  uuidValidation('importId'),
  bboxValidation,
  validate,
  asyncHandler(importController.getImportMapData),
);

router.get(
  '/:importId/quick-map',
  uuidValidation('importId'),
  validate,
  asyncHandler(importController.getImportQuickMapPreview),
);

router.get(
  '/:importId/tiles/:z/:x/:y',
  uuidValidation('importId'),
  tileParamValidation,
  validate,
  asyncHandler(importController.getImportMapTileData),
);

router.get(
  '/:importId/download',
  uuidValidation('importId'),
  validate,
  asyncHandler(importController.downloadImport),
);

router.get(
  '/:importId/comments',
  uuidValidation('importId'),
  validate,
  asyncHandler(importController.listImportComments),
);

router.get(
  '/:importId/features/:featureId',
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
      filters: req.body?.filters,
    }),
  }),
  importValidation.review,
  validate,
  asyncHandler(importController.reviewImport),
);

module.exports = router;

export {};
