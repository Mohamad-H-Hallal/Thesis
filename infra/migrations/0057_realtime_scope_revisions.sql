CREATE TABLE realtime_scope_revision (
  scope_type VARCHAR(40) NOT NULL,
  scope_id VARCHAR(120) NOT NULL,
  revision BIGINT NOT NULL DEFAULT 1,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (scope_type, scope_id),
  CONSTRAINT chk_realtime_scope_type_format CHECK (
    scope_type ~ '^[a-z][a-z0-9_]{0,39}$'
  ),
  CONSTRAINT chk_realtime_scope_id_format CHECK (
    scope_id ~ '^[A-Za-z0-9][A-Za-z0-9:_-]{0,119}$'
  ),
  CONSTRAINT chk_realtime_scope_revision_positive CHECK (revision > 0)
);

CREATE INDEX idx_realtime_scope_revision_updated
  ON realtime_scope_revision (updated_at DESC);

COMMENT ON TABLE realtime_scope_revision IS
  'Durable, non-sensitive revision ledger used to reconcile missed realtime invalidation hints.';

COMMENT ON COLUMN realtime_scope_revision.scope_id IS
  'Opaque application scope identifier; never stores credentials, contact details, or geometry.';
