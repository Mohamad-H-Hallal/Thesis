-- Completion is a database invariant, not merely a worker convention.

ALTER TABLE account_deletion_execution
  ADD COLUMN legacy_completion_recorded_at TIMESTAMPTZ;

UPDATE account_deletion_execution
SET legacy_completion_recorded_at = CURRENT_TIMESTAMP
WHERE status = 'completed'
  AND artifact_cleanup_completed_at IS NULL;

ALTER TABLE account_deletion_execution
  ADD CONSTRAINT account_deletion_execution_v2_completion_valid CHECK (
    status <> 'completed'
    OR (
      discard_completed_at IS NOT NULL
      AND account_tombstoned_at IS NOT NULL
      AND artifact_cleanup_completed_at IS NOT NULL
      AND unfinished_work_decision IS NOT NULL
      AND responsibility_decision IS NOT NULL
    )
    OR legacy_completion_recorded_at IS NOT NULL
  ) NOT VALID;

ALTER TABLE account_deletion_execution
  VALIDATE CONSTRAINT account_deletion_execution_v2_completion_valid;

CREATE OR REPLACE FUNCTION enforce_completed_account_deletion_request()
RETURNS trigger AS $$
BEGIN
  IF NEW.request_type = 'deletion' AND NEW.status = 'completed' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM account_deletion_execution execution
      WHERE execution.privacy_request_id = NEW.id
        AND execution.status = 'completed'
        AND (
          (
            execution.account_tombstoned_at IS NOT NULL
            AND execution.artifact_cleanup_completed_at IS NOT NULL
          )
          OR execution.legacy_completion_recorded_at IS NOT NULL
        )
    ) THEN
      RAISE EXCEPTION 'ACCOUNT_DELETION_EXECUTION_INCOMPLETE'
        USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_enforce_completed_account_deletion_request ON privacy_request;
CREATE CONSTRAINT TRIGGER trg_enforce_completed_account_deletion_request
AFTER INSERT OR UPDATE OF status ON privacy_request
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION enforce_completed_account_deletion_request();

COMMENT ON CONSTRAINT account_deletion_execution_v2_completion_valid
  ON account_deletion_execution IS
  'Prevents completion before explicit decisions, tombstoning, and durable storage cleanup are evidenced.';
COMMENT ON COLUMN account_deletion_execution.legacy_completion_recorded_at IS
  'Identifies a deletion completed before the v2 durable artifact stage. It is migration evidence, not proof that v2 cleanup ran.';
