import { synchronizeProjectStatuses } from '../lib/projectLifecycle';
import { deliverPendingNotificationEmails } from '../lib/notificationDelivery';
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
  const [emailSummary, pushSummary] = await Promise.all([
    deliverPendingNotificationEmails(),
    deliverPendingPushNotifications(),
  ]);

  logger.info('Notification maintenance completed', {
    emailAttempted: emailSummary.attempted,
    emailDelivered: emailSummary.delivered,
    emailFailed: emailSummary.failed,
    emailSkipped: emailSummary.skipped,
    pushAttempted: pushSummary.attempted,
    pushDelivered: pushSummary.delivered,
    pushFailed: pushSummary.failed,
    pushSkipped: pushSummary.skipped,
  });

  return {
    emailAttempted: emailSummary.attempted,
    emailDelivered: emailSummary.delivered,
    emailFailed: emailSummary.failed,
    emailSkipped: emailSummary.skipped,
    pushAttempted: pushSummary.attempted,
    pushDelivered: pushSummary.delivered,
    pushFailed: pushSummary.failed,
    pushSkipped: pushSummary.skipped,
  };
};

export { runNotificationMaintenance };
