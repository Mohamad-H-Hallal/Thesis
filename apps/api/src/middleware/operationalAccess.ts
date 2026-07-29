import { createHash, timingSafeEqual } from 'node:crypto';
import type { NextFunction, Request, Response } from 'express';

const digest = (value: string): Buffer => createHash('sha256').update(value).digest();

const safeTokenEqual = (provided: string, expected: string): boolean => {
  if (!provided || !expected) {
    return false;
  }
  return timingSafeEqual(digest(provided), digest(expected));
};

const requestToken = (req: Request, headerName: string): string => {
  const authorization = req.headers.authorization ?? '';
  if (authorization.startsWith('Bearer ')) {
    return authorization.slice('Bearer '.length).trim();
  }
  const headerValue = req.headers[headerName.toLowerCase()];
  return typeof headerValue === 'string' ? headerValue.trim() : '';
};

const createOperationalTokenGuard = ({
  expectedToken,
  headerName,
  hidden = false,
}: {
  expectedToken: string;
  headerName: string;
  hidden?: boolean;
}) =>
  (req: Request, res: Response, next: NextFunction): void => {
    if (safeTokenEqual(requestToken(req, headerName), expectedToken)) {
      next();
      return;
    }

    res.status(hidden ? 404 : 401).json({
      success: false,
      requestId: req.requestId,
      message: hidden ? 'Not found' : 'Unauthorized operational endpoint access',
    });
  };

export { createOperationalTokenGuard, requestToken, safeTokenEqual };
