import { synchronizeProjectStatuses } from '../lib/projectLifecycle';
import { deliverPendingPushNotifications } from '../lib/pushNotificationDelivery';
import { runApprovedRetentionCleanup } from '../services/dataRetention.service';
import { deleteExpiredPrivacyExportArtifacts } from '../services/privacyExport.service';
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
  const expiredPrivacyExports = await deleteExpiredPrivacyExportArtifacts();
  const retentionSummary = await runApprovedRetentionCleanup('scheduled');

  logger.info('Notification maintenance completed', {
    emailAttempted: 0,
    emailDelivered: 0,
    emailFailed: 0,
    emailSkipped: 0,
    pushAttempted: pushSummary.attempted,
    pushDelivered: pushSummary.delivered,
    pushFailed: pushSummary.failed,
    pushSkipped: pushSummary.skipped,
    retentionPolicies: retentionSummary.policyCount,
    retentionAffectedRows: retentionSummary.affectedRows,
    expiredPrivacyExports,
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
