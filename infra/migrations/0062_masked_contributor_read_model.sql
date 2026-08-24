-- Existing read models must display the one-way masked label after deletion
-- without retaining the deleted account's full name.

CREATE OR REPLACE VIEW user_productivity AS
SELECT
  u.id AS user_id,
  COALESCE(u.full_name, u.masked_contributor_label, 'Former contributor') AS full_name,
  u.email,
  u.role,
  COUNT(DISTINCT sf.id) AS collected_features,
  COUNT(DISTINCT sf.id) FILTER (WHERE sf.status = 'approved') AS approved_features,
  COUNT(DISTINCT sf.id) FILTER (WHERE sf.status = 'pending_review') AS pending_review_features,
  COUNT(DISTINCT ph.id) AS uploaded_photos,
  MAX(sf.collected_at) AS last_collection_at
FROM "user" u
LEFT JOIN spatial_feature sf ON sf.collected_by_user_id = u.id
LEFT JOIN photo ph ON ph.feature_id = sf.id
GROUP BY u.id;

CREATE OR REPLACE FUNCTION sync_user_contact_identity_columns()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.account_status = 'deleted' THEN
    NEW.email := NULL;
    NEW.email_original := NULL;
    NEW.email_canonical := NULL;
    NEW.email_verified_at := NULL;
    NEW.phone := NULL;
    NEW.phone_e164 := NULL;
    NEW.phone_verified_at := NULL;
    NEW.pending_email_original := NULL;
    NEW.pending_email_canonical := NULL;
    NEW.pending_phone_e164 := NULL;
    RETURN NEW;
  END IF;

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

COMMENT ON FUNCTION sync_user_contact_identity_columns() IS
  'Maintains canonical contacts for active accounts and preserves the constrained no-contact deleted tombstone state.';
