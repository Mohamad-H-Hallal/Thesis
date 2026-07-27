import type { NextFunction, Request, Response } from 'express';
const logger = require('../utils/logger');

// Custom error class
class AppError extends Error {
  statusCode: number;
  isOperational: boolean;
  errorCode?: string;
  disposition?: string;
  retryable?: boolean;
  currentVersion?: number;

  constructor(
    message: string,
    statusCode: number,
    options: {
      code?: string;
      disposition?: string;
      retryable?: boolean;
      currentVersion?: number;
    } = {},
  ) {
    super(message);
    this.statusCode = statusCode;
    this.isOperational = true;
    this.errorCode = options.code;
    this.disposition = options.disposition;
    this.retryable = options.retryable;
    this.currentVersion = options.currentVersion;
    Error.captureStackTrace(this, this.constructor);
  }
}

const permanentOfflineSyncError = (
  message: string,
  code:
    | 'OFFLINE_SYNC_ACCOUNT_INACTIVE'
    | 'OFFLINE_SYNC_ACCESS_REVOKED'
    | 'OFFLINE_SYNC_ROLE_FORBIDDEN'
    | 'OFFLINE_SYNC_PROJECT_UNAVAILABLE'
    | 'OFFLINE_SYNC_OWNER_MISMATCH'
    | 'OFFLINE_SYNC_PROJECT_MISMATCH'
    | 'OFFLINE_SYNC_PARENT_INACCESSIBLE'
    | 'OFFLINE_SYNC_PAYLOAD_REJECTED'
    | 'OFFLINE_SYNC_IDEMPOTENCY_MISMATCH'
    | 'OFFLINE_SYNC_ATTACHMENT_REJECTED',
  statusCode = 403,
): AppError =>
  new AppError(message, statusCode, {
    code,
    disposition: 'permanent_rejection',
    retryable: false,
  });

const offlineSyncConflictError = (currentVersion: number): AppError =>
  new AppError('Offline submission conflicts with a newer server revision.', 409, {
    code: 'OFFLINE_SYNC_VERSION_CONFLICT',
    disposition: 'conflict',
    retryable: false,
    currentVersion,
  });

// Not found handler
const notFound = (req: Request, _res: Response, next: NextFunction): void => {
  const error = new AppError(`Not found - ${req.originalUrl}`, 404);
  next(error);
};

// Global error handler
const errorHandler = (err: unknown, req: Request, res: Response, _next: NextFunction): void => {
  const error = err as Partial<NodeJS.ErrnoException> & {
    statusCode?: number;
    message?: string;
    stack?: string;
    name?: string;
    code?: string;
    errorCode?: string;
    disposition?: string;
    retryable?: boolean;
    currentVersion?: number;
    type?: string;
  };
  let statusCode = error.statusCode ?? 500;
  let message = error.message ?? 'Internal Server Error';
  let responseErrorCode = error.errorCode;
  let responseDisposition = error.disposition;
  let responseRetryable = error.retryable;

  // PostgreSQL errors
  if (error.code) {
    switch (error.code) {
      case '23505': // Unique violation
        statusCode = 409;
        message = 'Resource already exists';
        break;
      case '23503': // Foreign key violation
        statusCode = 400;
        message = 'Invalid reference to related resource';
        break;
      case '23502': // Not null violation
        statusCode = 400;
        message = 'Required field is missing';
        break;
      case '22P02': // Invalid text representation
        statusCode = 400;
        message = 'Invalid data format';
        break;
      case '42P01': // Undefined table
        statusCode = 500;
        message = 'Database configuration error';
        break;
    }
  }

  // JWT errors
  if (error.name === 'JsonWebTokenError') {
    statusCode = 401;
    message = 'Invalid token';
  }

  if (error.name === 'TokenExpiredError') {
    statusCode = 401;
    message = 'Token expired';
  }

  // Multer errors (file upload)
  if (error.name === 'MulterError') {
    statusCode = 400;
    if (error.code === 'LIMIT_FILE_SIZE') {
      message = 'File size too large';
    } else if (error.code === 'LIMIT_FILE_COUNT') {
      message = 'Too many files';
    } else {
      message = 'File upload error';
    }
  }

  const hasOfflineHeaders = [
    req.headers['x-offline-owner-id'],
    req.headers['x-offline-project-id'],
    req.headers['idempotency-key'],
  ].some((value) => typeof value === 'string' && value.trim().length > 0);
  if (
    hasOfflineHeaders &&
    (error.type === 'entity.parse.failed' || error.type === 'entity.too.large')
  ) {
    statusCode = error.type === 'entity.too.large' ? 413 : 422;
    message = 'Offline submission payload was rejected.';
    responseErrorCode = 'OFFLINE_SYNC_PAYLOAD_REJECTED';
    responseDisposition = 'permanent_rejection';
    responseRetryable = false;
  }

  if (hasOfflineHeaders && statusCode >= 500 && !responseErrorCode) {
    message = 'Offline synchronization is temporarily unavailable. Please retry later.';
    responseErrorCode = 'OFFLINE_SYNC_TEMPORARY_FAILURE';
    responseDisposition = 'retry';
    responseRetryable = true;
  }

  // Request bodies and file contents are intentionally excluded. This also
  // keeps rejected unsafe payloads out of normal logs.
  logger.error('Error:', {
    message: error.message,
    statusCode,
    stack: error.stack,
    requestId: req.requestId,
    url: req.originalUrl,
    method: req.method,
    ip: req.ip,
    userId: req.user?.id,
    errorCode: responseErrorCode,
  });

  // Send response
  res.status(statusCode).json({
    success: false,
    requestId: req.requestId,
    message,
    ...(responseErrorCode && responseDisposition
      ? {
          error: {
            code: responseErrorCode,
            disposition: responseDisposition,
            retryable: responseRetryable === true,
            ...(typeof error.currentVersion === 'number' &&
            Number.isSafeInteger(error.currentVersion) &&
            error.currentVersion > 0
              ? { current_version: error.currentVersion }
              : {}),
          },
        }
      : {}),
    ...(process.env.NODE_ENV === 'development' && {
      stack: error.stack,
      errorDetails: {
        name: error.name,
        type: error.type,
        code: responseErrorCode ?? error.code,
      },
    }),
  });
};

// Async handler wrapper
const asyncHandler =
  <TReq extends Request = Request, TRes extends Response = Response>(
    fn: (req: TReq, res: TRes, next: NextFunction) => Promise<unknown> | unknown,
  ) =>
  (req: TReq, res: TRes, next: NextFunction): void => {
    Promise.resolve(fn(req, res, next)).catch(next);
  };

export {
  AppError,
  permanentOfflineSyncError,
  offlineSyncConflictError,
  notFound,
  errorHandler,
  asyncHandler,
};
