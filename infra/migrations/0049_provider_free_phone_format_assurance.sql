-- Generalize phone-format assurance so production can use maintained local
-- libphonenumber metadata without an external provider account. Existing
-- Twilio Lookup timestamps and methods are preserved during the rename.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'user'
      AND column_name = 'phone_lookup_validated_at'
  ) AND NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'user'
      AND column_name = 'phone_format_validated_at'
  ) THEN
    ALTER TABLE "user"
      RENAME COLUMN phone_lookup_validated_at TO phone_format_validated_at;
  END IF;
END $$;

ALTER TABLE "user"
  ADD COLUMN IF NOT EXISTS phone_format_validated_at TIMESTAMPTZ;

ALTER TABLE "user"
  DROP CONSTRAINT IF EXISTS user_phone_validation_method_valid;
ALTER TABLE "user"
  ADD CONSTRAINT user_phone_validation_method_valid CHECK (
    phone_validation_method IS NULL
    OR phone_validation_method IN ('libphonenumber_max', 'twilio_lookup_basic')
  );

ALTER TABLE contact_verification_challenge
  DROP CONSTRAINT IF EXISTS contact_verification_challenge_channel_check;
ALTER TABLE contact_verification_challenge
  ADD CONSTRAINT contact_verification_challenge_channel_check CHECK (
    channel IN ('email', 'phone', 'sms')
  );

ALTER TABLE contact_verification_audit_event
  DROP CONSTRAINT IF EXISTS contact_verification_audit_event_channel_check;
ALTER TABLE contact_verification_audit_event
  ADD CONSTRAINT contact_verification_audit_event_channel_check CHECK (
    channel IN ('email', 'phone', 'sms')
  );

CREATE INDEX IF NOT EXISTS idx_user_phone_assurance_state
  ON "user" (phone_verified_at, phone_format_validated_at, account_status);

CREATE OR REPLACE FUNCTION sync_user_contact_identity_columns()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.email_original IS NULL
     OR (TG_OP = 'UPDATE'
         AND NEW.email IS DISTINCT FROM OLD.email
         AND NEW.email_original IS NOT DISTINCT FROM OLD.email_original) THEN
    NEW.email_original := BTRIM(NEW.email);
  END IF;

  IF NEW.email_canonical IS NULL
     OR (TG_OP = 'UPDATE'
         AND NEW.email IS DISTINCT FROM OLD.email
         AND NEW.email_canonical IS NOT DISTINCT FROM OLD.email_canonical) THEN
    NEW.email_canonical := LOWER(BTRIM(NEW.email));
  END IF;

  IF TG_OP = 'UPDATE'
     AND NEW.email IS DISTINCT FROM OLD.email
     AND NEW.email_verified_at IS NOT DISTINCT FROM OLD.email_verified_at THEN
    NEW.email_verified_at := NULL;
    NEW.is_active := FALSE;
    NEW.account_status := 'verification_required';
    NEW.verification_required_at := CURRENT_TIMESTAMP;
    NEW.auth_version := OLD.auth_version + 1;
  END IF;

  IF TG_OP = 'UPDATE'
     AND NEW.phone_e164 IS DISTINCT FROM OLD.phone_e164 THEN
    IF NEW.phone_verified_at IS NOT DISTINCT FROM OLD.phone_verified_at THEN
      NEW.phone_verified_at := NULL;
    END IF;
    IF NEW.phone_format_validated_at IS NOT DISTINCT FROM OLD.phone_format_validated_at THEN
      NEW.phone_format_validated_at := NULL;
      NEW.phone_validation_method := NULL;
    END IF;
    IF NEW.phone_verified_at IS NULL AND NEW.phone_format_validated_at IS NULL THEN
      NEW.is_active := FALSE;
      NEW.account_status := 'verification_required';
      NEW.verification_required_at := CURRENT_TIMESTAMP;
    END IF;
    NEW.auth_version := GREATEST(NEW.auth_version, OLD.auth_version + 1);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_contact_identity_write_guard ON "user";
CREATE TRIGGER trg_user_contact_identity_write_guard
BEFORE INSERT OR UPDATE OF email, email_original, email_canonical, email_verified_at,
  phone_e164, phone_verified_at, phone_format_validated_at, phone_validation_method
ON "user"
FOR EACH ROW
EXECUTE FUNCTION sync_user_contact_identity_columns();

COMMENT ON COLUMN "user".phone_format_validated_at IS
  'When the current phone passed configured structural format validation. This is not proof of possession, assignment, or reachability.';
COMMENT ON COLUMN "user".phone_validation_method IS
  'Structural phone-validation source. Only phone_verified_at represents a successful ownership challenge.';
