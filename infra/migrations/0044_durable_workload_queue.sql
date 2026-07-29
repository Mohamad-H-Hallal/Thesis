DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'workload_job_kind') THEN
    CREATE TYPE workload_job_kind AS ENUM ('gis_import', 'project_export');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'workload_job_status') THEN
    CREATE TYPE workload_job_status AS ENUM ('queued', 'running', 'succeeded', 'dead_letter');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS workload_job (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  kind workload_job_kind NOT NULL,
  entity_id UUID NOT NULL,
  status workload_job_status NOT NULL DEFAULT 'queued',
  attempt_count INTEGER NOT NULL DEFAULT 0,
  max_attempts INTEGER NOT NULL DEFAULT 3,
  available_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  lease_expires_at TIMESTAMPTZ,
  worker_id TEXT,
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT uq_workload_job_entity UNIQUE (kind, entity_id),
  CONSTRAINT chk_workload_job_attempts CHECK (
    attempt_count >= 0
    AND max_attempts BETWEEN 1 AND 20
    AND attempt_count <= max_attempts
  ),
  CONSTRAINT chk_workload_job_lease CHECK (
    (status = 'running' AND lease_expires_at IS NOT NULL AND worker_id IS NOT NULL)
    OR
    (status <> 'running' AND lease_expires_at IS NULL AND worker_id IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_workload_job_claim
  ON workload_job(status, available_at, lease_expires_at, created_at);

CREATE INDEX IF NOT EXISTS idx_workload_job_dead_letter
  ON workload_job(completed_at DESC)
  WHERE status = 'dead_letter';

CREATE OR REPLACE FUNCTION trg_set_workload_job_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_workload_job_updated_at ON workload_job;
CREATE TRIGGER trg_workload_job_updated_at
BEFORE UPDATE ON workload_job
FOR EACH ROW
EXECUTE FUNCTION trg_set_workload_job_updated_at();
