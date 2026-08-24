const { loadBackendEnvFiles } = require('../config/loadEnv');
loadBackendEnvFiles();

const logger = require('../utils/logger');
const { closePool, testConnection } = require('../config/database');
const { validateWorkloadWorkerEnv } = require('../config/env');
const { getPendingMigrations } = require('../db/migrationRunner');
import {
  startWorkloadWorker,
  stopWorkloadWorker,
  waitForWorkloadWorkerIdle,
} from './workloadWorker';
import { startWorkloadWorkerHealth, stopWorkloadWorkerHealth } from './workloadWorkerHealth';

const env = validateWorkloadWorkerEnv();
let shuttingDown = false;

const shutdown = async (signal: string): Promise<void> => {
  if (shuttingDown) {
    return;
  }
  shuttingDown = true;
  logger.info('Workload worker shutting down', { signal });
  await stopWorkloadWorkerHealth();
  stopWorkloadWorker();
  await waitForWorkloadWorkerIdle();
  await closePool();
};

const start = async (): Promise<void> => {
  const pending = await getPendingMigrations();
  if (pending.length > 0) {
    throw new Error(
      `Workload worker refuses to start with pending migrations: ${pending.join(', ')}`,
    );
  }
  if (!(await testConnection())) {
    throw new Error('Workload worker failed to connect to the database');
  }
  startWorkloadWorker();
  await startWorkloadWorkerHealth();
  logger.info('Durable workload worker started', {
    mode: env.WORKLOAD_WORKER_MODE,
  });
};

process.on('SIGTERM', () => void shutdown('SIGTERM').then(() => process.exit(0)));
process.on('SIGINT', () => void shutdown('SIGINT').then(() => process.exit(0)));

void start().catch((error) => {
  logger.error('Failed to start workload worker', {
    error: error instanceof Error ? error.message : String(error),
  });
  process.exit(1);
});
