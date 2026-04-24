ALTER TABLE gis_import_job
  ADD COLUMN IF NOT EXISTS processing_attempt_count INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS processing_started_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS processing_heartbeat_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_gis_import_job_processing_queue
  ON gis_import_job(status, processing_heartbeat_at, uploaded_at DESC);
