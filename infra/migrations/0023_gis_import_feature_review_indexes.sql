CREATE INDEX IF NOT EXISTS idx_gis_import_feature_job_source
  ON gis_import_feature(import_job_id, source_index);

CREATE INDEX IF NOT EXISTS idx_gis_import_feature_job_geometry_source
  ON gis_import_feature(import_job_id, geometry_type, source_index);

CREATE INDEX IF NOT EXISTS idx_gis_import_feature_validation_errors_gin
  ON gis_import_feature
  USING GIN (validation_errors);

CREATE INDEX IF NOT EXISTS idx_gis_import_feature_validation_warnings_gin
  ON gis_import_feature
  USING GIN (validation_warnings);
