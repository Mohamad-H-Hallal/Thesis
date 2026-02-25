import type { NextFunction, Request, Response } from 'express';
import { query } from '../config/database';
const logger = require('../utils/logger');

interface RequestMetricsState {
  totalRequests: number;
  inFlightRequests: number;
  statusCounts: Record<string, number>;
  routeCounts: Record<string, number>;
  startedAt: string;
}

const requestMetrics: RequestMetricsState = {
  totalRequests: 0,
  inFlightRequests: 0,
  statusCounts: {},
  routeCounts: {},
  startedAt: new Date().toISOString(),
};

const collectRequestMetrics = (req: Request, res: Response, next: NextFunction): void => {
  requestMetrics.totalRequests += 1;
  requestMetrics.inFlightRequests += 1;

  const routeKey = `${req.method} ${req.path}`;
  requestMetrics.routeCounts[routeKey] = (requestMetrics.routeCounts[routeKey] ?? 0) + 1;

  res.on('finish', () => {
    requestMetrics.inFlightRequests = Math.max(0, requestMetrics.inFlightRequests - 1);
    const statusClass = `${Math.floor(res.statusCode / 100)}xx`;
    requestMetrics.statusCounts[statusClass] = (requestMetrics.statusCounts[statusClass] ?? 0) + 1;
  });

  next();
};

const getMetricsSnapshot = () => {
  return {
    app: {
      uptimeSeconds: Math.round(process.uptime()),
      memory: process.memoryUsage(),
      startedAt: requestMetrics.startedAt,
      nodeVersion: process.version,
      env: process.env.NODE_ENV,
    },
    http: {
      totalRequests: requestMetrics.totalRequests,
      inFlightRequests: requestMetrics.inFlightRequests,
      statusCounts: requestMetrics.statusCounts,
      topRoutes: Object.entries(requestMetrics.routeCounts)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 10)
        .map(([route, count]) => ({ route, count })),
    },
  };
};

const assertMetricsConfig = (env: {
  NODE_ENV: string;
  METRICS_ENABLED: boolean;
  METRICS_TOKEN?: string;
}): void => {
  if (env.NODE_ENV !== 'production') {
    return;
  }

  if (!env.METRICS_ENABLED) {
    return;
  }

  if (!String(env.METRICS_TOKEN ?? '').trim()) {
    throw new Error('METRICS_TOKEN is required when METRICS_ENABLED=true in production');
  }
};

const metricsHandler = (req: Request, res: Response): void => {
  const metricsToken = process.env.METRICS_TOKEN ?? '';
  if (metricsToken) {
    const bearer = req.headers.authorization?.startsWith('Bearer ')
      ? req.headers.authorization.slice('Bearer '.length)
      : '';
    const headerToken = (req.headers['x-metrics-token'] as string | undefined) ?? '';
    const provided = bearer || headerToken;

    if (provided !== metricsToken) {
      res.status(401).json({
        success: false,
        message: 'Unauthorized metrics access',
        requestId: req.requestId,
      });
      return;
    }
  }

  res.json({
    success: true,
    requestId: req.requestId,
    data: getMetricsSnapshot(),
  });
};

const readinessHandler = async (req: Request, res: Response): Promise<void> => {
  try {
    const startedAt = Date.now();
    await query('SELECT 1 AS ok');
    const dbLatencyMs = Date.now() - startedAt;

    res.json({
      success: true,
      status: 'ready',
      requestId: req.requestId,
      checks: {
        database: {
          status: 'up',
          latencyMs: dbLatencyMs,
        },
      },
      timestamp: new Date().toISOString(),
    });
  } catch (error) {
    logger.error('Readiness check failed', { error });
    res.status(503).json({
      success: false,
      status: 'not_ready',
      requestId: req.requestId,
      checks: {
        database: {
          status: 'down',
        },
      },
      timestamp: new Date().toISOString(),
    });
  }
};

export {
  collectRequestMetrics,
  metricsHandler,
  readinessHandler,
  getMetricsSnapshot,
  assertMetricsConfig,
};
