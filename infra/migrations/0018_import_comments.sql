CREATE TABLE IF NOT EXISTS gis_import_comment (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  import_job_id UUID NOT NULL REFERENCES gis_import_job(id) ON DELETE CASCADE,
  author_user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  comment_text TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_gis_import_comment_job_created
  ON gis_import_comment (import_job_id, created_at ASC);
