import 'dotenv/config';
import { closePool, pool } from '../config/database';
import { validateEnv } from '../config/env';
import { ensureSuperAdminExists } from '../lib/userWorkflow';
const logger = require('../utils/logger');

const RUNTIME_TABLES = [
  'password_reset_request',
  'photo',
  'spatial_feature',
  'shapefile_export',
  'notification',
  'audit_log',
  'project_assignment',
  'project',
  'project_category',
  'lebanon_offline_map',
];

const assertResetAllowed = (): void => {
  const allowReset =
    String(process.env.ALLOW_RUNTIME_RESET ?? '')
      .trim()
      .toLowerCase() === 'true';

  if (!allowReset) {
    throw new Error(
      'Refusing to reset runtime data without ALLOW_RUNTIME_RESET=true. ' +
        'This command is destructive and intended only for clean local retesting.'
    );
  }

  const nodeEnv = String(process.env.NODE_ENV ?? 'development').trim().toLowerCase();
  if (nodeEnv === 'production') {
    throw new Error('Runtime reset is disabled in production.');
  }
};

const assertSuperAdminBootstrapConfigured = (): void => {
  const required = ['SUPER_ADMIN_EMAIL', 'SUPER_ADMIN_PASSWORD', 'SUPER_ADMIN_FULL_NAME'];
  const missing = required.filter((key) => !String(process.env[key] ?? '').trim());
  if (missing.length > 0) {
    throw new Error(
      `Runtime reset requires protected super admin bootstrap config. Missing: ${missing.join(', ')}`
    );
  }
};

const getSummary = async () => {
  const counts = await pool.query<{
    users: number;
    categories: number;
    projects: number;
    assignments: number;
    features: number;
    photos: number;
    exports: number;
    notifications: number;
    audit_logs: number;
    offline_maps: number;
  }>(
    `SELECT
       (SELECT COUNT(*)::int FROM "user") AS users,
       (SELECT COUNT(*)::int FROM project_category) AS categories,
       (SELECT COUNT(*)::int FROM project) AS projects,
       (SELECT COUNT(*)::int FROM project_assignment) AS assignments,
       (SELECT COUNT(*)::int FROM spatial_feature) AS features,
       (SELECT COUNT(*)::int FROM photo) AS photos,
       (SELECT COUNT(*)::int FROM shapefile_export) AS exports,
       (SELECT COUNT(*)::int FROM notification) AS notifications,
       (SELECT COUNT(*)::int FROM audit_log) AS audit_logs,
       (SELECT COUNT(*)::int FROM lebanon_offline_map) AS offline_maps`
  );

  const superAdmin = await pool.query<{
    email: string;
    role: string;
    is_active: boolean;
  }>(
    `SELECT email, role, is_active
     FROM "user"
     WHERE LOWER(email) = LOWER($1)
     LIMIT 1`,
    [process.env.SUPER_ADMIN_EMAIL]
  );

  return {
    counts: counts.rows[0],
    superAdmin: superAdmin.rows[0] ?? null,
  };
};

const run = async (): Promise<void> => {
  try {
    const env = validateEnv();
    assertResetAllowed();
    assertSuperAdminBootstrapConfigured();

    logger.warn('Runtime data reset requested', {
      dbHost: env.DB_HOST,
      dbPort: env.DB_PORT,
      dbName: env.DB_NAME,
      tables: RUNTIME_TABLES,
    });

    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query(`TRUNCATE TABLE ${RUNTIME_TABLES.join(', ')} RESTART IDENTITY CASCADE`);
      await client.query(`DELETE FROM "user"`);
      await client.query(`
        DO $$
        BEGIN
          IF EXISTS (
            SELECT 1
            FROM information_schema.tables
            WHERE table_schema = 'public'
              AND table_name = 'schema_seeds'
          ) THEN
            TRUNCATE TABLE schema_seeds RESTART IDENTITY;
          END IF;
        END $$;
      `);
      await client.query(
        `INSERT INTO app_support_settings (
           id,
           support_email,
           support_phone,
           office_hours,
           help_text,
           updated_by_user_id,
           updated_at
         )
         VALUES (1, NULL, NULL, NULL, NULL, NULL, CURRENT_TIMESTAMP)
         ON CONFLICT (id) DO UPDATE
         SET support_email = EXCLUDED.support_email,
             support_phone = EXCLUDED.support_phone,
             office_hours = EXCLUDED.office_hours,
             help_text = EXCLUDED.help_text,
             updated_by_user_id = EXCLUDED.updated_by_user_id,
             updated_at = EXCLUDED.updated_at`
      );
      await client.query('COMMIT');
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }

    await ensureSuperAdminExists(env);
    await pool.query('TRUNCATE TABLE audit_log RESTART IDENTITY');
    const summary = await getSummary();

    logger.info('Runtime data reset completed', summary);
  } catch (error) {
    logger.error('Runtime data reset failed', error);
    process.exitCode = 1;
  } finally {
    await closePool();
  }
};

void run();
