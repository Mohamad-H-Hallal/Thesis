DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type
    WHERE typname = 'push_notification_platform'
  ) THEN
    CREATE TYPE push_notification_platform AS ENUM ('android', 'ios');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS push_device_registration (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  token TEXT NOT NULL UNIQUE,
  platform push_notification_platform NOT NULL,
  device_label TEXT,
  app_version TEXT,
  notifications_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  invalidated_at TIMESTAMPTZ,
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_push_device_registration_user_active
  ON push_device_registration(user_id, notifications_enabled, updated_at DESC);

CREATE TABLE IF NOT EXISTS notification_push_delivery (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  notification_id UUID NOT NULL REFERENCES notification(id) ON DELETE CASCADE,
  device_registration_id UUID NOT NULL REFERENCES push_device_registration(id) ON DELETE CASCADE,
  token_snapshot TEXT NOT NULL,
  status notification_delivery_status NOT NULL DEFAULT 'pending',
  attempt_count INTEGER NOT NULL DEFAULT 0,
  first_attempted_at TIMESTAMPTZ,
  last_attempted_at TIMESTAMPTZ,
  delivered_at TIMESTAMPTZ,
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT valid_notification_push_attempts CHECK (attempt_count >= 0),
  UNIQUE (notification_id, device_registration_id)
);

CREATE INDEX IF NOT EXISTS idx_notification_push_delivery_status
  ON notification_push_delivery(status, created_at DESC);

CREATE OR REPLACE FUNCTION enqueue_notification_push_delivery()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO notification_push_delivery (
    notification_id,
    device_registration_id,
    token_snapshot,
    status
  )
  SELECT
    NEW.id,
    pdr.id,
    pdr.token,
    'pending'
  FROM push_device_registration pdr
  WHERE pdr.user_id = NEW.user_id
    AND pdr.notifications_enabled = TRUE
    AND pdr.invalidated_at IS NULL
  ON CONFLICT (notification_id, device_registration_id) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notification_push_delivery_enqueue ON notification;

CREATE TRIGGER notification_push_delivery_enqueue
AFTER INSERT ON notification
FOR EACH ROW
EXECUTE FUNCTION enqueue_notification_push_delivery();
