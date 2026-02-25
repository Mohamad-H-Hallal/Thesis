import 'dotenv/config';
import { pool } from '../config/database';
import { getPendingMigrations } from './migrationRunner';
const logger = require('../utils/logger');

interface VerifyConfig {
  strict: boolean;
  minUsers: number;
  minProjects: number;
  minAssignments: number;
  minFeatures: number;
  minPhotos: number;
  minCompletedExports: number;
  maxBboxMs: number;
}

interface CheckResult {
  name: string;
  ok: boolean;
  details: string;
}

const parseIntEnv = (name: string, fallback: number, min = 0): number => {
  const raw = process.env[name];
  if (!raw) {
    return fallback;
  }
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed < min) {
    return fallback;
  }
  return parsed;
};

const parseBooleanEnv = (name: string, fallback: boolean): boolean => {
  const raw = process.env[name];
  if (!raw) {
    return fallback;
  }
  const normalized = raw.trim().toLowerCase();
  if (['1', 'true', 'yes', 'y'].includes(normalized)) {
    return true;
  }
  if (['0', 'false', 'no', 'n'].includes(normalized)) {
    return false;
  }
  return fallback;
};

const buildConfig = (): VerifyConfig => ({
  strict: parseBooleanEnv('STAGING_VERIFY_STRICT', true),
  minUsers: parseIntEnv('STAGING_VERIFY_MIN_USERS', 40, 1),
  minProjects: parseIntEnv('STAGING_VERIFY_MIN_PROJECTS', 10, 1),
  minAssignments: parseIntEnv('STAGING_VERIFY_MIN_ASSIGNMENTS', 60, 1),
  minFeatures: parseIntEnv('STAGING_VERIFY_MIN_FEATURES', 1500, 1),
  minPhotos: parseIntEnv('STAGING_VERIFY_MIN_PHOTOS', 300, 1),
  minCompletedExports: parseIntEnv('STAGING_VERIFY_MIN_COMPLETED_EXPORTS', 5, 1),
  maxBboxMs: parseIntEnv('STAGING_VERIFY_MAX_BBOX_MS', 400, 1),
});

const collectPlanNodes = (planNode: any, nodes: any[] = []): any[] => {
  nodes.push(planNode);
  if (Array.isArray(planNode?.Plans)) {
    for (const child of planNode.Plans) {
      collectPlanNodes(child, nodes);
    }
  }
  return nodes;
};

const run = async (): Promise<void> => {
  const config = buildConfig();
  const client = await pool.connect();
  const checks: CheckResult[] = [];
  const start = Date.now();

  logger.info('Phase 11 staging verification started', config);

  try {
    const pending = await getPendingMigrations();
    checks.push({
      name: 'Pending migrations',
      ok: pending.length === 0,
      details: pending.length === 0 ? 'none pending' : `pending: ${pending.join(', ')}`,
    });

    const countStatements = [
      ['users', 'SELECT COUNT(*)::int AS value FROM "user"', config.minUsers],
      ['projects', 'SELECT COUNT(*)::int AS value FROM project', config.minProjects],
      ['assignments', 'SELECT COUNT(*)::int AS value FROM project_assignment', config.minAssignments],
      ['features', 'SELECT COUNT(*)::int AS value FROM spatial_feature', config.minFeatures],
      ['photos', 'SELECT COUNT(*)::int AS value FROM photo', config.minPhotos],
      [
        'completed_exports',
        "SELECT COUNT(*)::int AS value FROM shapefile_export WHERE status = 'completed'",
        config.minCompletedExports,
      ],
    ] as const;

    for (const [label, statement, min] of countStatements) {
      const result = await client.query<{ value: number }>(statement);
      const value = result.rows[0]?.value ?? 0;
      checks.push({
        name: `Dataset volume: ${label}`,
        ok: value >= min,
        details: `value=${value}, required>=${min}`,
      });
    }

    const explainResult = await client.query(
      `EXPLAIN (FORMAT JSON)
       SELECT sf.id
       FROM spatial_feature sf
       WHERE sf.geom && ST_MakeEnvelope($1, $2, $3, $4, 4326)
         AND sf.status = 'approved'
       ORDER BY sf.collected_at DESC
       LIMIT 100`,
      [35.0, 33.0, 36.6, 34.7]
    );

    const planRoot = explainResult.rows[0]['QUERY PLAN'][0].Plan;
    const nodes = collectPlanNodes(planRoot);
    const indexNode = nodes.find((node) => typeof node['Index Name'] === 'string');
    const indexName = indexNode?.['Index Name'] ?? '';

    checks.push({
      name: 'BBOX query uses spatial index',
      ok: /idx_spatial_feature_geom|idx_spatial_feature_geom_project_status/i.test(indexName),
      details: indexName || 'index not found in plan',
    });

    const bboxStart = process.hrtime.bigint();
    await client.query(
      `SELECT sf.id
       FROM spatial_feature sf
       WHERE sf.geom && ST_MakeEnvelope($1, $2, $3, $4, 4326)
       ORDER BY sf.collected_at DESC
       LIMIT 500`,
      [35.0, 33.0, 36.6, 34.7]
    );
    const bboxDurationMs = Number(process.hrtime.bigint() - bboxStart) / 1e6;
    checks.push({
      name: 'BBOX performance baseline',
      ok: bboxDurationMs <= config.maxBboxMs,
      details: `durationMs=${bboxDurationMs.toFixed(2)}, required<=${config.maxBboxMs}`,
    });

    const failed = checks.filter((check) => !check.ok);
    for (const check of checks) {
      const level = check.ok ? 'info' : 'warn';
      logger[level](`Phase11 verify: ${check.name}`, { ok: check.ok, details: check.details });
    }

    const elapsedMs = Date.now() - start;
    logger.info('Phase 11 staging verification completed', {
      elapsedMs,
      totalChecks: checks.length,
      failedChecks: failed.length,
      strictMode: config.strict,
    });

    if (failed.length > 0 && config.strict) {
      process.exitCode = 1;
    }
  } catch (error: unknown) {
    logger.error('Phase 11 staging verification failed:', error);
    process.exitCode = 1;
  } finally {
    client.release();
    await pool.end().catch(() => {});
  }
};

void run();
