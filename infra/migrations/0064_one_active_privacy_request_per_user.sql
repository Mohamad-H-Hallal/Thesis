-- Keep privacy intake independent by request type. An account may have one
-- active deletion, export, and correction request at the same time, but never
-- two active requests of the same type.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM privacy_request
    WHERE user_id IS NOT NULL
      AND status IN (
        'pending_verification', 'submitted', 'open', 'in_review', 'awaiting_user',
        'approved', 'scheduled', 'processing', 'failed'
      )
    GROUP BY user_id, request_type
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION
      'Cannot enforce one active privacy request per type: reconcile duplicate active cases first.';
  END IF;
END
$$;

DROP INDEX IF EXISTS uq_privacy_request_active_per_user;
DROP INDEX IF EXISTS uq_privacy_request_open_type_per_user;

CREATE UNIQUE INDEX uq_privacy_request_open_type_per_user
  ON privacy_request (user_id, request_type)
  WHERE user_id IS NOT NULL
    AND status IN (
      'pending_verification', 'submitted', 'open', 'in_review', 'awaiting_user',
      'approved', 'scheduled', 'processing', 'failed'
    );
