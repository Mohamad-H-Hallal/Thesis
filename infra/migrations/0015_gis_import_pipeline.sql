ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'import_event';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type
    WHERE typname = 'gis_import_status'
  ) THEN
    CREATE TYPE gis_import_status AS ENUM (
      'uploaded',
      'processing',
      'pending_review',
      'approved',
      'partially_approved',
      'rejected',
      'failed'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_type
    WHERE typname = 'gis_import_file_type'
  ) THEN
    CREATE TYPE gis_import_file_type AS ENUM (
      'geojson',
      'shapefile_zip',
      'kml',
      'kmz'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_type
    WHERE typname = 'gis_import_feature_status'
  ) THEN
    CREATE TYPE gis_import_feature_status AS ENUM (
      'pending_review',
      'approved',
      'rejected',
      'failed'
    );
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS gis_import_job (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  uploaded_by_user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  reviewed_by_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL,
  duplicate_of_import_job_id UUID REFERENCES gis_import_job(id) ON DELETE SET NULL,
  original_filename TEXT NOT NULL,
  stored_filename TEXT NOT NULL,
  file_path TEXT NOT NULL,
  file_size_bytes BIGINT NOT NULL,
  file_checksum_sha256 TEXT NOT NULL,
  file_type gis_import_file_type NOT NULL,
  source_crs TEXT,
  source_layer_name TEXT,
  status gis_import_status NOT NULL DEFAULT 'uploaded',
  geometry_count INTEGER NOT NULL DEFAULT 0,
  pending_feature_count INTEGER NOT NULL DEFAULT 0,
  approved_feature_count INTEGER NOT NULL DEFAULT 0,
  rejected_feature_count INTEGER NOT NULL DEFAULT 0,
  failed_feature_count INTEGER NOT NULL DEFAULT 0,
  warning_count INTEGER NOT NULL DEFAULT 0,
  error_count INTEGER NOT NULL DEFAULT 0,
  geometry_types TEXT[] NOT NULL DEFAULT '{}'::TEXT[],
  file_metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  validation_summary JSONB NOT NULL DEFAULT '{}'::JSONB,
  processing_message TEXT,
  rejection_reason TEXT,
  uploaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  processed_at TIMESTAMPTZ,
  reviewed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_gis_import_job_file_size CHECK (file_size_bytes > 0),
  CONSTRAINT chk_gis_import_job_checksum CHECK (char_length(file_checksum_sha256) = 64),
  CONSTRAINT chk_gis_import_job_counts CHECK (
    geometry_count >= 0
    AND pending_feature_count >= 0
    AND approved_feature_count >= 0
    AND rejected_feature_count >= 0
    AND failed_feature_count >= 0
    AND warning_count >= 0
    AND error_count >= 0
  ),
  CONSTRAINT chk_gis_import_job_file_metadata CHECK (
    jsonb_typeof(file_metadata) = 'object'
  ),
  CONSTRAINT chk_gis_import_job_validation_summary CHECK (
    jsonb_typeof(validation_summary) = 'object'
  )
);

CREATE INDEX IF NOT EXISTS idx_gis_import_job_project_status
  ON gis_import_job(project_id, status, uploaded_at DESC);

CREATE INDEX IF NOT EXISTS idx_gis_import_job_uploaded_by
  ON gis_import_job(uploaded_by_user_id, uploaded_at DESC);

CREATE INDEX IF NOT EXISTS idx_gis_import_job_status_uploaded
  ON gis_import_job(status, uploaded_at DESC);

CREATE INDEX IF NOT EXISTS idx_gis_import_job_checksum_project
  ON gis_import_job(project_id, file_checksum_sha256);

CREATE TABLE IF NOT EXISTS gis_import_feature (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  import_job_id UUID NOT NULL REFERENCES gis_import_job(id) ON DELETE CASCADE,
  source_index INTEGER NOT NULL,
  source_identifier TEXT,
  display_title TEXT NOT NULL,
  source_feature_name TEXT,
  geometry_type TEXT,
  geom GEOMETRY(Geometry, 4326),
  attributes JSONB NOT NULL DEFAULT '{}'::JSONB,
  status gis_import_feature_status NOT NULL DEFAULT 'pending_review',
  validation_warnings JSONB NOT NULL DEFAULT '[]'::JSONB,
  validation_errors JSONB NOT NULL DEFAULT '[]'::JSONB,
  validation_report JSONB NOT NULL DEFAULT '{}'::JSONB,
  duplicate_feature_id UUID REFERENCES spatial_feature(id) ON DELETE SET NULL,
  approved_feature_id UUID REFERENCES spatial_feature(id) ON DELETE SET NULL,
  reviewed_by_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL,
  reviewed_at TIMESTAMPTZ,
  approved_at TIMESTAMPTZ,
  review_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (import_job_id, source_index),
  CONSTRAINT chk_gis_import_feature_geometry_type CHECK (
    geometry_type IS NULL OR geometry_type IN ('Point', 'LineString', 'Polygon')
  ),
  CONSTRAINT chk_gis_import_feature_attributes CHECK (
    jsonb_typeof(attributes) = 'object'
  ),
  CONSTRAINT chk_gis_import_feature_warnings CHECK (
    jsonb_typeof(validation_warnings) = 'array'
  ),
  CONSTRAINT chk_gis_import_feature_errors CHECK (
    jsonb_typeof(validation_errors) = 'array'
  ),
  CONSTRAINT chk_gis_import_feature_validation_report CHECK (
    jsonb_typeof(validation_report) = 'object'
  ),
  CONSTRAINT chk_gis_import_feature_status_consistency CHECK (
    (status = 'failed' AND approved_feature_id IS NULL)
    OR (status IN ('pending_review', 'approved', 'rejected'))
  )
);

