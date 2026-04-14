require('dotenv').config();

const logger = require('./utils/logger');
const { testConnection, closePool } = require('./config/database');
const { validateEnv } = require('./config/env');
const { applyPendingMigrations, getPendingMigrations } = require('./db/migrationRunner');
const { ensureExportDir, cleanupOldExports } = require('./controllers/export.controller');
const { runNotificationMaintenance } = require('./jobs/notificationMaintenance');
const { buildApp } = require('./app');
import { ensureSuperAdminExists } from './lib/userWorkflow';

const env = validateEnv();
const app = buildApp(env);
const apiPrefix = String(env.API_VERSION_PREFIX || '/api/v1').replace(/\/+$/, '') || '/api/v1';

let server;
let exportCleanupInterval;
let notificationMaintenanceInterval;
let isShuttingDown = false;

const startServer = async () => {
  try {
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
      logger.error('Failed to connect to database');
      process.exit(1);
    }

    await ensureSuperAdminExists(env);

    await ensureExportDir();
    await cleanupOldExports();
    exportCleanupInterval = setInterval(
      () => cleanupOldExports().catch((error) => logger.error('Scheduled export cleanup failed:', error)),
      env.EXPORT_CLEANUP_INTERVAL_HOURS * 60 * 60 * 1000
    );
    await runNotificationMaintenance();
    notificationMaintenanceInterval = setInterval(
      () =>
        runNotificationMaintenance().catch((error) =>
          logger.error('Scheduled notification maintenance failed:', error),
        ),
      env.NOTIFICATION_MAINTENANCE_INTERVAL_MINUTES * 60 * 1000,
    );

    server = app.listen(env.PORT, env.HOST, () => {
      logger.info(`Server running in ${env.NODE_ENV} mode`);
      logger.info(`Server address: http://${env.HOST}:${env.PORT}`);
      logger.info(`Health check: http://${env.HOST}:${env.PORT}/health`);
      logger.info(`API root: http://${env.HOST}:${env.PORT}${apiPrefix}`);
      logger.info(`API documentation: http://${env.HOST}:${env.PORT}/docs/openapi.yaml`);
    });
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
