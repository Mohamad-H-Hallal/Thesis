-- Keep only statuses that have a real actor and a usable next step.

UPDATE privacy_request
SET status = 'in_review', updated_at = CURRENT_TIMESTAMP
WHERE status = 'awaiting_user';

ALTER TABLE privacy_request
  DROP CONSTRAINT IF EXISTS privacy_request_status_check;

ALTER TABLE privacy_request
  ADD CONSTRAINT privacy_request_status_check CHECK (
    status IN (
      'pending_verification',
      'submitted',
      'in_review',
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
      'pending_verification', 'submitted', 'in_review',
      'scheduled', 'processing', 'failed'
    );

UPDATE content_report
SET status = CASE status
  WHEN 'open' THEN 'submitted'
  WHEN 'awaiting_reporter' THEN 'in_review'
  WHEN 'action_required' THEN 'in_review'
  WHEN 'actioned' THEN 'resolved'
  ELSE status
END,
updated_at = CURRENT_TIMESTAMP
WHERE status IN ('open', 'awaiting_reporter', 'action_required', 'actioned');

ALTER TABLE content_report
  DROP CONSTRAINT IF EXISTS content_report_status_check;

ALTER TABLE content_report
  ALTER COLUMN status SET DEFAULT 'submitted';

ALTER TABLE content_report
  ADD CONSTRAINT content_report_status_check CHECK (
    status IN ('submitted', 'in_review', 'resolved', 'dismissed')
  );

DROP INDEX IF EXISTS idx_content_report_assignee_queue;

CREATE INDEX idx_content_report_assignee_queue
  ON content_report (assigned_to_user_id, status, internal_target_at)
  WHERE status NOT IN ('resolved', 'dismissed');
