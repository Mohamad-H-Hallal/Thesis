-- Keep canonical identity columns populated for trusted maintenance scripts,
-- legacy imports, and bootstrap operations that still write the base email
-- column directly. API validation and ownership verification remain
-- authoritative; this trigger is a database consistency guard, not proof of
-- contact ownership.

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
     AND NEW.phone_e164 IS DISTINCT FROM OLD.phone_e164
     AND NEW.phone_verified_at IS NOT DISTINCT FROM OLD.phone_verified_at THEN
    NEW.phone_verified_at := NULL;
    NEW.is_active := FALSE;
    NEW.account_status := 'verification_required';
    NEW.verification_required_at := CURRENT_TIMESTAMP;
    NEW.auth_version := GREATEST(NEW.auth_version, OLD.auth_version + 1);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_contact_identity_write_guard ON "user";
CREATE TRIGGER trg_user_contact_identity_write_guard
BEFORE INSERT OR UPDATE OF email, email_original, email_canonical, email_verified_at,
  phone_e164, phone_verified_at
ON "user"
FOR EACH ROW
EXECUTE FUNCTION sync_user_contact_identity_columns();

COMMENT ON FUNCTION sync_user_contact_identity_columns() IS
  'Populates canonical contact columns and clears unchanged verification state after direct identity updates.';
