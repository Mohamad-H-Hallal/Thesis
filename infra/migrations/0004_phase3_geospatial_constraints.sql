DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_spatial_feature_geom_srid_4326'
  ) THEN
    ALTER TABLE spatial_feature
      ADD CONSTRAINT chk_spatial_feature_geom_srid_4326
      CHECK (ST_SRID(geom) = 4326);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_spatial_feature_geom_type'
  ) THEN
    ALTER TABLE spatial_feature
      ADD CONSTRAINT chk_spatial_feature_geom_type
      CHECK (GeometryType(geom) IN ('POINT', 'LINESTRING', 'POLYGON'));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_spatial_feature_geom_valid'
  ) THEN
    ALTER TABLE spatial_feature
      ADD CONSTRAINT chk_spatial_feature_geom_valid
      CHECK (ST_IsValid(geom));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_spatial_feature_geom_project_status
  ON spatial_feature USING GIST (geom)
  WHERE status = 'approved';
