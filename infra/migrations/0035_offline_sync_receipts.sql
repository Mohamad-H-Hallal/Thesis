CREATE TABLE IF NOT EXISTS offline_sync_receipt (
  user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  project_id UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  operation VARCHAR(32) NOT NULL,
  idempotency_key_hash CHAR(64) NOT NULL,
  payload_hash CHAR(64) NOT NULL,
  entity_ids UUID[] NOT NULL DEFAULT '{}'::uuid[],
  outcome VARCHAR(32) NOT NULL DEFAULT 'accepted',
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, project_id, operation, idempotency_key_hash),
  CONSTRAINT chk_offline_sync_receipt_operation
    CHECK (
      operation IN ('create', 'update', 'submit', 'batch_create', 'photo_upload')
    ),
  CONSTRAINT chk_offline_sync_receipt_key_hash
    CHECK (idempotency_key_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT chk_offline_sync_receipt_payload_hash
    CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT chk_offline_sync_receipt_outcome
    CHECK (outcome IN ('accepted', 'already_synchronized'))
);

CREATE INDEX IF NOT EXISTS idx_offline_sync_receipt_created_at
  ON offline_sync_receipt(created_at);
