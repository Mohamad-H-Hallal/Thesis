import fs from 'node:fs';
import fsPromises from 'node:fs/promises';
import path from 'node:path';
import type { PoolClient } from 'pg';
import { pool } from '../config/database';
import {
  calculateCompatibleMigrationChecksums,
  calculateMigrationChecksum,
  findMigrationIntegrityIssues,
  resolveMigrationChecksumCompatibility,
  type MigrationChecksumRecord,
  type MigrationSourceChecksumRecord,
} from './migrationIntegrity';
const logger = require('../utils/logger');

const resolveMigrationsDir = (): string => {
  const configuredDir = process.env.MIGRATIONS_DIR?.trim();
  if (configuredDir) {
    const resolved = path.resolve(configuredDir);
    if (!fs.existsSync(resolved)) {
      throw new Error(`Configured MIGRATIONS_DIR does not exist: ${resolved}`);
    }
    return resolved;
  }

  const candidates = [
    path.resolve(process.cwd(), 'infra', 'migrations'),
    path.resolve(process.cwd(), '..', 'infra', 'migrations'),
    path.resolve(process.cwd(), '..', '..', 'infra', 'migrations'),
    path.resolve(__dirname, '..', '..', '..', 'infra', 'migrations'),
    path.resolve(__dirname, '..', '..', '..', '..', 'infra', 'migrations'),
  ];

  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  throw new Error(`Unable to locate infra/migrations. Checked: ${candidates.join(', ')}`);
};

const migrationsDir = resolveMigrationsDir();

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

const requireMigrationsTable = async (client: PoolClient): Promise<void> => {
  const result = await client.query<{ relation_name: string | null }>(
    `SELECT to_regclass('public.schema_migrations')::text AS relation_name`,
  );
  if (!result.rows[0]?.relation_name) {
    throw new Error(
      'Required schema_migrations table is missing; run the one-shot migration service before production startup',
    );
  }
};

const loadMigrationFiles = async (): Promise<string[]> => {
  try {
    await fsPromises.mkdir(migrationsDir, { recursive: true });
    const files = await fsPromises.readdir(migrationsDir);
    return files.filter((file) => file.endsWith('.sql')).sort((a, b) => a.localeCompare(b, 'en'));
  } catch (error: unknown) {
    logger.error('Failed to load migration files:', error);
    throw error;
  }
};

const loadMigrationChecksums = async (
  files: readonly string[],
): Promise<MigrationSourceChecksumRecord[]> => {
  const migrations = await Promise.all(
    files.map(async (filename) => {
      const sql = await fsPromises.readFile(path.join(migrationsDir, filename), 'utf8');
      return {
        filename,
        checksum: calculateMigrationChecksum(sql),
        compatibleChecksums: calculateCompatibleMigrationChecksums(sql),
      };
    }),
  );
  const compatibilityPath = path.join(migrationsDir, 'checksum-compatibility.json');
  let compatibilityValue: unknown = { version: 1, migrations: [] };
  try {
    compatibilityValue = JSON.parse(await fsPromises.readFile(compatibilityPath, 'utf8'));
  } catch (error: unknown) {
    const isMissing =
      error instanceof Error &&
      'code' in error &&
      (error as NodeJS.ErrnoException).code === 'ENOENT';
    if (!isMissing) {
      throw error;
    }
  }
  const compatibility = resolveMigrationChecksumCompatibility(compatibilityValue, migrations);

  return migrations.map((migration) => ({
    ...migration,
    compatibleChecksums: [
      ...(migration.compatibleChecksums ?? []),
      ...(compatibility.get(migration.filename) ?? []),
    ],
  }));
};

const getAppliedMigrations = async (client: PoolClient): Promise<MigrationChecksumRecord[]> => {
  const result = await client.query<MigrationChecksumRecord>(
    'SELECT filename, checksum FROM schema_migrations ORDER BY filename',
  );
  return result.rows;
};

const requireMigrationIntegrity = async (
  client: PoolClient,
  files: readonly string[],
): Promise<Set<string>> => {
  const [available, applied] = await Promise.all([
    loadMigrationChecksums(files),
    getAppliedMigrations(client),
  ]);
  const issues = findMigrationIntegrityIssues(available, applied);
  if (issues.length > 0) {
    throw new Error(`Migration integrity check failed:\n- ${issues.join('\n- ')}`);
  }
  return new Set(applied.map((migration) => migration.filename));
};

const getPendingMigrations = async (): Promise<string[]> => {
  const client = await pool.connect();
  try {
    if (process.env.NODE_ENV === 'production') {
      await requireMigrationsTable(client);
    } else {
      await ensureMigrationsTable(client);
    }
    const files = await loadMigrationFiles();
    const applied = await requireMigrationIntegrity(client, files);

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
    const applied = await requireMigrationIntegrity(client, files);
    const pending = files.filter((file) => !applied.has(file));

    if (pending.length === 0) {
      logger.info('No pending migrations');
      return appliedInRun;
    }

    for (const file of pending) {
      const filePath = path.join(migrationsDir, file);
      const sql = await fsPromises.readFile(filePath, 'utf8');
      const checksum = calculateMigrationChecksum(sql);

      await client.query('BEGIN');
      try {
        await client.query(sql);
        await client.query(
          `INSERT INTO schema_migrations (filename, checksum)
           VALUES ($1, $2)`,
          [file, checksum],
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
