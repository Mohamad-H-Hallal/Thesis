DO $$
BEGIN
  ALTER TYPE ai_run_status ADD VALUE IF NOT EXISTS 'created';
  ALTER TYPE ai_run_status ADD VALUE IF NOT EXISTS 'starting';
  ALTER TYPE ai_run_status ADD VALUE IF NOT EXISTS 'running';
  ALTER TYPE ai_run_status ADD VALUE IF NOT EXISTS 'completed';
  ALTER TYPE ai_run_status ADD VALUE IF NOT EXISTS 'cancelling';
  ALTER TYPE ai_run_status ADD VALUE IF NOT EXISTS 'paused';
END $$;

ALTER TABLE ai_run
  ADD COLUMN IF NOT EXISTS stage TEXT,
  ADD COLUMN IF NOT EXISTS progress DOUBLE PRECISION NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS message TEXT,
  ADD COLUMN IF NOT EXISTS ai_server_run_id TEXT,
  ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS callback_received_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS artifacts JSONB NOT NULL DEFAULT '{}'::JSONB,
  ADD COLUMN IF NOT EXISTS counts JSONB NOT NULL DEFAULT '{}'::JSONB,
  ADD COLUMN IF NOT EXISTS error_details JSONB NOT NULL DEFAULT '{}'::JSONB;

ALTER TABLE ai_run
  DROP CONSTRAINT IF EXISTS chk_ai_run_progress,
  ADD CONSTRAINT chk_ai_run_progress CHECK (progress >= 0 AND progress <= 1),
  DROP CONSTRAINT IF EXISTS chk_ai_run_artifacts,
  ADD CONSTRAINT chk_ai_run_artifacts CHECK (jsonb_typeof(artifacts) = 'object'),
  DROP CONSTRAINT IF EXISTS chk_ai_run_counts_json,
  ADD CONSTRAINT chk_ai_run_counts_json CHECK (jsonb_typeof(counts) = 'object'),
  DROP CONSTRAINT IF EXISTS chk_ai_run_error_details,
  ADD CONSTRAINT chk_ai_run_error_details CHECK (jsonb_typeof(error_details) = 'object');

CREATE INDEX IF NOT EXISTS idx_ai_run_server_status_updated
  ON ai_run(status, updated_at DESC);
