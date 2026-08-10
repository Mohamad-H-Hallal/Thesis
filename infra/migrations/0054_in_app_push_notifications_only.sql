ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'ai_event';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'project_event';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'account_event';

-- Workflow notifications are intentionally delivered only through the
-- persisted in-app inbox and registered push devices. Authentication and
-- account-security email flows use separate challenge/invitation tables and
-- are not affected by this migration.
DROP TRIGGER IF EXISTS notification_email_delivery_enqueue ON notification;
DROP FUNCTION IF EXISTS enqueue_notification_email_delivery();

UPDATE notification_delivery
SET status = 'skipped',
    updated_at = CURRENT_TIMESTAMP,
    last_error = 'Workflow notification email delivery is disabled; use in-app or push notifications.'
WHERE channel = 'email'
  AND status IN ('pending', 'processing', 'failed');

CREATE UNIQUE INDEX IF NOT EXISTS uq_notification_event_key
  ON notification (user_id, type, (metadata->>'event_key'))
  WHERE metadata ? 'event_key';
