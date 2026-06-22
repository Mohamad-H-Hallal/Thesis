import {
  body,
  param,
  query as queryParam,
  validationResult,
  type ValidationChain,
} from 'express-validator';
import type { NextFunction, Request, Response } from 'express';

const strongPasswordPattern = /^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[^A-Za-z\d]).{8,}$/;
const phonePattern = /^\d{8}$/;
const digitsOnly = (value: unknown): string => String(value ?? '').replace(/\D/g, '');

// Validation error handler
const validate = (req: Request, res: Response, next: NextFunction): Response | void => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) {
    return res.status(400).json({
      success: false,
      message: 'Validation failed',
      errors: errors.array(),
    });
  }
  next();
};

// User validation rules
const userValidation = {
  register: [
    body('email').trim().isEmail().normalizeEmail().withMessage('Valid email is required'),
    body('password')
      .isString()
      .withMessage('Password must be a string')
      .isLength({ min: 8 })
      .withMessage('Password must be at least 8 characters')
      .matches(strongPasswordPattern)
      .withMessage('Password must include uppercase, lowercase, number, and special character'),
    body('full_name').trim().notEmpty().withMessage('Full name is required'),
    body('phone')
      .customSanitizer(digitsOnly)
      .trim()
      .notEmpty()
      .withMessage('Enter a valid phone number.')
      .matches(phonePattern)
      .withMessage('Enter a valid phone number.'),
    body('role').isIn(['contributor', 'viewer']).withMessage('Role must be contributor or viewer'),
  ] as ValidationChain[],
  login: [
    body('email').trim().isEmail().normalizeEmail().withMessage('Valid email is required'),
    body('password')
      .isString()
      .withMessage('Password is required')
      .notEmpty()
      .withMessage('Password is required'),
  ] as ValidationChain[],
  update: [
    body('full_name').optional().trim().notEmpty(),
    body('phone')
      .optional()
      .customSanitizer(digitsOnly)
      .matches(phonePattern)
      .withMessage('Enter a valid phone number.'),
    body('email').optional().isEmail().normalizeEmail(),
  ] as ValidationChain[],
  changePassword: [
    body('current_password')
      .isString()
      .withMessage('Current password is required')
      .notEmpty()
      .withMessage('Current password is required'),
    body('new_password')
      .isString()
      .withMessage('New password must be a string')
      .isLength({ min: 8 })
      .withMessage('New password must be at least 8 characters')
      .matches(strongPasswordPattern)
      .withMessage('New password must include uppercase, lowercase, number, and special character')
      .custom((value, { req }) => value !== req.body.current_password)
      .withMessage('New password must be different from current password'),
  ] as ValidationChain[],
  createAdmin: [
    body('email').trim().isEmail().normalizeEmail().withMessage('Valid email is required'),
    body('password')
      .isString()
      .withMessage('Password must be a string')
      .isLength({ min: 8 })
      .withMessage('Password must be at least 8 characters')
      .matches(strongPasswordPattern)
      .withMessage('Password must include uppercase, lowercase, number, and special character'),
    body('full_name').trim().notEmpty().withMessage('Full name is required'),
    body('phone')
      .optional()
      .customSanitizer(digitsOnly)
      .matches(phonePattern)
      .withMessage('Enter a valid phone number.'),
  ] as ValidationChain[],
  adminUpdate: [
    body('full_name').optional().trim().notEmpty().withMessage('Full name cannot be empty'),
    body('phone')
      .optional()
      .customSanitizer(digitsOnly)
      .matches(phonePattern)
      .withMessage('Enter a valid phone number.'),
    body('role')
      .optional()
      .isIn(['admin', 'contributor', 'viewer'])
      .withMessage('Role must be admin, contributor, or viewer'),
    body('is_active').optional().isBoolean().withMessage('is_active must be a boolean'),
  ] as ValidationChain[],
  toggleAdminRole: [
    body('force_unassign').optional().isBoolean().withMessage('force_unassign must be a boolean'),
  ] as ValidationChain[],
  refreshToken: [
    body('refresh_token')
      .isString()
      .withMessage('Refresh token is required')
      .notEmpty()
      .withMessage('Refresh token is required')
      .isJWT()
      .withMessage('Refresh token format is invalid'),
  ] as ValidationChain[],
  forgotPassword: [
    body('email').trim().isEmail().normalizeEmail().withMessage('Valid email is required'),
  ] as ValidationChain[],
  verifyResetOtp: [
    body('email').trim().isEmail().normalizeEmail().withMessage('Valid email is required'),
    body('otp')
      .trim()
      .matches(/^\d{6}$/)
      .withMessage('Enter the 6-digit verification code'),
  ] as ValidationChain[],
  resetPassword: [
    body('reset_token')
      .isString()
      .withMessage('Password reset session is required')
      .notEmpty()
      .withMessage('Password reset session is required'),
    body('new_password')
      .isString()
      .withMessage('New password must be a string')
      .isLength({ min: 8 })
      .withMessage('New password must be at least 8 characters')
      .matches(strongPasswordPattern)
      .withMessage('New password must include uppercase, lowercase, number, and special character'),
  ] as ValidationChain[],
};

