import { randomUUID } from 'crypto';
import type { NextFunction, Request, Response } from 'express';
const logger = require('../utils/logger');

const attachRequestContext = (req: Request, res: Response, next: NextFunction): void => {
  const incoming = req.headers['x-request-id'];
  const requestId = typeof incoming === 'string' && incoming.trim().length > 0
    ? incoming.trim()
    : randomUUID();

  req.requestId = requestId;
  req.startTimeMs = Date.now();
  res.setHeader('x-request-id', requestId);

  res.on('finish', () => {
    const durationMs = req.startTimeMs ? Date.now() - req.startTimeMs : undefined;
    logger.info('HTTP request completed', {
      requestId,
      method: req.method,
      path: req.originalUrl,
      statusCode: res.statusCode,
      durationMs,
      userId: req.user?.id,
      ip: req.ip,
    });
  });

  next();
};

export { attachRequestContext };
