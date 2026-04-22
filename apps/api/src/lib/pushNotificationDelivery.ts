import { query, transaction } from '../config/database';
import {
  PushDeliveryError,
  sendPushNotification,
  isPlatformPushEnabled,
  isPushDeliveryConfigured,
} from './firebasePush';
import { validateEnv } from '../config/env';
const logger = require('../utils/logger');

type PushDeliveryRow = {
  id: string;
  notification_id: string;
  token_snapshot: string;
  title: string;
  message: string;
  platform: 'android' | 'ios';
  device_registration_id: string;
};

const markPushDeliveryStatus = async (
  deliveryId: string,
  status: 'delivered' | 'failed' | 'skipped',
  errorMessage?: string,
): Promise<void> => {
  await query(
    `UPDATE notification_push_delivery
     SET status = $2::notification_delivery_status,
         updated_at = CURRENT_TIMESTAMP,
         delivered_at = CASE WHEN $2 = 'delivered' THEN CURRENT_TIMESTAMP ELSE delivered_at END,
         last_error = $3
     WHERE id = $1`,
    [deliveryId, status, errorMessage ?? null],
  );
};

const invalidatePushRegistration = async (
  deviceRegistrationId: string,
  reason: string,
): Promise<void> => {
  await query(
    `UPDATE push_device_registration
     SET notifications_enabled = FALSE,
         invalidated_at = CURRENT_TIMESTAMP,
         updated_at = CURRENT_TIMESTAMP
     WHERE id = $1`,
    [deviceRegistrationId],
  );

  logger.warn('Push device registration invalidated', {
    deviceRegistrationId,
    reason,
  });
};

const claimPendingPushDeliveries = async (
  limit: number,
  maxAttempts: number,
): Promise<PushDeliveryRow[]> => {
  const result = await transaction(async (client) => {
    const claimed = await client.query<PushDeliveryRow>(
      `WITH candidates AS (
         SELECT npd.id
         FROM notification_push_delivery npd
         WHERE npd.status IN ('pending', 'failed')
           AND npd.attempt_count < $1
         ORDER BY npd.created_at ASC
         LIMIT $2
         FOR UPDATE SKIP LOCKED
       )
       UPDATE notification_push_delivery npd
       SET status = 'processing',
           attempt_count = npd.attempt_count + 1,
           first_attempted_at = COALESCE(npd.first_attempted_at, CURRENT_TIMESTAMP),
           last_attempted_at = CURRENT_TIMESTAMP,
           updated_at = CURRENT_TIMESTAMP,
           last_error = NULL
       FROM candidates c,
            notification n,
            push_device_registration pdr
       WHERE npd.id = c.id
         AND n.id = npd.notification_id
         AND pdr.id = npd.device_registration_id
       RETURNING npd.id,
                 npd.notification_id,
                 npd.token_snapshot,
                 n.title,
                 n.message,
                 pdr.platform,
                 npd.device_registration_id`,
      [maxAttempts, limit],
    );

    return claimed.rows;
  });

  return result;
};

const deliverPendingPushNotifications = async (): Promise<{
  attempted: number;
  delivered: number;
  failed: number;
  skipped: number;
}> => {
  const env = validateEnv();
  const deliveries = await claimPendingPushDeliveries(
    env.NOTIFICATION_PUSH_BATCH_SIZE,
    env.NOTIFICATION_PUSH_MAX_ATTEMPTS,
  );

  let delivered = 0;
  let failed = 0;
  let skipped = 0;

  if (deliveries.length == 0) {
    return { attempted: 0, delivered: 0, failed: 0, skipped: 0 };
  }

  if (!isPushDeliveryConfigured()) {
    for (const delivery of deliveries) {
      skipped += 1;
      await markPushDeliveryStatus(
        delivery.id,
        'skipped',
        'Push delivery is not configured for this environment.',
      );
    }

    logger.warn('Skipped push notification batch because push delivery is not configured', {
      attempted: deliveries.length,
    });

    return {
      attempted: deliveries.length,
      delivered,
      failed,
      skipped,
    };
  }

  for (const delivery of deliveries) {
    if (!isPlatformPushEnabled(delivery.platform)) {
      skipped += 1;
      await markPushDeliveryStatus(
        delivery.id,
        'skipped',
        delivery.platform === 'ios'
          ? 'iOS push delivery is disabled until APNs is configured for this environment.'
          : 'Android push delivery is disabled for this environment.',
      );
      continue;
    }

    try {
      await sendPushNotification(delivery.platform, {
        token: delivery.token_snapshot,
        title: delivery.title,
        message: delivery.message,
        notificationId: delivery.notification_id,
      });

      delivered += 1;
      await markPushDeliveryStatus(delivery.id, 'delivered');
    } catch (error) {
      const code = error instanceof PushDeliveryError ? error.code : '';
      const message = error instanceof Error ? error.message : 'Push notification delivery failed';

      if (
        code == 'messaging/registration-token-not-registered' ||
        code == 'messaging/invalid-registration-token'
      ) {
        skipped += 1;
        await invalidatePushRegistration(delivery.device_registration_id, message);
        await markPushDeliveryStatus(delivery.id, 'skipped', message);
        continue;
      }

      failed += 1;
      await markPushDeliveryStatus(delivery.id, 'failed', message);
    }
  }

  logger.info('Push notification batch processed', {
    attempted: deliveries.length,
    delivered,
    failed,
    skipped,
  });

  return {
    attempted: deliveries.length,
    delivered,
    failed,
    skipped,
  };
};

export { deliverPendingPushNotifications };
