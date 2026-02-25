INSERT INTO project_category (name, description)
VALUES
  ('Agriculture', 'General agricultural mapping projects'),
  ('Fruit Trees', 'Fruit tree survey and monitoring')
ON CONFLICT (name) DO NOTHING;

INSERT INTO "user" (email, password_hash, full_name, role)
VALUES
  ('admin@gis.local', '$2b$12$.L6M7JWBqPduQjIrz7F8A.6ZZEmef7jP0n6hH4NN4xub90QhM2GGW', 'System Admin', 'admin')
ON CONFLICT (email) DO NOTHING;

INSERT INTO lebanon_offline_map (version, zoom_level_min, zoom_level_max, tile_source, is_current)
VALUES ('v1-base', 8, 18, 'osm', true)
ON CONFLICT (version) DO NOTHING;
