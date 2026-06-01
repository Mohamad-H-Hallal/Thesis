ALTER TABLE spatial_feature
  DROP CONSTRAINT IF EXISTS chk_spatial_feature_geom_type;

ALTER TABLE spatial_feature
  ADD CONSTRAINT chk_spatial_feature_geom_type CHECK (
    GeometryType(geom) IN (
      'POINT',
      'MULTIPOINT',
      'LINESTRING',
      'MULTILINESTRING',
      'POLYGON',
      'MULTIPOLYGON'
    )
  );
