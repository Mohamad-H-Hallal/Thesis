ALTER TABLE spatial_feature
  DROP CONSTRAINT IF EXISTS chk_spatial_feature_source;

ALTER TABLE spatial_feature
  ADD CONSTRAINT chk_spatial_feature_source
  CHECK (source IN ('field', 'import', 'legacy', 'ai_validation', 'ai'));
