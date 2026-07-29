const { loadBackendEnvFiles } = require('./config/loadEnv');

const loadedEnvFiles = loadBackendEnvFiles();

const logger = require('./utils/logger');
const { testConnection, closePool } = require('./config/database');
const { validateEnv } = require('./config/env');
const { applyPendingMigrations, getPendingMigrations } = require('./db/migrationRunner');
const { ensureExportDir, cleanupOldExports } = require('./controllers/export.controller');
const {
  stopImportProcessingLoop,
} = require('./controllers/import.controller');
const { runNotificationMaintenance } = require('./jobs/notificationMaintenance');
const { buildApp } = require('./app');
import { ensureSuperAdminExists } from './lib/userWorkflow';
import { attachWorkflowSocket } from './realtime/workflowSocket';
import { startWorkflowChangeListener } from './realtime/workflowEvents';
import { processFeatureMediaCleanupJobs } from './services/featureMediaCleanup.service';
import {
  closeRateLimitBackend,
  initializeRateLimitBackend,
} from './services/sharedRateLimit.service';
import {
  startWorkloadWorker,
  stopWorkloadWorker,
  waitForWorkloadWorkerIdle,
} from './jobs/workloadWorker';

const env = validateEnv();
const app = buildApp(env);
const apiPrefix = String(env.API_VERSION_PREFIX || '/api/v1').replace(/\/+$/, '') || '/api/v1';

const sanitizeUrlForLog = (value: string): string => {
  const trimmed = value.trim();
  if (!trimmed) {
    return '(not configured)';
  }

  try {
    const url = new URL(trimmed);
    return `${url.protocol}//${url.host}`;
  } catch {
    return '(invalid URL)';
  }
};

const logAiServerRuntimeConfig = () => {
  logger.info('Backend environment files checked', {
    precedence: 'process env > apps/api/.env > root .env',
    files: loadedEnvFiles.map((file) => ({
      path: file.path,
      keysLoaded: file.keys.length,
    })),
  });

  if (String(env.AI_SERVER_URL ?? '').trim().length === 0) {
    logger.warn('AI_SERVER_URL is not configured; AI runs are disabled until it is set.');
  } else {
    logger.info('AI server URL configured', {
      aiServerUrl: sanitizeUrlForLog(env.AI_SERVER_URL),
      timeoutMs: env.AI_SERVER_TIMEOUT_MS,
    });
  }

  const callbackBaseUrl = env.AI_CALLBACK_BASE_URL || env.APP_PUBLIC_API_URL;
  logger.info('AI callback base URL configured', {
    callbackBaseUrl: sanitizeUrlForLog(callbackBaseUrl),
    source: env.AI_CALLBACK_BASE_URL ? 'AI_CALLBACK_BASE_URL' : 'APP_PUBLIC_API_URL',
  });

  if (String(env.AI_CALLBACK_SECRET ?? '').trim().length === 0) {
    logger.warn('AI_CALLBACK_SECRET is not configured; AI server callbacks will be rejected.');
  } else if (
    env.NODE_ENV === 'production' &&
    env.AI_CALLBACK_SECRET === 'dev-ai-callback-secret-change-me'
  ) {
    logger.warn('AI_CALLBACK_SECRET is using the development placeholder in production.');
  }
};

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
  await processFeatureMediaCleanupJobs();
  await initializeRateLimitBackend(env);
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
        runNotificationMaintenance()
          .then(() => processFeatureMediaCleanupJobs())
          .catch((error) => logger.error('Scheduled maintenance failed:', error)),
      env.NOTIFICATION_MAINTENANCE_INTERVAL_MINUTES * 60 * 1000,
    );
    if (env.WORKLOAD_WORKER_MODE === 'inline') {
      startWorkloadWorker();
    }
    closeWorkflowChangeListener = await startWorkflowChangeListener();

    server = app.listen(env.PORT, env.HOST, () => {
      logger.info(`Server running in ${env.NODE_ENV} mode`);
      logger.info(`Server address: http://${env.HOST}:${env.PORT}`);
      logger.info(`Health check: http://${env.HOST}:${env.PORT}/health`);
      logger.info(`API root: http://${env.HOST}:${env.PORT}${apiPrefix}`);
      logger.info(`API documentation: http://${env.HOST}:${env.PORT}/docs/openapi.yaml`);
      logAiServerRuntimeConfig();
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
  stopWorkloadWorker();
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

  await waitForWorkloadWorkerIdle();
  await Promise.all([closeRateLimitBackend(), closePool()]);
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
