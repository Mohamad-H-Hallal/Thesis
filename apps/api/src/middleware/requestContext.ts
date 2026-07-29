import { randomUUID } from 'crypto';
import type { NextFunction, Request, Response } from 'express';
const logger = require('../utils/logger');

const normalizeRequestPath = (originalUrl: string): string => {
  const pathname = originalUrl.split('?', 1)[0] || '/';
  return pathname
    .replace(
      /\/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}(?=\/|$)/gi,
      '/:id',
    )
    .replace(/\/\d+(?=\/|$)/g, '/:number')
    .slice(0, 256);
};

const normalizeRequestId = (incoming: unknown): string => {
  if (
    typeof incoming === 'string' &&
    /^[A-Za-z0-9._-]{1,128}$/.test(incoming.trim())
  ) {
    return incoming.trim();
  }
  return randomUUID();
};

const attachRequestContext = (req: Request, res: Response, next: NextFunction): void => {
  const requestId = normalizeRequestId(req.headers['x-request-id']);

  req.requestId = requestId;
  req.startTimeMs = Date.now();
  res.setHeader('x-request-id', requestId);

  res.on('finish', () => {
    const durationMs = req.startTimeMs ? Date.now() - req.startTimeMs : undefined;
    logger.info('HTTP request completed', {
      requestId,
      method: req.method,
      path: normalizeRequestPath(req.originalUrl),
      statusCode: res.statusCode,
      durationMs,
      userId: req.user?.id,
      ip: req.ip,
    });
  });

  next();
};

export { attachRequestContext, normalizeRequestId, normalizeRequestPath };
