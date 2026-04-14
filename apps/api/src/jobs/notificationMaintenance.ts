import { synchronizeProjectStatuses } from '../lib/projectLifecycle';
import { deliverPendingNotificationEmails } from '../lib/notificationDelivery';
const logger = require('../utils/logger');

const runNotificationMaintenance = async (): Promise<{
  emailAttempted: number;
  emailDelivered: number;
  emailFailed: number;
  emailSkipped: number;
}> => {
  await synchronizeProjectStatuses();
  const deliverySummary = await deliverPendingNotificationEmails();

  logger.info('Notification maintenance completed', {
    emailAttempted: deliverySummary.attempted,
    emailDelivered: deliverySummary.delivered,
    emailFailed: deliverySummary.failed,
    emailSkipped: deliverySummary.skipped,
  });

  return {
    emailAttempted: deliverySummary.attempted,
    emailDelivered: deliverySummary.delivered,
    emailFailed: deliverySummary.failed,
    emailSkipped: deliverySummary.skipped,
  };
};

export { runNotificationMaintenance };
