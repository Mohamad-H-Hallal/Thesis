-- Protected-super-admin-created administrator accounts are activated directly
-- without claiming that their email or phone ownership was verified. The
-- exemption remains explicit and auditable instead of populating false
-- email_verified_at or phone_verified_at timestamps.

ALTER TABLE "user"
  ADD COLUMN IF NOT EXISTS contact_verification_exempted_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS contact_verification_exempted_by UUID;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'user_contact_verification_exempted_by_fkey'
  ) THEN
    ALTER TABLE "user"
      ADD CONSTRAINT user_contact_verification_exempted_by_fkey
      FOREIGN KEY (contact_verification_exempted_by)
      REFERENCES "user"(id)
      ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'user_contact_verification_exemption_complete'
  ) THEN
    ALTER TABLE "user"
      ADD CONSTRAINT user_contact_verification_exemption_complete CHECK (
        (contact_verification_exempted_at IS NULL
          AND contact_verification_exempted_by IS NULL)
        OR
        (contact_verification_exempted_at IS NOT NULL
          AND contact_verification_exempted_by IS NOT NULL)
      );
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_user_contact_verification_exemption
  ON "user" (contact_verification_exempted_at)
  WHERE contact_verification_exempted_at IS NOT NULL;

COMMENT ON COLUMN "user".contact_verification_exempted_at IS
  'Administrative contact-verification exemption. This is not proof of email or phone ownership.';
COMMENT ON COLUMN "user".contact_verification_exempted_by IS
  'Protected super administrator that granted the contact-verification exemption during admin creation.';
