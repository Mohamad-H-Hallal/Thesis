import express from 'express';
import { body, header, param, query } from 'express-validator';
import {
  cancelMyPrivacyRequest,
  createContentReport,
  createExportGrant,
  createPrivacyRequest,
  downloadPersonalDataExport,
  getAccountDeletionEligibility,
  getContentReportForAdmin,
  getMyPrivacyRequest,
  getPrivacyAdminQueueCounts,
  getPrivacyRequestForAdmin,
  listContentReportsForAdmin,
  listMyContentReports,
  listMyPrivacyRequests,
  listPrivacyRequestsForAdmin,
  retryPrivacyRequestExecution,
  updateContentReportForAdmin,
  updatePrivacyRequestForAdmin,
} from '../controllers/privacy.controller';
import { authenticate, checkProjectAccess, requireProtectedSuperAdmin } from '../middleware/auth';
import { auditAction } from '../middleware/audit';
import { asyncHandler } from '../middleware/error';
import { validate } from '../middleware/validation';
import { contentReportRateLimit, privacyRequestRateLimit } from '../middleware/workloadRateLimit';

const privacyRouter = express.Router();
privacyRouter.use(authenticate);

privacyRouter.get('/account-deletion/eligibility', asyncHandler(getAccountDeletionEligibility));
privacyRouter.get('/requests', asyncHandler(listMyPrivacyRequests));
privacyRouter.get(
  '/requests/:requestId',
  param('requestId').isUUID(),
  validate,
  asyncHandler(getMyPrivacyRequest),
);
privacyRouter.post(
  '/requests',
  privacyRequestRateLimit,
  body('request_type').isIn([
    'access_export',
    'correction',
    'deletion',
    'restriction',
    'objection',
  ]),
  body('current_password').optional().isString().isLength({ min: 1, max: 256 }),
  body('details').optional().isObject(),
  validate,
  auditAction({
    actionType: 'create',
    entityType: 'privacy_request',
    resolveEntityId: (_req, _res, responseBody) => responseBody?.data?.id ?? null,
    resolveNewValues: (req) => ({
      request_type: req.body?.request_type,
      identity_verified: ['deletion', 'access_export'].includes(req.body?.request_type),
      details_present: Boolean(req.body?.details),
    }),
  }),
  asyncHandler(createPrivacyRequest),
);
privacyRouter.post(
  '/requests/:requestId/cancel',
  privacyRequestRateLimit,
  param('requestId').isUUID(),
  validate,
  auditAction({
    actionType: 'update',
    entityType: 'privacy_request',
    resolveEntityId: (req) => req.params.requestId,
    resolveNewValues: () => ({ status: 'cancelled' }),
  }),
  asyncHandler(cancelMyPrivacyRequest),
);
privacyRouter.post(
  '/requests/:requestId/export-grant',
  privacyRequestRateLimit,
  param('requestId').isUUID(),
  body('current_password').isString().isLength({ min: 1, max: 256 }),
  validate,
  auditAction({
    actionType: 'export',
    entityType: 'privacy_request',
    resolveEntityId: (req) => req.params.requestId,
    resolveNewValues: () => ({ event: 'personal_data_export_download_grant_created' }),
  }),
  asyncHandler(createExportGrant),
);
privacyRouter.get(
  '/exports/:artifactId/download',
  param('artifactId').isUUID(),
  header('x-privacy-export-grant').isString().isLength({ min: 20, max: 128 }),
  validate,
  asyncHandler(downloadPersonalDataExport),
);

