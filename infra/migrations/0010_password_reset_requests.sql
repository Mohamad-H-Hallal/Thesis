CREATE TABLE IF NOT EXISTS password_reset_request (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  requested_from_ip INET
);

CREATE INDEX IF NOT EXISTS idx_password_reset_request_user_id
  ON password_reset_request (user_id);

CREATE INDEX IF NOT EXISTS idx_password_reset_request_expires_at
  ON password_reset_request (expires_at);
