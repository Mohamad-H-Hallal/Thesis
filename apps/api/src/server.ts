require('dotenv').config();

const logger = require('./utils/logger');
const { testConnection, closePool } = require('./config/database');
const { validateEnv } = require('./config/env');
const { applyPendingMigrations, getPendingMigrations } = require('./db/migrationRunner');
const { ensureExportDir, cleanupOldExports } = require('./controllers/export.controller');
const {
  startImportProcessingLoop,
  stopImportProcessingLoop,
} = require('./controllers/import.controller');
const { runNotificationMaintenance } = require('./jobs/notificationMaintenance');
const { buildApp } = require('./app');
import { ensureSuperAdminExists } from './lib/userWorkflow';
import { attachWorkflowSocket } from './realtime/workflowSocket';
import { startWorkflowChangeListener } from './realtime/workflowEvents';

const env = validateEnv();
const app = buildApp(env);
const apiPrefix = String(env.API_VERSION_PREFIX || '/api/v1').replace(/\/+$/, '') || '/api/v1';

let server;
let exportCleanupInterval;
let notificationMaintenanceInterval;
let closeWorkflowSocket;
let closeWorkflowChangeListener;
let isShuttingDown = false;

const startupRetryAttempts = Math.max(
  1,
  Number.parseInt(process.env.STARTUP_RETRY_ATTEMPTS ?? '12', 10) || 12,
);
const startupRetryDelayMs = Math.max(
  1000,
  Number.parseInt(process.env.STARTUP_RETRY_DELAY_MS ?? '5000', 10) || 5000,
);

const sleep = (delayMs: number): Promise<void> =>
  new Promise((resolve) => {
    setTimeout(resolve, delayMs);
  });

const isRetryableStartupError = (error: unknown): boolean => {
  if (!error || typeof error !== 'object') {
    return false;
  }

  const typedError = error as { code?: unknown; message?: unknown; cause?: unknown };
  const code = typeof typedError.code === 'string' ? typedError.code : null;
  if (code && ['57P03', 'ECONNREFUSED', 'ETIMEDOUT', 'EAI_AGAIN'].includes(code)) {
    return true;
  }

  const message = typeof typedError.message === 'string' ? typedError.message.toLowerCase() : '';
  if (
    message.includes('database system is starting up') ||
    message.includes('failed to connect to database') ||
    message.includes('connect econnrefused') ||
    message.includes('connection terminated') ||
    message.includes('connection timeout')
  ) {
    return true;
  }

  return typedError.cause ? isRetryableStartupError(typedError.cause) : false;
};

const prepareServerStartup = async () => {
  const pendingMigrations = await getPendingMigrations();
  if (pendingMigrations.length > 0) {
    logger.warn('Pending migrations detected', { pendingMigrations });
    if (env.NODE_ENV === 'production') {
      logger.error('Refusing to start in production with pending migrations');
      process.exit(1);
    }

    const appliedMigrations = await applyPendingMigrations();
    logger.info('Applied pending migrations before server start', {
      appliedMigrations,
    });
  }

  const dbConnected = await testConnection();
  if (!dbConnected) {
    throw new Error('Failed to connect to database');
  }

  await ensureSuperAdminExists(env);
  await ensureExportDir();
  await cleanupOldExports();
  await runNotificationMaintenance();
};

const prepareServerStartupWithRetry = async () => {
  for (let attempt = 1; attempt <= startupRetryAttempts; attempt += 1) {
    try {
      await prepareServerStartup();
      return;
    } catch (error) {
      const canRetry = attempt < startupRetryAttempts && isRetryableStartupError(error);
      if (!canRetry) {
        throw error;
      }
      logger.warn('Server startup dependency is not ready; retrying', {
        attempt,
        maxAttempts: startupRetryAttempts,
        retryDelayMs: startupRetryDelayMs,
        error: error instanceof Error ? error.message : 'Unknown startup error',
      });
      await sleep(startupRetryDelayMs);
    }
  }
};

const startServer = async () => {
  try {
    await prepareServerStartupWithRetry();
    exportCleanupInterval = setInterval(
      () =>
        cleanupOldExports().catch((error) =>
          logger.error('Scheduled export cleanup failed:', error),
        ),
      env.EXPORT_CLEANUP_INTERVAL_HOURS * 60 * 60 * 1000,
    );
    notificationMaintenanceInterval = setInterval(
      () =>
        runNotificationMaintenance().catch((error) =>
          logger.error('Scheduled notification maintenance failed:', error),
        ),
      env.NOTIFICATION_MAINTENANCE_INTERVAL_MINUTES * 60 * 1000,
    );
    startImportProcessingLoop();
    closeWorkflowChangeListener = await startWorkflowChangeListener();

    server = app.listen(env.PORT, env.HOST, () => {
      logger.info(`Server running in ${env.NODE_ENV} mode`);
      logger.info(`Server address: http://${env.HOST}:${env.PORT}`);
      logger.info(`Health check: http://${env.HOST}:${env.PORT}/health`);
      logger.info(`API root: http://${env.HOST}:${env.PORT}${apiPrefix}`);
      logger.info(`API documentation: http://${env.HOST}:${env.PORT}/docs/openapi.yaml`);
    });
    closeWorkflowSocket = attachWorkflowSocket(server, apiPrefix);
  } catch (error) {
    logger.error('Failed to start server:', error);
    process.exit(1);
  }
};

const shutdown = async (signal) => {
  if (isShuttingDown) {
    return;
  }

  isShuttingDown = true;
  logger.info(`${signal} received, shutting down gracefully`);

  if (exportCleanupInterval) {
    clearInterval(exportCleanupInterval);
  }
  if (notificationMaintenanceInterval) {
    clearInterval(notificationMaintenanceInterval);
  }
  stopImportProcessingLoop();
  if (closeWorkflowSocket) {
    closeWorkflowSocket();
  }
  if (closeWorkflowChangeListener) {
    closeWorkflowChangeListener();
  }

  await new Promise<void>((resolve) => {
    if (!server) {
      resolve();
      return;
    }

    server.close((error) => {
      if (error) {
        logger.error('Error while closing server:', error);
      }
      resolve();
    });
  });

  await closePool();
  process.exit(0);
};

process.on('unhandledRejection', (err) => {
  logger.error('Unhandled Promise Rejection:', err);
  shutdown('unhandledRejection').catch(() => process.exit(1));
});

process.on('uncaughtException', (err) => {
  logger.error('Uncaught Exception:', err);
  shutdown('uncaughtException').catch(() => process.exit(1));
});

process.on('SIGTERM', () => {
  shutdown('SIGTERM').catch(() => process.exit(1));
});

process.on('SIGINT', () => {
  shutdown('SIGINT').catch(() => process.exit(1));
});

startServer();

module.exports = {
  app,
  startServer,
};

export {};
