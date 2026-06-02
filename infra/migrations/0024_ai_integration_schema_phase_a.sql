DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ai_scope_type') THEN
    CREATE TYPE ai_scope_type AS ENUM (
      'project',
      'governorate',
      'district',
      'city',
      'custom_polygon',
      'national'
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ai_run_status') THEN
    CREATE TYPE ai_run_status AS ENUM (
      'draft',
      'queued',
      'extracting_features',
      'training',
      'evaluating',
      'classifying',
      'ready_for_review',
      'published',
      'failed',
      'cancelled'
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ai_output_layer_type') THEN
    CREATE TYPE ai_output_layer_type AS ENUM (
      'classification',
      'confidence',
      'uncertainty',
      'statistics'
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ai_output_layer_status') THEN
    CREATE TYPE ai_output_layer_status AS ENUM (
      'draft',
      'ready_for_review',
      'published',
      'unpublished',
      'rejected',
      'failed'
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ai_uncertainty_area_status') THEN
    CREATE TYPE ai_uncertainty_area_status AS ENUM (
      'open',
      'assigned',
      'in_review',
      'validated',
      'dismissed'
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ai_run_log_level') THEN
    CREATE TYPE ai_run_log_level AS ENUM (
      'debug',
      'info',
      'warning',
      'error'
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ai_review_decision_type') THEN
    CREATE TYPE ai_review_decision_type AS ENUM (
      'approved_for_publish',
      'rejected',
      'needs_more_data',
      'needs_rerun',
      'unpublished'
    );
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS ai_project_settings (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  is_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  label_field TEXT,
  scope_type ai_scope_type NOT NULL DEFAULT 'project',
  scope_geometry GEOMETRY(Geometry, 4326),
  min_samples_per_class INTEGER NOT NULL DEFAULT 50,
  min_classes INTEGER NOT NULL DEFAULT 2,
  confidence_threshold DOUBLE PRECISION NOT NULL DEFAULT 0.6,
  model_preferences JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_by UUID REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by UUID REFERENCES "user"(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (project_id),
  CONSTRAINT chk_ai_project_settings_label_field CHECK (
    label_field IS NULL OR btrim(label_field) <> ''
  ),
  CONSTRAINT chk_ai_project_settings_min_samples CHECK (min_samples_per_class > 0),
  CONSTRAINT chk_ai_project_settings_min_classes CHECK (min_classes >= 2),
  CONSTRAINT chk_ai_project_settings_confidence CHECK (
    confidence_threshold >= 0 AND confidence_threshold <= 1
  ),
  CONSTRAINT chk_ai_project_settings_model_preferences CHECK (
    jsonb_typeof(model_preferences) = 'object'
  ),
  CONSTRAINT chk_ai_project_settings_scope_geom_srid CHECK (
    scope_geometry IS NULL OR ST_SRID(scope_geometry) = 4326
  ),
  CONSTRAINT chk_ai_project_settings_scope_geom_valid CHECK (
    scope_geometry IS NULL OR ST_IsValid(scope_geometry)
  )
);

CREATE INDEX IF NOT EXISTS idx_ai_project_settings_project_enabled
  ON ai_project_settings(project_id, is_enabled);

CREATE INDEX IF NOT EXISTS idx_ai_project_settings_created_by
  ON ai_project_settings(created_by);

CREATE INDEX IF NOT EXISTS idx_ai_project_settings_updated_by
  ON ai_project_settings(updated_by);

CREATE INDEX IF NOT EXISTS idx_ai_project_settings_scope_geometry
  ON ai_project_settings
  USING GIST (scope_geometry)
  WHERE scope_geometry IS NOT NULL;

CREATE TABLE IF NOT EXISTS ai_run (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  settings_id UUID REFERENCES ai_project_settings(id) ON DELETE SET NULL,
  status ai_run_status NOT NULL DEFAULT 'draft',
  label_field TEXT NOT NULL,
  scope_type ai_scope_type NOT NULL DEFAULT 'project',
  scope_geometry GEOMETRY(Geometry, 4326),
  region_preset TEXT,
  training_feature_count INTEGER NOT NULL DEFAULT 0,
  eligible_feature_count INTEGER NOT NULL DEFAULT 0,
  excluded_feature_count INTEGER NOT NULL DEFAULT 0,
  selected_model TEXT,
  started_by UUID REFERENCES "user"(id) ON DELETE SET NULL,
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  failed_at TIMESTAMPTZ,
  failure_reason TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_ai_run_label_field CHECK (btrim(label_field) <> ''),
  CONSTRAINT chk_ai_run_counts CHECK (
    training_feature_count >= 0
    AND eligible_feature_count >= 0
    AND excluded_feature_count >= 0
  ),
  CONSTRAINT chk_ai_run_metadata CHECK (jsonb_typeof(metadata) = 'object'),
  CONSTRAINT chk_ai_run_scope_geom_srid CHECK (
    scope_geometry IS NULL OR ST_SRID(scope_geometry) = 4326
  ),
  CONSTRAINT chk_ai_run_scope_geom_valid CHECK (
    scope_geometry IS NULL OR ST_IsValid(scope_geometry)
  ),
  CONSTRAINT chk_ai_run_failure_reason CHECK (
    status <> 'failed' OR NULLIF(btrim(COALESCE(failure_reason, '')), '') IS NOT NULL
  )
);

CREATE INDEX IF NOT EXISTS idx_ai_run_project_status_created
  ON ai_run(project_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_run_started_by
  ON ai_run(started_by, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_run_settings
  ON ai_run(settings_id);

CREATE INDEX IF NOT EXISTS idx_ai_run_scope_geometry
  ON ai_run
  USING GIST (scope_geometry)
  WHERE scope_geometry IS NOT NULL;

CREATE TABLE IF NOT EXISTS ai_run_metric (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ai_run_id UUID NOT NULL REFERENCES ai_run(id) ON DELETE CASCADE,
  model_name TEXT NOT NULL,
  overall_accuracy DOUBLE PRECISION,
  macro_f1 DOUBLE PRECISION,
  weighted_f1 DOUBLE PRECISION,
  metrics JSONB NOT NULL DEFAULT '{}'::JSONB,
  confusion_matrix JSONB NOT NULL DEFAULT '{}'::JSONB,
  feature_importance JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_ai_run_metric_model_name CHECK (btrim(model_name) <> ''),
  CONSTRAINT chk_ai_run_metric_overall_accuracy CHECK (
    overall_accuracy IS NULL OR (overall_accuracy >= 0 AND overall_accuracy <= 1)
  ),
  CONSTRAINT chk_ai_run_metric_macro_f1 CHECK (
    macro_f1 IS NULL OR (macro_f1 >= 0 AND macro_f1 <= 1)
  ),
  CONSTRAINT chk_ai_run_metric_weighted_f1 CHECK (
    weighted_f1 IS NULL OR (weighted_f1 >= 0 AND weighted_f1 <= 1)
  ),
  CONSTRAINT chk_ai_run_metric_metrics CHECK (jsonb_typeof(metrics) = 'object'),
  CONSTRAINT chk_ai_run_metric_confusion_matrix CHECK (
    jsonb_typeof(confusion_matrix) IN ('object', 'array')
  ),
  CONSTRAINT chk_ai_run_metric_feature_importance CHECK (
    jsonb_typeof(feature_importance) IN ('object', 'array')
  )
);

CREATE INDEX IF NOT EXISTS idx_ai_run_metric_run_model
  ON ai_run_metric(ai_run_id, model_name);

CREATE TABLE IF NOT EXISTS ai_output_layer (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ai_run_id UUID NOT NULL REFERENCES ai_run(id) ON DELETE CASCADE,
  project_id UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  layer_type ai_output_layer_type NOT NULL,
  status ai_output_layer_status NOT NULL DEFAULT 'draft',
  name TEXT NOT NULL,
  description TEXT,
  storage_path TEXT,
  asset_id TEXT,
  crs TEXT NOT NULL DEFAULT 'EPSG:4326',
  bounds GEOMETRY(Polygon, 4326),
  style JSONB NOT NULL DEFAULT '{}'::JSONB,
  published_at TIMESTAMPTZ,
  published_by UUID REFERENCES "user"(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_ai_output_layer_name CHECK (btrim(name) <> ''),
  CONSTRAINT chk_ai_output_layer_style CHECK (jsonb_typeof(style) = 'object'),
  CONSTRAINT chk_ai_output_layer_bounds_srid CHECK (
    bounds IS NULL OR ST_SRID(bounds) = 4326
  ),
  CONSTRAINT chk_ai_output_layer_bounds_valid CHECK (
    bounds IS NULL OR ST_IsValid(bounds)
  ),
  CONSTRAINT chk_ai_output_layer_published_by CHECK (
    status <> 'published'
    OR (published_at IS NOT NULL AND published_by IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_ai_output_layer_project_status
  ON ai_output_layer(project_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_output_layer_run_type
  ON ai_output_layer(ai_run_id, layer_type);

CREATE INDEX IF NOT EXISTS idx_ai_output_layer_published_by
  ON ai_output_layer(published_by)
  WHERE published_by IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ai_output_layer_bounds
  ON ai_output_layer
  USING GIST (bounds)
  WHERE bounds IS NOT NULL;

CREATE TABLE IF NOT EXISTS ai_class_statistic (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ai_run_id UUID NOT NULL REFERENCES ai_run(id) ON DELETE CASCADE,
  class_label TEXT NOT NULL,
  feature_count INTEGER NOT NULL DEFAULT 0,
  area_ha DOUBLE PRECISION,
  confidence_mean DOUBLE PRECISION,
  statistics JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_ai_class_statistic_label CHECK (btrim(class_label) <> ''),
  CONSTRAINT chk_ai_class_statistic_feature_count CHECK (feature_count >= 0),
  CONSTRAINT chk_ai_class_statistic_area CHECK (area_ha IS NULL OR area_ha >= 0),
  CONSTRAINT chk_ai_class_statistic_confidence CHECK (
    confidence_mean IS NULL OR (confidence_mean >= 0 AND confidence_mean <= 1)
  ),
  CONSTRAINT chk_ai_class_statistic_statistics CHECK (
    jsonb_typeof(statistics) = 'object'
  ),
  UNIQUE (ai_run_id, class_label)
);

CREATE INDEX IF NOT EXISTS idx_ai_class_statistic_run
  ON ai_class_statistic(ai_run_id);

CREATE TABLE IF NOT EXISTS ai_uncertainty_area (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ai_run_id UUID NOT NULL REFERENCES ai_run(id) ON DELETE CASCADE,
  project_id UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  geom GEOMETRY(Geometry, 4326) NOT NULL,
  uncertainty_score DOUBLE PRECISION NOT NULL,
  suggested_class TEXT,
  status ai_uncertainty_area_status NOT NULL DEFAULT 'open',
  assigned_to UUID REFERENCES "user"(id) ON DELETE SET NULL,
  validated_feature_id UUID REFERENCES spatial_feature(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_ai_uncertainty_area_score CHECK (
    uncertainty_score >= 0 AND uncertainty_score <= 1
  ),
  CONSTRAINT chk_ai_uncertainty_area_suggested_class CHECK (
    suggested_class IS NULL OR btrim(suggested_class) <> ''
  ),
  CONSTRAINT chk_ai_uncertainty_area_geom_srid CHECK (ST_SRID(geom) = 4326),
  CONSTRAINT chk_ai_uncertainty_area_geom_valid CHECK (ST_IsValid(geom))
);

CREATE INDEX IF NOT EXISTS idx_ai_uncertainty_area_run_status
  ON ai_uncertainty_area(ai_run_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_uncertainty_area_project_status
  ON ai_uncertainty_area(project_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_uncertainty_area_assigned_to
  ON ai_uncertainty_area(assigned_to, status)
  WHERE assigned_to IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ai_uncertainty_area_validated_feature
  ON ai_uncertainty_area(validated_feature_id)
  WHERE validated_feature_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ai_uncertainty_area_geom
  ON ai_uncertainty_area
  USING GIST (geom);

CREATE TABLE IF NOT EXISTS ai_run_log (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ai_run_id UUID NOT NULL REFERENCES ai_run(id) ON DELETE CASCADE,
  level ai_run_log_level NOT NULL DEFAULT 'info',
  message TEXT NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_ai_run_log_message CHECK (btrim(message) <> ''),
  CONSTRAINT chk_ai_run_log_metadata CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE INDEX IF NOT EXISTS idx_ai_run_log_run_created
  ON ai_run_log(ai_run_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_run_log_level_created
  ON ai_run_log(level, created_at DESC);

CREATE TABLE IF NOT EXISTS ai_review_decision (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ai_run_id UUID NOT NULL REFERENCES ai_run(id) ON DELETE CASCADE,
  decision ai_review_decision_type NOT NULL,
  reason TEXT,
  decided_by UUID REFERENCES "user"(id) ON DELETE SET NULL,
  decided_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  CONSTRAINT chk_ai_review_decision_metadata CHECK (
    jsonb_typeof(metadata) = 'object'
  )
);

CREATE INDEX IF NOT EXISTS idx_ai_review_decision_run_decided
  ON ai_review_decision(ai_run_id, decided_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_review_decision_decided_by
  ON ai_review_decision(decided_by, decided_at DESC)
  WHERE decided_by IS NOT NULL;

CREATE OR REPLACE FUNCTION trg_set_ai_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_ai_project_settings_updated_at ON ai_project_settings;
CREATE TRIGGER trg_ai_project_settings_updated_at
BEFORE UPDATE ON ai_project_settings
FOR EACH ROW
EXECUTE FUNCTION trg_set_ai_updated_at();

DROP TRIGGER IF EXISTS trg_ai_run_updated_at ON ai_run;
CREATE TRIGGER trg_ai_run_updated_at
BEFORE UPDATE ON ai_run
FOR EACH ROW
EXECUTE FUNCTION trg_set_ai_updated_at();

DROP TRIGGER IF EXISTS trg_ai_output_layer_updated_at ON ai_output_layer;
CREATE TRIGGER trg_ai_output_layer_updated_at
BEFORE UPDATE ON ai_output_layer
FOR EACH ROW
EXECUTE FUNCTION trg_set_ai_updated_at();

DROP TRIGGER IF EXISTS trg_ai_uncertainty_area_updated_at ON ai_uncertainty_area;
CREATE TRIGGER trg_ai_uncertainty_area_updated_at
BEFORE UPDATE ON ai_uncertainty_area
FOR EACH ROW
EXECUTE FUNCTION trg_set_ai_updated_at();
