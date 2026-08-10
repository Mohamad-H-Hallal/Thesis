import jwt, { type JwtPayload, type SignOptions } from 'jsonwebtoken';
import type { NextFunction, Request, Response } from 'express';
import { query } from '../config/database';
const logger = require('../utils/logger');
import type { user_role } from '../types/roles';
import { publicVisibleStatuses, synchronizeProjectStatuses } from '../lib/projectLifecycle';
import { isProtectedSuperAdminEmail } from '../lib/userWorkflow';
import { requestHasOfflineSyncSignal } from '../services/offlineSyncSecurity.service';
import { permanentOfflineSyncError } from './error';
import {
  assertVerificationTokenCurrent,
  verifyVerificationSessionToken,
} from '../services/contactVerification.service';
import { isContactAssuranceSatisfied } from '../services/contactAssurancePolicy.service';

interface TokenPayload extends JwtPayload {
  userId: string;
  role?: user_role;
  authVersion?: number;
}

const isOfflineSyncRequest = (req: Request): boolean => {
  const requestPath = req.originalUrl.toLowerCase();
  const isFeatureMutation =
    ['POST', 'PUT', 'PATCH'].includes(req.method) && /\/features(?:\/|[?]|$)/.test(requestPath);
  const isFeaturePhotoUpload =
    req.method === 'POST' && /\/photos\/feature\/[^/?]+(?:[/?]|$)/.test(requestPath);
  return isFeatureMutation || isFeaturePhotoUpload || requestHasOfflineSyncSignal(req);
};

const getSecrets = (current: string, previousRaw?: string): string[] => {
  const previous = (previousRaw ?? '')
    .split(',')
    .map((value) => value.trim())
    .filter(Boolean);
  return [current, ...previous];
};

const verifyWithSecrets = (token: string, secrets: string[]): TokenPayload => {
  let lastError: unknown = null;
  for (const secret of secrets) {
    try {
      return jwt.verify(token, secret) as TokenPayload;
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? new Error('Token verification failed');
};

// Generate JWT token
const generateToken = (userId: string, role: user_role, authVersion = 0): string => {
  const signingSecret = process.env.JWT_SECRET_CURRENT || process.env.JWT_SECRET;
  const expiresIn = (process.env.JWT_EXPIRE || '7d') as SignOptions['expiresIn'];
  return jwt.sign({ userId, role, authVersion }, signingSecret as string, { expiresIn });
};

// Generate refresh token
const generateRefreshToken = (userId: string, authVersion = 0): string => {
  const signingSecret = process.env.JWT_REFRESH_SECRET_CURRENT || process.env.JWT_REFRESH_SECRET;
  const expiresIn = (process.env.JWT_REFRESH_EXPIRE || '30d') as SignOptions['expiresIn'];
  return jwt.sign({ userId, authVersion }, signingSecret as string, { expiresIn });
};

const authenticateVerificationSession = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<Response | void> => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader?.startsWith('Bearer ')) {
      return res.status(401).json({
        success: false,
        message: 'A verification session is required.',
        error: {
          code: 'VERIFICATION_SESSION_REQUIRED',
          disposition: 'retry',
          retryable: false,
        },
      });
    }
    const token = authHeader.slice('Bearer '.length).trim();
    const payload = verifyVerificationSessionToken(token);
    const user = await assertVerificationTokenCurrent(payload);
    req.verificationUserId = user.id;
    next();
  } catch (error) {
    next(error);
  }
};

// Verify JWT token middleware
const authenticate = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<Response | void> => {
  try {
    // Get token from header
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return res.status(401).json({
        success: false,
        message: 'No token provided',
      });
    }

    const token = authHeader.split(' ')[1];
    if (!token) {
      return res.status(401).json({
        success: false,
        message: 'No token provided',
      });
    }

    // Verify token
    const accessSecrets = getSecrets(
      process.env.JWT_SECRET_CURRENT || process.env.JWT_SECRET || '',
      process.env.JWT_SECRET_PREVIOUS,
    );
    const decoded = verifyWithSecrets(token, accessSecrets);

    // Get user from database
    const result = await query(
      `SELECT id, email, full_name, role, is_active, account_status, auth_version,
              email_verified_at, phone_verified_at, phone_format_validated_at,
              contact_verification_exempted_at
       FROM "user" WHERE id = $1`,
      [decoded.userId],
    );

    if (result.rows.length === 0) {
      if (isOfflineSyncRequest(req)) {
        return next(
          permanentOfflineSyncError(
            'Offline submission discarded because this account is no longer available.',
            'OFFLINE_SYNC_ACCOUNT_INACTIVE',
          ),
        );
      }
      return res.status(401).json({
        success: false,
        message: 'User not found',
      });
    }

    const user = result.rows[0];

    if (
      typeof decoded.authVersion === 'number' &&
      decoded.authVersion !== Number(user.auth_version ?? 0)
    ) {
      return res.status(401).json({
        success: false,
        message: 'Your session is no longer current. Please sign in again.',
        error: {
          code: 'AUTH_SESSION_REPLACED',
          disposition: 'retry',
          retryable: false,
        },
      });
    }

    // Check if user is active
    if (!user.is_active || !isContactAssuranceSatisfied(user)) {
      if (isOfflineSyncRequest(req)) {
        return next(
          permanentOfflineSyncError(
            'Offline submission discarded because this account is no longer active.',
            'OFFLINE_SYNC_ACCOUNT_INACTIVE',
          ),
        );
      }
      return res.status(401).json({
        success: false,
        message: 'User account is inactive or requires contact verification',
      });
    }

    // Add user to request object
    req.user = user;
    next();
  } catch (error: unknown) {
    if (error instanceof jwt.TokenExpiredError) {
      return res.status(401).json({
        success: false,
        message: 'Token expired',
      });
    }
    if (error instanceof jwt.JsonWebTokenError) {
      return res.status(401).json({
        success: false,
        message: 'Invalid token',
      });
    }
    logger.error('Authentication error:', error);
    return res.status(500).json({
      success: false,
      message: 'Authentication failed',
    });
  }
};

