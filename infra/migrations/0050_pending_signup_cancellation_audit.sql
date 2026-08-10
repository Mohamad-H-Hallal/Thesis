-- Preserve a masked audit record when an unverified self-signup is cancelled.
-- The user and all active challenges are removed only through the scoped
-- verification-session endpoint; verified, invited, admin, and legacy accounts
-- are not eligible for this operation.

ALTER TABLE contact_verification_audit_event
  DROP CONSTRAINT IF EXISTS contact_verification_audit_event_event_type_check;

ALTER TABLE contact_verification_audit_event
  ADD CONSTRAINT contact_verification_audit_event_event_type_check CHECK (
    event_type IN (
      'send_requested',
      'send_succeeded',
      'send_failed',
      'verification_failed',
      'verification_succeeded',
      'challenge_blocked',
      'contact_change_requested',
      'contact_change_succeeded',
      'validation_requested',
      'validation_succeeded',
      'validation_failed',
      'pending_signup_cancelled'
    )
  );

COMMENT ON COLUMN contact_verification_audit_event.event_type IS
  'Purpose-bound contact assurance event; pending signup cancellation retains only masked contact data.';
