import 'dotenv/config';
import { closePool } from '../config/database';
import { runNotificationMaintenance } from './notificationMaintenance';
const logger = require('../utils/logger');

const run = async (): Promise<void> => {
  try {
    await runNotificationMaintenance();
  } catch (error) {
    logger.error('Notification maintenance run failed', error);
    process.exitCode = 1;
  } finally {
    await closePool();
  }
};

void run();
