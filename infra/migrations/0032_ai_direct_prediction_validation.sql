ALTER TABLE ai_run
  ADD COLUMN IF NOT EXISTS published_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS published_by UUID REFERENCES "user"(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS unpublished_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS unpublished_by UUID REFERENCES "user"(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_ai_run_project_published
  ON ai_run(project_id, published_at DESC)
  WHERE published_at IS NOT NULL;

ALTER TABLE ai_prediction_feature
  ADD COLUMN IF NOT EXISTS admin_validation_status TEXT,
  ADD COLUMN IF NOT EXISTS admin_note TEXT,
  ADD COLUMN IF NOT EXISTS admin_reviewed_by UUID REFERENCES "user"(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS admin_reviewed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS approved_class TEXT,
  ADD COLUMN IF NOT EXISTS promoted_spatial_feature_id UUID REFERENCES spatial_feature(id) ON DELETE SET NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_ai_prediction_feature_admin_validation_status'
  ) THEN
    ALTER TABLE ai_prediction_feature
      ADD CONSTRAINT chk_ai_prediction_feature_admin_validation_status
      CHECK (
        admin_validation_status IS NULL
        OR admin_validation_status IN ('approved', 'rejected', 'needs_more_validation')
      );
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_ai_prediction_feature_admin_status
  ON ai_prediction_feature(project_id, admin_validation_status, updated_at DESC)
  WHERE admin_validation_status IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ai_prediction_feature_promoted_feature
  ON ai_prediction_feature(promoted_spatial_feature_id)
  WHERE promoted_spatial_feature_id IS NOT NULL;

ALTER TABLE spatial_feature
  ADD COLUMN IF NOT EXISTS ai_run_id UUID REFERENCES ai_run(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS ai_prediction_feature_id UUID REFERENCES ai_prediction_feature(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS ai_predicted_class TEXT,
  ADD COLUMN IF NOT EXISTS ai_confidence DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS ai_validated BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS ai_validation_status TEXT,
  ADD COLUMN IF NOT EXISTS ai_approved_by UUID REFERENCES "user"(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS ai_approved_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS ai_admin_note TEXT,
  ADD COLUMN IF NOT EXISTS use_for_future_training BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS contributor_validation_summary JSONB NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS promoted_from_ai BOOLEAN NOT NULL DEFAULT FALSE;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_spatial_feature_ai_confidence'
  ) THEN
    ALTER TABLE spatial_feature
      ADD CONSTRAINT chk_spatial_feature_ai_confidence
      CHECK (ai_confidence IS NULL OR (ai_confidence >= 0 AND ai_confidence <= 1));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_spatial_feature_ai_validation_status'
  ) THEN
    ALTER TABLE spatial_feature
      ADD CONSTRAINT chk_spatial_feature_ai_validation_status
      CHECK (
        ai_validation_status IS NULL
        OR ai_validation_status IN (
          'admin_approved',
          'admin_rejected',
          'needs_more_validation',
          'approved',
          'corrected'
        )
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_spatial_feature_contributor_validation_summary'
  ) THEN
    ALTER TABLE spatial_feature
      ADD CONSTRAINT chk_spatial_feature_contributor_validation_summary
      CHECK (jsonb_typeof(contributor_validation_summary) = 'object');
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_spatial_feature_ai_prediction_source
  ON spatial_feature(project_id, ai_prediction_feature_id)
  WHERE source = 'ai' AND ai_prediction_feature_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_spatial_feature_ai_training
  ON spatial_feature(project_id, source, use_for_future_training, status)
  WHERE source = 'ai';

CREATE INDEX IF NOT EXISTS idx_spatial_feature_ai_prediction_feature
  ON spatial_feature(ai_prediction_feature_id)
  WHERE ai_prediction_feature_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS ai_prediction_feature_validation (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  ai_run_id UUID NOT NULL REFERENCES ai_run(id) ON DELETE CASCADE,
  ai_prediction_feature_id UUID NOT NULL REFERENCES ai_prediction_feature(id) ON DELETE CASCADE,
  contributor_user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  validation_result TEXT NOT NULL,
  corrected_class TEXT,
  note TEXT,
  photo_media_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
  gps_location GEOMETRY(Point, 4326),
  gps_accuracy_m DOUBLE PRECISION,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_ai_prediction_feature_validation_result CHECK (
    validation_result IN ('correct', 'incorrect', 'unsure', 'cannot_verify')
  ),
  CONSTRAINT chk_ai_prediction_feature_validation_corrected_class CHECK (
    validation_result <> 'incorrect'
    OR NULLIF(BTRIM(COALESCE(corrected_class, '')), '') IS NOT NULL
  ),
  CONSTRAINT chk_ai_prediction_feature_validation_photo_media_ids CHECK (
    jsonb_typeof(photo_media_ids) = 'array'
  ),
  CONSTRAINT chk_ai_prediction_feature_validation_metadata CHECK (
    jsonb_typeof(metadata) = 'object'
  ),
  CONSTRAINT chk_ai_prediction_feature_validation_gps_location CHECK (
    gps_location IS NULL OR ST_SRID(gps_location) = 4326
  ),
  CONSTRAINT chk_ai_prediction_feature_validation_gps_accuracy CHECK (
    gps_accuracy_m IS NULL OR gps_accuracy_m >= 0
  ),
  UNIQUE (ai_prediction_feature_id, contributor_user_id)
);

CREATE INDEX IF NOT EXISTS idx_ai_prediction_feature_validation_project
  ON ai_prediction_feature_validation(project_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_prediction_feature_validation_run
  ON ai_prediction_feature_validation(ai_run_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_prediction_feature_validation_prediction
  ON ai_prediction_feature_validation(ai_prediction_feature_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_prediction_feature_validation_contributor
  ON ai_prediction_feature_validation(contributor_user_id, created_at DESC);

DROP TRIGGER IF EXISTS trg_ai_prediction_feature_validation_updated_at
  ON ai_prediction_feature_validation;

CREATE TRIGGER trg_ai_prediction_feature_validation_updated_at
BEFORE UPDATE ON ai_prediction_feature_validation
FOR EACH ROW EXECUTE FUNCTION trg_set_ai_updated_at();
