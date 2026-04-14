DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type
    WHERE typname = 'notification_delivery_channel'
  ) THEN
    CREATE TYPE notification_delivery_channel AS ENUM ('email');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_type
    WHERE typname = 'notification_delivery_status'
  ) THEN
    CREATE TYPE notification_delivery_status AS ENUM (
      'pending',
      'processing',
      'delivered',
      'failed',
      'skipped'
    );
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS notification_delivery (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  notification_id UUID NOT NULL REFERENCES notification(id) ON DELETE CASCADE,
  channel notification_delivery_channel NOT NULL,
  recipient_email TEXT NOT NULL,
  status notification_delivery_status NOT NULL DEFAULT 'pending',
  attempt_count INTEGER NOT NULL DEFAULT 0,
  first_attempted_at TIMESTAMPTZ,
  last_attempted_at TIMESTAMPTZ,
  delivered_at TIMESTAMPTZ,
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT valid_notification_delivery_attempts CHECK (attempt_count >= 0),
  UNIQUE (notification_id, channel)
);

CREATE INDEX IF NOT EXISTS idx_notification_delivery_status
  ON notification_delivery(status, channel, created_at DESC);

CREATE OR REPLACE FUNCTION enqueue_notification_email_delivery()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  recipient TEXT;
BEGIN
  SELECT LOWER(TRIM(email))
    INTO recipient
    FROM "user"
   WHERE id = NEW.user_id
     AND COALESCE(TRIM(email), '') <> '';

  IF recipient IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO notification_delivery (
    notification_id,
    channel,
    recipient_email,
    status
  )
  VALUES (
    NEW.id,
    'email',
    recipient,
    'pending'
  )
  ON CONFLICT (notification_id, channel) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notification_email_delivery_enqueue ON notification;

CREATE TRIGGER notification_email_delivery_enqueue
AFTER INSERT ON notification
FOR EACH ROW
EXECUTE FUNCTION enqueue_notification_email_delivery();
