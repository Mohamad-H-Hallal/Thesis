-- Reconcile pre-release development databases with a clean migration run.
--
-- Migrations 0027, 0038, and 0039 were refined before the first production
-- deployment. Existing development databases recorded the earlier working
-- copies, while clean databases receive the final definitions. This additive,
-- idempotent migration makes both paths converge without rewriting history.

ALTER TYPE ai_uncertainty_area_status
  ADD VALUE IF NOT EXISTS 'in_progress';
ALTER TYPE ai_uncertainty_area_status
  ADD VALUE IF NOT EXISTS 'rejected';
ALTER TYPE ai_uncertainty_area_status
  ADD VALUE IF NOT EXISTS 'cancelled';

ALTER TABLE ai_uncertainty_area
  ADD COLUMN IF NOT EXISTS ai_output_layer_id UUID,
  ADD COLUMN IF NOT EXISTS artifact_feature_id TEXT,
  ADD COLUMN IF NOT EXISTS validation_notes TEXT,
  ADD COLUMN IF NOT EXISTS metadata JSONB NOT NULL DEFAULT '{}'::JSONB;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ai_uncertainty_area_ai_output_layer_id_fkey'
      AND conrelid = 'ai_uncertainty_area'::regclass
      AND confdeltype <> 'n'
  ) THEN
    ALTER TABLE ai_uncertainty_area
      DROP CONSTRAINT ai_uncertainty_area_ai_output_layer_id_fkey;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ai_uncertainty_area_ai_output_layer_id_fkey'
      AND conrelid = 'ai_uncertainty_area'::regclass
  ) THEN
    ALTER TABLE ai_uncertainty_area
      ADD CONSTRAINT ai_uncertainty_area_ai_output_layer_id_fkey
      FOREIGN KEY (ai_output_layer_id)
      REFERENCES ai_output_layer(id)
      ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_ai_uncertainty_area_artifact_feature_id'
      AND conrelid = 'ai_uncertainty_area'::regclass
  ) THEN
    ALTER TABLE ai_uncertainty_area
      ADD CONSTRAINT chk_ai_uncertainty_area_artifact_feature_id
      CHECK (artifact_feature_id IS NULL OR btrim(artifact_feature_id) <> '');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_ai_uncertainty_area_metadata'
      AND conrelid = 'ai_uncertainty_area'::regclass
  ) THEN
    ALTER TABLE ai_uncertainty_area
      ADD CONSTRAINT chk_ai_uncertainty_area_metadata
      CHECK (jsonb_typeof(metadata) = 'object');
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_uncertainty_area_layer_feature
  ON ai_uncertainty_area(ai_run_id, ai_output_layer_id, artifact_feature_id)
  WHERE ai_output_layer_id IS NOT NULL
    AND artifact_feature_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_uncertainty_area_run_feature
  ON ai_uncertainty_area(ai_run_id, artifact_feature_id)
  WHERE artifact_feature_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ai_uncertainty_area_layer
  ON ai_uncertainty_area(ai_output_layer_id)
  WHERE ai_output_layer_id IS NOT NULL;

ALTER TABLE app_support_settings
  ALTER COLUMN id SET DEFAULT 1;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM legacy_ai_validation_media_snapshot
    WHERE storage_name !~* '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpe?g|png|gif|hei[cf]s?)$'
  ) THEN
    RAISE EXCEPTION
      'legacy_ai_validation_media_snapshot contains an invalid storage name';
  END IF;
END $$;

DROP TRIGGER IF EXISTS trg_legacy_ai_validation_media_snapshot_immutable
  ON legacy_ai_validation_media_snapshot;

ALTER TABLE legacy_ai_validation_media_snapshot
  DROP CONSTRAINT IF EXISTS chk_legacy_ai_validation_media_snapshot_name;
ALTER TABLE legacy_ai_validation_media_snapshot
  ADD CONSTRAINT chk_legacy_ai_validation_media_snapshot_name CHECK (
    storage_name ~* '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpe?g|png|gif|hei[cf]s?)$'
  );

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

CREATE INDEX IF NOT EXISTS idx_photo_file_path
  ON photo(file_path);

CREATE INDEX IF NOT EXISTS idx_photo_thumbnail_path
  ON photo(thumbnail_path)
  WHERE thumbnail_path IS NOT NULL;

CREATE OR REPLACE FUNCTION trg_enforce_photo_project_limits()
RETURNS trigger AS $$
DECLARE
  target_feature_id uuid;
  target_project_id uuid;
  target_max_photos integer;
  current_count integer;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  target_feature_id := NEW.feature_id;

  SELECT sf.project_id, p.max_photos
  INTO target_project_id, target_max_photos
  FROM spatial_feature sf
  JOIN project p ON p.id = sf.project_id
  WHERE sf.id = target_feature_id;

  IF target_project_id IS NULL THEN
    RAISE EXCEPTION 'Spatial feature % not found for photo rule validation', target_feature_id;
  END IF;

  IF TG_OP = 'UPDATE' AND NEW.feature_id <> OLD.feature_id THEN
    RAISE EXCEPTION 'Changing photo.feature_id is not allowed';
  END IF;

  SELECT COUNT(*) INTO current_count
  FROM photo
  WHERE feature_id = target_feature_id;

  IF TG_OP = 'INSERT' THEN
    current_count := current_count + 1;
  END IF;

  IF current_count > target_max_photos THEN
    RAISE EXCEPTION
      'Photo count % exceeds project max_photos % for feature %',
      current_count,
      target_max_photos,
      target_feature_id;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION enqueue_deleted_feature_media_cleanup()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF (
    OLD.file_path IS NOT NULL
    AND NOT (char_length(OLD.file_path) BETWEEN 1 AND 2048)
  ) OR (
    OLD.thumbnail_path IS NOT NULL
    AND NOT (char_length(OLD.thumbnail_path) BETWEEN 1 AND 2048)
  ) THEN
    RAISE EXCEPTION USING
      MESSAGE = 'Photo media path cannot be queued for cleanup',
      ERRCODE = 'check_violation';
  END IF;

  INSERT INTO feature_media_cleanup_job (storage_path, reason, available_at)
  SELECT DISTINCT candidate.storage_path, 'photo_deleted', CURRENT_TIMESTAMP
  FROM (
    VALUES (OLD.file_path), (OLD.thumbnail_path)
  ) AS candidate(storage_path)
  WHERE candidate.storage_path IS NOT NULL
  ON CONFLICT (storage_path) DO UPDATE
  SET reason = 'photo_deleted',
      available_at = LEAST(feature_media_cleanup_job.available_at, CURRENT_TIMESTAMP),
      last_error_code = NULL;

  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_photo_enqueue_media_cleanup ON photo;

CREATE TRIGGER trg_photo_enqueue_media_cleanup
  AFTER DELETE ON photo
  FOR EACH ROW
  EXECUTE FUNCTION enqueue_deleted_feature_media_cleanup();
