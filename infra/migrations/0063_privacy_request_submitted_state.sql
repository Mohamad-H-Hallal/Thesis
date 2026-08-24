-- Distinguish a newly submitted request from an administrator-opened review.
-- Existing `open` rows remain valid for backward compatibility.

ALTER TABLE privacy_request
  DROP CONSTRAINT IF EXISTS privacy_request_status_check;

ALTER TABLE privacy_request
  ADD CONSTRAINT privacy_request_status_check CHECK (
    status IN (
      'pending_verification',
      'submitted',
      'open',
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
      'pending_verification', 'submitted', 'open', 'in_review', 'awaiting_user',
      'approved', 'scheduled', 'processing', 'failed'
    );
