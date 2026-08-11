import { statfs } from 'node:fs/promises';
import path from 'node:path';
import type { NextFunction, Request, Response } from 'express';
import { query } from '../config/database';
import { getRateLimitBackendReadiness } from '../services/sharedRateLimit.service';
import { normalizeRequestPath } from './requestContext';
const logger = require('../utils/logger');

interface RouteMetric {
  method: string;
  path: string;
  statusClass: string;
  statusCode: string;
  count: number;
}

interface RequestMetricsState {
  totalRequests: number;
  inFlightRequests: number;
  statusCounts: Record<string, number>;
  routeCounts: Record<string, RouteMetric>;
  durationBucketCounts: number[];
  durationSumSeconds: number;
  startedAt: string;
}

const durationBucketsSeconds = [0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30];
const maxRouteSeries = 200;
const requestMetrics: RequestMetricsState = {
  totalRequests: 0,
  inFlightRequests: 0,
  statusCounts: {},
  routeCounts: {},
  durationBucketCounts: durationBucketsSeconds.map(() => 0),
  durationSumSeconds: 0,
  startedAt: new Date().toISOString(),
};

const routeMetricKey = (
  method: string,
  requestPath: string,
  statusClass: string,
  statusCode: string,
): string => `${method}\u0000${requestPath}\u0000${statusClass}\u0000${statusCode}`;

const collectRequestMetrics = (req: Request, res: Response, next: NextFunction): void => {
  requestMetrics.totalRequests += 1;
  requestMetrics.inFlightRequests += 1;
  const startedAt = process.hrtime.bigint();

  res.on('finish', () => {
    requestMetrics.inFlightRequests = Math.max(0, requestMetrics.inFlightRequests - 1);
    const statusClass = `${Math.floor(res.statusCode / 100)}xx`;
    const statusCode = String(res.statusCode);
    requestMetrics.statusCounts[statusClass] = (requestMetrics.statusCounts[statusClass] ?? 0) + 1;

    const method = req.method.toUpperCase();
    let requestPath = normalizeRequestPath(req.originalUrl);
    let key = routeMetricKey(method, requestPath, statusClass, statusCode);
    if (!requestMetrics.routeCounts[key] && Object.keys(requestMetrics.routeCounts).length >= maxRouteSeries) {
      requestPath = '/other';
      key = routeMetricKey(method, requestPath, statusClass, statusCode);
    }
    const routeMetric = requestMetrics.routeCounts[key] ?? {
      method,
      path: requestPath,
      statusClass,
      statusCode,
      count: 0,
    };
    routeMetric.count += 1;
    requestMetrics.routeCounts[key] = routeMetric;

    const durationSeconds = Number(process.hrtime.bigint() - startedAt) / 1_000_000_000;
    requestMetrics.durationSumSeconds += durationSeconds;
    durationBucketsSeconds.forEach((upperBound, index) => {
      if (durationSeconds <= upperBound) {
        requestMetrics.durationBucketCounts[index] += 1;
      }
    });
  });

  next();
};

const getMetricsSnapshot = () => ({
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
    statusCounts: { ...requestMetrics.statusCounts },
    topRoutes: Object.values(requestMetrics.routeCounts)
      .sort((a, b) => b.count - a.count)
      .slice(0, 10)
      .map(({ method, path: requestPath, statusClass, statusCode, count }) => ({
        method,
        path: requestPath,
        statusClass,
        statusCode,
        count,
      })),
  },
});

const assertMetricsConfig = (env: {
  NODE_ENV: string;
  METRICS_ENABLED: boolean;
  METRICS_TOKEN?: string;
}): void => {
  if (
    env.NODE_ENV === 'production' &&
    env.METRICS_ENABLED &&
    !String(env.METRICS_TOKEN ?? '').trim()
  ) {
    throw new Error('METRICS_TOKEN is required when METRICS_ENABLED=true in production');
  }
};

