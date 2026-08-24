-- Production privacy-request execution and evidence model.
--
-- This migration deliberately keeps policy decisions (retention periods,
-- lawful bases, public masked-attribution rules, and legal holds) outside the
-- schema. It adds the technical controls needed to execute approved requests
-- without weakening the existing fail-closed behavior.

ALTER TYPE workload_job_kind ADD VALUE IF NOT EXISTS 'privacy_access_export';
ALTER TYPE workload_job_kind ADD VALUE IF NOT EXISTS 'account_deletion';

ALTER TABLE privacy_request
  DROP CONSTRAINT IF EXISTS privacy_request_status_check;

ALTER TABLE privacy_request
  ADD CONSTRAINT privacy_request_status_check CHECK (
    status IN (
      'pending_verification',
      'open',
      'in_review',
      'awaiting_user',
      'approved',
      'scheduled',
      'processing',
      'failed',
      'rejected',
      'completed',
      'cancelled'
    )
  );

ALTER TABLE privacy_request
  ADD COLUMN IF NOT EXISTS internal_resolution_notes TEXT,
  ADD COLUMN IF NOT EXISTS execution_started_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS failed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS failure_code TEXT,
  ADD COLUMN IF NOT EXISTS transfer_to_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL;

DROP INDEX IF EXISTS uq_privacy_request_open_type_per_user;
CREATE UNIQUE INDEX uq_privacy_request_open_type_per_user
  ON privacy_request (user_id, request_type)
  WHERE user_id IS NOT NULL
    AND status IN (
      'pending_verification', 'open', 'in_review', 'awaiting_user',
      'approved', 'scheduled', 'processing', 'failed'
    );

CREATE INDEX IF NOT EXISTS idx_privacy_request_admin_queue
  ON privacy_request (status, request_type, internal_target_at, requested_at, id);
CREATE INDEX IF NOT EXISTS idx_privacy_request_assignee_queue
  ON privacy_request (assigned_to_user_id, status, internal_target_at)
  WHERE status NOT IN ('completed', 'cancelled', 'rejected');

CREATE TABLE privacy_request_status_history (
  id BIGSERIAL PRIMARY KEY,
  request_id UUID NOT NULL REFERENCES privacy_request(id) ON DELETE CASCADE,
  from_status TEXT,
  to_status TEXT NOT NULL,
  actor_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL,
  actor_kind TEXT NOT NULL DEFAULT 'administrator' CHECK (
    actor_kind IN ('requester', 'administrator', 'worker', 'system')
  ),
  user_visible_message TEXT,
  resolution_code TEXT,
  resolution_summary TEXT,
  internal_note TEXT,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (from_status IS NULL OR from_status <> to_status),
  CHECK (char_length(COALESCE(user_visible_message, '')) <= 1000),
  CHECK (char_length(COALESCE(resolution_summary, '')) <= 2000),
  CHECK (char_length(COALESCE(internal_note, '')) <= 4000)
);

CREATE INDEX idx_privacy_request_history_request
  ON privacy_request_status_history (request_id, occurred_at DESC, id DESC);

INSERT INTO privacy_request_status_history
  (request_id, from_status, to_status, actor_kind, user_visible_message, occurred_at)
SELECT id, NULL, status, 'system', last_user_visible_message, created_at
FROM privacy_request
WHERE NOT EXISTS (
  SELECT 1 FROM privacy_request_status_history history WHERE history.request_id = privacy_request.id
);

ALTER TABLE content_report
  DROP CONSTRAINT IF EXISTS content_report_status_check;

ALTER TABLE content_report
  ADD CONSTRAINT content_report_status_check CHECK (
    status IN (
      'open', 'in_review', 'awaiting_reporter', 'escalated',
      'action_required', 'actioned', 'dismissed', 'closed'
    )
  );

