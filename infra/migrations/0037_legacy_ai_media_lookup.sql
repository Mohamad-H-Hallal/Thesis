-- Keep the narrowly grandfathered legacy AI evidence lookup indexed. New AI
-- validation media is stored under /uploads/ai-validation, while feature media
-- under the legacy photos directory is denied by default.
CREATE INDEX IF NOT EXISTS idx_ai_prediction_feature_validation_photo_media_ids_gin
  ON ai_prediction_feature_validation
  USING GIN (photo_media_ids jsonb_path_ops);
