-- Normalize structurally clear legacy Lebanese mobile values so the account
-- reuse policy counts data that predates phone_e164. Existing over-limit
-- groups are grandfathered in place; no account, role, or relationship is
-- changed, but the trigger prevents any additional account using that number.

DROP TRIGGER IF EXISTS trg_user_phone_account_limit ON "user";

WITH legacy_phone_candidates AS (
  SELECT
    id,
    regexp_replace(BTRIM(phone), '[[:space:]().-]', '', 'g') AS compact_phone
  FROM "user"
  WHERE phone_e164 IS NULL
    AND phone IS NOT NULL
),
normalized_legacy_phones AS (
  SELECT
    id,
    CASE
      WHEN compact_phone ~ '^03[0-9]{6}$'
        THEN '+961' || SUBSTRING(compact_phone FROM 2)
      WHEN compact_phone ~ '^(70|71|76|78|79|81)[0-9]{6}$'
        THEN '+961' || compact_phone
      WHEN compact_phone ~ '^\+9613[0-9]{6}$'
        THEN compact_phone
      WHEN compact_phone ~ '^\+961(70|71|76|78|79|81)[0-9]{6}$'
        THEN compact_phone
      WHEN compact_phone ~ '^9613[0-9]{6}$'
        THEN '+' || compact_phone
      WHEN compact_phone ~ '^961(70|71|76|78|79|81)[0-9]{6}$'
        THEN '+' || compact_phone
      ELSE NULL
    END AS phone_e164
  FROM legacy_phone_candidates
)
UPDATE "user" AS target
SET phone = normalized.phone_e164,
    phone_e164 = normalized.phone_e164
FROM normalized_legacy_phones AS normalized
WHERE target.id = normalized.id
  AND normalized.phone_e164 IS NOT NULL;

CREATE TRIGGER trg_user_phone_account_limit
BEFORE INSERT OR UPDATE OF phone_e164, pending_phone_e164
ON "user"
FOR EACH ROW
EXECUTE FUNCTION enforce_user_phone_account_limit();

COMMENT ON TRIGGER trg_user_phone_account_limit ON "user" IS
  'Prevents new or changed normalized phone assignments after three accounts; legacy over-limit groups remain preserved but cannot grow.';