ALTER TABLE content_report
  ADD COLUMN IF NOT EXISTS internal_target_at TIMESTAMPTZ NOT NULL
    DEFAULT (CURRENT_TIMESTAMP + INTERVAL '10 days'),
  ADD COLUMN IF NOT EXISTS user_visible_message TEXT,
  ADD COLUMN IF NOT EXISTS internal_resolution_notes TEXT,
  ADD COLUMN IF NOT EXISTS outcome_code TEXT,
  ADD COLUMN IF NOT EXISTS action_reference TEXT;

CREATE INDEX IF NOT EXISTS idx_content_report_admin_queue
  ON content_report (status, entity_type, internal_target_at, created_at, id);
CREATE INDEX IF NOT EXISTS idx_content_report_assignee_queue
  ON content_report (assigned_to_user_id, status, internal_target_at)
  WHERE status NOT IN ('actioned', 'dismissed', 'closed');
CREATE INDEX IF NOT EXISTS idx_content_report_reporter
  ON content_report (reporter_user_id, created_at DESC);

CREATE TABLE content_report_status_history (
  id BIGSERIAL PRIMARY KEY,
  report_id UUID NOT NULL REFERENCES content_report(id) ON DELETE CASCADE,
  from_status TEXT,
  to_status TEXT NOT NULL,
  actor_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL,
  actor_kind TEXT NOT NULL DEFAULT 'administrator' CHECK (
    actor_kind IN ('reporter', 'administrator', 'system')
  ),
  outcome_code TEXT,
  user_visible_message TEXT,
  resolution_summary TEXT,
  internal_note TEXT,
  action_reference TEXT,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (from_status IS NULL OR from_status <> to_status),
  CHECK (char_length(COALESCE(user_visible_message, '')) <= 1000),
  CHECK (char_length(COALESCE(resolution_summary, '')) <= 2000),
  CHECK (char_length(COALESCE(internal_note, '')) <= 4000)
);

CREATE INDEX idx_content_report_history_report
  ON content_report_status_history (report_id, occurred_at DESC, id DESC);

INSERT INTO content_report_status_history
  (report_id, from_status, to_status, actor_kind, occurred_at)
SELECT id, NULL, status, 'system', created_at
FROM content_report
WHERE NOT EXISTS (
  SELECT 1 FROM content_report_status_history history WHERE history.report_id = content_report.id
);

CREATE TABLE privacy_downstream_correction_task (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  privacy_request_id UUID NOT NULL REFERENCES privacy_request(id) ON DELETE CASCADE,
  processor_key TEXT NOT NULL CHECK (processor_key ~ '^[a-z][a-z0-9_:-]{1,119}$'),
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'sent', 'confirmed', 'not_required', 'failed')),
  safe_instruction TEXT NOT NULL CHECK (char_length(safe_instruction) BETWEEN 1 AND 1000),
  assigned_to_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL,
  completed_at TIMESTAMPTZ,
  evidence_reference TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (privacy_request_id, processor_key)
);

CREATE INDEX idx_downstream_correction_queue
  ON privacy_downstream_correction_task (status, created_at)
  WHERE status IN ('open', 'sent', 'failed');

CREATE TABLE privacy_free_text_review_task (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  privacy_request_id UUID NOT NULL REFERENCES privacy_request(id) ON DELETE CASCADE,
  record_table TEXT NOT NULL CHECK (record_table ~ '^[a-z][a-z0-9_]{1,79}$'),
  record_id UUID NOT NULL,
  reason_code TEXT NOT NULL CHECK (reason_code IN ('possible_name', 'possible_email', 'possible_phone')),
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'reviewed', 'redaction_required', 'closed')),
  assigned_to_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL,
  resolution_summary TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  reviewed_at TIMESTAMPTZ,
  UNIQUE (privacy_request_id, record_table, record_id, reason_code)
);

CREATE INDEX idx_privacy_free_text_review_queue
  ON privacy_free_text_review_task (status, created_at)
  WHERE status IN ('open', 'redaction_required');

