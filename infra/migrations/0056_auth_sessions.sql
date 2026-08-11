CREATE TABLE auth_session (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  refresh_token_hash CHAR(64) NOT NULL UNIQUE,
  refresh_expires_at TIMESTAMPTZ NOT NULL,
  auth_version INTEGER NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_rotated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  revoked_at TIMESTAMPTZ,
  revocation_reason TEXT,
  CONSTRAINT chk_auth_session_auth_version_nonnegative CHECK (auth_version >= 0),
  CONSTRAINT chk_auth_session_revocation_pair CHECK (
    (revoked_at IS NULL AND revocation_reason IS NULL)
    OR (revoked_at IS NOT NULL AND revocation_reason IS NOT NULL)
  )
);

CREATE INDEX idx_auth_session_user_active
  ON auth_session (user_id, refresh_expires_at DESC)
  WHERE revoked_at IS NULL;

CREATE INDEX idx_auth_session_cleanup
  ON auth_session (refresh_expires_at, revoked_at);
