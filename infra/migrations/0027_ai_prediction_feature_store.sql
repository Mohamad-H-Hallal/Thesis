DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ai_prediction_feature_status') THEN
    CREATE TYPE ai_prediction_feature_status AS ENUM (
      'draft',
      'ready_for_review',
      'approved',
      'published',
      'rejected'
    );
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS ai_prediction_feature (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  ai_run_id UUID NOT NULL REFERENCES ai_run(id) ON DELETE CASCADE,
  ai_output_layer_id UUID NOT NULL REFERENCES ai_output_layer(id) ON DELETE CASCADE,
  artifact_feature_id TEXT NOT NULL,
  geom GEOMETRY(Geometry, 4326) NOT NULL,
  geometry_type TEXT NOT NULL,
  predicted_class TEXT,
  confidence DOUBLE PRECISION,
  uncertainty_score DOUBLE PRECISION,
  model_name TEXT,
  source TEXT NOT NULL DEFAULT 'ai_prediction',
  status ai_prediction_feature_status NOT NULL DEFAULT 'draft',
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_ai_prediction_feature_artifact_id CHECK (btrim(artifact_feature_id) <> ''),
  CONSTRAINT chk_ai_prediction_feature_geometry_type CHECK (btrim(geometry_type) <> ''),
  CONSTRAINT chk_ai_prediction_feature_predicted_class CHECK (
    predicted_class IS NULL OR btrim(predicted_class) <> ''
  ),
  CONSTRAINT chk_ai_prediction_feature_confidence CHECK (
    confidence IS NULL OR (confidence >= 0 AND confidence <= 1)
  ),
  CONSTRAINT chk_ai_prediction_feature_uncertainty CHECK (
    uncertainty_score IS NULL OR (uncertainty_score >= 0 AND uncertainty_score <= 1)
  ),
  CONSTRAINT chk_ai_prediction_feature_model_name CHECK (
    model_name IS NULL OR btrim(model_name) <> ''
  ),
  CONSTRAINT chk_ai_prediction_feature_source CHECK (source = 'ai_prediction'),
  CONSTRAINT chk_ai_prediction_feature_metadata CHECK (jsonb_typeof(metadata) = 'object'),
  CONSTRAINT chk_ai_prediction_feature_geom_srid CHECK (ST_SRID(geom) = 4326),
  CONSTRAINT chk_ai_prediction_feature_geom_valid CHECK (ST_IsValid(geom)),
  CONSTRAINT uq_ai_prediction_feature_layer_artifact UNIQUE (
    ai_output_layer_id,
    artifact_feature_id
  )
);

CREATE INDEX IF NOT EXISTS idx_ai_prediction_feature_project
  ON ai_prediction_feature(project_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_prediction_feature_run
  ON ai_prediction_feature(ai_run_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_prediction_feature_output_layer
  ON ai_prediction_feature(ai_output_layer_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_prediction_feature_status
  ON ai_prediction_feature(status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_prediction_feature_predicted_class
  ON ai_prediction_feature(predicted_class)
  WHERE predicted_class IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ai_prediction_feature_geom
  ON ai_prediction_feature
  USING GIST (geom);

DROP TRIGGER IF EXISTS trg_ai_prediction_feature_updated_at ON ai_prediction_feature;
CREATE TRIGGER trg_ai_prediction_feature_updated_at
BEFORE UPDATE ON ai_prediction_feature
FOR EACH ROW
EXECUTE FUNCTION trg_set_ai_updated_at();

ALTER TABLE ai_uncertainty_area
  ADD COLUMN IF NOT EXISTS ai_prediction_feature_id UUID
  REFERENCES ai_prediction_feature(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_ai_uncertainty_area_prediction_feature
  ON ai_uncertainty_area(ai_prediction_feature_id)
  WHERE ai_prediction_feature_id IS NOT NULL;