CREATE TABLE privacy_export_artifact (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  privacy_request_id UUID NOT NULL UNIQUE REFERENCES privacy_request(id) ON DELETE RESTRICT,
  user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (
    status IN ('pending', 'generating', 'ready', 'failed', 'expired', 'deleted')
  ),
  format_version TEXT NOT NULL DEFAULT 'terraleb-personal-data-v1',
  content_type TEXT NOT NULL DEFAULT 'application/json',
  encrypted_file_path TEXT,
  encryption_algorithm TEXT,
  encryption_key_id TEXT,
  encryption_iv BYTEA,
  encryption_auth_tag BYTEA,
  plaintext_sha256 CHAR(64),
  encrypted_size_bytes BIGINT CHECK (encrypted_size_bytes IS NULL OR encrypted_size_bytes >= 0),
  record_counts JSONB NOT NULL DEFAULT '{}'::JSONB,
  generated_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,
  deleted_at TIMESTAMPTZ,
  failure_code TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (jsonb_typeof(record_counts) = 'object'),
  CHECK (
    status <> 'ready'
    OR (
      encrypted_file_path IS NOT NULL
      AND encryption_algorithm = 'AES-256-GCM'
      AND encryption_key_id IS NOT NULL
      AND encryption_iv IS NOT NULL
      AND encryption_auth_tag IS NOT NULL
      AND plaintext_sha256 ~ '^[a-f0-9]{64}$'
      AND generated_at IS NOT NULL
      AND expires_at IS NOT NULL
      AND expires_at > generated_at
    )
  ),
  CHECK (status NOT IN ('expired', 'deleted') OR deleted_at IS NOT NULL)
);

CREATE INDEX idx_privacy_export_expiry
  ON privacy_export_artifact (expires_at, status)
  WHERE status = 'ready';
CREATE INDEX idx_privacy_export_user
  ON privacy_export_artifact (user_id, created_at DESC);

