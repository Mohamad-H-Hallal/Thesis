-- Record the protected administrator's explicit handling decision and make
-- storage cleanup a durable, retryable stage of account deletion.

ALTER TABLE account_deletion_execution
  ADD COLUMN unfinished_work_decision TEXT,
  ADD COLUMN responsibility_decision TEXT,
  ADD COLUMN discard_counts JSONB NOT NULL DEFAULT '{}'::JSONB,
  ADD COLUMN discard_completed_at TIMESTAMPTZ,
  ADD COLUMN account_tombstoned_at TIMESTAMPTZ,
  ADD COLUMN artifact_cleanup_completed_at TIMESTAMPTZ;

UPDATE account_deletion_execution
SET unfinished_work_decision = 'require_resolution',
    responsibility_decision = 'release'
WHERE unfinished_work_decision IS NULL
   OR responsibility_decision IS NULL;

ALTER TABLE account_deletion_execution
  ALTER COLUMN unfinished_work_decision SET NOT NULL,
  ALTER COLUMN responsibility_decision SET NOT NULL,
  ADD CONSTRAINT account_deletion_execution_owner_decisions_valid CHECK (
    unfinished_work_decision IN ('require_resolution', 'discard_unapproved')
    AND responsibility_decision IN ('release', 'confirmed_transferred')
  ),
  ADD CONSTRAINT account_deletion_execution_discard_counts_object CHECK (
    jsonb_typeof(discard_counts) = 'object'
  );

CREATE TABLE account_deletion_artifact_cleanup (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  execution_id UUID NOT NULL REFERENCES account_deletion_execution(id) ON DELETE CASCADE,
  storage_reference TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'deleted', 'failed')),
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  last_error_code TEXT,
  deleted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (execution_id, storage_reference),
  CHECK (NULLIF(BTRIM(storage_reference), '') IS NOT NULL),
  CHECK (
    (status = 'deleted' AND deleted_at IS NOT NULL AND last_error_code IS NULL)
    OR (status = 'failed' AND deleted_at IS NULL AND last_error_code IS NOT NULL)
    OR (status = 'pending' AND deleted_at IS NULL)
  )
);

CREATE INDEX idx_account_deletion_artifact_cleanup_pending
  ON account_deletion_artifact_cleanup (execution_id, status, created_at)
  WHERE status <> 'deleted';

COMMENT ON COLUMN account_deletion_execution.unfinished_work_decision IS
  'Explicit protected-administrator choice. discard_unapproved authorizes removal of unfinished records; no destructive choice is inferred.';
COMMENT ON COLUMN account_deletion_execution.responsibility_decision IS
  'Whether residual assignments/cases are released by the executor or were transferred through authoritative workflows before approval.';
COMMENT ON TABLE account_deletion_artifact_cleanup IS
  'Restricted durable queue proving that unnecessary stored artifacts were removed before a deletion request is completed.';
