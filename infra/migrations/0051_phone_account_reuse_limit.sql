-- Permit a normalized Lebanese mobile number on at most three user accounts.
-- Email remains the unique login identity. The transaction-scoped advisory
-- lock makes the count safe when simultaneous signups target the same number.

DROP INDEX IF EXISTS uq_user_phone_e164_reserved;
DROP INDEX IF EXISTS uq_user_pending_phone_e164;

CREATE INDEX IF NOT EXISTS idx_user_phone_e164
  ON "user" (phone_e164)
  WHERE phone_e164 IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_user_pending_phone_e164
  ON "user" (pending_phone_e164)
  WHERE pending_phone_e164 IS NOT NULL;

CREATE OR REPLACE FUNCTION enforce_user_phone_account_limit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  target_phone TEXT;
  existing_accounts INTEGER;
BEGIN
  FOR target_phone IN
    SELECT DISTINCT value
    FROM (VALUES (NEW.phone_e164), (NEW.pending_phone_e164)) AS phones(value)
    WHERE value IS NOT NULL
    ORDER BY value
  LOOP
    PERFORM pg_advisory_xact_lock(
      hashtextextended('user-phone-account:' || target_phone, 0)
    );

    SELECT COUNT(DISTINCT id)::int
      INTO existing_accounts
    FROM "user"
    WHERE id IS DISTINCT FROM NEW.id
      AND (phone_e164 = target_phone OR pending_phone_e164 = target_phone);

    IF existing_accounts >= 3 THEN
      RAISE EXCEPTION USING
        ERRCODE = '23514',
        CONSTRAINT = 'user_phone_account_limit',
        MESSAGE = 'A mobile number cannot be used by more than three accounts.';
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_phone_account_limit ON "user";
CREATE TRIGGER trg_user_phone_account_limit
BEFORE INSERT OR UPDATE OF phone_e164, pending_phone_e164
ON "user"
FOR EACH ROW
EXECUTE FUNCTION enforce_user_phone_account_limit();

COMMENT ON FUNCTION enforce_user_phone_account_limit() IS
  'Enforces the hard maximum of three accounts per normalized phone, including pending phone changes.';
