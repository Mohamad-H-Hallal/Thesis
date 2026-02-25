-- Phase 3 geospatial performance baseline checks
-- Run after migrations and with representative data volume.

EXPLAIN (ANALYZE, BUFFERS)
SELECT sf.id
FROM spatial_feature sf
WHERE sf.geom && ST_MakeEnvelope(35.0, 33.0, 36.0, 34.5, 4326)
  AND sf.status = 'approved'
ORDER BY sf.collected_at DESC
LIMIT 100 OFFSET 0;

EXPLAIN (ANALYZE, BUFFERS)
SELECT sf.id
FROM spatial_feature sf
WHERE ST_DWithin(
  sf.geom::geography,
  ST_SetSRID(ST_MakePoint(35.5, 33.9), 4326)::geography,
  1000
)
AND sf.status = 'approved'
ORDER BY sf.collected_at DESC
LIMIT 50;