// Project validation rules
const projectValidation = {
  create: [
    body('name').trim().notEmpty().withMessage('Project name is required'),
    body('description').optional().trim(),
    body('category_id').isUUID().withMessage('Valid category ID is required'),
    body('status').optional().isIn(['draft', 'active', 'paused', 'completed', 'archived']),
    body('collection_form_schema')
      .isObject()
      .withMessage('Form schema must be a valid JSON object'),
    body('requires_photos').optional().isBoolean(),
    body('min_photos').optional().isInt({ min: 0 }),
    body('max_photos').optional().isInt({ min: 0 }),
    body('visible_to_viewers').optional().isBoolean(),
    body('visible_to_contributors').optional().isBoolean(),
    body('start_date')
      .optional({ nullable: true })
      .isISO8601()
      .withMessage('start_date must be a valid date'),
    body('end_date')
      .optional({ nullable: true })
      .isISO8601()
      .withMessage('end_date must be a valid date'),
  ] as ValidationChain[],
  update: [
    param('projectId').isUUID().withMessage('Valid project ID is required'),
    body('name').optional().trim().notEmpty(),
    body('description').optional().trim(),
    body('status').optional().isIn(['draft', 'active', 'paused', 'completed', 'archived']),
    body('collection_form_schema').optional().isObject(),
    body('category_id').optional().isUUID().withMessage('category_id must be a valid UUID'),
    body('requires_photos').optional().isBoolean(),
    body('min_photos').optional().isInt({ min: 0 }),
    body('max_photos').optional().isInt({ min: 0 }),
    body('visible_to_viewers').optional().isBoolean(),
    body('visible_to_contributors').optional().isBoolean(),
    body('start_date')
      .optional({ nullable: true })
      .isISO8601()
      .withMessage('start_date must be a valid date'),
    body('end_date')
      .optional({ nullable: true })
      .isISO8601()
      .withMessage('end_date must be a valid date'),
  ] as ValidationChain[],
};

// Feature validation rules
const featureValidation = {
  create: [
    body('id').optional().isUUID().withMessage('Valid feature ID is required'),
    body('project_id').isUUID().withMessage('Valid project ID is required'),
    body('geom').notEmpty().withMessage('Geometry is required'),
    body('geom.type').isIn(['Point', 'LineString', 'Polygon']).withMessage('Invalid geometry type'),
    body('geom.coordinates').isArray().withMessage('Coordinates must be an array'),
    body('attributes').isObject().withMessage('Attributes must be a JSON object'),
    body('accuracy_meters')
      .customSanitizer((value) => {
        if (value === null || value === undefined || value === '') {
          return undefined;
        }
        return value;
      })
      .optional()
      .isFloat({ min: 0 })
      .withMessage('GPS accuracy must be a positive number when provided'),
    body('collected_offline').optional().isBoolean(),
  ] as ValidationChain[],
  update: [
    param('featureId').isUUID().withMessage('Valid feature ID is required'),
    body('attributes').optional().isObject(),
    body('geom').optional().isObject().withMessage('Geometry must be an object'),
    body('geom.type')
      .optional()
      .isIn(['Point', 'LineString', 'Polygon'])
      .withMessage('Invalid geometry type'),
    body('geom.coordinates').optional().isArray().withMessage('Coordinates must be an array'),
    body('status').optional().isIn(['draft', 'pending_review', 'approved', 'rejected']),
  ] as ValidationChain[],
  review: [
    param('featureId').isUUID().withMessage('Valid feature ID is required'),
    body('status')
      .isIn(['approved', 'rejected'])
      .withMessage('Status must be approved or rejected'),
    body('review_notes').optional().trim(),
  ] as ValidationChain[],
};

