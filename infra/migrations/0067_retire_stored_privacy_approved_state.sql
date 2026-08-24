-- Approval is an administrator action, not a durable queue state. Every
-- approved request is persisted as its actual execution or completion state.

UPDATE privacy_request
SET status = 'failed',
    failed_at = COALESCE(failed_at, CURRENT_TIMESTAMP),
    failure_code = COALESCE(
      failure_code,
      'LEGACY_APPROVED_EXECUTION_REVIEW_REQUIRED'
    ),
    last_user_visible_message =
      'Your request requires an execution review before it can continue.',
    updated_at = CURRENT_TIMESTAMP
WHERE status = 'approved';

ALTER TABLE privacy_request
  DROP CONSTRAINT IF EXISTS privacy_request_status_check;

ALTER TABLE privacy_request
  ADD CONSTRAINT privacy_request_status_check CHECK (
    status IN (
      'pending_verification',
      'submitted',
      'in_review',
      'awaiting_user',
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
      'scheduled', 'processing', 'failed'
    );
