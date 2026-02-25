import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import type { PoolClient } from 'pg';
import { pool } from '../config/database';
const logger = require('../utils/logger');

const migrationsDir = path.resolve(
  process.env.MIGRATIONS_DIR || path.join(process.cwd(), '..', '..', 'infra', 'migrations')
);

const ensureMigrationsTable = async (client: PoolClient): Promise<void> => {
  await client.query(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      id SERIAL PRIMARY KEY,
      filename TEXT UNIQUE NOT NULL,
      checksum TEXT NOT NULL,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
};

const loadMigrationFiles = async (): Promise<string[]> => {
  try {
    await fs.mkdir(migrationsDir, { recursive: true });
    const files = await fs.readdir(migrationsDir);
    return files
      .filter((file) => file.endsWith('.sql'))
      .sort((a, b) => a.localeCompare(b, 'en'));
  } catch (error: unknown) {
    logger.error('Failed to load migration files:', error);
    throw error;
  }
};

const getAppliedMigrations = async (client: PoolClient): Promise<Set<string>> => {
  const result = await client.query<{ filename: string }>('SELECT filename FROM schema_migrations');
  return new Set(result.rows.map((row) => row.filename));
};

const getPendingMigrations = async (): Promise<string[]> => {
  const client = await pool.connect();
  try {
    await ensureMigrationsTable(client);
    const [files, applied] = await Promise.all([
      loadMigrationFiles(),
      getAppliedMigrations(client),
    ]);

    return files.filter((file) => !applied.has(file));
  } finally {
    client.release();
  }
};

const applyPendingMigrations = async (): Promise<string[]> => {
  const client = await pool.connect();
  const appliedInRun: string[] = [];

  try {
    await ensureMigrationsTable(client);
    const files = await loadMigrationFiles();
    const applied = await getAppliedMigrations(client);
    const pending = files.filter((file) => !applied.has(file));

    if (pending.length === 0) {
      logger.info('No pending migrations');
      return appliedInRun;
    }

    for (const file of pending) {
      const filePath = path.join(migrationsDir, file);
      const sql = await fs.readFile(filePath, 'utf8');
      const checksum = crypto.createHash('sha256').update(sql).digest('hex');

      await client.query('BEGIN');
      try {
        await client.query(sql);
        await client.query(
          `INSERT INTO schema_migrations (filename, checksum)
           VALUES ($1, $2)`,
          [file, checksum]
        );
        await client.query('COMMIT');
        appliedInRun.push(file);
        logger.info('Migration applied:', { file });
      } catch (error: unknown) {
        await client.query('ROLLBACK');
        const message = error instanceof Error ? error.message : 'Unknown migration error';
        logger.error('Migration failed:', { file, error: message });
        throw error;
      }
    }

    return appliedInRun;
  } finally {
    client.release();
  }
};

export { getPendingMigrations, applyPendingMigrations };

