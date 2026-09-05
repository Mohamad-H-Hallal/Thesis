ALTER TABLE app_support_settings
  ADD COLUMN IF NOT EXISTS hybrid_basemap_enabled BOOLEAN NOT NULL DEFAULT TRUE;

ALTER TABLE lebanon_offline_map
  ADD COLUMN IF NOT EXISTS artifact_reference TEXT,
  ADD COLUMN IF NOT EXISTS artifact_sha256 CHAR(64),
  ADD COLUMN IF NOT EXISTS artifact_content_type TEXT,
  ADD COLUMN IF NOT EXISTS source_acquisition_start DATE,
  ADD COLUMN IF NOT EXISTS source_acquisition_end DATE,
  ADD COLUMN IF NOT EXISTS source_scene_ids TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  ADD COLUMN IF NOT EXISTS source_terms_url TEXT,
  ADD COLUMN IF NOT EXISTS source_attribution TEXT,
  ADD COLUMN IF NOT EXISTS source_resolution_meters NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS processing_manifest JSONB NOT NULL DEFAULT '{}'::JSONB,
  ADD COLUMN IF NOT EXISTS published_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS published_by_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL;

ALTER TABLE lebanon_offline_map
  DROP CONSTRAINT IF EXISTS chk_offline_map_artifact_reference,
  DROP CONSTRAINT IF EXISTS chk_offline_map_artifact_sha256,
  DROP CONSTRAINT IF EXISTS chk_offline_map_source_terms,
  DROP CONSTRAINT IF EXISTS chk_offline_map_processing_manifest,
  DROP CONSTRAINT IF EXISTS chk_offline_map_publication;

UPDATE lebanon_offline_map
SET is_current = FALSE
WHERE is_current = TRUE
  AND tile_source IS DISTINCT FROM 'copernicus_sentinel2_osm_labels';

ALTER TABLE lebanon_offline_map
  ADD CONSTRAINT chk_offline_map_artifact_reference CHECK (
    artifact_reference IS NULL OR artifact_reference ~ '^storage://offline/[A-Za-z0-9._/-]+$'
  ),
  ADD CONSTRAINT chk_offline_map_artifact_sha256 CHECK (
    artifact_sha256 IS NULL OR artifact_sha256 ~ '^[a-f0-9]{64}$'
  ),
  ADD CONSTRAINT chk_offline_map_source_terms CHECK (
    source_terms_url IS NULL OR source_terms_url ~ '^https://[^[:space:]]+$'
  ),
  ADD CONSTRAINT chk_offline_map_processing_manifest CHECK (
    jsonb_typeof(processing_manifest) = 'object'
  ),
  ADD CONSTRAINT chk_offline_map_publication CHECK (
    is_current = FALSE OR (
      tile_source = 'copernicus_sentinel2_osm_labels'
      AND artifact_reference IS NOT NULL
      AND artifact_sha256 IS NOT NULL
      AND artifact_content_type = 'application/zip'
      AND source_acquisition_start IS NOT NULL
      AND source_acquisition_end IS NOT NULL
      AND cardinality(source_scene_ids) > 0
      AND source_terms_url IS NOT NULL
      AND source_attribution IS NOT NULL
      AND source_resolution_meters IS NOT NULL
      AND processing_manifest <> '{}'::JSONB
      AND published_at IS NOT NULL
    )
  );

CREATE INDEX IF NOT EXISTS idx_offline_map_published_current
  ON lebanon_offline_map (is_current, published_at DESC)
  WHERE artifact_reference IS NOT NULL;

INSERT INTO data_source_license (
  source_key,
  provider_name,
  dataset_name,
  source_type,
  terms_url,
  license_name,
  attribution_text,
  metadata
)
VALUES (
  'copernicus_sentinel2_osm_labels',
  'European Union Copernicus Sentinel-2 and OpenStreetMap contributors',
  'TerraLeb Lebanon offline orientation basemap',
  'imagery',
  'https://dataspace.copernicus.eu/terms-and-conditions',
  'Copernicus data terms and applicable OpenStreetMap attribution requirements',
  'Contains modified Copernicus Sentinel-2 data and © OpenStreetMap contributors',
  '{"package_evidence_required":true,"public_osm_tile_scraping":false,"nominal_imagery_resolution_meters":10}'::JSONB
)
ON CONFLICT (source_key) DO UPDATE
SET provider_name = EXCLUDED.provider_name,
    dataset_name = EXCLUDED.dataset_name,
    source_type = EXCLUDED.source_type,
    terms_url = EXCLUDED.terms_url,
    license_name = EXCLUDED.license_name,
    attribution_text = EXCLUDED.attribution_text,
    metadata = data_source_license.metadata || EXCLUDED.metadata,
    updated_at = CURRENT_TIMESTAMP;

COMMENT ON COLUMN app_support_settings.hybrid_basemap_enabled IS
  'Protected-super-admin kill switch. Environment authorization and provider credentials remain separate gates.';
COMMENT ON COLUMN lebanon_offline_map.artifact_reference IS
  'Private provider-neutral TerraLeb package reference; never a public provider tile URL.';
