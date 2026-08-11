import { query } from '../config/database';
const logger = require('../utils/logger');

/**
 * Workflow notification email delivery is intentionally disabled. This
 * compatibility entry point safely retires rows queued by older database
 * versions and can never call the SMTP transport. Authentication and security
 * email delivery use the separate mailer challenge flows.
 */
const deliverPendingNotificationEmails = async (): Promise<{
  attempted: number;
  delivered: number;
  failed: number;
  skipped: number;
}> => {
  const result = await query(
    `UPDATE notification_delivery
     SET status = 'skipped',
         updated_at = CURRENT_TIMESTAMP,
         last_error = 'Workflow notification email delivery is disabled; use in-app or push notifications.'
     WHERE channel = 'email'
       AND status IN ('pending', 'processing', 'failed')
     RETURNING id`,
  );
  const skipped = result.rowCount ?? 0;

  if (skipped > 0) {
    logger.info('Skipped legacy workflow notification email deliveries', { skipped });
  }

  return {
    attempted: skipped,
    delivered: 0,
    failed: 0,
    skipped,
  };
};

export { deliverPendingNotificationEmails };
