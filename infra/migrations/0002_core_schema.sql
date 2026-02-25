DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role') THEN
    CREATE TYPE user_role AS ENUM ('admin', 'contributor', 'viewer');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'project_status') THEN
    CREATE TYPE project_status AS ENUM ('draft', 'active', 'paused', 'completed', 'archived');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'assignment_role') THEN
    CREATE TYPE assignment_role AS ENUM ('admin', 'contributor');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'assignment_status') THEN
    CREATE TYPE assignment_status AS ENUM ('pending', 'approved', 'rejected');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'feature_status') THEN
    CREATE TYPE feature_status AS ENUM ('draft', 'pending_review', 'approved', 'rejected');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'photo_status') THEN
    CREATE TYPE photo_status AS ENUM ('pending', 'approved', 'rejected');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'notification_type') THEN
    CREATE TYPE notification_type AS ENUM ('assignment', 'review_completed', 'export_ready');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'export_status') THEN
    CREATE TYPE export_status AS ENUM ('pending', 'processing', 'completed', 'failed');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'audit_action_type') THEN
    CREATE TYPE audit_action_type AS ENUM ('create', 'update', 'delete', 'approve', 'reject', 'export');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS "user" (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  email TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  full_name TEXT NOT NULL,
  phone TEXT,
  role user_role NOT NULL DEFAULT 'contributor',
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_login TIMESTAMPTZ,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  profile_picture_url TEXT
);

CREATE TABLE IF NOT EXISTS project_category (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT UNIQUE NOT NULL,
  description TEXT,
  icon_url TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS project (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  category_id UUID REFERENCES project_category(id) ON DELETE SET NULL,
  created_by_user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  name VARCHAR(255) NOT NULL,
  description TEXT,
  objectives TEXT,
  status project_status NOT NULL DEFAULT 'draft',
  start_date DATE,
  end_date DATE,
  collection_form_schema JSONB NOT NULL DEFAULT '{}'::jsonb,
  requires_photos BOOLEAN NOT NULL DEFAULT FALSE,
  min_photos INTEGER NOT NULL DEFAULT 0,
  max_photos INTEGER NOT NULL DEFAULT 10,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT valid_date_range CHECK (end_date IS NULL OR start_date IS NULL OR end_date >= start_date),
  CONSTRAINT valid_photo_range CHECK (min_photos >= 0 AND max_photos >= min_photos),
  CONSTRAINT valid_form_schema CHECK (jsonb_typeof(collection_form_schema) = 'object')
);

CREATE TABLE IF NOT EXISTS project_assignment (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  role assignment_role NOT NULL DEFAULT 'contributor',
  status assignment_status NOT NULL DEFAULT 'pending',
  assigned_date DATE NOT NULL DEFAULT CURRENT_DATE,
  approved_date DATE,
  approved_by_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (project_id, user_id)
);

CREATE TABLE IF NOT EXISTS spatial_feature (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  collected_by_user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  geom GEOMETRY(Geometry, 4326) NOT NULL,
  attributes JSONB NOT NULL DEFAULT '{}'::jsonb,
  status feature_status NOT NULL DEFAULT 'draft',
  collected_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  submitted_at TIMESTAMPTZ,
  reviewed_at TIMESTAMPTZ,
  reviewed_by_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL,
  review_notes TEXT,
  accuracy_meters DOUBLE PRECISION,
  collected_offline BOOLEAN NOT NULL DEFAULT FALSE,
  synced_at TIMESTAMPTZ,
  version INTEGER NOT NULL DEFAULT 1,
  CONSTRAINT valid_feature_accuracy CHECK (accuracy_meters IS NULL OR accuracy_meters >= 0)
);

CREATE TABLE IF NOT EXISTS photo (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  feature_id UUID NOT NULL REFERENCES spatial_feature(id) ON DELETE CASCADE,
  file_path TEXT NOT NULL,
  thumbnail_path TEXT,
  location GEOMETRY(Point, 4326),
  accuracy_meters DOUBLE PRECISION,
  taken_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  exif_data JSONB,
  file_size_bytes BIGINT,
  status photo_status NOT NULL DEFAULT 'pending',
  display_order INTEGER NOT NULL DEFAULT 0,
  uploaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT valid_display_order CHECK (display_order >= 0),
  CONSTRAINT valid_file_size CHECK (file_size_bytes IS NULL OR file_size_bytes > 0),
  CONSTRAINT valid_photo_accuracy CHECK (accuracy_meters IS NULL OR accuracy_meters >= 0)
);

CREATE TABLE IF NOT EXISTS shapefile_export (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  requested_by_user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  requested_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  completed_at TIMESTAMPTZ,
  file_path TEXT,
  feature_count INTEGER,
  export_parameters JSONB NOT NULL DEFAULT '{}'::jsonb,
  status export_status NOT NULL DEFAULT 'pending',
  error_message TEXT,
  file_size_bytes BIGINT,
  CONSTRAINT valid_export_file_size CHECK (file_size_bytes IS NULL OR file_size_bytes > 0)
);

CREATE TABLE IF NOT EXISTS notification (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  type notification_type NOT NULL,
  title VARCHAR(255) NOT NULL,
  message TEXT NOT NULL,
  metadata JSONB,
  is_read BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  read_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS audit_log (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID REFERENCES "user"(id) ON DELETE SET NULL,
  action_type audit_action_type NOT NULL,
  entity_type VARCHAR(50) NOT NULL,
  entity_id UUID NOT NULL,
  old_values JSONB,
  new_values JSONB,
  ip_address INET,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS lebanon_offline_map (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  version VARCHAR(50) UNIQUE NOT NULL,
  zoom_level_min INTEGER NOT NULL,
  zoom_level_max INTEGER NOT NULL,
  downloaded_at TIMESTAMPTZ,
  last_updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  tile_count INTEGER,
  size_bytes BIGINT,
  tile_source VARCHAR(255),
  is_current BOOLEAN NOT NULL DEFAULT FALSE,
  CONSTRAINT valid_zoom_levels CHECK (zoom_level_max >= zoom_level_min AND zoom_level_min >= 0),
  CONSTRAINT valid_tile_count CHECK (tile_count IS NULL OR tile_count > 0),
  CONSTRAINT valid_map_size CHECK (size_bytes IS NULL OR size_bytes > 0)
);