CREATE INDEX IF NOT EXISTS idx_gis_import_feature_job_status
  ON gis_import_feature(import_job_id, status, source_index);

CREATE INDEX IF NOT EXISTS idx_gis_import_feature_status_reviewed
  ON gis_import_feature(status, reviewed_at DESC, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_gis_import_feature_approved_feature
  ON gis_import_feature(approved_feature_id);

CREATE INDEX IF NOT EXISTS idx_gis_import_feature_duplicate_feature
  ON gis_import_feature(duplicate_feature_id);

CREATE INDEX IF NOT EXISTS idx_gis_import_feature_geom
  ON gis_import_feature
  USING GIST (geom);

CREATE OR REPLACE FUNCTION trg_set_gis_import_job_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trg_set_gis_import_feature_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trg_sync_gis_import_job_rollup(target_job_id UUID)
RETURNS void AS $$
DECLARE
  pending_count INTEGER := 0;
  approved_count INTEGER := 0;
  rejected_count INTEGER := 0;
  failed_count INTEGER := 0;
  geom_count INTEGER := 0;
  warning_total INTEGER := 0;
  error_total INTEGER := 0;
  types TEXT[] := '{}'::TEXT[];
  current_status gis_import_status;
  next_status gis_import_status;
BEGIN
  SELECT status
  INTO current_status
  FROM gis_import_job
  WHERE id = target_job_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT
    COUNT(*) FILTER (WHERE status = 'pending_review')::INTEGER,
    COUNT(*) FILTER (WHERE status = 'approved')::INTEGER,
    COUNT(*) FILTER (WHERE status = 'rejected')::INTEGER,
    COUNT(*) FILTER (WHERE status = 'failed')::INTEGER,
    COUNT(*) FILTER (WHERE geom IS NOT NULL)::INTEGER,
    COALESCE(SUM(jsonb_array_length(validation_warnings)), 0)::INTEGER,
    COALESCE(SUM(jsonb_array_length(validation_errors)), 0)::INTEGER,
    COALESCE(
      ARRAY_AGG(DISTINCT geometry_type) FILTER (WHERE geometry_type IS NOT NULL),
      '{}'::TEXT[]
    )
  INTO
    pending_count,
    approved_count,
    rejected_count,
    failed_count,
    geom_count,
    warning_total,
    error_total,
    types
  FROM gis_import_feature
  WHERE import_job_id = target_job_id;

  next_status := current_status;
  IF current_status NOT IN ('uploaded', 'processing', 'failed') THEN
    IF pending_count > 0 THEN
      next_status := 'pending_review';
    ELSIF approved_count > 0 AND (rejected_count > 0 OR failed_count > 0) THEN
      next_status := 'partially_approved';
    ELSIF approved_count > 0 THEN
      next_status := 'approved';
    ELSIF rejected_count > 0 THEN
      next_status := 'rejected';
    ELSIF failed_count > 0 THEN
      next_status := 'failed';
    END IF;
  END IF;

  UPDATE gis_import_job
  SET geometry_count = geom_count,
      pending_feature_count = pending_count,
      approved_feature_count = approved_count,
      rejected_feature_count = rejected_count,
      failed_feature_count = failed_count,
      warning_count = warning_total,
      error_count = error_total,
      geometry_types = types,
      status = next_status,
      updated_at = CURRENT_TIMESTAMP
  WHERE id = target_job_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trg_after_gis_import_feature_change()
RETURNS trigger AS $$
BEGIN
  PERFORM trg_sync_gis_import_job_rollup(COALESCE(NEW.import_job_id, OLD.import_job_id));

  IF TG_OP = 'UPDATE' AND NEW.import_job_id IS DISTINCT FROM OLD.import_job_id THEN
    PERFORM trg_sync_gis_import_job_rollup(OLD.import_job_id);
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_gis_import_job_updated_at ON gis_import_job;
CREATE TRIGGER trg_gis_import_job_updated_at
BEFORE UPDATE ON gis_import_job
FOR EACH ROW
EXECUTE FUNCTION trg_set_gis_import_job_updated_at();

DROP TRIGGER IF EXISTS trg_gis_import_feature_updated_at ON gis_import_feature;
CREATE TRIGGER trg_gis_import_feature_updated_at
BEFORE UPDATE ON gis_import_feature
FOR EACH ROW
EXECUTE FUNCTION trg_set_gis_import_feature_updated_at();

DROP TRIGGER IF EXISTS trg_gis_import_feature_rollup ON gis_import_feature;
CREATE TRIGGER trg_gis_import_feature_rollup
AFTER INSERT OR UPDATE OR DELETE ON gis_import_feature
FOR EACH ROW
EXECUTE FUNCTION trg_after_gis_import_feature_change();
