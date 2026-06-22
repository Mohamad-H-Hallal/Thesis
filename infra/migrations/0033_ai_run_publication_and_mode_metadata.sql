ALTER TABLE ai_run
  ADD COLUMN IF NOT EXISTS display_name TEXT,
  ADD COLUMN IF NOT EXISTS is_dry_run BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS published_layer_name TEXT,
  ADD COLUMN IF NOT EXISTS unpublished_reason TEXT,
  ADD COLUMN IF NOT EXISTS replaced_by_run_id UUID REFERENCES ai_run(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS prediction_count INTEGER NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_ai_run_project_active
  ON ai_run(project_id, status, created_at DESC)
  WHERE status IN ('created', 'queued', 'starting', 'running', 'cancelling', 'paused');

CREATE INDEX IF NOT EXISTS idx_ai_run_project_current_published
  ON ai_run(project_id, published_at DESC)
  WHERE published_at IS NOT NULL AND unpublished_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_ai_run_one_current_published_per_project
  ON ai_run(project_id)
  WHERE published_at IS NOT NULL AND unpublished_at IS NULL;
