-- Correct the literal plus-sign escape for databases that applied migration
-- 0045 before its constraint definition was corrected.
ALTER TABLE "user" DROP CONSTRAINT IF EXISTS user_phone_e164_shape;
ALTER TABLE "user"
  ADD CONSTRAINT user_phone_e164_shape CHECK (
    phone_e164 IS NULL OR phone_e164 ~ '^\+961[0-9]{7,8}$'
  );

ALTER TABLE "user" DROP CONSTRAINT IF EXISTS user_pending_phone_e164_shape;
ALTER TABLE "user"
  ADD CONSTRAINT user_pending_phone_e164_shape CHECK (
    pending_phone_e164 IS NULL OR pending_phone_e164 ~ '^\+961[0-9]{7,8}$'
  );
