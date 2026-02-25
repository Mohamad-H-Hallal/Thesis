CREATE INDEX IF NOT EXISTS idx_user_email ON "user"(email);
CREATE INDEX IF NOT EXISTS idx_user_role ON "user"(role);
CREATE INDEX IF NOT EXISTS idx_user_is_active ON "user"(is_active);

CREATE INDEX IF NOT EXISTS idx_project_category_name ON project_category(name);

CREATE INDEX IF NOT EXISTS idx_project_category ON project(category_id);
CREATE INDEX IF NOT EXISTS idx_project_created_by ON project(created_by_user_id);
CREATE INDEX IF NOT EXISTS idx_project_status ON project(status);
CREATE INDEX IF NOT EXISTS idx_project_created_at ON project(created_at);
CREATE INDEX IF NOT EXISTS idx_project_name ON project(name);

CREATE INDEX IF NOT EXISTS idx_assignment_project ON project_assignment(project_id);
CREATE INDEX IF NOT EXISTS idx_assignment_user ON project_assignment(user_id);
CREATE INDEX IF NOT EXISTS idx_assignment_status ON project_assignment(status);
CREATE INDEX IF NOT EXISTS idx_assignment_approved_by ON project_assignment(approved_by_user_id);

CREATE INDEX IF NOT EXISTS idx_spatial_feature_project ON spatial_feature(project_id);
CREATE INDEX IF NOT EXISTS idx_spatial_feature_collector ON spatial_feature(collected_by_user_id);
CREATE INDEX IF NOT EXISTS idx_spatial_feature_reviewer ON spatial_feature(reviewed_by_user_id);
CREATE INDEX IF NOT EXISTS idx_spatial_feature_status ON spatial_feature(status);
CREATE INDEX IF NOT EXISTS idx_spatial_feature_collected_at ON spatial_feature(collected_at);
CREATE INDEX IF NOT EXISTS idx_spatial_feature_submitted_at ON spatial_feature(submitted_at);
CREATE INDEX IF NOT EXISTS idx_spatial_feature_project_status ON spatial_feature(project_id, status);
CREATE INDEX IF NOT EXISTS idx_spatial_feature_geom ON spatial_feature USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_spatial_feature_attributes ON spatial_feature USING GIN (attributes);

CREATE INDEX IF NOT EXISTS idx_photo_feature ON photo(feature_id);
CREATE INDEX IF NOT EXISTS idx_photo_location ON photo USING GIST (location);
CREATE INDEX IF NOT EXISTS idx_photo_status ON photo(status);
CREATE INDEX IF NOT EXISTS idx_photo_taken_at ON photo(taken_at);
CREATE INDEX IF NOT EXISTS idx_photo_display_order ON photo(feature_id, display_order);

CREATE INDEX IF NOT EXISTS idx_export_project ON shapefile_export(project_id);
CREATE INDEX IF NOT EXISTS idx_export_requested_by ON shapefile_export(requested_by_user_id);
CREATE INDEX IF NOT EXISTS idx_export_status ON shapefile_export(status);
CREATE INDEX IF NOT EXISTS idx_export_requested_at ON shapefile_export(requested_at);

CREATE INDEX IF NOT EXISTS idx_notification_user ON notification(user_id);
CREATE INDEX IF NOT EXISTS idx_notification_type ON notification(type);
CREATE INDEX IF NOT EXISTS idx_notification_is_read ON notification(is_read);
CREATE INDEX IF NOT EXISTS idx_notification_created_at ON notification(created_at);
CREATE INDEX IF NOT EXISTS idx_notification_user_read ON notification(user_id, is_read);

CREATE INDEX IF NOT EXISTS idx_audit_log_user ON audit_log(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_action ON audit_log(action_type);
CREATE INDEX IF NOT EXISTS idx_audit_log_entity ON audit_log(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_created_at ON audit_log(created_at);

CREATE INDEX IF NOT EXISTS idx_offline_map_version ON lebanon_offline_map(version);
CREATE INDEX IF NOT EXISTS idx_offline_map_is_current ON lebanon_offline_map(is_current);

CREATE OR REPLACE VIEW project_statistics AS
SELECT
  p.id AS project_id,
  p.name AS project_name,
  p.status,
  p.created_at,
  COUNT(DISTINCT pa.user_id) FILTER (WHERE pa.status = 'approved') AS approved_contributors,
  COUNT(DISTINCT sf.id) AS total_features,
  COUNT(DISTINCT sf.id) FILTER (WHERE sf.status = 'draft') AS draft_features,
  COUNT(DISTINCT sf.id) FILTER (WHERE sf.status = 'pending_review') AS pending_review_features,
  COUNT(DISTINCT sf.id) FILTER (WHERE sf.status = 'approved') AS approved_features,
  COUNT(DISTINCT sf.id) FILTER (WHERE sf.status = 'rejected') AS rejected_features,
  COUNT(DISTINCT ph.id) AS total_photos
FROM project p
LEFT JOIN project_assignment pa ON pa.project_id = p.id
LEFT JOIN spatial_feature sf ON sf.project_id = p.id
LEFT JOIN photo ph ON ph.feature_id = sf.id
GROUP BY p.id;

CREATE OR REPLACE VIEW user_productivity AS
SELECT
  u.id AS user_id,
  u.full_name,
  u.email,
  u.role,
  COUNT(DISTINCT sf.id) AS collected_features,
  COUNT(DISTINCT sf.id) FILTER (WHERE sf.status = 'approved') AS approved_features,
  COUNT(DISTINCT sf.id) FILTER (WHERE sf.status = 'pending_review') AS pending_review_features,
  COUNT(DISTINCT ph.id) AS uploaded_photos,
  MAX(sf.collected_at) AS last_collection_at
FROM "user" u
LEFT JOIN spatial_feature sf ON sf.collected_by_user_id = u.id
LEFT JOIN photo ph ON ph.feature_id = sf.id
GROUP BY u.id;
