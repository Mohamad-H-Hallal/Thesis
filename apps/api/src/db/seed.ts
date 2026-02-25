import 'dotenv/config';
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import type { PoolClient } from 'pg';
import { pool } from '../config/database';
const logger = require('../utils/logger');

const seedsDir = path.join(__dirname, 'seeds');

const ensureSeedsTable = async (client: PoolClient): Promise<void> => {
  await client.query(`
    CREATE TABLE IF NOT EXISTS schema_seeds (
      id SERIAL PRIMARY KEY,
      filename TEXT UNIQUE NOT NULL,
      checksum TEXT NOT NULL,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
};

const loadSeedFiles = async (): Promise<string[]> => {
  await fs.mkdir(seedsDir, { recursive: true });
  const files = await fs.readdir(seedsDir);
  return files
    .filter((file) => file.endsWith('.sql'))
    .sort((a, b) => a.localeCompare(b, 'en'));
};

const getAppliedSeeds = async (client: PoolClient): Promise<Set<string>> => {
  const result = await client.query<{ filename: string }>('SELECT filename FROM schema_seeds');
  return new Set(result.rows.map((row) => row.filename));
};

const run = async (): Promise<void> => {
  const client = await pool.connect();
  const appliedInRun: string[] = [];

  try {
    await ensureSeedsTable(client);
    const files = await loadSeedFiles();
    const applied = await getAppliedSeeds(client);
    const pending = files.filter((file) => !applied.has(file));

    if (pending.length === 0) {
      logger.info('No pending seeds');
      return;
    }

    for (const file of pending) {
      const filePath = path.join(seedsDir, file);
      const sql = await fs.readFile(filePath, 'utf8');
      const checksum = crypto.createHash('sha256').update(sql).digest('hex');

      await client.query('BEGIN');
      try {
        await client.query(sql);
        await client.query(
          `INSERT INTO schema_seeds (filename, checksum)
           VALUES ($1, $2)`,
          [file, checksum]
        );
        await client.query('COMMIT');
        appliedInRun.push(file);
        logger.info('Seed applied:', { file });
      } catch (error: unknown) {
        await client.query('ROLLBACK');
        const message = error instanceof Error ? error.message : 'Unknown seed error';
        logger.error('Seed failed:', { file, error: message });
        throw error;
      }
    }
  } catch (error: unknown) {
    logger.error('Seed run failed:', error);
    process.exitCode = 1;
  } finally {
    client.release();
    await pool.end().catch(() => {});
  }

  logger.info('Seed run complete', {
    appliedCount: appliedInRun.length,
    applied: appliedInRun,
  });
};

void run();
