ALTER TYPE ai_uncertainty_area_status ADD VALUE IF NOT EXISTS 'in_progress';
ALTER TYPE ai_uncertainty_area_status ADD VALUE IF NOT EXISTS 'rejected';
ALTER TYPE ai_uncertainty_area_status ADD VALUE IF NOT EXISTS 'cancelled';

ALTER TABLE ai_uncertainty_area
  ADD COLUMN IF NOT EXISTS ai_output_layer_id UUID,
  ADD COLUMN IF NOT EXISTS artifact_feature_id TEXT,
  ADD COLUMN IF NOT EXISTS metadata JSONB NOT NULL DEFAULT '{}'::JSONB;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ai_uncertainty_area_ai_output_layer_id_fkey'
      AND conrelid = 'ai_uncertainty_area'::regclass
      AND confdeltype <> 'n'
  ) THEN
    ALTER TABLE ai_uncertainty_area
      DROP CONSTRAINT ai_uncertainty_area_ai_output_layer_id_fkey;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ai_uncertainty_area_ai_output_layer_id_fkey'
      AND conrelid = 'ai_uncertainty_area'::regclass
  ) THEN
    ALTER TABLE ai_uncertainty_area
      ADD CONSTRAINT ai_uncertainty_area_ai_output_layer_id_fkey
      FOREIGN KEY (ai_output_layer_id)
      REFERENCES ai_output_layer(id)
      ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_ai_uncertainty_area_artifact_feature_id'
      AND conrelid = 'ai_uncertainty_area'::regclass
  ) THEN
    ALTER TABLE ai_uncertainty_area
      ADD CONSTRAINT chk_ai_uncertainty_area_artifact_feature_id
      CHECK (artifact_feature_id IS NULL OR btrim(artifact_feature_id) <> '');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_ai_uncertainty_area_metadata'
      AND conrelid = 'ai_uncertainty_area'::regclass
  ) THEN
    ALTER TABLE ai_uncertainty_area
      ADD CONSTRAINT chk_ai_uncertainty_area_metadata
      CHECK (jsonb_typeof(metadata) = 'object');
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_uncertainty_area_layer_feature
  ON ai_uncertainty_area(ai_run_id, ai_output_layer_id, artifact_feature_id)
  WHERE ai_output_layer_id IS NOT NULL
    AND artifact_feature_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_uncertainty_area_run_feature
  ON ai_uncertainty_area(ai_run_id, artifact_feature_id)
  WHERE artifact_feature_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ai_uncertainty_area_layer
  ON ai_uncertainty_area(ai_output_layer_id)
  WHERE ai_output_layer_id IS NOT NULL;
