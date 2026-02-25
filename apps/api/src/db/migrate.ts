import 'dotenv/config';
import { applyPendingMigrations } from './migrationRunner';
import { pool } from '../config/database';
const logger = require('../utils/logger');

const run = async (): Promise<void> => {
  try {
    const applied = await applyPendingMigrations();
    logger.info('Migration run complete', { appliedCount: applied.length, applied });
    process.exit(0);
  } catch (error: unknown) {
    logger.error('Migration run failed:', error);
    process.exit(1);
  } finally {
    await pool.end().catch(() => {});
  }
};

void run();

