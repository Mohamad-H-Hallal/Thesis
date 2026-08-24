-- Remove workflow states and transfer fields that do not represent a real
-- decision or ownership boundary in the protected administration workspace.

UPDATE privacy_request
SET status = 'submitted', updated_at = CURRENT_TIMESTAMP
WHERE status = 'open';

ALTER TABLE privacy_request
  DROP CONSTRAINT IF EXISTS privacy_request_status_check;

ALTER TABLE privacy_request
  ADD CONSTRAINT privacy_request_status_check CHECK (
    status IN (
      'pending_verification',
      'submitted',
      'in_review',
      'awaiting_user',
      'approved',
      'scheduled',
      'processing',
      'failed',
      'rejected',
      'completed',
      'cancelled'
    )
  );

DROP INDEX IF EXISTS uq_privacy_request_open_type_per_user;

CREATE UNIQUE INDEX uq_privacy_request_open_type_per_user
  ON privacy_request (user_id, request_type)
  WHERE user_id IS NOT NULL
    AND status IN (
      'pending_verification', 'submitted', 'in_review', 'awaiting_user',
      'approved', 'scheduled', 'processing', 'failed'
    );

ALTER TABLE privacy_request
  DROP COLUMN IF EXISTS transfer_to_user_id;

UPDATE content_report
SET status = 'in_review', updated_at = CURRENT_TIMESTAMP
WHERE status = 'escalated';

UPDATE content_report
SET status = 'actioned', updated_at = CURRENT_TIMESTAMP,
    resolved_at = COALESCE(resolved_at, CURRENT_TIMESTAMP)
WHERE status = 'closed';

ALTER TABLE content_report
  DROP CONSTRAINT IF EXISTS content_report_status_check;

ALTER TABLE content_report
  ADD CONSTRAINT content_report_status_check CHECK (
    status IN (
      'open', 'in_review', 'awaiting_reporter',
      'action_required', 'actioned', 'dismissed'
    )
  );

DROP INDEX IF EXISTS idx_content_report_assignee_queue;

CREATE INDEX idx_content_report_assignee_queue
  ON content_report (assigned_to_user_id, status, internal_target_at)
  WHERE status NOT IN ('actioned', 'dismissed');

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'account_deletion_execution'
      AND column_name = 'responsibilities_transferred_at'
  ) AND NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'account_deletion_execution'
      AND column_name = 'responsibilities_released_at'
  ) THEN
    ALTER TABLE account_deletion_execution
      RENAME COLUMN responsibilities_transferred_at TO responsibilities_released_at;
  END IF;
END
$$;