CREATE TABLE privacy_export_download_grant (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  artifact_id UUID NOT NULL REFERENCES privacy_export_artifact(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  session_id UUID NOT NULL REFERENCES auth_session(id) ON DELETE CASCADE,
  token_hash CHAR(64) NOT NULL UNIQUE,
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (expires_at > created_at)
);

CREATE INDEX idx_privacy_export_grant_lookup
  ON privacy_export_download_grant (artifact_id, user_id, session_id, expires_at)
  WHERE used_at IS NULL;

CREATE TABLE account_deletion_execution (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  privacy_request_id UUID NOT NULL UNIQUE REFERENCES privacy_request(id) ON DELETE RESTRICT,
  user_id UUID NOT NULL UNIQUE REFERENCES "user"(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'scheduled' CHECK (
    status IN ('scheduled', 'processing', 'completed', 'failed')
  ),
  masked_contributor_label TEXT,
  eligibility_checked_at TIMESTAMPTZ,
  sessions_revoked_at TIMESTAMPTZ,
  responsibilities_transferred_at TIMESTAMPTZ,
  direct_identifiers_erased_at TIMESTAMPTZ,
  structured_snapshots_scrubbed_at TIMESTAMPTZ,
  free_text_review_scheduled_at TIMESTAMPTZ,
  backup_expiry_scheduled_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  failure_code TEXT,
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (
    status <> 'completed'
    OR (
      masked_contributor_label IS NOT NULL
      AND eligibility_checked_at IS NOT NULL
      AND sessions_revoked_at IS NOT NULL
      AND responsibilities_transferred_at IS NOT NULL
      AND direct_identifiers_erased_at IS NOT NULL
      AND structured_snapshots_scrubbed_at IS NOT NULL
      AND free_text_review_scheduled_at IS NOT NULL
      AND backup_expiry_scheduled_at IS NOT NULL
      AND completed_at IS NOT NULL
    )
  )
);

CREATE INDEX idx_account_deletion_execution_status
  ON account_deletion_execution (status, created_at);

CREATE TABLE backup_account_deletion_schedule (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  privacy_request_id UUID NOT NULL REFERENCES privacy_request(id) ON DELETE RESTRICT,
  user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  requested_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  purge_eligible_at TIMESTAMPTZ,
  policy_reference TEXT,
  status TEXT NOT NULL DEFAULT 'awaiting_approved_policy' CHECK (
    status IN ('awaiting_approved_policy', 'scheduled', 'confirmed_expired')
  ),
  confirmed_at TIMESTAMPTZ,
  UNIQUE (privacy_request_id)
);

CREATE INDEX idx_backup_deletion_schedule_status
  ON backup_account_deletion_schedule (status, purge_eligible_at);

ALTER TABLE "user"
  ADD COLUMN IF NOT EXISTS permanently_deleted_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS masked_contributor_label TEXT,
  ADD COLUMN IF NOT EXISTS deleted_by_privacy_request_id UUID
    REFERENCES privacy_request(id) ON DELETE RESTRICT;

ALTER TABLE "user"
  ALTER COLUMN email DROP NOT NULL,
  ALTER COLUMN email_original DROP NOT NULL,
  ALTER COLUMN email_canonical DROP NOT NULL,
  ALTER COLUMN password_hash DROP NOT NULL,
  ALTER COLUMN full_name DROP NOT NULL;

ALTER TABLE "user"
  DROP CONSTRAINT IF EXISTS user_account_status_valid;
ALTER TABLE "user"
  ADD CONSTRAINT user_account_status_valid CHECK (
    account_status IN (
      'pending_verification', 'verification_required', 'invited',
      'pending_approval', 'active', 'rejected', 'blocked', 'inactive', 'deleted'
    )
  );

ALTER TABLE "user"
  ADD CONSTRAINT user_deleted_tombstone_valid CHECK (
    (
      account_status = 'deleted'
      AND permanently_deleted_at IS NOT NULL
      AND deleted_by_privacy_request_id IS NOT NULL
      AND NULLIF(BTRIM(masked_contributor_label), '') IS NOT NULL
      AND email IS NULL
      AND email_original IS NULL
      AND email_canonical IS NULL
      AND password_hash IS NULL
      AND full_name IS NULL
      AND phone IS NULL
      AND phone_e164 IS NULL
      AND pending_email_original IS NULL
      AND pending_email_canonical IS NULL
      AND pending_phone_e164 IS NULL
      AND profile_picture_url IS NULL
      AND is_active = FALSE
    )
    OR
    (
      account_status <> 'deleted'
      AND permanently_deleted_at IS NULL
      AND deleted_by_privacy_request_id IS NULL
      AND masked_contributor_label IS NULL
      AND email IS NOT NULL
      AND email_original IS NOT NULL
      AND email_canonical IS NOT NULL
      AND password_hash IS NOT NULL
      AND full_name IS NOT NULL
    )
  ) NOT VALID;

ALTER TABLE "user" VALIDATE CONSTRAINT user_deleted_tombstone_valid;

COMMENT ON COLUMN "user".masked_contributor_label IS
  'One-way display label generated before direct-identifier erasure. This is pseudonymous, not anonymous.';
COMMENT ON COLUMN "user".permanently_deleted_at IS
  'Marks a non-authenticatable relational tombstone; deleted accounts cannot be reactivated.';
COMMENT ON TABLE privacy_export_artifact IS
  'Encrypted, requester-isolated personal-data artifact metadata. The file is never exposed by a public static route.';
COMMENT ON TABLE account_deletion_execution IS
  'Idempotent stage evidence for reviewed account deletion. Request completion is forbidden until every mandatory stage succeeds.';
COMMENT ON TABLE backup_account_deletion_schedule IS
  'Deletion propagation evidence for backup ageing; purge dates remain unset until an approved backup retention policy exists.';