// Assignment validation rules
const assignmentValidation = {
  create: [
    body('project_id').isUUID().withMessage('Valid project ID is required'),
    body('user_id').isUUID().withMessage('Valid user ID is required'),
    body('role')
      .optional()
      .isIn(['contributor'])
      .withMessage('Assignments are for contributors only'),
  ] as ValidationChain[],
  update: [
    param('assignmentId').isUUID().withMessage('Valid assignment ID is required'),
    body('status')
      .isIn(['approved', 'rejected'])
      .withMessage('Status must be approved or rejected'),
  ] as ValidationChain[],
};

const categoryValidation = {
  create: [
    body('name').trim().notEmpty().withMessage('Category name is required'),
    body('description').optional().trim(),
    body('icon_url').optional().isString(),
  ] as ValidationChain[],
  update: [
    param('categoryId').isUUID().withMessage('Valid category ID is required'),
    body('name').optional().trim().notEmpty(),
    body('description').optional().trim(),
    body('icon_url').optional().isString(),
  ] as ValidationChain[],
};

const settingsValidation = {
  updateSupport: [
    body('support_email')
      .optional({ nullable: true })
      .customSanitizer((value) => {
        if (value === null || value === undefined) {
          return value;
        }
        const normalized = String(value).trim();
        return normalized.length === 0 ? null : normalized;
      })
      .isEmail()
      .withMessage('Valid email is required'),
    body('support_phone')
      .optional({ nullable: true })
      .customSanitizer((value) => {
        if (value === null || value === undefined) {
          return value;
        }
        const normalized = digitsOnly(value);
        return normalized.length === 0 ? null : normalized;
      })
      .matches(phonePattern)
      .withMessage('Enter a valid phone number.'),
    body('office_hours').optional({ nullable: true }).trim(),
    body('help_text').optional({ nullable: true }).trim(),
  ] as ValidationChain[],
};

const notificationValidation = {
  registerDevice: [
    body('token')
      .trim()
      .notEmpty()
      .withMessage('Device token is required')
      .isLength({ min: 16, max: 4096 })
      .withMessage('Device token format is invalid'),
    body('platform').trim().isIn(['android', 'ios']).withMessage('platform must be android or ios'),
    body('device_label').optional().trim().isLength({ max: 120 }),
    body('app_version').optional().trim().isLength({ max: 60 }),
  ] as ValidationChain[],
  unregisterDevice: [
    body('token')
      .trim()
      .notEmpty()
      .withMessage('Device token is required')
      .isLength({ min: 16, max: 4096 })
      .withMessage('Device token format is invalid'),
  ] as ValidationChain[],
};

