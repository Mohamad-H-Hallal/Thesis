ALTER TABLE project
  VALIDATE CONSTRAINT chk_project_category_required;

ALTER TABLE project_assignment
  VALIDATE CONSTRAINT chk_project_assignment_approved_meta;

ALTER TABLE spatial_feature
  VALIDATE CONSTRAINT chk_spatial_feature_review_required;

ALTER TABLE shapefile_export
  VALIDATE CONSTRAINT chk_export_failed_requires_error;

ALTER TABLE shapefile_export
  VALIDATE CONSTRAINT chk_export_completed_requires_file;
