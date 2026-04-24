ALTER TABLE gis_import_feature
  DROP CONSTRAINT IF EXISTS chk_gis_import_feature_geometry_type;

ALTER TABLE gis_import_feature
  ADD CONSTRAINT chk_gis_import_feature_geometry_type CHECK (
    geometry_type IS NULL
    OR geometry_type IN (
      'Point',
      'MultiPoint',
      'LineString',
      'MultiLineString',
      'Polygon',
      'MultiPolygon'
    )
  );