const importValidation = {
  list: [
    queryParam('status')
      .optional()
      .isIn([
        'uploaded',
        'processing',
        'pending_review',
        'approved',
        'partially_approved',
        'rejected',
        'failed',
      ])
      .withMessage('Invalid import status'),
    queryParam('project_id').optional().isUUID().withMessage('project_id must be a valid UUID'),
    queryParam('category_id').optional().isUUID().withMessage('category_id must be a valid UUID'),
  ] as ValidationChain[],
  listFeatures: [
    queryParam('status')
      .optional()
      .isIn(['pending_review', 'approved', 'rejected', 'failed'])
      .withMessage('Invalid import feature status'),
    queryParam('geometry_type')
      .optional()
      .isIn([
        'point',
        'line',
        'polygon',
        'Point',
        'LineString',
        'Polygon',
        'MultiPoint',
        'MultiLineString',
        'MultiPolygon',
      ])
      .withMessage('Invalid import feature geometry type'),
    queryParam('search')
      .optional()
      .trim()
      .isLength({ max: 200 })
      .withMessage('search must be 200 characters or fewer'),
    queryParam('feature_type')
      .optional()
      .trim()
      .isLength({ max: 100 })
      .withMessage('feature_type must be 100 characters or fewer'),
  ] as ValidationChain[],
  review: [
    param('importId').isUUID().withMessage('Valid import ID is required'),
    body('status')
      .isIn(['approved', 'rejected'])
      .withMessage('status must be approved or rejected'),
    body('reason').optional({ nullable: true }).trim(),
    body('feature_ids')
      .optional()
      .isArray({ min: 1 })
      .withMessage('feature_ids must be a non-empty array when provided'),
    body('feature_ids.*')
      .optional()
      .isUUID()
      .withMessage('feature_ids must contain valid UUID values'),
    body('filters')
      .optional({ nullable: true })
      .isObject()
      .withMessage('filters must be an object when provided'),
    body('filters.status')
      .optional({ nullable: true })
      .isIn(['pending_review', 'approved', 'rejected', 'failed'])
      .withMessage('filters.status must be a valid import feature status'),
    body('filters.issue')
      .optional({ nullable: true })
      .trim()
      .isLength({ max: 1000 })
      .withMessage('filters.issue must be 1000 characters or fewer'),
    body('filters.search')
      .optional({ nullable: true })
      .trim()
      .isLength({ max: 200 })
      .withMessage('filters.search must be 200 characters or fewer'),
    body('filters.geometry_type')
      .optional({ nullable: true })
      .isIn([
        'point',
        'line',
        'polygon',
        'Point',
        'LineString',
        'Polygon',
        'MultiPoint',
        'MultiLineString',
        'MultiPolygon',
      ])
      .withMessage('filters.geometry_type must be a valid geometry type'),
    body('filters.feature_type')
      .optional({ nullable: true })
      .trim()
      .isLength({ max: 100 })
      .withMessage('filters.feature_type must be 100 characters or fewer'),
  ] as ValidationChain[],
  comment: [
    param('importId').isUUID().withMessage('Valid import ID is required'),
    body('comment')
      .trim()
      .notEmpty()
      .withMessage('comment is required')
      .isLength({ max: 4000 })
      .withMessage('comment must be 4000 characters or fewer'),
    body('feature_id')
      .optional({ nullable: true })
      .isUUID()
      .withMessage('feature_id must be a valid UUID'),
  ] as ValidationChain[],
};

const aiScopeTypes = ['project', 'governorate', 'district', 'city', 'custom_polygon', 'national'];
const aiPredictionValidationTaskStatuses = [
  'open',
  'assigned',
  'in_progress',
  'submitted',
  'accepted',
  'rejected',
  'cancelled',
];
const aiPredictionValidationResults = ['correct', 'wrong_class', 'not_target_class', 'unsure'];
const aiPredictionFeatureValidationResults = ['correct', 'incorrect', 'unsure', 'cannot_verify'];
const aiPreferredModels = [
  'auto',
  'random_forest',
  'rf',
  'svm',
  'svm_rbf',
  'gradient_boosting',
  'gradient_boost',
  'gradient_tree_boost',
  'gb',
];

