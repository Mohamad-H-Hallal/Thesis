import type { NextFunction, Request, Response } from 'express';
const logger = require('../utils/logger');

// Custom error class
class AppError extends Error {
  statusCode: number;
  isOperational: boolean;

  constructor(message: string, statusCode: number) {
    super(message);
    this.statusCode = statusCode;
    this.isOperational = true;
    Error.captureStackTrace(this, this.constructor);
  }
}

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
  };
  let statusCode = error.statusCode ?? 500;
  let message = error.message ?? 'Internal Server Error';

  // Log error
  logger.error('Error:', {
    message: error.message,
    statusCode,
    stack: error.stack,
    requestId: req.requestId,
    url: req.originalUrl,
    method: req.method,
    ip: req.ip,
    userId: req.user?.id,
  });

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

  // Send response
  res.status(statusCode).json({
    success: false,
    requestId: req.requestId,
    message,
    ...(process.env.NODE_ENV === 'development' && {
      stack: error.stack,
      error,
    }),
  });
};

// Async handler wrapper
const asyncHandler = <TReq extends Request = Request, TRes extends Response = Response>(
  fn: (req: TReq, res: TRes, next: NextFunction) => Promise<unknown> | unknown
) => (req: TReq, res: TRes, next: NextFunction): void => {
  Promise.resolve(fn(req, res, next)).catch(next);
};

export { AppError, notFound, errorHandler, asyncHandler };
