import { query, transaction } from '../config/database';
import { validateEnv } from '../config/env';
import { sendNotificationEmail } from './mailer';
const logger = require('../utils/logger');

type NotificationDeliveryRow = {
  id: string;
  notification_id: string;
  recipient_email: string;
  title: string;
  message: string;
  user_full_name: string | null;
};

const markNotificationDeliverySkipped = async (
  deliveryId: string,
  reason: string,
): Promise<void> => {
  await query(
    `UPDATE notification_delivery
     SET status = 'skipped',
         updated_at = CURRENT_TIMESTAMP,
         last_error = $2
     WHERE id = $1`,
    [deliveryId, reason],
  );
};

const claimPendingNotificationDeliveries = async (
  limit: number,
  maxAttempts: number,
): Promise<NotificationDeliveryRow[]> => {
  const result = await transaction(async (client) => {
    const claimed = await client.query<NotificationDeliveryRow>(
      `WITH candidates AS (
         SELECT nd.id
         FROM notification_delivery nd
         WHERE nd.channel = 'email'
           AND nd.status IN ('pending', 'failed')
           AND nd.attempt_count < $1
         ORDER BY nd.created_at ASC
         LIMIT $2
         FOR UPDATE SKIP LOCKED
       )
       UPDATE notification_delivery nd
       SET status = 'processing',
           attempt_count = nd.attempt_count + 1,
           first_attempted_at = COALESCE(nd.first_attempted_at, CURRENT_TIMESTAMP),
           last_attempted_at = CURRENT_TIMESTAMP,
           updated_at = CURRENT_TIMESTAMP,
           last_error = NULL
       FROM candidates c,
            notification n,
            "user" u
       WHERE nd.id = c.id
         AND n.id = nd.notification_id
         AND u.id = n.user_id
       RETURNING nd.id,
                 nd.notification_id,
                 nd.recipient_email,
                 n.title,
                 n.message,
                 u.full_name AS user_full_name`,
      [maxAttempts, limit],
    );

    return claimed.rows;
  });

  return result;
};

const deliverPendingNotificationEmails = async (): Promise<{
  attempted: number;
  delivered: number;
  failed: number;
  skipped: number;
}> => {
  const env = validateEnv();
  const deliveries = await claimPendingNotificationDeliveries(
    env.NOTIFICATION_EMAIL_BATCH_SIZE,
    env.NOTIFICATION_EMAIL_MAX_ATTEMPTS,
  );

  let delivered = 0;
  let failed = 0;
  let skipped = 0;

  for (const delivery of deliveries) {
    if (delivery.recipient_email.trim().length === 0) {
      skipped += 1;
      await markNotificationDeliverySkipped(
        delivery.id,
        'Recipient email is missing for this notification.',
      );
      continue;
    }

    try {
      await sendNotificationEmail({
        toEmail: delivery.recipient_email,
        recipientName: delivery.user_full_name ?? 'User',
        title: delivery.title,
        message: delivery.message,
      });

      delivered += 1;
      await query(
        `UPDATE notification_delivery
         SET status = 'delivered',
             delivered_at = CURRENT_TIMESTAMP,
             updated_at = CURRENT_TIMESTAMP,
             last_error = NULL
         WHERE id = $1`,
        [delivery.id],
      );
    } catch (error) {
      failed += 1;
      await query(
        `UPDATE notification_delivery
         SET status = 'failed',
             updated_at = CURRENT_TIMESTAMP,
             last_error = $2
         WHERE id = $1`,
        [
          delivery.id,
          error instanceof Error
            ? error.message
            : typeof error === 'string'
              ? error
              : 'Notification email delivery failed',
        ],
      );
    }
  }

  if (deliveries.length > 0) {
    logger.info('Notification email batch processed', {
      attempted: deliveries.length,
      delivered,
      failed,
      skipped,
    });
  }

  return {
    attempted: deliveries.length,
    delivered,
    failed,
    skipped,
  };
};

export { deliverPendingNotificationEmails };
