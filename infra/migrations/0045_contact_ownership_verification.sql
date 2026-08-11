-- Contact ownership verification and canonical identity storage.
-- Existing contact values are intentionally NOT marked verified. Existing
-- accounts enter verification_required while IDs, roles, permissions and all
-- relationships remain unchanged.

ALTER TABLE "user"
  ADD COLUMN IF NOT EXISTS email_original TEXT,
  ADD COLUMN IF NOT EXISTS email_canonical TEXT,
  ADD COLUMN IF NOT EXISTS email_verified_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS phone_e164 TEXT,
  ADD COLUMN IF NOT EXISTS phone_verified_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS account_status TEXT NOT NULL DEFAULT 'verification_required',
  ADD COLUMN IF NOT EXISTS pending_email_original TEXT,
  ADD COLUMN IF NOT EXISTS pending_email_canonical TEXT,
  ADD COLUMN IF NOT EXISTS pending_phone_e164 TEXT,
  ADD COLUMN IF NOT EXISTS verification_required_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS auth_version INTEGER NOT NULL DEFAULT 0;

UPDATE "user"
SET email_original = COALESCE(email_original, BTRIM(email)),
    email_canonical = COALESCE(email_canonical, LOWER(BTRIM(email))),
    verification_required_at = COALESCE(verification_required_at, CURRENT_TIMESTAMP),
    account_status = CASE
      WHEN account_status IS NULL OR account_status = 'active' THEN 'verification_required'
      ELSE account_status
    END;

ALTER TABLE "user"
  ALTER COLUMN email_original SET NOT NULL,
  ALTER COLUMN email_canonical SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'user_account_status_valid'
  ) THEN
    ALTER TABLE "user"
      ADD CONSTRAINT user_account_status_valid CHECK (
        account_status IN (
          'pending_verification',
          'verification_required',
          'invited',
          'pending_approval',
          'active',
          'rejected',
          'blocked',
          'inactive'
        )
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'user_phone_e164_shape'
  ) THEN
    ALTER TABLE "user"
      ADD CONSTRAINT user_phone_e164_shape CHECK (
        phone_e164 IS NULL OR phone_e164 ~ '^\\+961[0-9]{7,8}$'
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'user_pending_phone_e164_shape'
  ) THEN
    ALTER TABLE "user"
      ADD CONSTRAINT user_pending_phone_e164_shape CHECK (
        pending_phone_e164 IS NULL OR pending_phone_e164 ~ '^\\+961[0-9]{7,8}$'
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'user_auth_version_nonnegative'
  ) THEN
    ALTER TABLE "user"
      ADD CONSTRAINT user_auth_version_nonnegative CHECK (auth_version >= 0);
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_user_email_canonical
  ON "user" (email_canonical);

CREATE UNIQUE INDEX IF NOT EXISTS uq_user_pending_email_canonical
  ON "user" (pending_email_canonical)
  WHERE pending_email_canonical IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_user_phone_e164_reserved
  ON "user" (phone_e164)
  WHERE phone_e164 IS NOT NULL
    AND account_status NOT IN ('rejected', 'inactive');

CREATE UNIQUE INDEX IF NOT EXISTS uq_user_pending_phone_e164
  ON "user" (pending_phone_e164)
  WHERE pending_phone_e164 IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_user_contact_verification_state
  ON "user" (account_status, email_verified_at, phone_verified_at);

CREATE TABLE IF NOT EXISTS contact_verification_challenge (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  channel TEXT NOT NULL CHECK (channel IN ('email', 'sms')),
  purpose TEXT NOT NULL CHECK (
    purpose IN ('signup', 'change_email', 'change_phone', 'invite', 'recovery')
  ),
  target TEXT NOT NULL,
  secret_hash TEXT,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  invalidated_at TIMESTAMPTZ,
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  max_attempts INTEGER NOT NULL DEFAULT 5 CHECK (max_attempts > 0),
  send_count INTEGER NOT NULL DEFAULT 1 CHECK (send_count > 0),
  last_sent_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  blocked_until TIMESTAMPTZ,
  requested_from_ip INET,
  request_fingerprint_hash TEXT,
  provider_reference TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (expires_at > created_at),
  CHECK (consumed_at IS NULL OR invalidated_at IS NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_contact_verification_active_purpose
  ON contact_verification_challenge (user_id, channel, purpose)
  WHERE consumed_at IS NULL AND invalidated_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_contact_verification_active_lookup
  ON contact_verification_challenge (user_id, channel, purpose, target, created_at DESC)
  WHERE consumed_at IS NULL AND invalidated_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_contact_verification_expiration
  ON contact_verification_challenge (expires_at)
  WHERE consumed_at IS NULL AND invalidated_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_contact_verification_target_daily
  ON contact_verification_challenge (channel, purpose, target, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_contact_verification_ip_daily
  ON contact_verification_challenge (requested_from_ip, created_at DESC)
  WHERE requested_from_ip IS NOT NULL;

CREATE TABLE IF NOT EXISTS contact_verification_audit_event (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID REFERENCES "user"(id) ON DELETE SET NULL,
  challenge_id UUID REFERENCES contact_verification_challenge(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL CHECK (
    event_type IN (
      'send_requested',
      'send_succeeded',
      'send_failed',
      'verification_failed',
      'verification_succeeded',
      'challenge_blocked',
      'contact_change_requested',
      'contact_change_succeeded'
    )
  ),
  channel TEXT NOT NULL CHECK (channel IN ('email', 'sms')),
  purpose TEXT NOT NULL,
  masked_target TEXT NOT NULL,
  request_ip INET,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_contact_verification_audit_user_created
  ON contact_verification_audit_event (user_id, created_at DESC);

COMMENT ON COLUMN "user".email_original IS
  'Trimmed user-provided email retained for display and delivery.';
COMMENT ON COLUMN "user".email_canonical IS
  'Canonical comparison key with a normalized ASCII domain.';
COMMENT ON COLUMN "user".phone_e164 IS
  'Verified or pending Lebanese mobile identity in E.164 format.';
COMMENT ON TABLE contact_verification_challenge IS
  'Single-purpose, single-use ownership challenges. Secrets are HMAC-protected or provider-managed.';