const aiValidation = {
  readiness: [
    queryParam('label_field')
      .optional()
      .trim()
      .isLength({ min: 1, max: 120 })
      .withMessage('label_field must be between 1 and 120 characters'),
    queryParam('scope_type').optional().isIn(aiScopeTypes).withMessage('scope_type is invalid'),
    queryParam('min_samples_per_class')
      .optional()
      .isInt({ min: 1, max: 10000 })
      .withMessage('min_samples_per_class must be a positive integer'),
  ] as ValidationChain[],
  settings: [
    body('is_enabled').optional().isBoolean().withMessage('is_enabled must be a boolean'),
    body('label_field')
      .optional({ nullable: true })
      .trim()
      .isLength({ min: 1, max: 120 })
      .withMessage('label_field must be between 1 and 120 characters'),
    body('scope_type').optional().isIn(aiScopeTypes).withMessage('scope_type is invalid'),
    body('scope_geometry')
      .optional({ nullable: true })
      .custom((value) => {
        if (value === null) {
          return true;
        }
        return (
          value &&
          typeof value === 'object' &&
          ['Polygon', 'MultiPolygon', 'GeometryCollection'].includes(value.type) &&
          Array.isArray(value.coordinates ?? value.geometries)
        );
      })
      .withMessage('scope_geometry must be a GeoJSON polygon geometry when provided'),
    body('min_samples_per_class')
      .optional()
      .isInt({ min: 1, max: 10000 })
      .withMessage('min_samples_per_class must be a positive integer'),
    body('model_preferences')
      .optional()
      .isObject()
      .withMessage('model_preferences must be an object'),
    body('model_preferences.preferred_model')
      .optional()
      .custom((value) => {
        const model = String(value ?? '')
          .trim()
          .toLowerCase()
          .replace(/[-\s]+/g, '_');
        return model.length === 0 || aiPreferredModels.includes(model);
      })
      .withMessage('preferred_model must be Auto, Random Forest, SVM, or Gradient Boosting'),
  ] as ValidationChain[],
  createRun: [
    body('status')
      .optional()
      .isIn(['draft', 'queued', 'created', 'starting', 'running'])
      .withMessage('status must be draft, queued, created, starting, or running'),
    body('label_field')
      .optional()
      .trim()
      .isLength({ min: 1, max: 120 })
      .withMessage('label_field must be between 1 and 120 characters'),
    body('scope_type').optional().isIn(aiScopeTypes).withMessage('scope_type is invalid'),
    body('scope_geometry')
      .optional({ nullable: true })
      .custom((value) => {
        if (value === null) {
          return true;
        }
        return (
          value &&
          typeof value === 'object' &&
          ['Polygon', 'MultiPolygon', 'GeometryCollection'].includes(value.type) &&
          Array.isArray(value.coordinates ?? value.geometries)
        );
      })
      .withMessage('scope_geometry must be a GeoJSON polygon geometry when provided'),
    body('region_preset')
      .optional({ nullable: true })
      .trim()
      .isLength({ max: 120 })
      .withMessage('region_preset must be 120 characters or fewer'),
    body('execution_mode')
      .optional()
      .isIn([
        'mock',
        'dry_run',
        'local_ground_truth_export',
        'regional_feature_extraction',
        'regional_model_eval',
        'regional_classification',
        'regional_vectorization_artifacts',
        'regional_full_review_artifacts',
      ])
      .withMessage('execution_mode is invalid'),
    body('min_samples_per_class')
      .optional()
      .isInt({ min: 1, max: 10000 })
      .withMessage('min_samples_per_class must be a positive integer'),
  ] as ValidationChain[],
  listRuns: [
    queryParam('status')
      .optional()
      .isIn([
        'draft',
        'created',
        'queued',
        'starting',
        'running',
        'extracting_features',
        'training',
        'evaluating',
        'classifying',
        'ready_for_review',
        'completed',
        'cancelling',
        'paused',
        'published',
        'failed',
        'cancelled',
      ])
      .withMessage('status is invalid'),
  ] as ValidationChain[],
  reviewRun: [
    body('action')
      .isIn(['approve_for_publication', 'reject', 'request_more_data', 'keep_draft'])
      .withMessage(
        'action must be approve_for_publication, reject, request_more_data, or keep_draft',
      ),
    body()
      .custom((value) => {
        const action = value?.action;
        if (action === 'reject' || action === 'request_more_data') {
          return typeof value?.reason === 'string' && value.reason.trim().length > 0;
        }
        return true;
      })
      .withMessage('reason is required for reject and request_more_data actions'),
    body('reason')
      .optional({ nullable: true })
      .trim()
      .isLength({ max: 4000 })
      .withMessage('reason must be 4000 characters or fewer')
      .withMessage('reason must be 4000 characters or fewer'),
  ] as ValidationChain[],
  listPredictionValidationTasks: [
    queryParam('status')
      .optional()
      .isIn(aiPredictionValidationTaskStatuses)
      .withMessage('status is invalid'),
    queryParam('assigned_to').optional().isUUID().withMessage('assigned_to must be a valid UUID'),
    queryParam('ai_run_id').optional().isUUID().withMessage('ai_run_id must be a valid UUID'),
  ] as ValidationChain[],
  generatePredictionValidationTasks: [
    body('ai_run_id')
      .optional({ nullable: true })
      .isUUID()
      .withMessage('ai_run_id must be a valid UUID'),
    body('ai_output_layer_id')
      .optional({ nullable: true })
      .isUUID()
      .withMessage('ai_output_layer_id must be a valid UUID'),
    body('ai_prediction_feature_id')
      .optional({ nullable: true })
      .isUUID()
      .withMessage('ai_prediction_feature_id must be a valid UUID'),
    body('prediction_feature_id')
      .optional({ nullable: true })
      .isUUID()
      .withMessage('prediction_feature_id must be a valid UUID'),
    body()
      .custom((value) => !(value?.ai_prediction_feature_id && value?.prediction_feature_id))
      .withMessage('Use only one prediction feature id field'),
    body('confidence_threshold')
      .optional({ nullable: true })
      .isFloat({ min: 0, max: 1 })
      .withMessage('confidence_threshold must be between 0 and 1'),
    body('limit')
      .optional({ nullable: true })
      .isInt({ min: 1, max: 10000 })
      .withMessage('limit must be between 1 and 10000'),
    body('priority')
      .optional({ nullable: true })
      .isInt({ min: 0, max: 1000 })
      .withMessage('priority must be between 0 and 1000'),
  ] as ValidationChain[],
  assignPredictionValidationTask: [
    body('assigned_to').isUUID().withMessage('assigned_to must be a valid UUID'),
  ] as ValidationChain[],
  updatePredictionValidationTaskStatus: [
    body('status').isIn(aiPredictionValidationTaskStatuses).withMessage('status is invalid'),
  ] as ValidationChain[],
  submitPredictionValidation: [
    body('result')
      .isIn(aiPredictionValidationResults)
      .withMessage('result must be correct, wrong_class, not_target_class, or unsure'),
    body('note')
      .trim()
      .notEmpty()
      .withMessage('note is required')
      .isLength({ max: 4000 })
      .withMessage('note must be 4000 characters or fewer'),
    body('corrected_class')
      .optional({ nullable: true })
      .trim()
      .isLength({ min: 1, max: 200 })
      .withMessage('corrected_class must be between 1 and 200 characters'),
    body()
      .custom((value) => {
        if (value?.result === 'wrong_class') {
          return (
            typeof value?.corrected_class === 'string' && value.corrected_class.trim().length > 0
          );
        }
        return true;
      })
      .withMessage('corrected_class is required when result is wrong_class'),
    body()
      .custom((value) => {
        if (value?.result === 'not_target_class') {
          return (
            value?.corrected_class === undefined ||
            value?.corrected_class === null ||
            String(value.corrected_class).trim().length === 0
          );
        }
        return true;
      })
      .withMessage('corrected_class must be empty when result is not_target_class'),
    body('evidence')
      .optional({ nullable: true })
      .isObject()
      .withMessage('evidence must be an object'),
    body('linked_feature_id')
      .optional({ nullable: true })
      .isUUID()
      .withMessage('linked_feature_id must be a valid UUID'),
  ] as ValidationChain[],
  reviewPredictionValidationTask: [
    body('decision')
      .isIn(['accepted', 'rejected'])
      .withMessage('decision must be accepted or rejected'),
    body('reason')
      .optional({ nullable: true })
      .trim()
      .isLength({ max: 4000 })
      .withMessage('reason must be 4000 characters or fewer'),
    body('submission_id')
      .optional({ nullable: true })
      .isUUID()
      .withMessage('submission_id must be a valid UUID'),
    body()
      .custom((value) => {
        if (value?.decision === 'rejected') {
          return typeof value?.reason === 'string' && value.reason.trim().length > 0;
        }
        return true;
      })
      .withMessage('reason is required when decision is rejected'),
  ] as ValidationChain[],
  submitPredictionFeatureValidation: [
    body('validation_result')
      .optional({ nullable: true })
      .isIn(aiPredictionFeatureValidationResults)
      .withMessage('validation_result must be correct, incorrect, unsure, or cannot_verify'),
    body('result')
      .optional({ nullable: true })
      .isIn(aiPredictionFeatureValidationResults)
      .withMessage('result must be correct, incorrect, unsure, or cannot_verify'),
    body()
      .custom((value) => Boolean(value?.validation_result || value?.result))
      .withMessage('validation_result is required'),
    body('note')
      .optional({ nullable: true })
      .trim()
      .isLength({ max: 4000 })
      .withMessage('note must be 4000 characters or fewer'),
    body('corrected_class')
      .optional({ nullable: true })
      .trim()
      .isLength({ min: 1, max: 200 })
      .withMessage('corrected_class must be between 1 and 200 characters'),
    body()
      .custom((value) => {
        const result = value?.validation_result ?? value?.result;
        if (result === 'incorrect') {
          return (
            typeof value?.corrected_class === 'string' && value.corrected_class.trim().length > 0
          );
        }
        return true;
      })
      .withMessage('corrected_class is required when validation_result is incorrect'),
    body()
      .custom((value) => {
        const result = value?.validation_result ?? value?.result;
        if (result !== 'incorrect') {
          return (
            value?.corrected_class === undefined ||
            value?.corrected_class === null ||
            String(value.corrected_class).trim().length === 0
          );
        }
        return true;
      })
      .withMessage('corrected_class is only allowed when validation_result is incorrect'),
    body('photo_media_ids')
      .optional({ nullable: true })
      .isArray()
      .withMessage('photo_media_ids must be an array'),
    body('photo_media_ids.*')
      .optional()
      .isString()
      .withMessage('photo_media_ids entries must be strings'),
    body('gps_location')
      .optional({ nullable: true })
      .isObject()
      .withMessage('gps_location must be an object'),
    body('gps_accuracy_m')
      .optional({ nullable: true })
      .isFloat({ min: 0 })
      .withMessage('gps_accuracy_m must be zero or greater'),
    body('metadata')
      .optional({ nullable: true })
      .isObject()
      .withMessage('metadata must be an object'),
  ] as ValidationChain[],
  reviewPredictionFeature: [
    body('approval_status')
      .optional({ nullable: true })
      .isIn(['approved', 'rejected', 'needs_more_validation'])
      .withMessage('approval_status must be approved, rejected, or needs_more_validation'),
    body('status')
      .optional({ nullable: true })
      .isIn(['approved', 'rejected', 'needs_more_validation'])
      .withMessage('status must be approved, rejected, or needs_more_validation'),
    body()
      .custom((value) => Boolean(value?.approval_status || value?.status))
      .withMessage('approval_status is required'),
    body('admin_note')
      .optional({ nullable: true })
      .trim()
      .isLength({ max: 4000 })
      .withMessage('admin_note must be 4000 characters or fewer'),
    body('note')
      .optional({ nullable: true })
      .trim()
      .isLength({ max: 4000 })
      .withMessage('note must be 4000 characters or fewer'),
    body('approved_class')
      .optional({ nullable: true })
      .trim()
      .isLength({ min: 1, max: 200 })
      .withMessage('approved_class must be between 1 and 200 characters'),
  ] as ValidationChain[],
};

