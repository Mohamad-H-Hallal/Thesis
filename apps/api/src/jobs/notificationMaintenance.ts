import { synchronizeProjectStatuses } from '../lib/projectLifecycle';
import { deliverPendingPushNotifications } from '../lib/pushNotificationDelivery';
const logger = require('../utils/logger');

const runNotificationMaintenance = async (): Promise<{
  emailAttempted: number;
  emailDelivered: number;
  emailFailed: number;
  emailSkipped: number;
  pushAttempted: number;
  pushDelivered: number;
  pushFailed: number;
  pushSkipped: number;
}> => {
  await synchronizeProjectStatuses();
  const pushSummary = await deliverPendingPushNotifications();

  logger.info('Notification maintenance completed', {
    emailAttempted: 0,
    emailDelivered: 0,
    emailFailed: 0,
    emailSkipped: 0,
    pushAttempted: pushSummary.attempted,
    pushDelivered: pushSummary.delivered,
    pushFailed: pushSummary.failed,
    pushSkipped: pushSummary.skipped,
  });

  return {
    emailAttempted: 0,
    emailDelivered: 0,
    emailFailed: 0,
    emailSkipped: 0,
    pushAttempted: pushSummary.attempted,
    pushDelivered: pushSummary.delivered,
    pushFailed: pushSummary.failed,
    pushSkipped: pushSummary.skipped,
  };
};

export { runNotificationMaintenance };
