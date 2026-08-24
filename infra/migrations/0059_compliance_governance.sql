-- Compliance/governance records are deliberately policy-neutral. Nullable
-- approval fields and disabled execution flags prevent engineering defaults
-- from becoming invented legal decisions.

CREATE TABLE legal_document_version (
  document_type TEXT NOT NULL CHECK (
    document_type IN (
      'privacy',
      'terms',
      'acceptable_use',
      'important_notices',
      'account_deletion',
      'subprocessors',
      'open_source'
    )
  ),
  version TEXT NOT NULL CHECK (version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$'),
  locale TEXT NOT NULL CHECK (locale ~ '^[a-z]{2}(?:-[A-Z]{2})?$'),
  title TEXT NOT NULL CHECK (char_length(title) BETWEEN 1 AND 200),
  content_sha256 TEXT NOT NULL CHECK (content_sha256 ~ '^[a-f0-9]{64}$'),
  status TEXT NOT NULL CHECK (status IN ('draft', 'approved', 'retired')),
  effective_at TIMESTAMPTZ,
  published_at TIMESTAMPTZ,
  retired_at TIMESTAMPTZ,
  counsel_approved_at TIMESTAMPTZ,
  approval_reference TEXT,
  is_current BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (document_type, version, locale),
  CHECK (
    status <> 'approved'
    OR (
      effective_at IS NOT NULL
      AND counsel_approved_at IS NOT NULL
      AND NULLIF(BTRIM(approval_reference), '') IS NOT NULL
    )
  ),
  CHECK (NOT is_current OR status IN ('draft', 'approved'))
);

CREATE UNIQUE INDEX uq_legal_document_current_locale
  ON legal_document_version (document_type, locale)
  WHERE is_current = TRUE;

CREATE TABLE legal_acceptance (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  document_type TEXT NOT NULL,
  document_version TEXT NOT NULL,
  locale TEXT NOT NULL,
  accepted_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  session_id UUID REFERENCES auth_session(id) ON DELETE SET NULL,
  request_id TEXT,
  evidence JSONB NOT NULL DEFAULT '{}'::JSONB,
  withdrawn_at TIMESTAMPTZ,
  superseded_at TIMESTAMPTZ,
  FOREIGN KEY (document_type, document_version, locale)
    REFERENCES legal_document_version(document_type, version, locale)
    ON DELETE RESTRICT,
  UNIQUE (user_id, document_type, document_version, locale)
);

CREATE INDEX idx_legal_acceptance_user_current
  ON legal_acceptance (user_id, document_type, accepted_at DESC)
  WHERE withdrawn_at IS NULL;

CREATE TABLE privacy_request (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES "user"(id) ON DELETE SET NULL,
  request_type TEXT NOT NULL CHECK (
    request_type IN (
      'access_export',
      'correction',
      'deletion',
      'restriction',
      'objection'
    )
  ),
  status TEXT NOT NULL DEFAULT 'open' CHECK (
    status IN (
      'pending_verification',
      'open',
      'in_review',
      'awaiting_user',
      'approved',
      'rejected',
      'completed',
      'cancelled'
    )
  ),
  request_details JSONB NOT NULL DEFAULT '{}'::JSONB,
  identity_verified_at TIMESTAMPTZ,
  requested_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  internal_target_at TIMESTAMPTZ NOT NULL DEFAULT (CURRENT_TIMESTAMP + INTERVAL '10 days'),
  acknowledged_at TIMESTAMPTZ,
  assigned_to_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL,
  reviewed_by_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL,
  reviewed_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ,
  resolution_code TEXT,
  resolution_summary TEXT,
  retention_exceptions JSONB NOT NULL DEFAULT '[]'::JSONB,
  last_user_visible_message TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (identity_verified_at IS NULL OR user_id IS NOT NULL),
  CHECK (status <> 'completed' OR completed_at IS NOT NULL),
  CHECK (status <> 'cancelled' OR cancelled_at IS NOT NULL),
  CHECK (jsonb_typeof(request_details) = 'object'),
  CHECK (jsonb_typeof(retention_exceptions) = 'array')
);

CREATE UNIQUE INDEX uq_privacy_request_open_type_per_user
  ON privacy_request (user_id, request_type)
  WHERE user_id IS NOT NULL
    AND status IN ('pending_verification', 'open', 'in_review', 'awaiting_user', 'approved');

CREATE INDEX idx_privacy_request_queue
  ON privacy_request (status, internal_target_at, requested_at);

CREATE INDEX idx_privacy_request_user
  ON privacy_request (user_id, requested_at DESC);

CREATE TABLE data_retention_policy (
  data_category TEXT PRIMARY KEY CHECK (data_category ~ '^[a-z][a-z0-9_]{1,79}$'),
  description TEXT NOT NULL,
  trigger_event TEXT NOT NULL,
  retention_days INTEGER CHECK (retention_days IS NULL OR retention_days >= 0),
  disposal_action TEXT CHECK (
    disposal_action IS NULL OR disposal_action IN ('delete', 'anonymize', 'archive', 'review')
  ),
  legal_basis_reference TEXT,
  backup_expiry_days INTEGER CHECK (backup_expiry_days IS NULL OR backup_expiry_days >= 0),
  approved_at TIMESTAMPTZ,
  approval_reference TEXT,
  automated_cleanup_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (
    NOT automated_cleanup_enabled
    OR (
      retention_days IS NOT NULL
      AND disposal_action IS NOT NULL
      AND approved_at IS NOT NULL
      AND NULLIF(BTRIM(approval_reference), '') IS NOT NULL
    )
  )
);

CREATE TABLE data_retention_hold (
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

CREATE INDEX idx_data_retention_hold_active
  ON data_retention_hold (data_category, record_table, record_id)
  WHERE released_at IS NULL;

CREATE TABLE data_retention_cleanup_run (
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

CREATE TABLE data_retention_cleanup_item (
  id BIGSERIAL PRIMARY KEY,
  run_id UUID NOT NULL REFERENCES data_retention_cleanup_run(id) ON DELETE CASCADE,
  data_category TEXT NOT NULL REFERENCES data_retention_policy(data_category) ON DELETE RESTRICT,
  retention_days INTEGER NOT NULL CHECK (retention_days >= 0),
  disposal_action TEXT NOT NULL,
  approval_reference TEXT NOT NULL,
  affected_rows INTEGER NOT NULL DEFAULT 0 CHECK (affected_rows >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO data_retention_policy (data_category, description, trigger_event)
VALUES
  ('auth_sessions', 'Authentication sessions and revocation evidence', 'expiry or revocation'),
  ('password_reset_requests', 'Password reset challenges', 'expiry or consumption'),
  ('contact_verification', 'Contact challenges and assurance audit', 'expiry or consumption'),
  ('push_devices', 'Push registrations and token snapshots', 'invalidation or account action'),
  ('notifications', 'In-app notification content and delivery state', 'creation or user deletion'),
  ('imports', 'Import uploads, parsed rows and review records', 'completion, failure or project closure'),
  ('exports', 'Generated export files and metadata', 'completion or regeneration'),
  ('photos_and_drafts', 'Field photos and unsubmitted drafts', 'sync, rejection, discard or account action'),
  ('gis_history', 'Submitted feature history and review evidence', 'project closure or withdrawal'),
  ('ai_artifacts', 'AI runs, artifacts, evidence and validation', 'completion, rejection or retraction'),
  ('audit_logs', 'Application and database audit records', 'record creation'),
  ('backups', 'Database and object-storage backups', 'backup creation'),
  ('privacy_requests', 'Privacy request and fulfillment evidence', 'request completion')
ON CONFLICT (data_category) DO NOTHING;

CREATE TABLE data_source_license (
  source_key TEXT PRIMARY KEY CHECK (source_key ~ '^[a-z][a-z0-9_]{1,79}$'),
  provider_name TEXT NOT NULL,
  dataset_name TEXT NOT NULL,
  source_type TEXT NOT NULL CHECK (
    source_type IN ('basemap', 'imagery', 'reference', 'import', 'ai_dataset', 'other')
  ),
  terms_url TEXT,
  license_name TEXT,
  attribution_text TEXT,
  online_use_approved_at TIMESTAMPTZ,
  offline_use_approved_at TIMESTAMPTZ,
  cache_use_approved_at TIMESTAMPTZ,
  derived_work_approved_at TIMESTAMPTZ,
  redistribution_approved_at TIMESTAMPTZ,
  approval_reference TEXT,
  reviewed_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (jsonb_typeof(metadata) = 'object')
);

INSERT INTO data_source_license
  (source_key, provider_name, dataset_name, source_type, terms_url, license_name, attribution_text, metadata)
VALUES
  (
    'openstreetmap_standard',
    'OpenStreetMap contributors / OpenStreetMap Foundation tile service',
    'OpenStreetMap Standard tiles',
    'basemap',
    'https://operations.osmfoundation.org/policies/tiles/',
    'Open Data Commons Open Database License for OSM data; separate tile-service policy',
    '© OpenStreetMap contributors',
    '{"public_tile_offline_download_allowed": false}'::JSONB
  ),
  (
    'esri_world_imagery',
    'Esri and listed imagery providers',
    'World Imagery',
    'imagery',
    'https://www.esri.com/en-us/legal/overview',
    NULL,
    'Source: Esri and imagery providers',
    '{"license_evidence_required": true}'::JSONB
  ),
  (
    'esri_reference_labels',
    'Esri',
    'World Boundaries and Places',
    'reference',
    'https://www.esri.com/en-us/legal/overview',
    NULL,
    'Source: Esri',
    '{"license_evidence_required": true}'::JSONB
  )
ON CONFLICT (source_key) DO NOTHING;

ALTER TABLE gis_import_job
  ADD COLUMN source_provider TEXT,
  ADD COLUMN source_dataset_name TEXT,
  ADD COLUMN source_dataset_date DATE,
  ADD COLUMN source_accuracy_statement TEXT,
  ADD COLUMN source_license_or_authority TEXT,
  ADD COLUMN source_attribution TEXT,
  ADD COLUMN source_terms_url TEXT,
  ADD COLUMN source_redistribution_rules TEXT,
  ADD COLUMN provenance_confirmed_at TIMESTAMPTZ,
  ADD COLUMN provenance_confirmed_by_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL;

ALTER TABLE gis_import_job
  ADD CONSTRAINT chk_gis_import_job_source_terms_url
    CHECK (
      source_terms_url IS NULL
      OR source_terms_url ~ '^https?://[^[:space:]]+$'
    ),
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

ALTER TABLE spatial_feature
  ADD COLUMN source_provenance JSONB NOT NULL DEFAULT '{}'::JSONB,
  ADD CONSTRAINT chk_spatial_feature_source_provenance
    CHECK (jsonb_typeof(source_provenance) = 'object');

CREATE TABLE ai_governance_artifact (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  artifact_type TEXT NOT NULL CHECK (artifact_type IN ('model', 'dataset', 'evaluation')),
  stable_key TEXT NOT NULL CHECK (stable_key ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$'),
  version TEXT NOT NULL CHECK (char_length(version) BETWEEN 1 AND 160),
  display_name TEXT NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 240),
  digest TEXT,
  provider_name TEXT,
  license_name TEXT,
  license_url TEXT,
  intended_use TEXT,
  prohibited_uses JSONB NOT NULL DEFAULT '[]'::JSONB,
  provenance JSONB NOT NULL DEFAULT '{}'::JSONB,
  evaluation JSONB NOT NULL DEFAULT '{}'::JSONB,
  personal_data_reviewed_at TIMESTAMPTZ,
  training_use_approved_at TIMESTAMPTZ,
  publication_use_approved_at TIMESTAMPTZ,
  approval_reference TEXT,
  retired_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (artifact_type, stable_key, version),
  CHECK (jsonb_typeof(prohibited_uses) = 'array'),
  CHECK (jsonb_typeof(provenance) = 'object'),
  CHECK (jsonb_typeof(evaluation) = 'object')
);

CREATE TABLE project_ai_governance (
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

CREATE TABLE content_report (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  project_id UUID REFERENCES project(id) ON DELETE CASCADE,
  entity_type TEXT NOT NULL CHECK (
    entity_type IN ('project', 'feature', 'photo', 'import', 'comment', 'ai_output', 'user')
  ),
  entity_id UUID NOT NULL,
  reason_code TEXT NOT NULL CHECK (
    reason_code IN (
      'privacy',
      'sensitive_location',
      'unauthorized_content',
      'harassment',
      'illegal_content',
      'copyright_or_license',
      'misleading_or_inaccurate',
      'other'
    )
  ),
  description TEXT CHECK (description IS NULL OR char_length(description) <= 2000),
  status TEXT NOT NULL DEFAULT 'open' CHECK (
    status IN ('open', 'in_review', 'actioned', 'rejected', 'closed')
  ),
  assigned_to_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL,
  reviewed_by_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL,
  resolution_summary TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  resolved_at TIMESTAMPTZ
);

CREATE INDEX idx_content_report_queue
  ON content_report (status, created_at);
CREATE INDEX idx_content_report_project
  ON content_report (project_id, status, created_at);

ALTER TABLE push_device_registration
  ADD COLUMN show_sensitive_preview BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON TABLE legal_document_version IS
  'Immutable legal-document version metadata; production publication requires exact-content counsel approval.';
COMMENT ON TABLE legal_acceptance IS
  'Affirmative acceptance evidence. Privacy notice viewing is not represented as consent.';
COMMENT ON TABLE privacy_request IS
  'Identity-bound privacy request queue. Completion requires an approved retention/deletion policy.';
COMMENT ON TABLE data_retention_policy IS
  'Central policy registry. Cleanup is fail-closed until a dated decision and evidence reference exist.';
COMMENT ON TABLE data_retention_hold IS
  'Category-wide or record-specific legal/security holds checked before automated disposal.';
COMMENT ON TABLE data_retention_cleanup_run IS
  'Low-sensitivity audit of scheduled retention execution; contains counts and policy references, not record contents.';
COMMENT ON TABLE data_source_license IS
  'GIS/map/data source rights and attribution evidence; technical accessibility is not approval.';
COMMENT ON COLUMN gis_import_job.provenance_confirmed_at IS
  'Uploader or authorized reviewer attestation that source authority, attribution and redistribution metadata are complete; not a legal license approval.';
COMMENT ON COLUMN spatial_feature.source_provenance IS
  'Non-sensitive source and redistribution metadata carried from an approved import into downstream exports.';
COMMENT ON TABLE ai_governance_artifact IS
  'Model, dataset and evaluation provenance/approval metadata; an empty registry blocks production AI claims.';
COMMENT ON TABLE project_ai_governance IS
  'Separate documented authority for project data training use and viewer-facing AI publication; ordinary AI enablement is insufficient.';
COMMENT ON TABLE content_report IS
  'Authorized user report/takedown queue for project and user-generated GIS content.';
