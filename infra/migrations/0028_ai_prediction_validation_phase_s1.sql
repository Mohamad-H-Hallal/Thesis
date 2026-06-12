DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type WHERE typname = 'ai_prediction_validation_task_status'
  ) THEN
    CREATE TYPE ai_prediction_validation_task_status AS ENUM (
      'open',
      'assigned',
      'in_progress',
      'submitted',
      'accepted',
      'rejected',
      'cancelled'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_type WHERE typname = 'ai_prediction_validation_submission_result'
  ) THEN
    CREATE TYPE ai_prediction_validation_submission_result AS ENUM (
      'correct',
      'wrong_class',
      'not_target_class',
      'unsure'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_type WHERE typname = 'ai_prediction_validation_submission_status'
  ) THEN
    CREATE TYPE ai_prediction_validation_submission_status AS ENUM (
      'submitted',
      'accepted',
      'rejected'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_type WHERE typname = 'ai_prediction_validation_review_decision'
  ) THEN
    CREATE TYPE ai_prediction_validation_review_decision AS ENUM (
      'accepted',
      'rejected'
    );
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS ai_prediction_validation_task (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  ai_run_id UUID NOT NULL REFERENCES ai_run(id) ON DELETE CASCADE,
  ai_prediction_feature_id UUID NOT NULL REFERENCES ai_prediction_feature(id) ON DELETE CASCADE,
  status ai_prediction_validation_task_status NOT NULL DEFAULT 'open',
  assigned_to UUID REFERENCES "user"(id) ON DELETE SET NULL,
  created_by UUID REFERENCES "user"(id) ON DELETE SET NULL,
  reviewed_by UUID REFERENCES "user"(id) ON DELETE SET NULL,
  review_decision ai_prediction_validation_review_decision,
  review_reason TEXT,
  priority INTEGER NOT NULL DEFAULT 0,
  due_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_ai_prediction_validation_task_priority CHECK (priority >= 0),
  CONSTRAINT chk_ai_prediction_validation_task_metadata CHECK (jsonb_typeof(metadata) = 'object'),
  CONSTRAINT chk_ai_prediction_validation_task_assignee CHECK (
    status NOT IN ('assigned', 'in_progress', 'submitted')
    OR assigned_to IS NOT NULL
  ),
  CONSTRAINT chk_ai_prediction_validation_task_review CHECK (
    review_decision IS NULL
    OR status IN ('accepted', 'rejected')
  ),
  CONSTRAINT chk_ai_prediction_validation_task_review_reason CHECK (
    review_reason IS NULL OR btrim(review_reason) <> ''
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_ai_prediction_validation_task_active_prediction
  ON ai_prediction_validation_task(ai_prediction_feature_id)
  WHERE status IN ('open', 'assigned', 'in_progress', 'submitted');

CREATE INDEX IF NOT EXISTS idx_ai_prediction_validation_task_project_status
  ON ai_prediction_validation_task(project_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_prediction_validation_task_run
  ON ai_prediction_validation_task(ai_run_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_prediction_validation_task_assigned
  ON ai_prediction_validation_task(assigned_to, status, created_at DESC)
  WHERE assigned_to IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ai_prediction_validation_task_prediction
  ON ai_prediction_validation_task(ai_prediction_feature_id);

DROP TRIGGER IF EXISTS trg_ai_prediction_validation_task_updated_at
  ON ai_prediction_validation_task;
CREATE TRIGGER trg_ai_prediction_validation_task_updated_at
BEFORE UPDATE ON ai_prediction_validation_task
FOR EACH ROW
EXECUTE FUNCTION trg_set_ai_updated_at();

CREATE TABLE IF NOT EXISTS ai_prediction_validation_submission (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  validation_task_id UUID NOT NULL REFERENCES ai_prediction_validation_task(id) ON DELETE CASCADE,
  submitted_by UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  result ai_prediction_validation_submission_result NOT NULL,
  corrected_class TEXT,
  note TEXT NOT NULL,
  evidence JSONB NOT NULL DEFAULT '{}'::JSONB,
  linked_feature_id UUID REFERENCES spatial_feature(id) ON DELETE SET NULL,
  status ai_prediction_validation_submission_status NOT NULL DEFAULT 'submitted',
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  reviewed_at TIMESTAMPTZ,
  reviewed_by UUID REFERENCES "user"(id) ON DELETE SET NULL,
  CONSTRAINT chk_ai_prediction_validation_submission_note CHECK (btrim(note) <> ''),
  CONSTRAINT chk_ai_prediction_validation_submission_evidence CHECK (
    jsonb_typeof(evidence) = 'object'
  ),
  CONSTRAINT chk_ai_prediction_validation_submission_wrong_class CHECK (
    result <> 'wrong_class'
    OR (corrected_class IS NOT NULL AND btrim(corrected_class) <> '')
  ),
  CONSTRAINT chk_ai_prediction_validation_submission_not_target CHECK (
    result <> 'not_target_class'
    OR corrected_class IS NULL
  ),
  CONSTRAINT chk_ai_prediction_validation_submission_corrected_class CHECK (
    corrected_class IS NULL OR btrim(corrected_class) <> ''
  ),
  CONSTRAINT chk_ai_prediction_validation_submission_review CHECK (
    status = 'submitted'
    OR (reviewed_at IS NOT NULL AND reviewed_by IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_ai_prediction_validation_submission_task
  ON ai_prediction_validation_submission(validation_task_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_prediction_validation_submission_submitted_by
  ON ai_prediction_validation_submission(submitted_by, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_prediction_validation_submission_status
  ON ai_prediction_validation_submission(status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_prediction_validation_submission_linked_feature
  ON ai_prediction_validation_submission(linked_feature_id)
  WHERE linked_feature_id IS NOT NULL;
