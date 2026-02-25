import { body, param, query as queryParam, validationResult, type ValidationChain } from 'express-validator';
import type { NextFunction, Request, Response } from 'express';

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
    body('email')
      .trim()
      .isEmail()
      .normalizeEmail()
      .withMessage('Valid email is required'),
    body('password')
      .isString()
      .withMessage('Password must be a string')
      .isLength({ min: 8 })
      .withMessage('Password must be at least 8 characters')
      .matches(/\S/)
      .withMessage('Password cannot be empty'),
    body('full_name')
      .trim()
      .notEmpty()
      .withMessage('Full name is required'),
    body('phone')
      .optional()
      .matches(/^\+?[0-9-]+$/)
      .withMessage('Invalid phone number format'),
    body('role')
      .optional()
      .isIn(['contributor', 'viewer'])
      .withMessage('Public registration cannot request admin role'),
  ] as ValidationChain[],
  login: [
    body('email')
      .trim()
      .isEmail()
      .normalizeEmail()
      .withMessage('Valid email is required'),
    body('password')
      .isString()
      .withMessage('Password is required')
      .notEmpty()
      .withMessage('Password is required'),
  ] as ValidationChain[],
  update: [
    body('full_name').optional().trim().notEmpty(),
    body('phone').optional().matches(/^\+?[0-9-]+$/),
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
      .custom((value, { req }) => value !== req.body.current_password)
      .withMessage('New password must be different from current password'),
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
};

// Project validation rules
const projectValidation = {
  create: [
    body('name').trim().notEmpty().withMessage('Project name is required'),
    body('description').optional().trim(),
    body('category_id').isUUID().withMessage('Valid category ID is required'),
    body('status')
      .optional()
      .isIn(['draft', 'active', 'paused', 'completed', 'archived']),
    body('collection_form_schema')
      .isObject()
      .withMessage('Form schema must be a valid JSON object'),
    body('requires_photos').optional().isBoolean(),
    body('min_photos').optional().isInt({ min: 0 }),
    body('max_photos').optional().isInt({ min: 0 }),
  ] as ValidationChain[],
  update: [
    param('projectId').isUUID().withMessage('Valid project ID is required'),
    body('name').optional().trim().notEmpty(),
    body('description').optional().trim(),
    body('status').optional().isIn(['draft', 'active', 'paused', 'completed', 'archived']),
    body('collection_form_schema').optional().isObject(),
  ] as ValidationChain[],
};

// Feature validation rules
const featureValidation = {
  create: [
    body('project_id').isUUID().withMessage('Valid project ID is required'),
    body('geom').notEmpty().withMessage('Geometry is required'),
    body('geom.type')
      .isIn(['Point', 'LineString', 'Polygon'])
      .withMessage('Invalid geometry type'),
    body('geom.coordinates').isArray().withMessage('Coordinates must be an array'),
    body('attributes').isObject().withMessage('Attributes must be a JSON object'),
    body('accuracy_meters').optional().isFloat({ min: 0 }),
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
    body('status')
      .optional()
      .isIn(['draft', 'pending_review', 'approved', 'rejected']),
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
      .isIn(['admin', 'contributor'])
      .withMessage('Role must be admin or contributor'),
  ] as ValidationChain[],
  update: [
    param('assignmentId').isUUID().withMessage('Valid assignment ID is required'),
    body('status')
      .isIn(['pending', 'approved', 'rejected'])
      .withMessage('Invalid status'),
  ] as ValidationChain[],
};

// Export validation rules
const exportValidation = {
  create: [
    body('export_parameters').optional().isObject(),
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
  queryParam('project_id')
    .optional()
    .isUUID()
    .withMessage('project_id must be a valid UUID'),
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
  exportValidation,
  paginationValidation,
  bboxValidation,
  uuidValidation,
};
