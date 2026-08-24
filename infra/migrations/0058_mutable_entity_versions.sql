ALTER TABLE project
  ADD COLUMN version BIGINT NOT NULL DEFAULT 1;

ALTER TABLE project_category
  ADD COLUMN version BIGINT NOT NULL DEFAULT 1;

ALTER TABLE project
  ADD CONSTRAINT chk_project_version_positive CHECK (version > 0);

ALTER TABLE project_category
  ADD CONSTRAINT chk_project_category_version_positive CHECK (version > 0);

COMMENT ON COLUMN project.version IS
  'Optimistic concurrency version supplied by editing clients as expected_version.';

COMMENT ON COLUMN project_category.version IS
  'Optimistic concurrency version supplied by editing clients as expected_version.';