// Role-based authorization middleware
const authorize = (...roles: user_role[]) => {
  return (req: Request, res: Response, next: NextFunction): Response | void => {
    if (!req.user) {
      return res.status(401).json({
        success: false,
        message: 'Not authenticated',
      });
    }

    if (!roles.includes(req.user.role)) {
      return res.status(403).json({
        success: false,
        message: 'Not authorized to access this resource',
      });
    }

    next();
  };
};

// Protected super-admin authorization middleware
const requireProtectedSuperAdmin = (
  req: Request,
  res: Response,
  next: NextFunction,
): Response | void => {
  if (!req.user) {
    return res.status(401).json({
      success: false,
      message: 'Not authenticated',
    });
  }

  if (req.user.role !== 'admin' || !isProtectedSuperAdminEmail(req.user.email)) {
    return res.status(403).json({
      success: false,
      message: 'Only the protected super administrator can manage project AI.',
    });
  }

  next();
};

// Check project access middleware
const checkProjectAccess = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<Response | void> => {
  try {
    const projectId = req.params.projectId || req.body.project_id;
    const userId = req.user?.id;
    if (!projectId || !userId) {
      return res.status(400).json({
        success: false,
        message: 'Project context is missing',
      });
    }

    await synchronizeProjectStatuses(projectId);

    // Admin can access all projects
    if (req.user.role === 'admin') {
      return next();
    }

    if (req.user.role === 'viewer') {
      const visibleStatuses = publicVisibleStatuses.map((status) => `'${status}'`).join(', ');
      const visibleProject = await query(
        `SELECT id
         FROM project
         WHERE id = $1
           AND visible_to_viewers = TRUE
           AND status IN (${visibleStatuses})`,
        [projectId],
      );

      if (visibleProject.rows.length === 0) {
        return res.status(403).json({
          success: false,
          message: 'You do not have access to this project',
        });
      }

      return next();
    }

    const visibleStatuses = publicVisibleStatuses.map((status) => `'${status}'`).join(', ');
    const contributorAccess = await query(
      `SELECT
          EXISTS (
            SELECT 1
            FROM project_assignment
            WHERE project_id = $1
              AND user_id = $2
              AND status = 'approved'
          ) AS has_assignment,
          (
            SELECT role
            FROM project_assignment
            WHERE project_id = $1
              AND user_id = $2
              AND status = 'approved'
            LIMIT 1
          ) AS assignment_role,
          EXISTS (
            SELECT 1
            FROM project
            WHERE id = $1
              AND visible_to_contributors = TRUE
              AND status IN (${visibleStatuses})
          ) AS is_public_project`,
      [projectId, userId],
    );

    const accessRow = contributorAccess.rows[0];
    const hasAssignment = accessRow?.has_assignment === true;
    const isPublicProject = accessRow?.is_public_project === true;

    if (!hasAssignment && !isPublicProject) {
      return res.status(403).json({
        success: false,
        message: 'You do not have access to this project',
      });
    }

    if (hasAssignment && accessRow.assignment_role) {
      req.projectRole = accessRow.assignment_role as 'admin' | 'contributor';
    }
    next();
  } catch (error: unknown) {
    logger.error('Project access check error:', error);
    return res.status(500).json({
      success: false,
      message: 'Error checking project access',
    });
  }
};

// Check project admin access
const checkProjectAdmin = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<Response | void> => {
  try {
    const projectId = req.params.projectId || req.body.project_id;
    const userId = req.user?.id;
    if (!projectId || !userId) {
      return res.status(400).json({
        success: false,
        message: 'Project context is missing',
      });
    }

    await synchronizeProjectStatuses(projectId);

    // System admin can access all projects
    if (req.user.role === 'admin') {
      return next();
    }

    // Check if user is project admin
    const result = await query(
      `SELECT id FROM project_assignment 
       WHERE project_id = $1 AND user_id = $2 AND role = 'admin' AND status = 'approved'`,
      [projectId, userId],
    );

    if (result.rows.length === 0) {
      return res.status(403).json({
        success: false,
        message: 'You must be a project admin to perform this action',
      });
    }

    next();
  } catch (error: unknown) {
    logger.error('Project admin check error:', error);
    return res.status(500).json({
      success: false,
      message: 'Error checking project admin access',
    });
  }
};

export {
  generateToken,
  generateRefreshToken,
  authenticateVerificationSession,
  authenticate,
  authorize,
  requireProtectedSuperAdmin,
  checkProjectAccess,
  checkProjectAdmin,
};