// Export validation rules
const exportValidation = {
  create: [
    body('status_filter').optional().isArray().withMessage('status_filter must be an array'),
    body('status_filter.*')
      .optional()
      .isIn(['draft', 'pending_review', 'approved', 'rejected'])
      .withMessage('status_filter contains invalid status'),
    body('date_from')
      .optional({ values: 'falsy' })
      .isISO8601()
      .withMessage('date_from must be a valid date'),
    body('date_to')
      .optional({ values: 'falsy' })
      .isISO8601()
      .withMessage('date_to must be a valid date'),
    body('geometry_types').optional().isArray().withMessage('geometry_types must be an array'),
    body('geometry_types.*')
      .optional()
      .isIn(['Point', 'LineString', 'Polygon'])
      .withMessage('geometry_types contains invalid geometry type'),
    body('include_photos').optional().isBoolean(),
    body('export_ai_predictions').optional().isBoolean(),
    body('category_id').optional({ values: 'falsy' }).isUUID(),
    body('feature_type')
      .optional({ values: 'falsy' })
      .trim()
      .isLength({ max: 120 })
      .withMessage('feature_type must be 120 characters or fewer'),
    body('export_polygon')
      .optional({ values: 'falsy' })
      .custom((value) => {
        const parsed = typeof value === 'string' ? JSON.parse(value) : value;
        return parsed?.type === 'Polygon' && Array.isArray(parsed.coordinates);
      })
      .withMessage('export_polygon must be a GeoJSON Polygon'),
    body('coordinate_system').optional().isString(),
    body('format').optional().isIn(['geojson', 'shapefile']),
    body('bbox')
      .optional({ values: 'falsy' })
      .custom((value) => {
        const raw = Array.isArray(value)
          ? value.map((item) => String(item))
          : String(value).split(',');
        if (raw.length !== 4) {
          return false;
        }
        const numbers = raw.map((item) => Number.parseFloat(String(item).trim()));
        if (numbers.some((item) => Number.isNaN(item))) {
          return false;
        }
        const [minLon, minLat, maxLon, maxLat] = numbers;
        return minLon < maxLon && minLat < maxLat;
      })
      .withMessage('bbox must use minLon,minLat,maxLon,maxLat'),
  ] as ValidationChain[],
};

