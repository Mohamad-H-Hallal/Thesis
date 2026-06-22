ALTER TABLE shapefile_export
  ADD COLUMN IF NOT EXISTS file_status TEXT NOT NULL DEFAULT 'missing',
  ADD COLUMN IF NOT EXISTS retention_expires_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS retention_expired_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS file_deleted_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS regenerated_from_export_id UUID REFERENCES shapefile_export(id) ON DELETE SET NULL;

ALTER TABLE shapefile_export
  DROP CONSTRAINT IF EXISTS chk_shapefile_export_file_status,
  ADD CONSTRAINT chk_shapefile_export_file_status
    CHECK (file_status IN ('available', 'expired', 'deleted', 'missing'));

ALTER TABLE shapefile_export
  DROP CONSTRAINT IF EXISTS chk_export_completed_requires_file,
  ADD CONSTRAINT chk_export_completed_requires_file
    CHECK (
      status <> 'completed'
      OR file_status IN ('expired', 'deleted')
      OR NULLIF(file_path, '') IS NOT NULL
    );

UPDATE shapefile_export
SET file_status = 'available'
WHERE status = 'completed'
  AND file_path IS NOT NULL
  AND file_status = 'missing';

UPDATE shapefile_export
SET status = 'completed',
    file_status = 'expired',
    file_deleted_at = COALESCE(file_deleted_at, completed_at, NOW()),
    retention_expired_at = COALESCE(retention_expired_at, completed_at, NOW()),
    retention_expires_at = COALESCE(retention_expires_at, completed_at),
    file_path = NULL,
    error_message = 'Export completed, but the file expired. Regenerate it to download again.'
WHERE status = 'failed'
  AND error_message IS NOT NULL
  AND (
    lower(error_message) LIKE '%retention period%'
    OR lower(error_message) LIKE '%file expired%'
    OR lower(error_message) LIKE '%file deleted after retention%'
    OR lower(error_message) LIKE '%file missing after cleanup%'
  )
  AND (completed_at IS NOT NULL OR feature_count IS NOT NULL OR file_size_bytes IS NOT NULL);

CREATE INDEX IF NOT EXISTS idx_shapefile_export_file_status
  ON shapefile_export(file_status, requested_at DESC);

CREATE INDEX IF NOT EXISTS idx_shapefile_export_retention_expires
  ON shapefile_export(retention_expires_at)
  WHERE status = 'completed' AND file_status = 'available';

ALTER TABLE ai_prediction_feature
  ADD COLUMN IF NOT EXISTS raw_geom GEOMETRY(Geometry, 4326),
  ADD COLUMN IF NOT EXISTS processed_geom GEOMETRY(Geometry, 4326),
  ADD COLUMN IF NOT EXISTS source_resolution_m DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS raw_area_m2 DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS processed_area_m2 DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS area_change_percent DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS processing_method TEXT,
  ADD COLUMN IF NOT EXISTS minimum_mapping_unit_m2 DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS simplification_tolerance_m DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS smoothing_iterations INTEGER,
  ADD COLUMN IF NOT EXISTS geometry_quality TEXT;

UPDATE ai_prediction_feature
SET raw_geom = COALESCE(raw_geom, geom),
    processed_geom = COALESCE(processed_geom, geom),
    source_resolution_m = COALESCE(source_resolution_m, 30),
    processing_method = COALESCE(processing_method, 'legacy_imported_geometry'),
    geometry_quality = COALESCE(geometry_quality, 'valid')
WHERE geom IS NOT NULL;

ALTER TABLE ai_prediction_feature
  DROP CONSTRAINT IF EXISTS chk_ai_prediction_feature_raw_geom_srid,
  ADD CONSTRAINT chk_ai_prediction_feature_raw_geom_srid
    CHECK (raw_geom IS NULL OR ST_SRID(raw_geom) = 4326),
  DROP CONSTRAINT IF EXISTS chk_ai_prediction_feature_processed_geom_srid,
  ADD CONSTRAINT chk_ai_prediction_feature_processed_geom_srid
    CHECK (processed_geom IS NULL OR ST_SRID(processed_geom) = 4326),
  DROP CONSTRAINT IF EXISTS chk_ai_prediction_feature_raw_geom_valid,
  ADD CONSTRAINT chk_ai_prediction_feature_raw_geom_valid
    CHECK (raw_geom IS NULL OR ST_IsValid(raw_geom)),
  DROP CONSTRAINT IF EXISTS chk_ai_prediction_feature_processed_geom_valid,
  ADD CONSTRAINT chk_ai_prediction_feature_processed_geom_valid
    CHECK (processed_geom IS NULL OR ST_IsValid(processed_geom));

CREATE INDEX IF NOT EXISTS idx_ai_prediction_feature_processed_geom
  ON ai_prediction_feature
  USING GIST (processed_geom)
  WHERE processed_geom IS NOT NULL;
