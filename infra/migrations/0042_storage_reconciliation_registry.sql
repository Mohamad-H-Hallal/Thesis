CREATE TABLE IF NOT EXISTS storage_object_migration (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  manifest_sha256 TEXT NOT NULL,
  object_kind TEXT NOT NULL,
  reference_table TEXT NOT NULL,
  reference_column TEXT NOT NULL,
  reference_row_id UUID NOT NULL,
  source_reference TEXT NOT NULL,
  destination_reference TEXT NOT NULL,
  source_size_bytes BIGINT NOT NULL,
  source_sha256 TEXT NOT NULL,
  destination_size_bytes BIGINT,
  destination_sha256 TEXT,
  status TEXT NOT NULL DEFAULT 'planned',
  source_retained BOOLEAN NOT NULL DEFAULT TRUE,
  rollback_retain_until TIMESTAMPTZ,
  started_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  copied_at TIMESTAMPTZ,
  verified_at TIMESTAMPTZ,
  switched_at TIMESTAMPTZ,
  rolled_back_at TIMESTAMPTZ,
  last_error_code TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT uq_storage_object_migration_reference
    UNIQUE (reference_table, reference_column, reference_row_id),
  CONSTRAINT uq_storage_object_migration_destination UNIQUE (destination_reference),
  CONSTRAINT chk_storage_object_migration_manifest CHECK (
    manifest_sha256 ~ '^[0-9a-f]{64}$'
  ),
  CONSTRAINT chk_storage_object_migration_kind CHECK (
    object_kind IN (
      'feature_photo',
      'feature_thumbnail',
      'gis_import',
      'export_file'
    )
  ),
  CONSTRAINT chk_storage_object_migration_target CHECK (
    (reference_table = 'photo' AND reference_column IN ('file_path', 'thumbnail_path'))
    OR
    (reference_table = 'gis_import_job' AND reference_column = 'file_path')
    OR
    (reference_table = 'shapefile_export' AND reference_column = 'file_path')
  ),
  CONSTRAINT chk_storage_object_migration_source_reference CHECK (
    char_length(source_reference) BETWEEN 1 AND 2048
  ),
  CONSTRAINT chk_storage_object_migration_destination_reference CHECK (
    destination_reference ~ '^storage://(uploads|exports)/'
    AND char_length(destination_reference) BETWEEN 1 AND 2048
  ),
  CONSTRAINT chk_storage_object_migration_source_size CHECK (source_size_bytes > 0),
  CONSTRAINT chk_storage_object_migration_source_checksum CHECK (
    source_sha256 ~ '^[0-9a-f]{64}$'
  ),
  CONSTRAINT chk_storage_object_migration_destination_size CHECK (
    destination_size_bytes IS NULL OR destination_size_bytes > 0
  ),
  CONSTRAINT chk_storage_object_migration_destination_checksum CHECK (
    destination_sha256 IS NULL OR destination_sha256 ~ '^[0-9a-f]{64}$'
  ),
  CONSTRAINT chk_storage_object_migration_status CHECK (
    status IN ('planned', 'copied', 'verified', 'switched', 'rolled_back', 'failed')
  ),
  CONSTRAINT chk_storage_object_migration_metadata CHECK (
    jsonb_typeof(metadata) = 'object'
  ),
  CONSTRAINT chk_storage_object_migration_switch CHECK (
    status <> 'switched'
    OR (
      destination_size_bytes = source_size_bytes
      AND destination_sha256 = source_sha256
      AND source_retained = TRUE
      AND rollback_retain_until IS NOT NULL
      AND copied_at IS NOT NULL
      AND verified_at IS NOT NULL
      AND switched_at IS NOT NULL
    )
  )
);

CREATE INDEX IF NOT EXISTS idx_storage_object_migration_status
  ON storage_object_migration(status, started_at DESC);

CREATE INDEX IF NOT EXISTS idx_storage_object_migration_manifest
  ON storage_object_migration(manifest_sha256, started_at DESC);

CREATE TABLE IF NOT EXISTS storage_orphan_quarantine_record (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  manifest_sha256 TEXT NOT NULL,
  source_reference TEXT NOT NULL,
  quarantine_reference TEXT NOT NULL,
  object_size_bytes BIGINT NOT NULL,
  object_sha256 TEXT NOT NULL,
  reviewed_by TEXT NOT NULL,
  reviewed_at TIMESTAMPTZ NOT NULL,
  review_reason TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'copied',
  copied_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  source_removed_at TIMESTAMPTZ,
  last_error_code TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT uq_storage_orphan_quarantine_source
    UNIQUE (source_reference, object_sha256),
  CONSTRAINT uq_storage_orphan_quarantine_destination UNIQUE (quarantine_reference),
  CONSTRAINT chk_storage_orphan_quarantine_manifest CHECK (
    manifest_sha256 ~ '^[0-9a-f]{64}$'
  ),
  CONSTRAINT chk_storage_orphan_quarantine_source CHECK (
    char_length(source_reference) BETWEEN 1 AND 2048
  ),
  CONSTRAINT chk_storage_orphan_quarantine_destination CHECK (
    quarantine_reference ~ '^storage://(uploads|exports)/\\.quarantine/legacy-orphans/'
    AND char_length(quarantine_reference) BETWEEN 1 AND 2048
  ),
  CONSTRAINT chk_storage_orphan_quarantine_size CHECK (object_size_bytes > 0),
  CONSTRAINT chk_storage_orphan_quarantine_checksum CHECK (
    object_sha256 ~ '^[0-9a-f]{64}$'
  ),
  CONSTRAINT chk_storage_orphan_quarantine_reviewer CHECK (
    char_length(reviewed_by) BETWEEN 1 AND 200
  ),
  CONSTRAINT chk_storage_orphan_quarantine_reason CHECK (
    char_length(review_reason) BETWEEN 1 AND 1000
  ),
  CONSTRAINT chk_storage_orphan_quarantine_status CHECK (
    status IN ('copied', 'quarantined', 'failed')
  ),
  CONSTRAINT chk_storage_orphan_quarantine_metadata CHECK (
    jsonb_typeof(metadata) = 'object'
  ),
  CONSTRAINT chk_storage_orphan_quarantine_completion CHECK (
    status <> 'quarantined' OR source_removed_at IS NOT NULL
  )
);

CREATE INDEX IF NOT EXISTS idx_storage_orphan_quarantine_status
  ON storage_orphan_quarantine_record(status, copied_at DESC);

CREATE INDEX IF NOT EXISTS idx_storage_orphan_quarantine_manifest
  ON storage_orphan_quarantine_record(manifest_sha256, copied_at DESC);
