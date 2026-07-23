-- Freeze the legacy AI evidence paths that existed when this migration ran.
-- New validation uploads use /uploads/ai-validation and must never make a
-- feature-photo file public merely by referencing it in mutable JSON.
CREATE TABLE IF NOT EXISTS legacy_ai_validation_media_snapshot (
  storage_name TEXT PRIMARY KEY,
  snapshotted_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_legacy_ai_validation_media_snapshot_name CHECK (
    storage_name ~* '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpe?g|png|gif|hei[cf]s?)$'
  )
);

-- Reapplying this still-unreleased migration in a development database must
-- be able to refresh the one-time snapshot without leaving it writable after
-- the transaction commits.
DROP TRIGGER IF EXISTS trg_legacy_ai_validation_media_snapshot_immutable
  ON legacy_ai_validation_media_snapshot;

ALTER TABLE legacy_ai_validation_media_snapshot
  DROP CONSTRAINT IF EXISTS chk_legacy_ai_validation_media_snapshot_name;
ALTER TABLE legacy_ai_validation_media_snapshot
  ADD CONSTRAINT chk_legacy_ai_validation_media_snapshot_name CHECK (
    storage_name ~* '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpe?g|png|gif|hei[cf]s?)$'
  );

TRUNCATE legacy_ai_validation_media_snapshot;

INSERT INTO legacy_ai_validation_media_snapshot (storage_name)
SELECT DISTINCT normalized.storage_name
FROM ai_prediction_feature_validation AS validation
CROSS JOIN LATERAL jsonb_array_elements_text(validation.photo_media_ids) AS media(media_url)
CROSS JOIN LATERAL (
  SELECT regexp_replace(media.media_url, '^/uploads/photos/', '') AS storage_name
) AS normalized
WHERE normalized.storage_name ~* '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpe?g|png|gif|hei[cf]s?)$'
  AND NOT EXISTS (
    SELECT 1
    FROM photo AS feature_photo
    WHERE RIGHT(
            REPLACE(feature_photo.file_path, E'\\', '/'),
            LENGTH('/' || normalized.storage_name)
          ) = '/' || normalized.storage_name
       OR RIGHT(
            REPLACE(COALESCE(feature_photo.thumbnail_path, ''), E'\\', '/'),
            LENGTH('/' || normalized.storage_name)
          ) = '/' || normalized.storage_name
  )
ON CONFLICT (storage_name) DO NOTHING;

CREATE OR REPLACE FUNCTION reject_legacy_ai_validation_media_snapshot_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'legacy AI validation media snapshot is immutable'
    USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER trg_legacy_ai_validation_media_snapshot_immutable
  BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE
  ON legacy_ai_validation_media_snapshot
  FOR EACH STATEMENT
  EXECUTE FUNCTION reject_legacy_ai_validation_media_snapshot_mutation();

-- This index supported the old mutable lookup and is deliberately removed so
-- the runtime cannot accidentally drift back to trusting photo_media_ids.
DROP INDEX IF EXISTS idx_ai_prediction_feature_validation_photo_media_ids_gin;
