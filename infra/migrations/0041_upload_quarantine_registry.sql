CREATE TABLE IF NOT EXISTS upload_quarantine_record (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  upload_kind TEXT NOT NULL,
  storage_path TEXT NOT NULL UNIQUE,
  original_filename TEXT NOT NULL,
  uploaded_by_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL,
  project_id UUID REFERENCES project(id) ON DELETE SET NULL,
  file_size_bytes BIGINT NOT NULL,
  file_checksum_sha256 TEXT NOT NULL,
  detected_type TEXT,
  scan_status TEXT NOT NULL DEFAULT 'pending',
  disposition TEXT NOT NULL DEFAULT 'quarantined',
  reason_code TEXT,
  scanner_signature TEXT,
  released_path TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  released_at TIMESTAMPTZ,
  CONSTRAINT chk_upload_quarantine_kind CHECK (
    upload_kind IN ('gis_import', 'ai_validation_photo', 'category_icon', 'feature_photo')
  ),
  CONSTRAINT chk_upload_quarantine_storage_path CHECK (
    char_length(storage_path) BETWEEN 1 AND 2048
  ),
  CONSTRAINT chk_upload_quarantine_original_filename CHECK (
    char_length(original_filename) BETWEEN 1 AND 255
  ),
  CONSTRAINT chk_upload_quarantine_size CHECK (file_size_bytes > 0),
  CONSTRAINT chk_upload_quarantine_checksum CHECK (
    file_checksum_sha256 ~ '^[0-9a-f]{64}$'
  ),
  CONSTRAINT chk_upload_quarantine_scan_status CHECK (
    scan_status IN ('pending', 'clean', 'infected', 'unavailable', 'skipped')
  ),
  CONSTRAINT chk_upload_quarantine_disposition CHECK (
    disposition IN ('quarantined', 'released')
  ),
  CONSTRAINT chk_upload_quarantine_metadata CHECK (jsonb_typeof(metadata) = 'object'),
  CONSTRAINT chk_upload_quarantine_release CHECK (
    (
      disposition = 'quarantined'
      AND released_path IS NULL
      AND released_at IS NULL
    )
    OR
    (
      disposition = 'released'
      AND NULLIF(released_path, '') IS NOT NULL
      AND released_at IS NOT NULL
      AND scan_status IN ('clean', 'skipped')
    )
  )
);

CREATE INDEX IF NOT EXISTS idx_upload_quarantine_disposition_created
  ON upload_quarantine_record(disposition, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_upload_quarantine_project_created
  ON upload_quarantine_record(project_id, created_at DESC)
  WHERE project_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_upload_quarantine_scan_status
  ON upload_quarantine_record(scan_status, created_at DESC);