// Pagination validation
const paginationValidation: ValidationChain[] = [
  queryParam('page').optional().isInt({ min: 1 }).withMessage('Page must be a positive integer'),
  queryParam('limit')
    .optional()
    .isInt({ min: 1, max: 100 })
    .withMessage('Limit must be between 1 and 100'),
];

const bboxPaginationValidation: ValidationChain[] = [
  queryParam('page').optional().isInt({ min: 1 }).withMessage('Page must be a positive integer'),
  queryParam('limit')
    .optional()
    .isInt({ min: 1, max: 20000 })
    .withMessage('Limit must be between 1 and 20000'),
];

const tileParamValidation: ValidationChain[] = [
  param('z').isInt({ min: 0, max: 22 }).withMessage('z must be between 0 and 22'),
  param('x').isInt({ min: 0 }).withMessage('x must be a non-negative integer'),
  param('y').isInt({ min: 0 }).withMessage('y must be a non-negative integer'),
];

const tileFeatureQueryValidation: ValidationChain[] = [
  queryParam('project_id').isUUID().withMessage('project_id must be a valid UUID'),
  queryParam('zoom')
    .optional()
    .isFloat({ min: 0, max: 24 })
    .withMessage('zoom must be between 0 and 24'),
  queryParam('status')
    .optional()
    .isIn(['draft', 'pending_review', 'approved', 'rejected'])
    .withMessage('Invalid status value'),
  queryParam('feature_type')
    .optional()
    .trim()
    .isLength({ max: 100 })
    .withMessage('feature_type must be 100 characters or fewer'),
];