privacyRouter.get(
  '/admin/requests',
  requireProtectedSuperAdmin,
  query('page').optional().isInt({ min: 1 }),
  query('limit').optional().isInt({ min: 1, max: 100 }),
  query('status')
    .optional()
    .isIn([
      'pending_verification',
      'submitted',
      'in_review',
      'scheduled',
      'processing',
      'failed',
      'rejected',
      'completed',
      'cancelled',
    ]),
  query('request_type')
    .optional()
    .isIn(['access_export', 'correction', 'deletion', 'restriction', 'objection']),
  query('q').optional().isString().isLength({ max: 120 }),
  validate,
  asyncHandler(listPrivacyRequestsForAdmin),
);
privacyRouter.get(
  '/admin/queue-counts',
  requireProtectedSuperAdmin,
  asyncHandler(getPrivacyAdminQueueCounts),
);
privacyRouter.get(
  '/admin/requests/:requestId',
  requireProtectedSuperAdmin,
  param('requestId').isUUID(),
  validate,
  asyncHandler(getPrivacyRequestForAdmin),
);
privacyRouter.patch(
  '/admin/requests/:requestId',
  requireProtectedSuperAdmin,
  param('requestId').isUUID(),
  body('status').isIn(['in_review', 'approved', 'rejected']),
  body('user_message').optional().isString().isLength({ max: 1000 }),
  body('resolution_code').optional().isString().isLength({ max: 120 }),
  body('unfinished_work_decision')
    .optional()
    .isIn(['require_resolution', 'discard_unapproved']),
  body('responsibility_decision').optional().isIn(['release', 'confirmed_transferred']),
  validate,
  auditAction({
    actionType: 'update',
    entityType: 'privacy_request',
    resolveEntityId: (req) => req.params.requestId,
  }),
  asyncHandler(updatePrivacyRequestForAdmin),
);
privacyRouter.post(
  '/admin/requests/:requestId/retry',
  requireProtectedSuperAdmin,
  param('requestId').isUUID(),
  body('user_message').optional().isString().isLength({ max: 1000 }),
  validate,
  auditAction({
    actionType: 'update',
    entityType: 'privacy_request',
    resolveEntityId: (req) => req.params.requestId,
    resolveNewValues: () => ({ event: 'privacy_execution_retry_requested' }),
  }),
  asyncHandler(retryPrivacyRequestExecution),
);

privacyRouter.post(
  '/content-reports',
  contentReportRateLimit,
  body('project_id').isUUID(),
  body('entity_type').isIn([
    'project',
    'feature',
    'photo',
    'import',
    'comment',
    'ai_output',
    'user',
  ]),
  body('entity_id').isUUID(),
  body('reason_code').isIn([
    'privacy',
    'sensitive_location',
    'unauthorized_content',
    'harassment',
    'illegal_content',
    'copyright_or_license',
    'misleading_or_inaccurate',
    'other',
  ]),
  body('description')
    .optional()
    .isString()
    .isLength({ max: 2000 })
    .custom((value, { req }) => {
      if (req.body.reason_code === 'other' && String(value ?? '').trim().length < 10) {
        throw new Error('Describe the issue in at least 10 characters when selecting Other.');
      }
      return true;
    }),
  validate,
  checkProjectAccess,
  auditAction({
    actionType: 'create',
    entityType: 'content_report',
    resolveEntityId: (_req, _res, responseBody) => responseBody?.data?.id ?? null,
  }),
  asyncHandler(createContentReport),
);
privacyRouter.get('/content-reports', asyncHandler(listMyContentReports));
privacyRouter.get(
  '/admin/content-reports',
  requireProtectedSuperAdmin,
  query('page').optional().isInt({ min: 1 }),
  query('limit').optional().isInt({ min: 1, max: 100 }),
  query('status').optional().isIn(['submitted', 'in_review', 'resolved', 'dismissed']),
  query('entity_type')
    .optional()
    .isIn(['project', 'feature', 'photo', 'import', 'comment', 'ai_output', 'user']),
  query('q').optional().isString().isLength({ max: 120 }),
  validate,
  asyncHandler(listContentReportsForAdmin),
);
privacyRouter.get(
  '/admin/content-reports/:reportId',
  requireProtectedSuperAdmin,
  param('reportId').isUUID(),
  validate,
  asyncHandler(getContentReportForAdmin),
);
privacyRouter.patch(
  '/admin/content-reports/:reportId',
  requireProtectedSuperAdmin,
  param('reportId').isUUID(),
  body('status').isIn(['in_review', 'resolved', 'dismissed']),
  body('outcome_code').optional().isString().isLength({ max: 120 }),
  body('user_message').optional().isString().isLength({ max: 1000 }),
  validate,
  auditAction({
    actionType: 'update',
    entityType: 'content_report',
    resolveEntityId: (req) => req.params.reportId,
  }),
  asyncHandler(updateContentReportForAdmin),
);

export { privacyRouter };
