ALTER TABLE gis_import_comment
  ADD COLUMN IF NOT EXISTS import_feature_id UUID NULL
  REFERENCES gis_import_feature(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_gis_import_comment_feature_created
  ON gis_import_comment (import_feature_id, created_at ASC)
  WHERE import_feature_id IS NOT NULL;