const bboxValidation: ValidationChain[] = [
  queryParam('minLon')
    .exists()
    .withMessage('minLon is required')
    .bail()
    .isFloat({ min: -180, max: 180 })
    .withMessage('minLon must be between -180 and 180'),
  queryParam('minLat')
    .exists()
    .withMessage('minLat is required')
    .bail()
    .isFloat({ min: -90, max: 90 })
    .withMessage('minLat must be between -90 and 90'),
  queryParam('maxLon')
    .exists()
    .withMessage('maxLon is required')
    .bail()
    .isFloat({ min: -180, max: 180 })
    .withMessage('maxLon must be between -180 and 180'),
  queryParam('maxLat')
    .exists()
    .withMessage('maxLat is required')
    .bail()
    .isFloat({ min: -90, max: 90 })
    .withMessage('maxLat must be between -90 and 90'),
  queryParam('status')
    .optional()
    .isIn(['draft', 'pending_review', 'approved', 'rejected'])
    .withMessage('Invalid status value'),
  queryParam('project_id').optional().isUUID().withMessage('project_id must be a valid UUID'),
  queryParam('maxLon')
    .custom((value, { req }) => parseFloat(value) > parseFloat(String(req.query?.minLon ?? 'NaN')))
    .withMessage('maxLon must be greater than minLon'),
  queryParam('maxLat')
    .custom((value, { req }) => parseFloat(value) > parseFloat(String(req.query?.minLat ?? 'NaN')))
    .withMessage('maxLat must be greater than minLat'),
];

// UUID parameter validation
const uuidValidation = (paramName = 'id'): ValidationChain[] => [
  param(paramName).isUUID().withMessage(`Valid ${paramName} is required`),
];

export {
  validate,
  userValidation,
  projectValidation,
  featureValidation,
  assignmentValidation,
  categoryValidation,
  settingsValidation,
  notificationValidation,
  importValidation,
  aiValidation,
  exportValidation,
  paginationValidation,
  bboxPaginationValidation,
  tileParamValidation,
  tileFeatureQueryValidation,
  bboxValidation,
  uuidValidation,
};
