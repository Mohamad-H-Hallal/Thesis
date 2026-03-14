DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_project_category_required'
  ) THEN
    ALTER TABLE project
      ADD CONSTRAINT chk_project_category_required
      CHECK (category_id IS NOT NULL) NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_project_assignment_approved_meta'
  ) THEN
    ALTER TABLE project_assignment
      ADD CONSTRAINT chk_project_assignment_approved_meta
      CHECK (
        status <> 'approved'
        OR (approved_by_user_id IS NOT NULL AND approved_date IS NOT NULL)
      ) NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_spatial_feature_review_required'
  ) THEN
    ALTER TABLE spatial_feature
      ADD CONSTRAINT chk_spatial_feature_review_required
      CHECK (
        status NOT IN ('approved', 'rejected')
        OR (reviewed_by_user_id IS NOT NULL AND reviewed_at IS NOT NULL)
      ) NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_notification_metadata_object'
  ) THEN
    ALTER TABLE notification
      ADD CONSTRAINT chk_notification_metadata_object
      CHECK (metadata IS NULL OR jsonb_typeof(metadata) = 'object');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_export_failed_requires_error'
  ) THEN
    ALTER TABLE shapefile_export
      ADD CONSTRAINT chk_export_failed_requires_error
      CHECK (status <> 'failed' OR NULLIF(error_message, '') IS NOT NULL) NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_export_completed_requires_file'
  ) THEN
    ALTER TABLE shapefile_export
      ADD CONSTRAINT chk_export_completed_requires_file
      CHECK (status <> 'completed' OR NULLIF(file_path, '') IS NOT NULL) NOT VALID;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_lebanon_offline_map_single_current
  ON lebanon_offline_map (is_current)
  WHERE is_current;

CREATE OR REPLACE FUNCTION trg_set_project_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_project_updated_at ON project;
CREATE TRIGGER trg_project_updated_at
BEFORE UPDATE ON project
FOR EACH ROW
EXECUTE FUNCTION trg_set_project_updated_at();

CREATE OR REPLACE FUNCTION trg_enforce_project_status_transition()
RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN
      RAISE EXCEPTION 'project.status must start at draft';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF OLD.status = 'draft' AND NEW.status = 'active' THEN
    RETURN NEW;
  END IF;

  IF OLD.status = 'active' AND NEW.status = 'completed' THEN
    RETURN NEW;
  END IF;

  IF OLD.status = 'completed' AND NEW.status = 'archived' THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION
    'Invalid project status transition from % to %',
    OLD.status,
    NEW.status;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_project_status_transition ON project;
CREATE TRIGGER trg_project_status_transition
BEFORE INSERT OR UPDATE OF status ON project
FOR EACH ROW
EXECUTE FUNCTION trg_enforce_project_status_transition();

CREATE OR REPLACE FUNCTION trg_enforce_notification_metadata_context()
RETURNS trigger AS $$
DECLARE
  has_context_key boolean;
BEGIN
  IF NEW.metadata IS NULL THEN
    RAISE EXCEPTION 'notification.metadata is required and must include context identifiers';
  END IF;

  IF jsonb_typeof(NEW.metadata) <> 'object' THEN
    RAISE EXCEPTION 'notification.metadata must be a JSON object';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM jsonb_object_keys(NEW.metadata) AS k(key_name)
    WHERE key_name ~* '(_id|_ids|_uuid|ids)$'
  )
  INTO has_context_key;

  IF NOT has_context_key THEN
    RAISE EXCEPTION 'notification.metadata must contain at least one context id key (e.g. project_id, feature_id)';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_notification_metadata_context ON notification;
CREATE TRIGGER trg_notification_metadata_context
BEFORE INSERT OR UPDATE ON notification
FOR EACH ROW
EXECUTE FUNCTION trg_enforce_notification_metadata_context();

CREATE OR REPLACE FUNCTION trg_enforce_photo_project_limits()
RETURNS trigger AS $$
DECLARE
  target_feature_id uuid;
  target_project_id uuid;
  target_max_photos integer;
  current_count integer;
BEGIN
  target_feature_id := COALESCE(NEW.feature_id, OLD.feature_id);

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
  ELSIF TG_OP = 'DELETE' THEN
    current_count := GREATEST(current_count - 1, 0);
  END IF;

  IF current_count > target_max_photos THEN
    RAISE EXCEPTION
      'Photo count % exceeds project max_photos % for feature %',
      current_count,
      target_max_photos,
      target_feature_id;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_photo_project_limits ON photo;
CREATE TRIGGER trg_photo_project_limits
BEFORE INSERT OR UPDATE OR DELETE ON photo
FOR EACH ROW
EXECUTE FUNCTION trg_enforce_photo_project_limits();

CREATE OR REPLACE FUNCTION trg_enforce_feature_photo_policy()
RETURNS trigger AS $$
DECLARE
  project_requires_photos boolean;
  project_min_photos integer;
  project_max_photos integer;
  current_count integer;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF NEW.status NOT IN ('pending_review', 'approved') THEN
    RETURN NEW;
  END IF;

  SELECT p.requires_photos, p.min_photos, p.max_photos
  INTO project_requires_photos, project_min_photos, project_max_photos
  FROM project p
  WHERE p.id = NEW.project_id;

  IF project_min_photos IS NULL THEN
    RAISE EXCEPTION 'Project % not found for feature photo policy', NEW.project_id;
  END IF;

  SELECT COUNT(*) INTO current_count
  FROM photo
  WHERE feature_id = NEW.id;

  IF current_count > project_max_photos THEN
    RAISE EXCEPTION
      'Feature % has % photos which exceeds project max_photos %',
      NEW.id,
      current_count,
      project_max_photos;
  END IF;

  IF project_requires_photos AND current_count < project_min_photos THEN
    RAISE EXCEPTION
      'Feature % requires at least % photos before status % (current: %)',
      NEW.id,
      project_min_photos,
      NEW.status,
      current_count;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_feature_photo_policy ON spatial_feature;
CREATE TRIGGER trg_feature_photo_policy
BEFORE INSERT OR UPDATE OF status ON spatial_feature
FOR EACH ROW
EXECUTE FUNCTION trg_enforce_feature_photo_policy();
