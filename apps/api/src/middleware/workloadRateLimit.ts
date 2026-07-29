import rateLimit from 'express-rate-limit';
import type { Request, Response } from 'express';
import { createSharedRateLimitStore } from '../services/sharedRateLimit.service';

const positiveIntegerSetting = (name: string, fallback: number): number => {
  const parsed = Number.parseInt(process.env[name] ?? '', 10);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
};

const retryableHandler =
  (code: string, message: string) =>
  (req: Request, res: Response): void => {
    const resetTime = (req as Request & { rateLimit?: { resetTime?: Date } }).rateLimit?.resetTime;
    if (resetTime) {
      res.setHeader(
        'Retry-After',
        String(Math.max(1, Math.ceil((resetTime.getTime() - Date.now()) / 1000))),
      );
    }
    res.status(429).json({
      success: false,
      requestId: req.requestId,
      message,
      error: {
        code,
        disposition: 'retry',
        retryable: true,
      },
    });
  };

const userKey = (scope: string) => (req: Request): string =>
  `${scope}:${req.user?.id ?? req.ip ?? 'unknown'}`;

const buildWorkloadLimiter = ({
  policy,
  maxSetting,
  fallback,
  code,
  message,
  authenticated = true,
}: {
  policy: string;
  maxSetting: string;
  fallback: number;
  code: string;
  message: string;
  authenticated?: boolean;
}) =>
  rateLimit({
    windowMs: positiveIntegerSetting('RATE_LIMIT_WORKLOAD_WINDOW_MS', 60000),
    max: positiveIntegerSetting(maxSetting, fallback),
    standardHeaders: true,
    legacyHeaders: false,
    passOnStoreError: false,
    ...(authenticated ? { keyGenerator: userKey(policy) } : {}),
    store: createSharedRateLimitStore(policy),
    handler: retryableHandler(code, message),
  });

const importUploadRateLimit = buildWorkloadLimiter({
  policy: 'import-upload',
  maxSetting: 'RATE_LIMIT_IMPORT_MAX_REQUESTS',
  fallback: 6,
  code: 'IMPORT_RATE_LIMITED',
  message: 'Import requests are temporarily rate limited. Please retry later.',
});

const exportCreateRateLimit = buildWorkloadLimiter({
  policy: 'export-create',
  maxSetting: 'RATE_LIMIT_EXPORT_MAX_REQUESTS',
  fallback: 10,
  code: 'EXPORT_RATE_LIMITED',
  message: 'Export requests are temporarily rate limited. Please retry later.',
});

const aiJobRateLimit = buildWorkloadLimiter({
  policy: 'ai-jobs',
  maxSetting: 'RATE_LIMIT_AI_JOB_MAX_REQUESTS',
  fallback: 10,
  code: 'AI_JOB_RATE_LIMITED',
  message: 'AI job operations are temporarily rate limited. Please retry later.',
});

const mapAggregationRateLimit = buildWorkloadLimiter({
  policy: 'map-aggregation',
  maxSetting: 'RATE_LIMIT_MAP_MAX_REQUESTS',
  fallback: 60,
  code: 'MAP_AGGREGATION_RATE_LIMITED',
  message: 'Map aggregation is temporarily rate limited. Please retry later.',
});

const notificationMutationRateLimit = buildWorkloadLimiter({
  policy: 'notification-mutation',
  maxSetting: 'RATE_LIMIT_NOTIFICATION_MAX_REQUESTS',
  fallback: 30,
  code: 'NOTIFICATION_RATE_LIMITED',
  message: 'Notification operations are temporarily rate limited. Please retry later.',
});

const passwordResetRateLimit = buildWorkloadLimiter({
  policy: 'password-reset',
  maxSetting: 'RATE_LIMIT_PASSWORD_RESET_MAX_REQUESTS',
  fallback: 5,
  code: 'PASSWORD_RESET_RATE_LIMITED',
  message: 'Password reset requests are temporarily rate limited. Please retry later.',
  authenticated: false,
});

export {
  aiJobRateLimit,
  exportCreateRateLimit,
  importUploadRateLimit,
  mapAggregationRateLimit,
  notificationMutationRateLimit,
  passwordResetRateLimit,
};
