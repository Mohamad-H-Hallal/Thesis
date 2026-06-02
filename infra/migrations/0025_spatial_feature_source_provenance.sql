ALTER TABLE spatial_feature
  ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'field';

UPDATE spatial_feature sf
SET source = 'import'
FROM gis_import_feature gif
WHERE gif.approved_feature_id = sf.id
  AND sf.source = 'field';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_spatial_feature_source'
  ) THEN
    ALTER TABLE spatial_feature
      ADD CONSTRAINT chk_spatial_feature_source
      CHECK (source IN ('field', 'import', 'legacy', 'ai_validation'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_spatial_feature_project_source_status
  ON spatial_feature(project_id, source, status);