const escapeLabelValue = (value: string): string =>
  value.replace(/\\/g, '\\\\').replace(/\n/g, '\\n').replace(/"/g, '\\"');

const metricLine = (
  name: string,
  value: number,
  labels: Record<string, string> = {},
): string => {
  const entries = Object.entries(labels);
  const renderedLabels =
    entries.length === 0
      ? ''
      : `{${entries
          .map(([key, labelValue]) => `${key}="${escapeLabelValue(labelValue)}"`)
          .join(',')}}`;
  return `${name}${renderedLabels} ${Number.isFinite(value) ? value : 0}`;
};

const appendMetricHeader = (
  lines: string[],
  name: string,
  help: string,
  type: 'counter' | 'gauge' | 'histogram',
): void => {
  lines.push(`# HELP ${name} ${help}`, `# TYPE ${name} ${type}`);
};

interface OperationalCounts {
  workload_queued: string;
  workload_running: string;
  workload_dead_letter: string;
  cleanup_backlog: string;
  quarantine_pending: string;
  malware_detected_recent: string;
}

const getOperationalCounts = async (): Promise<{
  databaseReady: number;
  counts: OperationalCounts | null;
}> => {
  try {
    const result = await query<OperationalCounts>(
      `SELECT
         (SELECT COUNT(*) FROM workload_job WHERE status = 'queued')::text AS workload_queued,
         (SELECT COUNT(*) FROM workload_job WHERE status = 'running')::text AS workload_running,
         (SELECT COUNT(*) FROM workload_job WHERE status = 'dead_letter')::text AS workload_dead_letter,
         (SELECT COUNT(*) FROM feature_media_cleanup_job)::text AS cleanup_backlog,
         (
           SELECT COUNT(*)
           FROM upload_quarantine_record
           WHERE disposition = 'quarantined' AND scan_status IN ('pending', 'unavailable')
         )::text AS quarantine_pending,
         (
           SELECT COUNT(*)
           FROM upload_quarantine_record
           WHERE scan_status = 'infected'
             AND created_at >= CURRENT_TIMESTAMP - INTERVAL '15 minutes'
         )::text AS malware_detected_recent`,
    );
    return {
      databaseReady: 1,
      counts: result.rows[0] ?? null,
    };
  } catch (error) {
    logger.error('Metrics database collection failed', {
      errorName: error instanceof Error ? error.name : 'UnknownMetricsDatabaseError',
    });
    return {
      databaseReady: 0,
      counts: null,
    };
  }
};

const getAvailableBytes = async (targetPath: string): Promise<number | null> => {
  try {
    const stats = await statfs(path.resolve(targetPath));
    return Number(stats.bavail) * Number(stats.bsize);
  } catch {
    return null;
  }
};

const renderPrometheusMetrics = async ({
  uploadDir,
  exportDir,
}: {
  uploadDir: string;
  exportDir: string;
}): Promise<string> => {
  const lines: string[] = [];
  const memory = process.memoryUsage();
  const completedRequests = Object.values(requestMetrics.statusCounts).reduce(
    (total, count) => total + count,
    0,
  );
  const [operational, rateLimitBackend, uploadAvailable, exportAvailable] = await Promise.all([
    getOperationalCounts(),
    getRateLimitBackendReadiness(),
    getAvailableBytes(uploadDir),
    getAvailableBytes(exportDir),
  ]);

  appendMetricHeader(lines, 'gis_api_info', 'Static API runtime information.', 'gauge');
  lines.push(
    metricLine('gis_api_info', 1, {
      node_version: process.version,
      environment: process.env.NODE_ENV ?? 'unknown',
    }),
  );
  appendMetricHeader(lines, 'gis_api_uptime_seconds', 'API process uptime in seconds.', 'gauge');
  lines.push(metricLine('gis_api_uptime_seconds', process.uptime()));
  appendMetricHeader(
    lines,
    'gis_api_process_resident_memory_bytes',
    'Resident memory used by the API process.',
    'gauge',
  );
  lines.push(metricLine('gis_api_process_resident_memory_bytes', memory.rss));
  appendMetricHeader(
    lines,
    'gis_api_http_requests_total',
    'Completed HTTP requests by method, normalized path, and status class.',
    'counter',
  );
  for (const routeMetric of Object.values(requestMetrics.routeCounts)) {
    lines.push(
      metricLine('gis_api_http_requests_total', routeMetric.count, {
        method: routeMetric.method,
        path: routeMetric.path,
        status_class: routeMetric.statusClass,
        status_code: routeMetric.statusCode,
      }),
    );
  }
  appendMetricHeader(
    lines,
    'gis_api_http_requests_in_flight',
    'HTTP requests currently being processed.',
    'gauge',
  );
  lines.push(metricLine('gis_api_http_requests_in_flight', requestMetrics.inFlightRequests));
  appendMetricHeader(
    lines,
    'gis_api_http_request_duration_seconds',
    'HTTP request duration histogram.',
    'histogram',
  );
  durationBucketsSeconds.forEach((upperBound, index) => {
    lines.push(
      metricLine(
        'gis_api_http_request_duration_seconds_bucket',
        requestMetrics.durationBucketCounts[index],
        { le: String(upperBound) },
      ),
    );
  });
  lines.push(
    metricLine('gis_api_http_request_duration_seconds_bucket', completedRequests, {
      le: '+Inf',
    }),
    metricLine('gis_api_http_request_duration_seconds_sum', requestMetrics.durationSumSeconds),
    metricLine('gis_api_http_request_duration_seconds_count', completedRequests),
  );

  appendMetricHeader(
    lines,
    'gis_api_dependency_ready',
    'Whether a required API dependency is ready.',
    'gauge',
  );
  lines.push(
    metricLine('gis_api_dependency_ready', operational.databaseReady, { dependency: 'database' }),
    metricLine('gis_api_dependency_ready', rateLimitBackend.status === 'down' ? 0 : 1, {
      dependency: 'rate_limit_backend',
    }),
  );

  if (operational.counts) {
    appendMetricHeader(
      lines,
      'gis_api_workload_jobs',
      'Durable workload jobs by operational state.',
      'gauge',
    );
    lines.push(
      metricLine('gis_api_workload_jobs', Number(operational.counts.workload_queued), {
        status: 'queued',
      }),
      metricLine('gis_api_workload_jobs', Number(operational.counts.workload_running), {
        status: 'running',
      }),
      metricLine('gis_api_workload_jobs', Number(operational.counts.workload_dead_letter), {
        status: 'dead_letter',
      }),
    );
    appendMetricHeader(
      lines,
      'gis_api_media_cleanup_backlog',
      'Feature-media cleanup jobs waiting for completion.',
      'gauge',
    );
    lines.push(
      metricLine('gis_api_media_cleanup_backlog', Number(operational.counts.cleanup_backlog)),
    );
    appendMetricHeader(
      lines,
      'gis_api_quarantine_pending',
      'Uploads still quarantined because scanning is pending or unavailable.',
      'gauge',
    );
    lines.push(
      metricLine('gis_api_quarantine_pending', Number(operational.counts.quarantine_pending)),
    );
    appendMetricHeader(
      lines,
      'gis_api_malware_detections_recent',
      'Malware detections recorded during the previous 15 minutes.',
      'gauge',
    );
    lines.push(
      metricLine(
        'gis_api_malware_detections_recent',
        Number(operational.counts.malware_detected_recent),
      ),
    );
  }

  appendMetricHeader(
    lines,
    'gis_api_storage_available_bytes',
    'Available bytes on API-managed storage filesystems.',
    'gauge',
  );
  if (uploadAvailable !== null) {
    lines.push(metricLine('gis_api_storage_available_bytes', uploadAvailable, { area: 'uploads' }));
  }
  if (exportAvailable !== null) {
    lines.push(metricLine('gis_api_storage_available_bytes', exportAvailable, { area: 'exports' }));
  }

  return `${lines.join('\n')}\n`;
};

const createMetricsHandler = ({
  uploadDir,
  exportDir,
}: {
  uploadDir: string;
  exportDir: string;
}) =>
  async (req: Request, res: Response): Promise<void> => {
    try {
      const metrics = await renderPrometheusMetrics({ uploadDir, exportDir });
      res
        .status(200)
        .type('text/plain; version=0.0.4; charset=utf-8')
        .send(metrics);
  } catch (error) {
    logger.error('Metrics rendering failed', {
      requestId: req.requestId,
      errorName: error instanceof Error ? error.name : 'UnknownMetricsRenderingError',
      });
      res.status(503).json({
        success: false,
        requestId: req.requestId,
        message: 'Metrics are temporarily unavailable',
      });
    }
  };

const readinessHandler = async (req: Request, res: Response): Promise<void> => {
  const startedAt = Date.now();
  let databaseCheck: { status: 'up' | 'down'; latencyMs?: number };
  try {
    await query('SELECT 1 AS ok');
    databaseCheck = {
      status: 'up',
      latencyMs: Date.now() - startedAt,
    };
  } catch {
    databaseCheck = {
      status: 'down',
    };
  }
  const rateLimitBackend = await getRateLimitBackendReadiness();
  const ready = databaseCheck.status === 'up' && rateLimitBackend.status !== 'down';
  const diagnosticChecks =
    process.env.NODE_ENV === 'production'
      ? undefined
      : {
          database: databaseCheck,
          rateLimitBackend,
        };

  if (ready) {
    res.json({
      success: true,
      status: 'ready',
      requestId: req.requestId,
      ...(diagnosticChecks ? { checks: diagnosticChecks } : {}),
      timestamp: new Date().toISOString(),
    });
    return;
  }

  logger.error('Readiness check failed', {
    database: databaseCheck.status,
    rateLimitBackend: rateLimitBackend.status,
  });
  res.status(503).json({
    success: false,
    status: 'not_ready',
    requestId: req.requestId,
    ...(diagnosticChecks ? { checks: diagnosticChecks } : {}),
    timestamp: new Date().toISOString(),
  });
};

export {
  assertMetricsConfig,
  collectRequestMetrics,
  createMetricsHandler,
  getMetricsSnapshot,
  readinessHandler,
  renderPrometheusMetrics,
};
