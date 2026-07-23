CREATE TABLE IF NOT EXISTS feature_media_cleanup_job (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  storage_path TEXT NOT NULL UNIQUE,
  reason VARCHAR(32) NOT NULL,
  available_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  last_attempted_at TIMESTAMPTZ,
  last_error_code VARCHAR(64),
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_feature_media_cleanup_job_path
    CHECK (char_length(storage_path) BETWEEN 1 AND 2048),
  CONSTRAINT chk_feature_media_cleanup_job_reason
    CHECK (reason IN ('upload_rollback', 'photo_deleted')),
  CONSTRAINT chk_feature_media_cleanup_job_attempts
    CHECK (attempt_count BETWEEN 0 AND 1000000),
  CONSTRAINT chk_feature_media_cleanup_job_error_code
    CHECK (
      last_error_code IS NULL
      OR last_error_code ~ '^[A-Z0-9_]{1,64}$'
    )
);

CREATE INDEX IF NOT EXISTS idx_feature_media_cleanup_job_available
  ON feature_media_cleanup_job(available_at, created_at);

CREATE INDEX IF NOT EXISTS idx_photo_file_path
  ON photo(file_path);

CREATE INDEX IF NOT EXISTS idx_photo_thumbnail_path
  ON photo(thumbnail_path)
  WHERE thumbnail_path IS NOT NULL;

-- Deleting a photo cannot violate the project photo-count ceiling. The original
-- trigger attempted to reload the parent feature during ON DELETE CASCADE, after
-- PostgreSQL had already made the parent row unavailable to the child trigger.
-- Preserve the existing insert/update enforcement while allowing both direct
-- photo deletion and feature cascades to complete.
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
