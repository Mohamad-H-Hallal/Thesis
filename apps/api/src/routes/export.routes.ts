const express = require('express');
const router = express.Router();
const rateLimit = require('express-rate-limit');
const exportController = require('../controllers/export.controller');
const { authenticate, checkProjectAccess } = require('../middleware/auth');
const { exportValidation, validate, uuidValidation } = require('../middleware/validation');
const { asyncHandler } = require('../middleware/error');
import { auditAction } from '../middleware/audit';
import { validateEnv } from '../config/env';

const env = validateEnv();

const exportCreateLimiter = rateLimit({
  windowMs: env.RATE_LIMIT_WINDOW_MS,
  max: env.RATE_LIMIT_EXPORT_MAX_REQUESTS,
  message: 'Too many export requests, please slow down',
  standardHeaders: true,
  legacyHeaders: false,
});

// All routes require authentication
router.use(authenticate);

// Request new export for a project
router.post(
  '/project/:projectId',
  exportCreateLimiter,
  uuidValidation('projectId'),
  checkProjectAccess,
  auditAction({
    actionType: 'export',
    entityType: 'shapefile_export',
    resolveEntityId: (_req, _res, body) => body?.data?.export_id ?? null,
  }),
  exportValidation.create,
  validate,
  asyncHandler(exportController.requestExport)
);

// Get all my exports
router.get('/', asyncHandler(exportController.getMyExports));

// Get single export status
router.get(
  '/:exportId',
  uuidValidation('exportId'),
  validate,
  asyncHandler(exportController.getExportStatus)
);

// Download export file
router.get(
  '/:exportId/download',
  uuidValidation('exportId'),
  auditAction({
    actionType: 'export',
    entityType: 'shapefile_export',
    resolveEntityId: (req) => req.params.exportId ?? null,
    resolveNewValues: () => ({ event: 'download_export' }),
  }),
  validate,
  asyncHandler(exportController.downloadExport)
);

module.exports = router;

export {};
