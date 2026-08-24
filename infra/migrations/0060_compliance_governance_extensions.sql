-- Reconcile compliance extensions for pre-release databases that applied the
-- initial 0059 migration. Every operation is idempotent because a fresh
-- database receives the same objects from the current 0059 source first.

CREATE TABLE IF NOT EXISTS data_retention_hold (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  data_category TEXT NOT NULL REFERENCES data_retention_policy(data_category) ON DELETE RESTRICT,
  record_table TEXT,
  record_id TEXT,
  reason TEXT NOT NULL CHECK (char_length(reason) BETWEEN 1 AND 1000),
  approval_reference TEXT NOT NULL CHECK (NULLIF(BTRIM(approval_reference), '') IS NOT NULL),
  created_by_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL,
  starts_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at TIMESTAMPTZ,
  released_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK ((record_table IS NULL) = (record_id IS NULL)),
  CHECK (expires_at IS NULL OR expires_at > starts_at)
);

CREATE INDEX IF NOT EXISTS idx_data_retention_hold_active
  ON data_retention_hold (data_category, record_table, record_id)
  WHERE released_at IS NULL;

CREATE TABLE IF NOT EXISTS data_retention_cleanup_run (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  status TEXT NOT NULL CHECK (status IN ('running', 'completed', 'failed', 'skipped_locked')),
  started_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  completed_at TIMESTAMPTZ,
  initiated_by TEXT NOT NULL DEFAULT 'scheduled' CHECK (initiated_by IN ('scheduled', 'startup', 'manual')),
  affected_rows INTEGER NOT NULL DEFAULT 0 CHECK (affected_rows >= 0),
  policy_count INTEGER NOT NULL DEFAULT 0 CHECK (policy_count >= 0),
  summary JSONB NOT NULL DEFAULT '{}'::JSONB,
  error_code TEXT,
  CHECK (jsonb_typeof(summary) = 'object')
);

CREATE TABLE IF NOT EXISTS data_retention_cleanup_item (
  id BIGSERIAL PRIMARY KEY,
  run_id UUID NOT NULL REFERENCES data_retention_cleanup_run(id) ON DELETE CASCADE,
  data_category TEXT NOT NULL REFERENCES data_retention_policy(data_category) ON DELETE RESTRICT,
  retention_days INTEGER NOT NULL CHECK (retention_days >= 0),
  disposal_action TEXT NOT NULL,
  approval_reference TEXT NOT NULL,
  affected_rows INTEGER NOT NULL DEFAULT 0 CHECK (affected_rows >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE gis_import_job
  ADD COLUMN IF NOT EXISTS source_provider TEXT,
  ADD COLUMN IF NOT EXISTS source_dataset_name TEXT,
  ADD COLUMN IF NOT EXISTS source_dataset_date DATE,
  ADD COLUMN IF NOT EXISTS source_accuracy_statement TEXT,
  ADD COLUMN IF NOT EXISTS source_license_or_authority TEXT,
  ADD COLUMN IF NOT EXISTS source_attribution TEXT,
  ADD COLUMN IF NOT EXISTS source_terms_url TEXT,
  ADD COLUMN IF NOT EXISTS source_redistribution_rules TEXT,
  ADD COLUMN IF NOT EXISTS provenance_confirmed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS provenance_confirmed_by_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_gis_import_job_source_terms_url'
      AND conrelid = 'gis_import_job'::REGCLASS
  ) THEN
    ALTER TABLE gis_import_job
      ADD CONSTRAINT chk_gis_import_job_source_terms_url
      CHECK (
        source_terms_url IS NULL
        OR source_terms_url ~ '^https?://[^[:space:]]+$'
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_gis_import_job_provenance_confirmation'
      AND conrelid = 'gis_import_job'::REGCLASS
  ) THEN
    ALTER TABLE gis_import_job
      ADD CONSTRAINT chk_gis_import_job_provenance_confirmation
      CHECK (
        provenance_confirmed_at IS NULL
        OR (
          NULLIF(BTRIM(source_provider), '') IS NOT NULL
          AND NULLIF(BTRIM(source_dataset_name), '') IS NOT NULL
          AND NULLIF(BTRIM(source_license_or_authority), '') IS NOT NULL
          AND NULLIF(BTRIM(source_redistribution_rules), '') IS NOT NULL
          AND provenance_confirmed_by_user_id IS NOT NULL
        )
      );
  END IF;
END
$$;

ALTER TABLE spatial_feature
  ADD COLUMN IF NOT EXISTS source_provenance JSONB NOT NULL DEFAULT '{}'::JSONB;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_spatial_feature_source_provenance'
      AND conrelid = 'spatial_feature'::REGCLASS
  ) THEN
    ALTER TABLE spatial_feature
      ADD CONSTRAINT chk_spatial_feature_source_provenance
      CHECK (jsonb_typeof(source_provenance) = 'object');
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS project_ai_governance (
  project_id UUID PRIMARY KEY REFERENCES project(id) ON DELETE CASCADE,
  training_data_use_authorized BOOLEAN NOT NULL DEFAULT FALSE,
  training_authority_basis TEXT,
  training_approval_reference TEXT,
  training_authorized_at TIMESTAMPTZ,
  training_authorized_by UUID REFERENCES "user"(id) ON DELETE SET NULL,
  publication_authorized BOOLEAN NOT NULL DEFAULT FALSE,
  publication_authority_basis TEXT,
  publication_approval_reference TEXT,
  publication_authorized_at TIMESTAMPTZ,
  publication_authorized_by UUID REFERENCES "user"(id) ON DELETE SET NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (
    NOT training_data_use_authorized OR (
      NULLIF(BTRIM(training_authority_basis), '') IS NOT NULL
      AND NULLIF(BTRIM(training_approval_reference), '') IS NOT NULL
      AND training_authorized_at IS NOT NULL
      AND training_authorized_by IS NOT NULL
    )
  ),
  CHECK (
    NOT publication_authorized OR (
      NULLIF(BTRIM(publication_authority_basis), '') IS NOT NULL
      AND NULLIF(BTRIM(publication_approval_reference), '') IS NOT NULL
      AND publication_authorized_at IS NOT NULL
      AND publication_authorized_by IS NOT NULL
    )
  )
);

COMMENT ON TABLE data_retention_hold IS
  'Category-wide or record-specific legal/security holds checked before automated disposal.';
COMMENT ON TABLE data_retention_cleanup_run IS
  'Low-sensitivity audit of scheduled retention execution; contains counts and policy references, not record contents.';
COMMENT ON COLUMN gis_import_job.provenance_confirmed_at IS
  'Uploader or authorized reviewer attestation that source authority, attribution and redistribution metadata are complete; not a legal license approval.';
COMMENT ON COLUMN spatial_feature.source_provenance IS
  'Non-sensitive source and redistribution metadata carried from an approved import into downstream exports.';
COMMENT ON TABLE project_ai_governance IS
  'Separate documented authority for project data training use and viewer-facing AI publication; ordinary AI enablement is insufficient.';
