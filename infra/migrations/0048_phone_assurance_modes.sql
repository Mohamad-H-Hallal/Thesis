-- Support an explicit phone-format assurance path without conflating it with
-- SMS ownership verification. Twilio Lookup Basic may populate the lookup
-- timestamp, but only an OTP confirmation may populate phone_verified_at.

ALTER TABLE "user"
  ADD COLUMN IF NOT EXISTS phone_lookup_validated_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS phone_validation_method TEXT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'user_phone_validation_method_valid'
  ) THEN
    ALTER TABLE "user"
      ADD CONSTRAINT user_phone_validation_method_valid CHECK (
        phone_validation_method IS NULL
        OR phone_validation_method IN ('twilio_lookup_basic')
      );
  END IF;

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
        'validation_failed'
      )
    );
END $$;

CREATE INDEX IF NOT EXISTS idx_user_phone_assurance_state
  ON "user" (phone_verified_at, phone_lookup_validated_at, account_status);

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
    IF NEW.phone_lookup_validated_at IS NOT DISTINCT FROM OLD.phone_lookup_validated_at THEN
      NEW.phone_lookup_validated_at := NULL;
      NEW.phone_validation_method := NULL;
    END IF;
    IF NEW.phone_verified_at IS NULL AND NEW.phone_lookup_validated_at IS NULL THEN
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
  phone_e164, phone_verified_at, phone_lookup_validated_at, phone_validation_method
ON "user"
FOR EACH ROW
EXECUTE FUNCTION sync_user_contact_identity_columns();

COMMENT ON COLUMN "user".phone_lookup_validated_at IS
  'When the current phone passed the configured format/numbering lookup. This is not proof of possession.';
COMMENT ON COLUMN "user".phone_validation_method IS
  'Non-ownership phone validation source. Never use this column as an OTP-verification timestamp.';
COMMENT ON COLUMN "user".phone_verified_at IS
  'When possession of the current phone was confirmed through SMS OTP.';
COMMENT ON COLUMN "user".phone_e164 IS
  'Current Lebanese mobile identity normalized to E.164; assurance is represented by separate timestamps.';
