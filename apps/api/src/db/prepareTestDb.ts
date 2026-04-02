import { Client } from 'pg';
import { applyTestEnvDefaults } from '../config/testEnv';
const logger = require('../utils/logger');

const quoteIdentifier = (value: string): string => `"${value.replace(/"/g, '""')}"`;

const ensureDatabaseExists = async (): Promise<void> => {
  const testDb = applyTestEnvDefaults();
  const adminClient = new Client({
    host: testDb.host,
    port: testDb.port,
    database: testDb.adminDatabase,
    user: testDb.user,
    password: testDb.password,
  });

  try {
    await adminClient.connect();
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : 'Unknown database connection error';
    throw new Error(
      `Unable to connect to the test database server at ${testDb.host}:${testDb.port}. Start the compose DB first with "docker compose up -d db". ${message}`,
    );
  }

  try {
    const result = await adminClient.query<{ exists: boolean }>(
      'SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = $1) AS exists',
      [testDb.database],
    );

    if (!result.rows[0]?.exists) {
      await adminClient.query(`CREATE DATABASE ${quoteIdentifier(testDb.database)}`);
      logger.info('Created API test database', {
        database: testDb.database,
        host: testDb.host,
        port: testDb.port,
      });
    }
  } finally {
    await adminClient.end().catch(() => {});
  }
};

const run = async (): Promise<void> => {
  try {
    const testDb = applyTestEnvDefaults();
    await ensureDatabaseExists();
    const { applyPendingMigrations } = await import('./migrationRunner');
    const applied = await applyPendingMigrations();
    logger.info('API test database prepared', {
      database: testDb.database,
      host: testDb.host,
      port: testDb.port,
      appliedCount: applied.length,
    });
    process.exit(0);
  } catch (error: unknown) {
    logger.error('API test database preparation failed', error);
    process.exit(1);
  } finally {
    const { closePool } = await import('../config/database');
    await closePool();
  }
};

void run();
