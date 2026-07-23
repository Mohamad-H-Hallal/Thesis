import rateLimit from 'express-rate-limit';
import type { Request, Response } from 'express';
import { requestHasOfflineSyncSignal } from '../services/offlineSyncSecurity.service';

const positiveIntegerSetting = (value: string | undefined, fallback: number): number => {
  const parsed = Number.parseInt(value ?? '', 10);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
};

const looksLikeOfflineSync = (req: Request): boolean => requestHasOfflineSyncSignal(req);

const looksLikeOfflineSyncIngress = (req: Request): boolean => {
  const requestPath = req.path.toLowerCase();
  if (
    req.method === 'POST' &&
    /\/photos\/feature\/[^/]+\/?$/.test(requestPath)
  ) {
    return true;
  }
  return (
    ['POST', 'PUT', 'PATCH'].includes(req.method) &&
    /\/features(?:\/|$)/.test(requestPath)
  );
};

const retryableRateLimitResponse = (req: Request, res: Response): void => {
  const resetTime = (req as Request & { rateLimit?: { resetTime?: Date } }).rateLimit?.resetTime;
  if (resetTime) {
    const seconds = Math.max(1, Math.ceil((resetTime.getTime() - Date.now()) / 1000));
    res.setHeader('Retry-After', String(seconds));
  }
  res.status(429).json({
    success: false,
    requestId: req.requestId,
    message: 'Offline synchronization is temporarily rate limited. Please retry later.',
    error: {
      code: 'OFFLINE_SYNC_RATE_LIMITED',
      disposition: 'retry',
      retryable: true,
    },
  });
};

const buildOfflineSyncLimiter = ({ always }: { always: boolean }) =>
  rateLimit({
    windowMs: positiveIntegerSetting(process.env.OFFLINE_SYNC_RATE_LIMIT_WINDOW_MS, 60000),
    max: positiveIntegerSetting(process.env.OFFLINE_SYNC_RATE_LIMIT_MAX_REQUESTS, 60),
    standardHeaders: true,
    legacyHeaders: false,
    skip: (req) => !always && !looksLikeOfflineSync(req),
    keyGenerator: (req) => `offline-sync:${req.user?.id ?? 'unauthenticated'}`,
    handler: retryableRateLimitResponse,
  });

const offlineSyncRateLimit = buildOfflineSyncLimiter({ always: false });
const offlineBundleRateLimit = buildOfflineSyncLimiter({ always: true });
const featurePhotoUploadRateLimit = buildOfflineSyncLimiter({ always: true });
const offlineSyncIngressRateLimit = rateLimit({
  windowMs: positiveIntegerSetting(process.env.OFFLINE_SYNC_RATE_LIMIT_WINDOW_MS, 60000),
  max: positiveIntegerSetting(process.env.OFFLINE_SYNC_INGRESS_RATE_LIMIT_MAX_REQUESTS, 240),
  standardHeaders: true,
  legacyHeaders: false,
  skip: (req) => !looksLikeOfflineSyncIngress(req),
  handler: retryableRateLimitResponse,
});

export {
  offlineSyncRateLimit,
  offlineBundleRateLimit,
  featurePhotoUploadRateLimit,
  offlineSyncIngressRateLimit,
  looksLikeOfflineSync,
  looksLikeOfflineSyncIngress,
};
