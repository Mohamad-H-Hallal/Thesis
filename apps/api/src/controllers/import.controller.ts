import type { Request, Response } from 'express';
import path from 'node:path';
import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import vm from 'node:vm';

const AdmZip = require('adm-zip');
const { DOMParser } = require('@xmldom/xmldom');
const toGeoJSON = require('@tmcw/togeojson');
const { query, transaction } = require('../config/database');
const { AppError } = require('../middleware/error');
const logger = require('../utils/logger');
import { validateEnv } from '../config/env';
import { sanitizeManagedFeatureAttributes } from '../lib/featureAttributes';
import { createNotification, isProtectedSuperAdminEmail } from '../lib/userWorkflow';
import { synchronizeProjectStatuses } from '../lib/projectLifecycle';

const LEBANON_BOUNDS = {
  minLon: 35.094,
  minLat: 33.045,
  maxLon: 36.645,
  maxLat: 34.695,
};
const LEBANON_BUFFER_DEGREES = 0.2;
const IMPORT_DETAIL_PREVIEW_LIMIT = 20;
const IMPORT_QUICK_MAP_PREVIEW_LIMIT = 500;
const IMPORT_QUICK_MAP_SIMPLIFY_TOLERANCE_DEGREES = 0.00005;
const IMPORT_MAP_TILE_LOW_ZOOM_LIMIT = 300;
const IMPORT_MAP_TILE_HIGH_ZOOM_LIMIT = 3500;
const IMPORT_MAP_LAYER_CACHE_MAX_ENTRIES = Number.parseInt(
  process.env.IMPORT_MAP_LAYER_CACHE_MAX_ENTRIES ?? '512',
  10,
);
const IMPORT_MAP_LAYER_CACHE_TTL_MS = Number.parseInt(
  process.env.IMPORT_MAP_LAYER_CACHE_TTL_MS ?? '60000',
  10,
);
const PAGE_MAX_LIMIT = 200;
const IMPORT_INSERT_BATCH_SIZE = 250;
const SUPPORTED_SPATIAL_FEATURE_GEOMETRY_TYPES = [
  'POINT',
  'MULTIPOINT',
  'LINESTRING',
  'MULTILINESTRING',
  'POLYGON',
  'MULTIPOLYGON',
];
const IMPORT_PROCESSING_POLL_INTERVAL_MS = Number.parseInt(
  process.env.IMPORT_PROCESSING_POLL_INTERVAL_MS ??
    (process.env.NODE_ENV === 'test' ? '250' : '2000'),
  10,
);
const IMPORT_PROCESSING_STALE_AFTER_MS = Number.parseInt(
  process.env.IMPORT_PROCESSING_STALE_AFTER_MS ?? String(5 * 60 * 1000),
  10,
);

const normalizeMapZoom = (zoomRaw: unknown, fallback = 11): number => {
  const parsed = Number.parseFloat(String(zoomRaw ?? fallback));
  if (!Number.isFinite(parsed)) {
    return fallback;
  }
  return Math.max(0, Math.min(parsed, 24));
};

const mapSimplifyTolerance = (zoom: number): number => {
  if (zoom >= 13.5) {
    return 0;
  }
  if (zoom >= 12.5) {
    return 0.00008;
  }
  if (zoom >= 11.5) {
    return 0.0002;
  }
  if (zoom >= 10.5) {
    return 0.0005;
  }
  return 0;
};

const mapClusterCellSizeDegrees = (zoom: number): number => {
  if (zoom < 7.5) {
    return 0.1;
  }
  if (zoom < 8.5) {
    return 0.07;
  }
  if (zoom < 9.5) {
    return 0.045;
  }
  if (zoom < 10.5) {
    return 0.028;
  }
  return 0.02;
};

const parseViewportBounds = (input: {
  minLon: unknown;
  minLat: unknown;
  maxLon: unknown;
  maxLat: unknown;
}) => {
  const minLon = Number.parseFloat(String(input.minLon ?? LEBANON_BOUNDS.minLon));
  const minLat = Number.parseFloat(String(input.minLat ?? LEBANON_BOUNDS.minLat));
  const maxLon = Number.parseFloat(String(input.maxLon ?? LEBANON_BOUNDS.maxLon));
  const maxLat = Number.parseFloat(String(input.maxLat ?? LEBANON_BOUNDS.maxLat));

  if (
    !Number.isFinite(minLon) ||
    !Number.isFinite(minLat) ||
    !Number.isFinite(maxLon) ||
    !Number.isFinite(maxLat)
  ) {
    return {
      minLon: LEBANON_BOUNDS.minLon,
      minLat: LEBANON_BOUNDS.minLat,
      maxLon: LEBANON_BOUNDS.maxLon,
      maxLat: LEBANON_BOUNDS.maxLat,
    };
  }

  if (minLon >= maxLon || minLat >= maxLat) {
    return {
      minLon: LEBANON_BOUNDS.minLon,
      minLat: LEBANON_BOUNDS.minLat,
      maxLon: LEBANON_BOUNDS.maxLon,
      maxLat: LEBANON_BOUNDS.maxLat,
    };
  }

  return { minLon, minLat, maxLon, maxLat };
};

const getTileBounds = (zRaw: unknown, xRaw: unknown, yRaw: unknown) => {
  const z = Math.max(0, Math.min(22, Number.parseInt(String(zRaw ?? '0'), 10) || 0));
  const tilesPerAxis = 2 ** z;
  const x = Math.max(0, Math.min(tilesPerAxis - 1, Number.parseInt(String(xRaw ?? '0'), 10) || 0));
  const y = Math.max(0, Math.min(tilesPerAxis - 1, Number.parseInt(String(yRaw ?? '0'), 10) || 0));

  const lonFromX = (tileX: number): number => (tileX / tilesPerAxis) * 360 - 180;
  const latFromY = (tileY: number): number => {
    const mercator = Math.PI * (1 - (2 * tileY) / tilesPerAxis);
    return (180 / Math.PI) * Math.atan(Math.sinh(mercator));
  };

  return {
    minLon: lonFromX(x),
    minLat: latFromY(y + 1),
    maxLon: lonFromX(x + 1),
    maxLat: latFromY(y),
  };
};

const mapRenderGeometrySql = (geometrySql: string, zoom: number, simplifyTolerance: number) => {
  const zoomLiteral = Number(zoom.toFixed(2));
  const toleranceLiteral = Number(simplifyTolerance.toFixed(8));
  return `
  CASE
    WHEN ${zoomLiteral} < 10.5
      AND GeometryType(${geometrySql}) IN ('POLYGON', 'MULTIPOLYGON')
      THEN ST_AsGeoJSON(ST_PointOnSurface(${geometrySql}))
    WHEN ${zoomLiteral} < 10.5
      AND GeometryType(${geometrySql}) IN ('LINESTRING', 'MULTILINESTRING')
      THEN ST_AsGeoJSON(ST_Centroid(${geometrySql}))
    WHEN ${toleranceLiteral} > 0
      AND GeometryType(${geometrySql}) IN ('POLYGON', 'MULTIPOLYGON', 'LINESTRING', 'MULTILINESTRING')
      THEN ST_AsGeoJSON(ST_SimplifyPreserveTopology(${geometrySql}, ${toleranceLiteral}))
    ELSE ST_AsGeoJSON(${geometrySql})
  END
`;
};

type ImportFileType = 'geojson' | 'shapefile_zip' | 'kml' | 'kmz' | 'csv' | 'xlsx';
type GeometryType =
  | 'Point'
  | 'MultiPoint'
  | 'LineString'
  | 'MultiLineString'
  | 'Polygon'
  | 'MultiPolygon';
type PlainObject = Record<string, unknown>;

type CollectionFormFieldForImport = {
  key: string | null;
  label: string | null;
  displayName: string;
  type: ImportSchemaFieldType;
  required: boolean;
  options: string[];
  identifiers: string[];
  min: number | null;
  max: number | null;
};

type ImportSchemaFieldType =
  | 'text'
  | 'select'
  | 'multiselect'
  | 'number'
  | 'integer'
  | 'boolean'
  | 'date'
  | 'datetime'
  | 'file'
  | 'unknown';

type ImportReviewFilters = {
  status?: string;
  issue?: string;
  search?: string;
  geometry_type?: string;
  feature_type?: string;
};

type ParsedImportPayload = {
  fileType: ImportFileType;
  sourceCrs: string | null;
  sourceLayerName: string | null;
  features: NormalizedIncomingFeature[];
  fileMetadata: Record<string, unknown>;
};

type NormalizedIncomingFeature = {
  sourceIndex: number;
  sourceIdentifier: string | null;
  sourceFeatureName: string | null;
  displayTitle: string;
  geometryType: GeometryType | null;
  geometry: PlainObject | null;
  attributes: Record<string, unknown>;
};

type ImportValidationResult = {
  geometryType: GeometryType | null;
  geometryJson: string | null;
  attributes: Record<string, unknown>;
  warnings: string[];
  errors: string[];
  report: Record<string, unknown>;
  duplicateFeatureId: string | null;
};

type ImportJobRow = {
  id: string;
  project_id: string;
  project_name: string;
  uploaded_by_user_id: string;
  uploaded_by_name: string;
  reviewed_by_user_id: string | null;
  reviewed_by_name: string | null;
  duplicate_of_import_job_id: string | null;
  original_filename: string;
  stored_filename: string;
  file_path: string;
  file_size_bytes: number;
  file_checksum_sha256: string;
  file_type: ImportFileType;
  source_crs: string | null;
  source_layer_name: string | null;
  status: string;
  geometry_count: number;
  pending_feature_count: number;
  approved_feature_count: number;
  rejected_feature_count: number;
  failed_feature_count: number;
  warning_count: number;
  error_count: number;
  geometry_types: string[];
  file_metadata: Record<string, unknown>;
  validation_summary: Record<string, unknown>;
  processing_message: string | null;
  rejection_reason: string | null;
  uploaded_at: string;
  processed_at: string | null;
  reviewed_at: string | null;
  created_at: string;
  updated_at: string;
};

type ImportJobAccessRow = ImportJobRow & {
  uploaded_by_email: string;
  uploaded_by_role: string;
  project_collection_form_schema?: Record<string, unknown>;
};

type ImportFeatureRow = {
  id: string;
  import_job_id: string;
  source_index: number;
  source_identifier: string | null;
  display_title: string;
  source_feature_name: string | null;
  geometry_type: string | null;
  geometry: string | null;
  attributes: Record<string, unknown>;
  summary_attributes?: Record<string, unknown>;
  attribute_count?: number;
  status: string;
  validation_warnings: unknown[];
  validation_errors: unknown[];
  validation_report: Record<string, unknown>;
  duplicate_feature_id: string | null;
  approved_feature_id: string | null;
  reviewed_by_user_id: string | null;
  reviewed_by_name: string | null;
  reviewed_at: string | null;
  approved_at: string | null;
  review_reason: string | null;
  is_summary?: boolean;
  is_aggregate?: boolean;
  cluster_count?: number;
  created_at: string;
  updated_at: string;
};

type ImportCommentRow = {
  id: string;
  import_job_id: string;
  import_feature_id: string | null;
  feature_display_title: string | null;
  author_user_id: string;
  author_name: string;
  author_role: string;
  comment_text: string;
  created_at: string;
};

type ImportMapLayerData = {
  staged_features: ReturnType<typeof mapImportMapFeatureRow>[];
  approved_project_features: ReturnType<typeof mapImportMapProjectFeatureRow>[];
};

type ImportQuickMapPreview = {
  total_feature_count: number;
  geometry_feature_count: number;
  rendered_feature_count: number;
  is_clustered: boolean;
  bounds: {
    min_lon: number;
    min_lat: number;
    max_lon: number;
    max_lat: number;
  } | null;
  status_counts: Record<string, number>;
  features: ReturnType<typeof mapImportMapFeatureRow>[];
};

type StagedImportInsertRow = {
  importJobId: string;
  sourceIndex: number;
  sourceIdentifier: string | null;
  displayTitle: string;
  sourceFeatureName: string | null;
  geometryType: GeometryType | null;
  geometryJson: string | null;
  attributes: Record<string, unknown>;
  status: 'pending_review' | 'failed';
  validationWarnings: string[];
  validationErrors: string[];
  validationReport: Record<string, unknown>;
  duplicateFeatureId: string | null;
};

const env = validateEnv();
let importProcessingLoop: NodeJS.Timeout | null = null;
let importProcessingDrainScheduled = false;
let importProcessingDrainRunning = false;
let importProcessingDrainTimeout: NodeJS.Timeout | null = null;
const importMapLayerCache = new Map<string, { expiresAt: number; data: ImportMapLayerData }>();

const getPagination = (pageRaw: unknown, limitRaw: unknown) => {
  const page = Math.max(1, Number.parseInt(String(pageRaw ?? '1'), 10) || 1);
  const requestedLimit = Math.max(1, Number.parseInt(String(limitRaw ?? '50'), 10) || 50);
  const limit = Math.min(requestedLimit, PAGE_MAX_LIMIT);
  return {
    page,
    limit,
    offset: (page - 1) * limit,
  };
};

const importMapLayerCacheKey = ({
  importId,
  projectId,
  bounds,
  zoom,
  cacheVersion,
}: {
  importId: string;
  projectId: string;
  bounds: { minLon: number; minLat: number; maxLon: number; maxLat: number };
  zoom: number;
  cacheVersion: string | null;
}): string =>
  [
    importId,
    projectId,
    cacheVersion ?? 'no-version',
    bounds.minLon.toFixed(6),
    bounds.minLat.toFixed(6),
    bounds.maxLon.toFixed(6),
    bounds.maxLat.toFixed(6),
    zoom.toFixed(2),
  ].join(':');

const getCachedImportMapLayer = (key: string): ImportMapLayerData | null => {
  const cached = importMapLayerCache.get(key);
  if (!cached) {
    return null;
  }
  if (cached.expiresAt <= Date.now()) {
    importMapLayerCache.delete(key);
    return null;
  }
  importMapLayerCache.delete(key);
  importMapLayerCache.set(key, cached);
  return cached.data;
};

const rememberImportMapLayer = (key: string, data: ImportMapLayerData): void => {
  importMapLayerCache.set(key, {
    data,
    expiresAt: Date.now() + IMPORT_MAP_LAYER_CACHE_TTL_MS,
  });
  while (importMapLayerCache.size > IMPORT_MAP_LAYER_CACHE_MAX_ENTRIES) {
    const oldestKey = importMapLayerCache.keys().next().value;
    if (!oldestKey) {
      break;
    }
    importMapLayerCache.delete(oldestKey);
  }
};

const inferImportFileType = (filename: string): ImportFileType => {
  const lower = filename.trim().toLowerCase();
  if (lower.endsWith('.geojson') || lower.endsWith('.json')) {
    return 'geojson';
  }
  if (lower.endsWith('.kml')) {
    return 'kml';
  }
  if (lower.endsWith('.kmz')) {
    return 'kmz';
  }
  if (lower.endsWith('.zip')) {
    return 'shapefile_zip';
  }
  if (lower.endsWith('.csv')) {
    return 'csv';
  }
  if (lower.endsWith('.xlsx')) {
    return 'xlsx';
  }
  throw new AppError(
    'Unsupported GIS file type. Upload GeoJSON, zipped shapefile, KML, KMZ, CSV, or Excel .xlsx.',
    400,
  );
};

const sha256File = async (filePath: string): Promise<string> => {
  const buffer = await fs.readFile(filePath);
  return crypto.createHash('sha256').update(buffer).digest('hex');
};

const ensureAttributesObject = (attributes: unknown): Record<string, unknown> => {
  if (!attributes || typeof attributes !== 'object' || Array.isArray(attributes)) {
    return {};
  }
  return Object.fromEntries(Object.entries(attributes as PlainObject));
};

const PHOTO_REFERENCE_KEYS = new Set([
  'photo',
  'photos',
  'photourl',
  'photourls',
  'image',
  'imageurl',
  'imageurls',
  'picture',
  'pictureurl',
  'attachment',
  'attachments',
  'media',
  'mediaurl',
  'file',
  'filepath',
]);

const sanitizeImportedText = (value: string): string => {
  const withoutControlCharacters = Array.from(value)
    .map((character) => {
      const code = character.charCodeAt(0);
      return (code >= 0 && code <= 8) ||
        code === 11 ||
        code === 12 ||
        (code >= 14 && code <= 31) ||
        code === 127
        ? ' '
        : character;
    })
    .join('')
    .trim();
  const csvSafe = /^[=+\-@]/.test(withoutControlCharacters)
    ? `'${withoutControlCharacters}`
    : withoutControlCharacters;
  return csvSafe.slice(0, 4096);
};

const sanitizePhotoReferenceValue = (value: unknown): unknown => {
  if (typeof value === 'string') {
    return sanitizeImportedText(value);
  }
  if (Array.isArray(value)) {
    return value.map(sanitizePhotoReferenceValue);
  }
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).map(([key, nestedValue]) => [
        sanitizeImportedText(key),
        sanitizePhotoReferenceValue(nestedValue),
      ]),
    );
  }
  return value;
};

const sanitizeImportedAttributes = (
  attributes: Record<string, unknown>,
): Record<string, unknown> => {
  const sanitized: Record<string, unknown> = {};
  for (const [rawKey, value] of Object.entries(attributes)) {
    const key = sanitizeImportedText(rawKey);
    if (!key) {
      continue;
    }
    const normalizedKey = normalizeHeaderKey(key);
    sanitized[key] = PHOTO_REFERENCE_KEYS.has(normalizedKey)
      ? sanitizePhotoReferenceValue(value)
      : value;
  }
  return sanitized;
};

const normalizeImportedAttributeAliases = (
  attributes: Record<string, unknown>,
): Record<string, unknown> => {
  if (attributes.feature_type === undefined) {
    const featureTypeAlias = Object.keys(attributes).find((key) =>
      ['featuretyp', 'featurety'].includes(normalizeHeaderKey(key)),
    );
    if (featureTypeAlias) {
      attributes.feature_type = attributes[featureTypeAlias];
    }
  }
  return attributes;
};

const friendlyInvalidGeometryMessage = (reason: unknown, geometryType?: string | null): string => {
  const rawReason = typeof reason === 'string' ? reason.trim() : '';
  const normalizedReason = rawReason.toLowerCase();
  if (
    normalizedReason.includes('ring self-intersection') ||
    normalizedReason.includes('self-intersection')
  ) {
    return 'Invalid polygon geometry: ring self-intersection. Fix the geometry in GIS software or exclude this feature.';
  }
  if (!rawReason) {
    return 'Geometry is invalid.';
  }
  if (rawReason.toLowerCase().startsWith('invalid geometry')) {
    return rawReason;
  }
  const suffix = rawReason.endsWith('.') ? rawReason : `${rawReason}.`;
  const prefix =
    geometryType === 'Polygon' || geometryType === 'MultiPolygon'
      ? 'Invalid polygon geometry'
      : 'Invalid geometry';
  return `${prefix}: ${suffix}`;
};

const isPosition = (value: unknown): value is [number, number] => {
  if (!Array.isArray(value) || value.length < 2) {
    return false;
  }

  const lon = Number(value[0]);
  const lat = Number(value[1]);

  return Number.isFinite(lon) && Number.isFinite(lat);
};

const validateLinearRing = (ring: unknown): boolean => {
  if (!Array.isArray(ring) || ring.length < 4 || !ring.every(isPosition)) {
    return false;
  }

  const first = ring[0] as [number, number];
  const last = ring[ring.length - 1] as [number, number];
  return first[0] === last[0] && first[1] === last[1];
};

const validateCoordinates = (type: GeometryType, coordinates: unknown): boolean => {
  switch (type) {
    case 'Point':
      return isPosition(coordinates);
    case 'MultiPoint':
      return Array.isArray(coordinates) && coordinates.length > 0 && coordinates.every(isPosition);
    case 'LineString':
      return Array.isArray(coordinates) && coordinates.length >= 2 && coordinates.every(isPosition);
    case 'MultiLineString':
      return (
        Array.isArray(coordinates) &&
        coordinates.length > 0 &&
        coordinates.every(
          (line) => Array.isArray(line) && line.length >= 2 && line.every(isPosition),
        )
      );
    case 'Polygon':
      return (
        Array.isArray(coordinates) &&
        coordinates.length > 0 &&
        coordinates.every(validateLinearRing)
      );
    case 'MultiPolygon':
      return (
        Array.isArray(coordinates) &&
        coordinates.length > 0 &&
        coordinates.every(
          (polygon) =>
            Array.isArray(polygon) && polygon.length > 0 && polygon.every(validateLinearRing),
        )
      );
  }
};

const mercatorToWgs84 = ([x, y]: [number, number]): [number, number] => {
  const lon = (x / 20037508.34) * 180;
  const lat = (Math.atan(Math.exp((y / 20037508.34) * Math.PI)) * 360) / Math.PI - 90;
  return [Number(lon.toFixed(8)), Number(lat.toFixed(8))];
};

const transformMultiPointCoordinates = (
  coordinates: Array<[number, number]>,
  projector: (value: [number, number]) => [number, number],
) => coordinates.map(projector);

const transformMultiLineCoordinates = (
  coordinates: Array<Array<[number, number]>>,
  projector: (value: [number, number]) => [number, number],
) => coordinates.map((line) => line.map(projector));

const transformMultiPolygonCoordinates = (
  coordinates: Array<Array<Array<[number, number]>>>,
  projector: (value: [number, number]) => [number, number],
) => coordinates.map((polygon) => polygon.map((ring) => ring.map(projector)));

const transformGeometryCoordinates = (
  geometryType: GeometryType,
  coordinates: unknown,
  projector: (value: [number, number]) => [number, number],
): unknown => {
  switch (geometryType) {
    case 'Point':
      return projector(coordinates as [number, number]);
    case 'MultiPoint':
      return transformMultiPointCoordinates(coordinates as Array<[number, number]>, projector);
    case 'LineString':
      return transformMultiPointCoordinates(coordinates as Array<[number, number]>, projector);
    case 'MultiLineString':
      return transformMultiLineCoordinates(
        coordinates as Array<Array<[number, number]>>,
        projector,
      );
    case 'Polygon':
      return transformMultiLineCoordinates(
        coordinates as Array<Array<[number, number]>>,
        projector,
      );
    case 'MultiPolygon':
      return transformMultiPolygonCoordinates(
        coordinates as Array<Array<Array<[number, number]>>>,
        projector,
      );
  }
};

const stripPositionDimensions = (position: unknown): unknown => {
  if (!Array.isArray(position) || position.length < 2) {
    return position;
  }
  return [Number(position[0]), Number(position[1])];
};

const stripGeometryCoordinateDimensions = (
  geometryType: GeometryType,
  coordinates: unknown,
): unknown => {
  switch (geometryType) {
    case 'Point':
      return stripPositionDimensions(coordinates);
    case 'MultiPoint':
    case 'LineString':
      return Array.isArray(coordinates) ? coordinates.map(stripPositionDimensions) : coordinates;
    case 'MultiLineString':
    case 'Polygon':
      return Array.isArray(coordinates)
        ? coordinates.map((line) =>
            Array.isArray(line) ? line.map(stripPositionDimensions) : line,
          )
        : coordinates;
    case 'MultiPolygon':
      return Array.isArray(coordinates)
        ? coordinates.map((polygon) =>
            Array.isArray(polygon)
              ? polygon.map((ring) =>
                  Array.isArray(ring) ? ring.map(stripPositionDimensions) : ring,
                )
              : polygon,
          )
        : coordinates;
  }
};

const normalizeCrsName = (raw: unknown): string | null => {
  const normalized = String(raw ?? '').trim();
  return normalized.length > 0 ? normalized.toUpperCase() : null;
};

const SUPPORTED_GEOJSON_CRS = new Set([
  'EPSG:4326',
  'URN:OGC:DEF:CRS:EPSG::4326',
  'OGC:CRS84',
  'URN:OGC:DEF:CRS:OGC:1.3:CRS84',
  'CRS84',
  'EPSG:3857',
  'URN:OGC:DEF:CRS:EPSG::3857',
]);

const assertSupportedGeoJsonCrs = (sourceCrs: string | null): void => {
  if (!sourceCrs) {
    return;
  }

  if (!SUPPORTED_GEOJSON_CRS.has(sourceCrs)) {
    throw new AppError(
      `Unsupported coordinate reference system "${sourceCrs}". Use WGS84 (EPSG:4326 / CRS84) or Web Mercator (EPSG:3857).`,
      400,
    );
  }
};

const normalizeGeoJsonGeometry = (
  geometry: PlainObject | null | undefined,
  sourceCrs: string | null,
): { geometryType: GeometryType | null; geometry: PlainObject | null } => {
  if (!geometry) {
    return { geometryType: null, geometry: null };
  }

  const geometryType = geometry.type as GeometryType | undefined;
  if (
    !geometryType ||
    !['Point', 'MultiPoint', 'LineString', 'MultiLineString', 'Polygon', 'MultiPolygon'].includes(
      geometryType,
    )
  ) {
    return {
      geometryType: null,
      geometry: null,
    };
  }

  let coordinates = stripGeometryCoordinateDimensions(geometryType, geometry.coordinates);
  if (sourceCrs === 'EPSG:3857' || sourceCrs === 'URN:OGC:DEF:CRS:EPSG::3857') {
    coordinates = transformGeometryCoordinates(geometryType, coordinates, mercatorToWgs84);
  }

  if (!validateCoordinates(geometryType, coordinates)) {
    return {
      geometryType,
      geometry: null,
    };
  }

  return {
    geometryType,
    geometry: {
      type: geometryType,
      coordinates,
    },
  };
};

const featureTitleFromAttributes = (
  attributes: Record<string, unknown>,
  geometryType: GeometryType | null,
  sourceIndex: number,
): string => {
  const preferredKeys = [
    'name',
    'title',
    'label',
    'feature_name',
    'site_name',
    'object_name',
    'id',
  ];
  for (const key of preferredKeys) {
    const value = attributes[key];
    if (typeof value === 'string' && value.trim().length > 0) {
      return value.trim();
    }
  }

  const featureType = attributes['feature_type'];
  if (typeof featureType === 'string' && featureType.trim().length > 0) {
    return featureType.trim();
  }

  switch (geometryType) {
    case 'Point':
      return `Point feature ${sourceIndex + 1}`;
    case 'MultiPoint':
      return `Point feature ${sourceIndex + 1}`;
    case 'LineString':
      return `Line feature ${sourceIndex + 1}`;
    case 'MultiLineString':
      return `Line feature ${sourceIndex + 1}`;
    case 'Polygon':
      return `Polygon feature ${sourceIndex + 1}`;
    case 'MultiPolygon':
      return `Polygon feature ${sourceIndex + 1}`;
    default:
      return `Imported feature ${sourceIndex + 1}`;
  }
};

const parseGeoJson = async (filePath: string): Promise<ParsedImportPayload> => {
  const raw = await fs.readFile(filePath, 'utf8');
  let parsed: any;
  try {
    parsed = JSON.parse(raw);
  } catch (_error) {
    throw new AppError('The GeoJSON file could not be parsed.', 400);
  }

  const sourceCrs = normalizeCrsName(parsed?.crs?.properties?.name);
  assertSupportedGeoJsonCrs(sourceCrs);
  let features: any[] = [];
  if (parsed?.type === 'FeatureCollection' && Array.isArray(parsed.features)) {
    features = parsed.features;
  } else if (parsed?.type === 'Feature') {
    features = [parsed];
  } else {
    throw new AppError('GeoJSON must be a Feature or FeatureCollection.', 400);
  }

  const normalized = features.map((feature, index) => {
    const properties = normalizeImportedAttributeAliases(
      sanitizeImportedAttributes(ensureAttributesObject(feature?.properties)),
    );
    const geometryResult = normalizeGeoJsonGeometry(
      feature?.geometry as PlainObject | null,
      sourceCrs,
    );
    return {
      sourceIndex: index,
      sourceIdentifier: feature?.id == null ? null : String(feature.id),
      sourceFeatureName: typeof properties.name === 'string' ? properties.name : null,
      displayTitle: featureTitleFromAttributes(properties, geometryResult.geometryType, index),
      geometryType: geometryResult.geometryType,
      geometry: geometryResult.geometry,
      attributes: properties,
    } satisfies NormalizedIncomingFeature;
  });

  return {
    fileType: 'geojson',
    sourceCrs: sourceCrs ?? 'EPSG:4326',
    sourceLayerName: null,
    features: normalized,
    fileMetadata: {
      feature_collection_type: parsed?.type,
      feature_count: normalized.length,
    },
  };
};

const flattenShpParsed = (parsed: any): { layerName: string | null; features: any[] } => {
  if (parsed?.type === 'FeatureCollection' && Array.isArray(parsed.features)) {
    return { layerName: null, features: parsed.features };
  }

  if (Array.isArray(parsed)) {
    return {
      layerName: null,
      features: parsed.flatMap((entry) => (Array.isArray(entry?.features) ? entry.features : [])),
    };
  }

  if (parsed && typeof parsed === 'object') {
    const layerEntries = Object.entries(parsed).filter(
      ([, value]) => (value as any)?.type === 'FeatureCollection',
    );
    return {
      layerName: layerEntries[0]?.[0] ?? null,
      features: layerEntries.flatMap(([, value]) => (value as any).features ?? []),
    };
  }

  return { layerName: null, features: [] };
};

let cachedShapefileParser: ((buffer: Buffer) => Promise<any>) | null = null;

const loadShapefileParser = async (): Promise<(buffer: Buffer) => Promise<any>> => {
  if (cachedShapefileParser) {
    return cachedShapefileParser;
  }

  const bundlePath = require.resolve('shpjs');
  const source = await fs.readFile(bundlePath, 'utf8');
  const sandbox: Record<string, unknown> = {
    module: { exports: {} },
    exports: {},
    self: globalThis,
    TextDecoder,
    TextEncoder,
    DecompressionStream: (globalThis as typeof globalThis & { DecompressionStream?: unknown })
      .DecompressionStream,
    console,
  };

  vm.runInNewContext(source, sandbox, { filename: bundlePath });

  const parser = (sandbox.module as { exports?: unknown }).exports;
  if (typeof parser !== 'function') {
    throw new Error('Shapefile parser could not be loaded.');
  }

  cachedShapefileParser = parser as (buffer: Buffer) => Promise<any>;
  return cachedShapefileParser;
};

const parseShapefileZip = async (filePath: string): Promise<ParsedImportPayload> => {
  const buffer = await fs.readFile(filePath);
  let zip: any;
  try {
    zip = new AdmZip(buffer);
  } catch (_error) {
    throw new AppError(
      'The Shapefile ZIP could not be read. Upload a valid zipped shapefile.',
      400,
    );
  }
  const entries = zip.getEntries().map((entry: any) => entry.entryName.toLowerCase());
  const hasShp = entries.some((entry: string) => entry.endsWith('.shp'));
  const hasShx = entries.some((entry: string) => entry.endsWith('.shx'));
  const hasDbf = entries.some((entry: string) => entry.endsWith('.dbf'));
  if (!hasShp || !hasShx || !hasDbf) {
    throw new AppError('A zipped shapefile must include .shp, .shx, and .dbf files.', 400);
  }

  const parseShapefile = await loadShapefileParser();
  const parsed = await parseShapefile(buffer);
  const flattened = flattenShpParsed(parsed);
  const normalized = flattened.features.map((feature: any, index: number) => {
    const properties = normalizeImportedAttributeAliases(
      sanitizeImportedAttributes(ensureAttributesObject(feature?.properties)),
    );
    const geometryResult = normalizeGeoJsonGeometry(
      feature?.geometry as PlainObject | null,
      'EPSG:4326',
    );
    return {
      sourceIndex: index,
      sourceIdentifier: feature?.id == null ? null : String(feature.id),
      sourceFeatureName: typeof properties.name === 'string' ? properties.name : null,
      displayTitle: featureTitleFromAttributes(properties, geometryResult.geometryType, index),
      geometryType: geometryResult.geometryType,
      geometry: geometryResult.geometry,
      attributes: properties,
    } satisfies NormalizedIncomingFeature;
  });

  const layerName = flattened.layerName ?? path.basename(filePath, path.extname(filePath));
  const hasPrj = entries.some((entry: string) => entry.endsWith('.prj'));

  return {
    fileType: 'shapefile_zip',
    sourceCrs: hasPrj ? 'Derived from shapefile .prj / normalized to EPSG:4326' : 'EPSG:4326',
    sourceLayerName: layerName,
    features: normalized,
    fileMetadata: {
      archive_entries: entries.length,
      feature_count: normalized.length,
      has_prj: hasPrj,
    },
  };
};

const parseKmlDocument = (xml: string, fileType: ImportFileType): ParsedImportPayload => {
  let document: any;
  try {
    document = new DOMParser().parseFromString(xml, 'text/xml');
  } catch (_error) {
    throw new AppError('The KML file could not be parsed.', 400);
  }
  if (document.getElementsByTagName('parsererror')?.length > 0) {
    throw new AppError('The KML file could not be parsed.', 400);
  }
  let featureCollection: any;
  try {
    featureCollection = toGeoJSON.kml(document);
  } catch (_error) {
    throw new AppError('The KML file could not be parsed.', 400);
  }
  const features = Array.isArray(featureCollection?.features) ? featureCollection.features : [];
  const placemarks = Array.from(document.getElementsByTagName('Placemark') ?? []) as any[];
  const extendedDataByFeature = placemarks.map((placemark) => {
    const attributes: Record<string, unknown> = {};
    const dataNodes = Array.from(placemark.getElementsByTagName('Data') ?? []) as any[];
    for (const dataNode of dataNodes) {
      const key = dataNode.getAttribute('name');
      if (!key) {
        continue;
      }
      const valueNode = dataNode.getElementsByTagName('value')?.[0];
      attributes[key] = valueNode?.textContent ?? '';
    }
    const simpleDataNodes = Array.from(placemark.getElementsByTagName('SimpleData') ?? []) as any[];
    for (const simpleDataNode of simpleDataNodes) {
      const key = simpleDataNode.getAttribute('name');
      if (!key) {
        continue;
      }
      attributes[key] = simpleDataNode.textContent ?? '';
    }
    return attributes;
  });
  const normalized = features.map((feature: any, index: number) => {
    const properties = normalizeImportedAttributeAliases(
      sanitizeImportedAttributes({
        ...extendedDataByFeature[index],
        ...ensureAttributesObject(feature?.properties),
      }),
    );
    const geometryResult = normalizeGeoJsonGeometry(
      feature?.geometry as PlainObject | null,
      'EPSG:4326',
    );
    return {
      sourceIndex: index,
      sourceIdentifier: feature?.id == null ? null : String(feature.id),
      sourceFeatureName: typeof properties.name === 'string' ? properties.name : null,
      displayTitle: featureTitleFromAttributes(properties, geometryResult.geometryType, index),
      geometryType: geometryResult.geometryType,
      geometry: geometryResult.geometry,
      attributes: properties,
    } satisfies NormalizedIncomingFeature;
  });

  return {
    fileType,
    sourceCrs: 'EPSG:4326',
    sourceLayerName: null,
    features: normalized,
    fileMetadata: {
      feature_count: normalized.length,
    },
  };
};

const parseKml = async (filePath: string): Promise<ParsedImportPayload> => {
  const xml = await fs.readFile(filePath, 'utf8');
  return parseKmlDocument(xml, 'kml');
};

const parseKmz = async (filePath: string): Promise<ParsedImportPayload> => {
  const buffer = await fs.readFile(filePath);
  let zip: any;
  try {
    zip = new AdmZip(buffer);
  } catch (_error) {
    throw new AppError('The KMZ archive could not be read. Upload a valid KMZ file.', 400);
  }
  const kmlEntry = zip
    .getEntries()
    .find((entry: any) => entry.entryName.toLowerCase().endsWith('.kml'));
  if (!kmlEntry) {
    throw new AppError('KMZ archive does not contain a KML document.', 400);
  }
  const xml = kmlEntry.getData().toString('utf8');
  const payload = parseKmlDocument(xml, 'kmz');
  return {
    ...payload,
    fileMetadata: {
      ...(payload.fileMetadata ?? {}),
      archive_entries: zip.getEntries().length,
      source_entry: kmlEntry.entryName,
    },
  };
};

const normalizeHeaderKey = (value: unknown): string =>
  String(value ?? '')
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]/g, '');

const parseDelimitedRows = (raw: string, delimiter = ','): string[][] => {
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = '';
  let inQuotes = false;
  for (let index = 0; index < raw.length; index += 1) {
    const char = raw[index];
    const next = raw[index + 1];
    if (char === '"') {
      if (inQuotes && next === '"') {
        cell += '"';
        index += 1;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }
    if (char === delimiter && !inQuotes) {
      row.push(cell);
      cell = '';
      continue;
    }
    if ((char === '\n' || char === '\r') && !inQuotes) {
      if (char === '\r' && next === '\n') {
        index += 1;
      }
      row.push(cell);
      if (row.some((value) => value.trim().length > 0)) {
        rows.push(row);
      }
      row = [];
      cell = '';
      continue;
    }
    cell += char;
  }
  row.push(cell);
  if (row.some((value) => value.trim().length > 0)) {
    rows.push(row);
  }
  return rows;
};

const detectCsvDelimiter = (raw: string): string => {
  const sampleLine = raw.split(/\r?\n/).find((line) => line.trim().length > 0) ?? '';
  const candidates = [',', ';', '\t', '|'];
  const scored = candidates.map((delimiter) => ({
    delimiter,
    columns: parseDelimitedRows(sampleLine, delimiter)[0]?.length ?? 0,
  }));
  return scored.sort((left, right) => right.columns - left.columns)[0]?.delimiter ?? ',';
};

const uniqueTabularHeaders = (rawHeaders: unknown[]): string[] => {
  const seen = new Map<string, number>();
  return rawHeaders.map((rawHeader, index) => {
    const baseHeader =
      String(rawHeader ?? '')
        .trim()
        .toLowerCase()
        .replace(/[\s-]+/g, '_')
        .replace(/[^a-z0-9_]/g, '')
        .replace(/_+/g, '_')
        .replace(/^_|_$/g, '') || `column_${index + 1}`;
    const normalized = normalizeHeaderKey(baseHeader) || `column${index + 1}`;
    const count = (seen.get(normalized) ?? 0) + 1;
    seen.set(normalized, count);
    return count === 1 ? baseHeader : `${baseHeader}_${count}`;
  });
};

const cellValue = (row: Record<string, unknown>, key: string | null): string => {
  if (!key) {
    return '';
  }
  return String(row[key] ?? '').trim();
};

const parseNumberCell = (value: string): number | null => {
  const parsed = Number.parseFloat(value);
  return Number.isFinite(parsed) ? parsed : null;
};

const normalizeTabularCellValue = (value: unknown): string => String(value ?? '').trim();

const splitTopLevel = (value: string): string[] => {
  const parts: string[] = [];
  let depth = 0;
  let current = '';
  for (const char of value) {
    if (char === '(') {
      depth += 1;
    } else if (char === ')') {
      depth -= 1;
    }
    if (char === ',' && depth === 0) {
      parts.push(current.trim());
      current = '';
      continue;
    }
    current += char;
  }
  if (current.trim().length > 0) {
    parts.push(current.trim());
  }
  return parts;
};

const parseWktPosition = (value: string): [number, number] | null => {
  const parts = value
    .trim()
    .split(/\s+/)
    .map((part) => Number.parseFloat(part));
  if (parts.length < 2 || !Number.isFinite(parts[0]) || !Number.isFinite(parts[1])) {
    return null;
  }
  return [parts[0], parts[1]];
};

const stripOuterParens = (value: string): string => {
  const trimmed = value.trim();
  return trimmed.startsWith('(') && trimmed.endsWith(')') ? trimmed.slice(1, -1).trim() : trimmed;
};

const parseWktGeometry = (raw: string): PlainObject | null => {
  const trimmed = raw.trim();
  const match = /^([a-z]+)\s*(?:Z|M|ZM)?\s*\((.*)\)$/i.exec(trimmed);
  if (!match) {
    return null;
  }
  const type = match[1].toUpperCase();
  const body = match[2].trim();
  if (type === 'POINT') {
    const position = parseWktPosition(body);
    return position ? { type: 'Point', coordinates: position } : null;
  }
  if (type === 'LINESTRING') {
    const coordinates = splitTopLevel(body).map(parseWktPosition);
    return coordinates.every(Boolean)
      ? { type: 'LineString', coordinates: coordinates as Array<[number, number]> }
      : null;
  }
  if (type === 'POLYGON') {
    const rings = splitTopLevel(body).map((ring) =>
      splitTopLevel(stripOuterParens(ring)).map(parseWktPosition),
    );
    return rings.every((ring) => ring.every(Boolean))
      ? { type: 'Polygon', coordinates: rings as Array<Array<[number, number]>> }
      : null;
  }
  if (type === 'MULTIPOINT') {
    const coordinates = splitTopLevel(body).map((point) =>
      parseWktPosition(stripOuterParens(point)),
    );
    return coordinates.every(Boolean)
      ? { type: 'MultiPoint', coordinates: coordinates as Array<[number, number]> }
      : null;
  }
  if (type === 'MULTILINESTRING') {
    const lines = splitTopLevel(body).map((line) =>
      splitTopLevel(stripOuterParens(line)).map(parseWktPosition),
    );
    return lines.every((line) => line.every(Boolean))
      ? { type: 'MultiLineString', coordinates: lines as Array<Array<[number, number]>> }
      : null;
  }
  if (type === 'MULTIPOLYGON') {
    const polygons = splitTopLevel(body).map((polygon) =>
      splitTopLevel(stripOuterParens(polygon)).map((ring) =>
        splitTopLevel(stripOuterParens(ring)).map(parseWktPosition),
      ),
    );
    return polygons.every((polygon) => polygon.every((ring) => ring.every(Boolean)))
      ? { type: 'MultiPolygon', coordinates: polygons as Array<Array<Array<[number, number]>>> }
      : null;
  }
  return null;
};

const detectTabularGeometryColumns = (headers: string[]) => {
  const byNormalized = new Map(headers.map((header) => [normalizeHeaderKey(header), header]));
  const latLonPairs = [
    ['latitude', 'longitude'],
    ['latitude', 'long'],
    ['lat', 'lon'],
    ['lat', 'long'],
    ['lat', 'lng'],
    ['y', 'x'],
  ];
  for (const [latKey, lonKey] of latLonPairs) {
    const latHeader = byNormalized.get(latKey);
    const lonHeader = byNormalized.get(lonKey);
    if (latHeader && lonHeader) {
      return { mode: 'latlon' as const, latHeader, lonHeader, geometryHeader: null };
    }
  }
  for (const key of ['geometry', 'geom', 'wkt']) {
    const geometryHeader = byNormalized.get(key);
    if (geometryHeader) {
      return { mode: 'geometry' as const, latHeader: null, lonHeader: null, geometryHeader };
    }
  }
  throw new AppError(
    'No supported geometry columns found. Use lat/lon, WKT, or GeoJSON geometry.',
    400,
  );
};

const buildTabularFeatures = (
  rows: Array<Record<string, unknown>>,
  fileType: 'csv' | 'xlsx',
  metadata: Record<string, unknown>,
): ParsedImportPayload => {
  if (rows.length === 0) {
    throw new AppError('The uploaded CSV/Excel file is empty.', 400);
  }
  const headers = Object.keys(rows[0] ?? {});
  const geometryColumns = detectTabularGeometryColumns(headers);
  const features = rows.map((row, index) => {
    let geometry: PlainObject | null = null;
    let geometryType: GeometryType | null = null;
    if (geometryColumns.mode === 'latlon') {
      const lat = parseNumberCell(cellValue(row, geometryColumns.latHeader));
      const lon = parseNumberCell(cellValue(row, geometryColumns.lonHeader));
      if (lat !== null && lon !== null && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) {
        geometry = { type: 'Point', coordinates: [lon, lat] };
        geometryType = 'Point';
      }
    } else {
      const rawGeometry = cellValue(row, geometryColumns.geometryHeader);
      if (rawGeometry.startsWith('{')) {
        try {
          const parsed = JSON.parse(rawGeometry);
          const normalized = normalizeGeoJsonGeometry(parsed, null);
          geometry = normalized.geometry;
          geometryType = normalized.geometryType;
        } catch (_error) {
          geometry = null;
        }
      } else {
        const parsed = parseWktGeometry(rawGeometry);
        const normalized = normalizeGeoJsonGeometry(parsed, null);
        geometry = normalized.geometry;
        geometryType = normalized.geometryType;
      }
    }
    const attributes = normalizeImportedAttributeAliases(
      sanitizeImportedAttributes(
        Object.fromEntries(
          Object.entries(row).filter(
            ([key]) =>
              key !== geometryColumns.latHeader &&
              key !== geometryColumns.lonHeader &&
              key !== geometryColumns.geometryHeader,
          ),
        ),
      ),
    );
    return {
      sourceIndex: index,
      sourceIdentifier: cellValue(row, 'id') || null,
      sourceFeatureName: cellValue(row, 'name') || null,
      displayTitle: featureTitleFromAttributes(attributes, geometryType, index),
      geometryType,
      geometry,
      attributes,
    };
  });
  return {
    fileType,
    sourceCrs: 'EPSG:4326',
    sourceLayerName: fileType === 'xlsx' ? String(metadata.sheet_name ?? 'Sheet 1') : null,
    features,
    fileMetadata: {
      ...metadata,
      headers,
      geometry_detection: geometryColumns,
      row_count: rows.length,
    },
  };
};

const parseCsv = async (filePath: string): Promise<ParsedImportPayload> => {
  const raw = await fs.readFile(filePath, 'utf8');
  const sanitizedRaw = raw.replace(/^\uFEFF/, '');
  const delimiter = detectCsvDelimiter(sanitizedRaw);
  const rows = parseDelimitedRows(sanitizedRaw, delimiter);
  if (rows.length < 2) {
    throw new AppError('The uploaded CSV file is empty or has no data rows.', 400);
  }
  const headers = uniqueTabularHeaders(rows[0]);
  const dataRows = rows
    .slice(1)
    .map((row) =>
      Object.fromEntries(
        headers.map((header, index) => [header, normalizeTabularCellValue(row[index])]),
      ),
    );
  return buildTabularFeatures(dataRows, 'csv', { delimiter, header_row: 1 });
};

const firstXmlText = (node: any, tagName: string): string | null => {
  const item = node.getElementsByTagName(tagName)?.[0];
  return item?.textContent ?? null;
};

const parseXlsxWorksheetRows = ({
  parser,
  sheetEntry,
  sharedStrings,
}: {
  parser: any;
  sheetEntry: any;
  sharedStrings: string[];
}): string[][] => {
  const sheet = parser.parseFromString(sheetEntry.getData().toString('utf8'), 'text/xml');
  const rowNodes = Array.from(sheet.getElementsByTagName('row') ?? []) as any[];
  return rowNodes
    .map((rowNode) => {
      const values: string[] = [];
      const cells = Array.from(rowNode.getElementsByTagName('c') ?? []) as any[];
      for (const cell of cells) {
        const ref = String(cell.getAttribute('r') ?? '');
        const columnLetters = /^[A-Z]+/i.exec(ref)?.[0]?.toUpperCase() ?? '';
        const columnIndex =
          columnLetters.split('').reduce((sum, char) => sum * 26 + char.charCodeAt(0) - 64, 0) - 1;
        const type = cell.getAttribute('t');
        const rawValue = firstXmlText(cell, 'v') ?? firstXmlText(cell, 't') ?? '';
        const value =
          type === 's' ? (sharedStrings[Number.parseInt(rawValue, 10)] ?? '') : rawValue;
        values[columnIndex >= 0 ? columnIndex : values.length] = value;
      }
      return values;
    })
    .filter((row) => row.some((value) => String(value ?? '').trim().length > 0));
};

const parseXlsx = async (filePath: string): Promise<ParsedImportPayload> => {
  const zip = new AdmZip(await fs.readFile(filePath));
  if (
    zip
      .getEntries()
      .some((entry: any) => entry.entryName.toLowerCase().endsWith('vbaProject.bin'.toLowerCase()))
  ) {
    throw new AppError('Macro-enabled Excel content is not supported for GIS imports.', 400);
  }
  const workbookEntry = zip.getEntry('xl/workbook.xml');
  const relsEntry = zip.getEntry('xl/_rels/workbook.xml.rels');
  const sharedEntry = zip.getEntry('xl/sharedStrings.xml');
  if (!workbookEntry || !relsEntry) {
    throw new AppError('The Excel workbook could not be read.', 400);
  }
  const parser = new DOMParser();
  const workbook = parser.parseFromString(workbookEntry.getData().toString('utf8'), 'text/xml');
  const sheets = Array.from(workbook.getElementsByTagName('sheet') ?? []) as any[];
  const rels = parser.parseFromString(relsEntry.getData().toString('utf8'), 'text/xml');
  const relationships = Array.from(rels.getElementsByTagName('Relationship') ?? []) as any[];
  const sharedStrings = sharedEntry
    ? (
        Array.from(
          parser
            .parseFromString(sharedEntry.getData().toString('utf8'), 'text/xml')
            .getElementsByTagName('si') ?? [],
        ) as any[]
      ).map((si) =>
        Array.from(si.getElementsByTagName('t') ?? [])
          .map((t: any) => t.textContent ?? '')
          .join(''),
      )
    : [];

  let lastError: InstanceType<typeof AppError> | null = null;
  for (const [sheetIndex, sheet] of sheets.entries()) {
    const sheetName = sheet?.getAttribute('name') ?? `Sheet ${sheetIndex + 1}`;
    const relId = sheet?.getAttribute('r:id');
    const target = relationships
      .find((rel) => rel.getAttribute('Id') === relId)
      ?.getAttribute('Target');
    const sheetPath = target
      ? `xl/${String(target).replace(/^\/?xl\//, '')}`
      : `xl/worksheets/sheet${sheetIndex + 1}.xml`;
    const sheetEntry = zip.getEntry(sheetPath);
    if (!sheetEntry) {
      lastError = new AppError(`Excel worksheet "${sheetName}" could not be read.`, 400);
      continue;
    }
    const matrix = parseXlsxWorksheetRows({ parser, sheetEntry, sharedStrings });
    if (matrix.length < 2) {
      lastError = new AppError(`Excel worksheet "${sheetName}" is empty or has no data rows.`, 400);
      continue;
    }
    const headers = uniqueTabularHeaders(matrix[0]);
    const dataRows = matrix
      .slice(1)
      .map((row) =>
        Object.fromEntries(
          headers.map((header, index) => [header, normalizeTabularCellValue(row[index])]),
        ),
      );
    try {
      return buildTabularFeatures(dataRows, 'xlsx', {
        sheet_name: sheetName,
        sheet_index: sheetIndex + 1,
        header_row: 1,
      });
    } catch (error: unknown) {
      if (error instanceof AppError) {
        lastError = error;
        continue;
      }
      throw error;
    }
  }
  throw lastError ?? new AppError('The Excel workbook does not contain a readable worksheet.', 400);
};

const parseImportFile = async (
  filePath: string,
  fileType: ImportFileType,
): Promise<ParsedImportPayload> => {
  switch (fileType) {
    case 'geojson':
      return parseGeoJson(filePath);
    case 'shapefile_zip':
      return parseShapefileZip(filePath);
    case 'kml':
      return parseKml(filePath);
    case 'kmz':
      return parseKmz(filePath);
    case 'csv':
      return parseCsv(filePath);
    case 'xlsx':
      return parseXlsx(filePath);
  }
};

const shouldHideImportAttributeKey = (key: string): boolean => {
  const normalized = key
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]/g, '');
  return (
    normalized === 'accuracy' || normalized === 'accuracymeter' || normalized === 'accuracymeters'
  );
};

const normalizeSchemaString = (value: unknown): string | null => {
  if (typeof value !== 'string') {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

const uniqueNonEmpty = (values: Array<string | null>): string[] =>
  Array.from(new Set(values.filter((value): value is string => Boolean(value))));

const normalizeImportSchemaFieldType = (type: string | null): ImportSchemaFieldType => {
  const normalized = normalizeHeaderKey(type ?? '');
  if (
    [
      'string',
      'text',
      'textarea',
      'multiline',
      'notes',
      'note',
      'description',
      'descr',
      'memo',
      'longtext',
    ].includes(normalized)
  ) {
    return 'text';
  }
  if (['select', 'dropdown', 'radio', 'choice', 'combo', 'enum'].includes(normalized)) {
    return 'select';
  }
  if (
    [
      'multiselect',
      'multipleselect',
      'multichoice',
      'checkboxgroup',
      'checkboxes',
      'checklist',
    ].includes(normalized)
  ) {
    return 'multiselect';
  }
  if (['number', 'decimal', 'float', 'double'].includes(normalized)) {
    return 'number';
  }
  if (['integer', 'int', 'whole'].includes(normalized)) {
    return 'integer';
  }
  if (['boolean', 'bool', 'switch', 'toggle', 'yesno'].includes(normalized)) {
    return 'boolean';
  }
  if (normalized === 'checkbox') {
    return 'boolean';
  }
  if (['date'].includes(normalized)) {
    return 'date';
  }
  if (['datetime', 'timestamp', 'datetime-local', 'datetimelocal'].includes(normalized)) {
    return 'datetime';
  }
  if (['photo', 'file', 'image', 'attachment', 'upload', 'document'].includes(normalized)) {
    return 'file';
  }
  return 'unknown';
};

const isBlankAttributeValue = (value: unknown): boolean =>
  value === undefined || value === null || (typeof value === 'string' && value.trim().length === 0);

const displayImportedValue = (value: unknown): string => {
  if (typeof value === 'string') {
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : '(blank)';
  }
  if (value === null || value === undefined) {
    return '(blank)';
  }
  return String(value);
};

const optionToString = (value: unknown): string | null => {
  if (value === null || value === undefined) {
    return null;
  }
  if (typeof value === 'object' && !Array.isArray(value)) {
    const option = value as Record<string, unknown>;
    return normalizeSchemaString(option.value) ?? normalizeSchemaString(option.label);
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
};

const normalizeSelectComparisonValue = (value: unknown): string =>
  String(value ?? '')
    .trim()
    .replace(/\s+/g, ' ')
    .toLowerCase();

const valueMatchesAllowedOption = (value: unknown, allowedValue: string): boolean => {
  if (String(value) === allowedValue) {
    return true;
  }
  if (value === null || value === undefined) {
    return false;
  }
  return normalizeSelectComparisonValue(value) === normalizeSelectComparisonValue(allowedValue);
};

const multiValueParts = (value: unknown): unknown[] => {
  if (Array.isArray(value)) {
    return value;
  }
  if (typeof value === 'string') {
    return value
      .split(/[,;|]/)
      .map((part) => part.trim())
      .filter((part) => part.length > 0);
  }
  return [value];
};

const parseImportedNumber = (value: unknown): number | null => {
  if (typeof value === 'number') {
    return Number.isFinite(value) ? value : null;
  }
  if (typeof value !== 'string') {
    return null;
  }
  const trimmed = value.trim();
  if (!/^[+-]?(?:\d+|\d*\.\d+)(?:e[+-]?\d+)?$/i.test(trimmed)) {
    return null;
  }
  const parsed = Number(trimmed);
  return Number.isFinite(parsed) ? parsed : null;
};

const parseImportedBoolean = (value: unknown): boolean | null => {
  if (typeof value === 'boolean') {
    return value;
  }
  if (typeof value === 'number') {
    if (value === 1) {
      return true;
    }
    if (value === 0) {
      return false;
    }
    return null;
  }
  if (typeof value !== 'string') {
    return null;
  }
  const normalized = value.trim().toLowerCase();
  if (['true', 'yes', 'y', '1'].includes(normalized)) {
    return true;
  }
  if (['false', 'no', 'n', '0'].includes(normalized)) {
    return false;
  }
  return null;
};

const isParseableDate = (value: unknown): boolean => {
  if (value instanceof Date) {
    return !Number.isNaN(value.getTime());
  }
  if (typeof value !== 'string') {
    return false;
  }
  const trimmed = value.trim();
  if (trimmed.length === 0) {
    return false;
  }
  return !Number.isNaN(Date.parse(trimmed));
};

const schemaNumberLimit = (value: unknown): number | null => {
  if (typeof value === 'number') {
    return Number.isFinite(value) ? value : null;
  }
  if (typeof value === 'string') {
    return parseImportedNumber(value);
  }
  return null;
};

const validateJsonSchemaType = (value: unknown, expectedType: string): boolean => {
  if (value === null || value === undefined) {
    return true;
  }
  switch (normalizeHeaderKey(expectedType)) {
    case 'string':
    case 'text':
      return typeof value === 'string';
    case 'number':
      return parseImportedNumber(value) !== null;
    case 'integer': {
      const parsed = parseImportedNumber(value);
      return parsed !== null && Number.isInteger(parsed);
    }
    case 'boolean':
      return parseImportedBoolean(value) !== null;
    case 'object':
      return typeof value === 'object' && !Array.isArray(value);
    case 'array':
      return Array.isArray(value);
    default:
      return true;
  }
};

const validateSchemaFieldValue = (
  field: CollectionFormFieldForImport,
  value: unknown,
): string | null => {
  if (isBlankAttributeValue(value)) {
    return null;
  }
  if (field.type === 'number' || field.type === 'integer') {
    const parsed = parseImportedNumber(value);
    if (parsed === null) {
      return `Invalid number for ${field.displayName}: ${displayImportedValue(value)}.`;
    }
    if (field.type === 'integer' && !Number.isInteger(parsed)) {
      return `Invalid integer for ${field.displayName}: ${displayImportedValue(value)}.`;
    }
    if (field.min !== null && parsed < field.min) {
      return `Invalid value for ${field.displayName}: ${displayImportedValue(value)}. Minimum value is ${field.min}.`;
    }
    if (field.max !== null && parsed > field.max) {
      return `Invalid value for ${field.displayName}: ${displayImportedValue(value)}. Maximum value is ${field.max}.`;
    }
    return null;
  }
  if (field.type === 'boolean') {
    if (parseImportedBoolean(value) === null) {
      return `Invalid boolean for ${field.displayName}: ${displayImportedValue(value)}. Use true/false, yes/no, or 1/0.`;
    }
    return null;
  }
  if (field.type === 'date' || field.type === 'datetime') {
    if (!isParseableDate(value)) {
      return `Invalid ${field.type} for ${field.displayName}: ${displayImportedValue(value)}.`;
    }
    return null;
  }
  return null;
};

const shouldValidateAllowedOptions = (field: CollectionFormFieldForImport): boolean => {
  if (field.options.length === 0) {
    return false;
  }
  if (field.type === 'text' || field.type === 'file') {
    return false;
  }
  return true;
};

const allowedOptionValidationError = (
  field: CollectionFormFieldForImport,
  value: unknown,
): string | null => {
  if (!shouldValidateAllowedOptions(field) || isBlankAttributeValue(value)) {
    return null;
  }
  const values = field.type === 'multiselect' ? multiValueParts(value) : [value];
  const invalidValues = values.filter(
    (item) => !field.options.some((allowedValue) => valueMatchesAllowedOption(item, allowedValue)),
  );
  if (invalidValues.length === 0) {
    return null;
  }
  return `Invalid value for ${field.displayName}: ${invalidValues.map(displayImportedValue).join(', ')}. Allowed values: ${field.options.join(', ')}.`;
};

const collectionFormFieldsForImport = (
  schema: Record<string, unknown>,
): CollectionFormFieldForImport[] => {
  const fields = Array.isArray(schema.fields)
    ? (schema.fields as Array<Record<string, unknown>>)
    : [];

  return fields
    .map((field) => {
      const key = normalizeSchemaString(field.key) ?? normalizeSchemaString(field.name);
      const label =
        normalizeSchemaString(field.label) ??
        normalizeSchemaString(field.name) ??
        normalizeSchemaString(field.key);
      const identifiers = uniqueNonEmpty([key, label]);
      if (identifiers.length === 0) {
        return null;
      }
      const rawOptions =
        Array.isArray(field.options) && field.options.length > 0
          ? field.options
          : Array.isArray(field.enum) && field.enum.length > 0
            ? field.enum
            : [];
      const options = uniqueNonEmpty(rawOptions.map(optionToString));
      const rawType = normalizeSchemaString(field.type);
      const normalizedRawType = normalizeHeaderKey(rawType ?? '');
      const type =
        normalizedRawType === 'checkbox' && options.length > 0
          ? 'multiselect'
          : normalizeImportSchemaFieldType(rawType);
      return {
        key,
        label,
        displayName: label ?? key ?? identifiers[0],
        type,
        required: field.required === true,
        options,
        identifiers,
        min: schemaNumberLimit(field.min),
        max: schemaNumberLimit(field.max),
      } satisfies CollectionFormFieldForImport;
    })
    .filter((field): field is CollectionFormFieldForImport => field !== null);
};

const findAttributeMatch = (
  attributes: Record<string, unknown>,
  identifiers: string[],
): { key: string; value: unknown } | null => {
  for (const identifier of identifiers) {
    if (Object.prototype.hasOwnProperty.call(attributes, identifier)) {
      return { key: identifier, value: attributes[identifier] };
    }
  }

  const normalizedIdentifiers = identifiers
    .map(normalizeHeaderKey)
    .filter((identifier) => identifier.length > 0);
  if (normalizedIdentifiers.length === 0) {
    return null;
  }

  for (const [key, value] of Object.entries(attributes)) {
    if (normalizedIdentifiers.includes(normalizeHeaderKey(key))) {
      return { key, value };
    }
  }

  return null;
};

const ensureCanonicalAttribute = (
  attributes: Record<string, unknown>,
  canonicalKey: string | null,
  match: { key: string; value: unknown } | null,
): void => {
  if (!canonicalKey || !match || match.key === canonicalKey) {
    return;
  }
  if (!isBlankAttributeValue(attributes[canonicalKey])) {
    return;
  }
  attributes[canonicalKey] = match.value;
};

const validateAttributesAgainstSchema = (
  attributesInput: Record<string, unknown>,
  schema: Record<string, unknown>,
): {
  attributes: Record<string, unknown>;
  warnings: string[];
  errors: string[];
  report: Record<string, unknown>;
} => {
  const attributes = { ...attributesInput };
  const errors: string[] = [];
  const warnings: string[] = [];
  const missingRequired: string[] = [];
  const invalidFields: string[] = [];

  const jsonSchemaRequired = Array.isArray(schema.required) ? (schema.required as string[]) : [];
  const jsonSchemaProps =
    schema.properties && typeof schema.properties === 'object' && !Array.isArray(schema.properties)
      ? (schema.properties as Record<string, Record<string, unknown>>)
      : {};

  for (const requiredKey of jsonSchemaRequired) {
    const match = findAttributeMatch(attributes, [requiredKey]);
    ensureCanonicalAttribute(attributes, requiredKey, match);
    if (isBlankAttributeValue(attributes[requiredKey])) {
      missingRequired.push(requiredKey);
      errors.push(`Missing required field: ${requiredKey}`);
    }
  }

  for (const [key, propSchema] of Object.entries(jsonSchemaProps)) {
    const match = findAttributeMatch(attributes, [key]);
    ensureCanonicalAttribute(attributes, key, match);
    if (attributes[key] === undefined) {
      continue;
    }
    const expectedType = typeof propSchema?.type === 'string' ? propSchema.type : null;
    if (expectedType && !validateJsonSchemaType(attributes[key], expectedType)) {
      invalidFields.push(key);
      errors.push(`Invalid type for attribute "${key}"`);
    }
  }

  const fields = collectionFormFieldsForImport(schema);
  for (const field of fields) {
    const match = findAttributeMatch(attributes, field.identifiers);
    ensureCanonicalAttribute(attributes, field.key, match);
    const value = field.key ? attributes[field.key] : match?.value;

    if (field.required && isBlankAttributeValue(value)) {
      if (!missingRequired.includes(field.displayName)) {
        missingRequired.push(field.displayName);
        errors.push(`Missing required field: ${field.displayName}`);
      }
    }

    const fieldValueError = validateSchemaFieldValue(field, value);
    if (fieldValueError !== null) {
      if (!invalidFields.includes(field.displayName)) {
        invalidFields.push(field.displayName);
      }
      errors.push(fieldValueError);
    }

    const optionError = allowedOptionValidationError(field, value);
    if (optionError !== null) {
      errors.push(optionError);
    }
  }

  const knownFieldIdentifiers = new Set(
    fields.flatMap((field) => field.identifiers.map(normalizeHeaderKey)),
  );
  const unknownKeys = Object.keys(attributesInput).filter((key) => {
    if (shouldHideImportAttributeKey(key)) {
      return false;
    }
    if (Object.prototype.hasOwnProperty.call(jsonSchemaProps, key)) {
      return false;
    }
    const normalizedKey = normalizeHeaderKey(key);
    if (knownFieldIdentifiers.has(normalizedKey)) {
      return false;
    }
    return !fields.some((field) => field.identifiers.includes(key));
  });
  if (unknownKeys.length > 0) {
    warnings.push(
      `Attributes not defined in the project form were kept: ${unknownKeys.join(', ')}`,
    );
  }

  return {
    attributes,
    warnings,
    errors,
    report: {
      missing_required: missingRequired,
      invalid_fields: invalidFields,
      unknown_fields: unknownKeys,
    },
  };
};

const getProjectForImport = async (projectId: string) => {
  await synchronizeProjectStatuses(projectId);
  const projectResult = await query(
    `SELECT id, name, status, collection_form_schema
     FROM project
     WHERE id = $1`,
    [projectId],
  );

  if (projectResult.rows.length === 0) {
    throw new AppError('Project not found', 404);
  }

  return projectResult.rows[0];
};

const assertProjectAllowsImport = async (projectId: string): Promise<void> => {
  const project = await getProjectForImport(projectId);
  if (project.status === 'active') {
    return;
  }
  if (project.status === 'paused') {
    throw new AppError(
      'This project is paused. GIS imports are unavailable until it is reactivated.',
      409,
    );
  }
  throw new AppError(
    `GIS imports are unavailable while the project status is ${project.status}.`,
    409,
  );
};

const hasProjectImportAccess = async (
  projectId: string,
  user: Express.UserContext,
): Promise<boolean> => {
  if (user.role === 'admin') {
    return !isProtectedSuperAdminEmail(user.email);
  }
  const accessCheck = await query(
    `SELECT 1
     FROM project_assignment
     WHERE project_id = $1
       AND user_id = $2
       AND status = 'approved'
     LIMIT 1`,
    [projectId, user.id],
  );
  return accessCheck.rows.length > 0;
};

const hasProjectImportReviewAccess = async (
  projectId: string,
  user: Express.UserContext,
): Promise<boolean> => {
  if (user.role === 'admin') {
    return true;
  }
  const accessCheck = await query(
    `SELECT 1
     FROM project_assignment
     WHERE project_id = $1
       AND user_id = $2
       AND role = 'admin'
       AND status = 'approved'
     LIMIT 1`,
    [projectId, user.id],
  );
  return accessCheck.rows.length > 0;
};

const importNeedsProtectedSuperAdminReview = (
  job: Pick<ImportJobAccessRow, 'uploaded_by_role' | 'uploaded_by_email'>,
): boolean =>
  job.uploaded_by_role === 'admin' && !isProtectedSuperAdminEmail(job.uploaded_by_email);

const canReviewImportJob = async (
  job: ImportJobAccessRow,
  user: Express.UserContext,
): Promise<boolean> => {
  if (user.role !== 'admin') {
    return false;
  }
  if (importNeedsProtectedSuperAdminReview(job)) {
    return isProtectedSuperAdminEmail(user.email);
  }
  return hasProjectImportReviewAccess(job.project_id, user);
};

const canCommentOnImportJob = async (
  job: ImportJobAccessRow,
  user: Express.UserContext,
): Promise<boolean> => canReviewImportJob(job, user);

const canDownloadImportJob = async (
  job: ImportJobAccessRow,
  user: Express.UserContext,
): Promise<boolean> => canReviewImportJob(job, user);

const getImportReviewRecipients = async (
  executor: any,
  projectId: string,
  {
    uploaderRole,
    uploaderEmail,
  }: {
    uploaderRole: string;
    uploaderEmail?: string | null;
  },
) => {
  if (uploaderRole === 'admin' && !isProtectedSuperAdminEmail(uploaderEmail)) {
    const protectedEmail = String(process.env.SUPER_ADMIN_EMAIL ?? '')
      .trim()
      .toLowerCase();
    const result = await executor.query(
      `SELECT DISTINCT u.id, u.full_name, u.email
       FROM "user" u
       WHERE u.is_active = TRUE
         AND u.role = 'admin'
         AND LOWER(u.email) = $1`,
      [protectedEmail],
    );
    return result.rows as Array<{ id: string; full_name: string; email: string }>;
  }

  const result = await executor.query(
    `SELECT DISTINCT u.id, u.full_name, u.email
     FROM "user" u
     WHERE u.is_active = TRUE
       AND (
         u.role = 'admin'
         OR EXISTS (
           SELECT 1
           FROM project_assignment pa
           WHERE pa.project_id = $1
             AND pa.user_id = u.id
             AND pa.role = 'admin'
             AND pa.status = 'approved'
         )
       )`,
    [projectId],
  );
  return result.rows as Array<{ id: string; full_name: string; email: string }>;
};

const validateImportedFeature = async (
  client: any,
  {
    projectId,
    formSchema,
    incoming,
  }: {
    projectId: string;
    formSchema: Record<string, unknown>;
    incoming: NormalizedIncomingFeature;
  },
): Promise<ImportValidationResult> => {
  const warnings: string[] = [];
  const errors: string[] = [];
  const report: Record<string, unknown> = {};
  const attributeValidation = validateAttributesAgainstSchema(incoming.attributes, formSchema);
  warnings.push(...attributeValidation.warnings);
  errors.push(...attributeValidation.errors);
  report.attributes = attributeValidation.report;
  const attributes = attributeValidation.attributes;

  if (!incoming.geometryType || !incoming.geometry) {
    errors.push('Geometry is missing or unsupported.');
    report.geometry = {
      valid: false,
      reason: 'missing_or_unsupported',
    };
    return {
      geometryType: incoming.geometryType,
      geometryJson: null,
      attributes,
      warnings,
      errors,
      report,
      duplicateFeatureId: null,
    };
  }

  const geometryJson = JSON.stringify(incoming.geometry);
  const geometryValidation = await client.query(
    `WITH candidate AS (
       SELECT ST_SetSRID(ST_GeomFromGeoJSON($1), 4326) AS geom
     )
     SELECT
       ST_IsValid(candidate.geom) AS is_valid,
       ST_IsValidReason(candidate.geom) AS valid_reason,
       ST_Intersects(
         candidate.geom,
         ST_MakeEnvelope($2, $3, $4, $5, 4326)
       ) AS intersects_lebanon,
       EXISTS (
         SELECT 1
         FROM spatial_feature sf
         WHERE sf.project_id = $6
           AND sf.status = 'approved'
           AND ST_Equals(sf.geom, candidate.geom)
       ) AS exact_duplicate,
       (
         SELECT sf.id
         FROM spatial_feature sf
         WHERE sf.project_id = $6
           AND sf.status = 'approved'
           AND ST_Equals(sf.geom, candidate.geom)
         LIMIT 1
       ) AS duplicate_feature_id,
       EXISTS (
         SELECT 1
         FROM spatial_feature sf
         WHERE sf.project_id = $6
           AND sf.status = 'approved'
           AND ST_DWithin(
             sf.geom::geography,
             candidate.geom::geography,
             5
           )
       ) AS nearby_duplicate
     FROM candidate`,
    [
      geometryJson,
      LEBANON_BOUNDS.minLon - LEBANON_BUFFER_DEGREES,
      LEBANON_BOUNDS.minLat - LEBANON_BUFFER_DEGREES,
      LEBANON_BOUNDS.maxLon + LEBANON_BUFFER_DEGREES,
      LEBANON_BOUNDS.maxLat + LEBANON_BUFFER_DEGREES,
      projectId,
    ],
  );

  const geoRow = geometryValidation.rows[0] ?? {};
  report.geometry = {
    valid: geoRow.is_valid === true,
    valid_reason: geoRow.valid_reason ?? null,
    intersects_lebanon: geoRow.intersects_lebanon === true,
    exact_duplicate: geoRow.exact_duplicate === true,
    nearby_duplicate: geoRow.nearby_duplicate === true,
  };

  if (geoRow.is_valid !== true) {
    errors.push(friendlyInvalidGeometryMessage(geoRow.valid_reason, incoming.geometryType));
  }
  if (geoRow.intersects_lebanon !== true) {
    warnings.push('Geometry falls outside the Lebanon workspace bounds.');
  }
  if (geoRow.exact_duplicate === true) {
    warnings.push('Geometry matches an approved feature already present in this project.');
  } else if (geoRow.nearby_duplicate === true) {
    warnings.push('Geometry is very close to an approved feature already present in this project.');
  }

  return {
    geometryType: incoming.geometryType,
    geometryJson,
    attributes,
    warnings,
    errors,
    report,
    duplicateFeatureId: geoRow.duplicate_feature_id ?? null,
  };
};

const buildValidationSummary = ({
  parsed,
  reviewableCount,
  failedCount,
  warningCount,
  errorCount,
  duplicateOfImportJobId,
  warningBreakdown,
  errorBreakdown,
}: {
  parsed: ParsedImportPayload;
  reviewableCount: number;
  failedCount: number;
  warningCount: number;
  errorCount: number;
  duplicateOfImportJobId: string | null;
  warningBreakdown: Map<string, number>;
  errorBreakdown: Map<string, number>;
}) => ({
  file_type: parsed.fileType,
  source_crs: parsed.sourceCrs,
  source_layer_name: parsed.sourceLayerName,
  feature_count: parsed.features.length,
  reviewable_feature_count: reviewableCount,
  failed_feature_count: failedCount,
  warning_count: warningCount,
  error_count: errorCount,
  duplicate_of_import_job_id: duplicateOfImportJobId,
  warning_breakdown: issueBreakdownObject(warningBreakdown),
  error_breakdown: issueBreakdownObject(errorBreakdown),
  top_warnings: summarizeIssueBreakdown(warningBreakdown),
  top_errors: summarizeIssueBreakdown(errorBreakdown),
});

const issueBreakdownObject = (issues: Map<string, number>) =>
  Object.fromEntries(
    [...issues.entries()].sort((left, right) => {
      if (right[1] !== left[1]) {
        return right[1] - left[1];
      }
      return left[0].localeCompare(right[0]);
    }),
  );

const summarizeIssueBreakdown = (issues: Map<string, number>) =>
  [...issues.entries()]
    .sort((left, right) => {
      if (right[1] !== left[1]) {
        return right[1] - left[1];
      }
      return left[0].localeCompare(right[0]);
    })
    .slice(0, 8)
    .map(([message, count]) => ({ message, count }));

const mapImportJobRow = (row: ImportJobRow | ImportJobAccessRow) => ({
  id: row.id,
  project_id: row.project_id,
  project_name: row.project_name,
  uploaded_by_user_id: row.uploaded_by_user_id,
  uploaded_by_name: row.uploaded_by_name,
  reviewed_by_user_id: row.reviewed_by_user_id,
  reviewed_by_name: row.reviewed_by_name,
  duplicate_of_import_job_id: row.duplicate_of_import_job_id,
  possible_duplicate: Boolean(row.duplicate_of_import_job_id),
  original_filename: row.original_filename,
  stored_filename: row.stored_filename,
  file_path: row.file_path,
  file_size_bytes: row.file_size_bytes,
  file_checksum_sha256: row.file_checksum_sha256,
  file_type: row.file_type,
  source_crs: row.source_crs,
  source_layer_name: row.source_layer_name,
  status: row.status,
  geometry_count: row.geometry_count,
  pending_feature_count: row.pending_feature_count,
  approved_feature_count: row.approved_feature_count,
  rejected_feature_count: row.rejected_feature_count,
  failed_feature_count: row.failed_feature_count,
  warning_count: row.warning_count,
  error_count: row.error_count,
  geometry_types: row.geometry_types ?? [],
  file_metadata: row.file_metadata ?? {},
  validation_summary: row.validation_summary ?? {},
  processing_message: row.processing_message,
  rejection_reason: row.rejection_reason,
  review_scope:
    'uploaded_by_role' in row && importNeedsProtectedSuperAdminReview(row)
      ? 'protected_super_admin'
      : 'admin',
  uploaded_at: row.uploaded_at,
  processed_at: row.processed_at,
  reviewed_at: row.reviewed_at,
  created_at: row.created_at,
  updated_at: row.updated_at,
});

const mapImportFeatureRow = (row: ImportFeatureRow) => ({
  id: row.id,
  import_job_id: row.import_job_id,
  source_index: row.source_index,
  source_identifier: row.source_identifier,
  display_title: row.display_title,
  source_feature_name: row.source_feature_name,
  geometry_type: row.geometry_type,
  geometry: row.geometry ? JSON.parse(row.geometry) : null,
  attributes: row.attributes ?? {},
  summary_attributes: row.summary_attributes ?? {},
  attribute_count: row.attribute_count ?? Object.keys(row.attributes ?? {}).length,
  status: row.status,
  validation_warnings: row.validation_warnings ?? [],
  validation_errors: row.validation_errors ?? [],
  validation_report: row.validation_report ?? {},
  duplicate_feature_id: row.duplicate_feature_id,
  approved_feature_id: row.approved_feature_id,
  reviewed_by_user_id: row.reviewed_by_user_id,
  reviewed_by_name: row.reviewed_by_name,
  reviewed_at: row.reviewed_at,
  approved_at: row.approved_at,
  review_reason: row.review_reason,
  is_summary: row.is_summary ?? false,
  is_aggregate: row.is_aggregate ?? false,
  cluster_count: row.cluster_count ?? 1,
  created_at: row.created_at,
  updated_at: row.updated_at,
});

const normalizeSummaryAttributeValue = (value: unknown): string => {
  if (Array.isArray(value)) {
    return value
      .map((item) => String(item ?? '').trim())
      .filter(Boolean)
      .join('|');
  }
  return String(value ?? '')
    .trim()
    .toLowerCase();
};

const isSummaryAttributeValue = (value: unknown): boolean => {
  if (value === null || value === undefined) {
    return false;
  }
  if (typeof value === 'string') {
    return value.trim().length > 0;
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return true;
  }
  if (Array.isArray(value)) {
    return value.length > 0 && value.length <= 6;
  }
  return false;
};

const addSummaryAttribute = (
  summary: Record<string, unknown>,
  seenValues: Set<string>,
  key: string,
  value: unknown,
): void => {
  if (!key.trim() || !isSummaryAttributeValue(value)) {
    return;
  }
  if (Object.prototype.hasOwnProperty.call(summary, key)) {
    return;
  }
  const normalizedValue = normalizeSummaryAttributeValue(value);
  if (!normalizedValue) {
    return;
  }
  const normalizedKey = normalizeHeaderKey(key);
  const canDedupeByValue =
    normalizedKey.includes('type') ||
    normalizedKey.includes('descr') ||
    normalizedKey.includes('name') ||
    normalizedKey.includes('crop');
  if (canDedupeByValue && seenValues.has(normalizedValue)) {
    return;
  }
  if (canDedupeByValue) {
    seenValues.add(normalizedValue);
  }
  summary[key] = value;
};

const buildImportFeatureSummaryAttributes = (
  row: ImportFeatureRow,
  formSchema: Record<string, unknown>,
): Record<string, unknown> => {
  const attributes = row.attributes ?? {};
  const summary: Record<string, unknown> = {};
  const seenValues = new Set<string>();
  const requiredFields = collectionFormFieldsForImport(formSchema).filter(
    (field) => field.required,
  );
  const requiredIdentifiers = [...requiredFields.map((field) => field.identifiers)];
  const jsonSchemaRequired = Array.isArray(formSchema.required)
    ? (formSchema.required as unknown[])
        .map((value) => normalizeSchemaString(value))
        .filter((value): value is string => value !== null)
    : [];

  for (const requiredKey of jsonSchemaRequired) {
    if (
      !requiredIdentifiers.some((identifiers) =>
        identifiers.some(
          (identifier) => normalizeHeaderKey(identifier) === normalizeHeaderKey(requiredKey),
        ),
      )
    ) {
      requiredIdentifiers.push([requiredKey]);
    }
  }

  for (const identifiers of requiredIdentifiers) {
    const match = findAttributeMatch(attributes, identifiers);
    if (match) {
      addSummaryAttribute(summary, seenValues, match.key, match.value);
    }
  }

  return summary;
};

const mapImportFeatureSummaryRow = (
  row: ImportFeatureRow,
  formSchema: Record<string, unknown> = {},
) => {
  const summaryAttributes =
    row.summary_attributes ?? buildImportFeatureSummaryAttributes(row, formSchema);
  return {
    id: row.id,
    import_job_id: row.import_job_id,
    source_index: row.source_index,
    source_identifier: row.source_identifier,
    display_title: row.display_title,
    source_feature_name: row.source_feature_name,
    geometry_type: row.geometry_type,
    geometry: null,
    attributes: summaryAttributes,
    summary_attributes: summaryAttributes,
    attribute_count: row.attribute_count ?? Object.keys(row.attributes ?? {}).length,
    status: row.status,
    validation_warnings: row.validation_warnings ?? [],
    validation_errors: row.validation_errors ?? [],
    validation_report: row.validation_report ?? {},
    duplicate_feature_id: row.duplicate_feature_id,
    approved_feature_id: row.approved_feature_id,
    reviewed_by_user_id: row.reviewed_by_user_id,
    reviewed_by_name: row.reviewed_by_name,
    reviewed_at: row.reviewed_at,
    approved_at: row.approved_at,
    review_reason: row.review_reason,
    is_summary: true,
    is_aggregate: false,
    cluster_count: 1,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
};

const mapImportMapFeatureRow = (row: ImportFeatureRow) => ({
  id: row.id,
  import_job_id: row.import_job_id,
  source_index: row.source_index,
  source_identifier: row.source_identifier,
  display_title: row.display_title,
  source_feature_name: row.source_feature_name,
  geometry_type: row.geometry_type,
  geometry: row.geometry ? JSON.parse(row.geometry) : null,
  attributes: {},
  summary_attributes: {},
  attribute_count: 0,
  status: row.status,
  validation_warnings: [],
  validation_errors: [],
  validation_report: {},
  duplicate_feature_id: row.duplicate_feature_id,
  approved_feature_id: row.approved_feature_id,
  reviewed_by_user_id: row.reviewed_by_user_id,
  reviewed_by_name: row.reviewed_by_name,
  reviewed_at: row.reviewed_at,
  approved_at: row.approved_at,
  review_reason: row.review_reason,
  is_summary: true,
  is_aggregate: row.is_aggregate ?? false,
  cluster_count: row.cluster_count ?? 1,
  created_at: row.created_at,
  updated_at: row.updated_at,
});

const mapImportCommentRow = (row: ImportCommentRow) => ({
  id: row.id,
  import_job_id: row.import_job_id,
  import_feature_id: row.import_feature_id,
  feature_display_title: row.feature_display_title,
  author_user_id: row.author_user_id,
  author_name: row.author_name,
  author_role: row.author_role,
  comment_text: row.comment_text,
  created_at: row.created_at,
});

const mapImportMapProjectFeatureRow = (row: any) => ({
  id: row.id,
  status: row.status,
  geometry: row.geometry ? JSON.parse(row.geometry) : null,
  attributes: sanitizeManagedFeatureAttributes(row.attributes),
  source_geometry_type: row.source_geometry_type ?? null,
  collected_by: row.collected_by ?? null,
  reviewed_by: row.reviewed_by ?? null,
  review_notes: row.review_notes ?? null,
  collected_at: row.collected_at ?? null,
  submitted_at: row.submitted_at ?? null,
  reviewed_at: row.reviewed_at ?? null,
  photo_count: row.photo_count ?? 0,
  is_summary: true,
  is_aggregate: row.is_aggregate ?? false,
  cluster_count: row.cluster_count ?? 1,
});

const insertStagedImportFeaturesBatch = async (
  client: any,
  rows: StagedImportInsertRow[],
): Promise<void> => {
  if (rows.length === 0) {
    return;
  }

  const valuesSql: string[] = [];
  const params: unknown[] = [];

  for (const row of rows) {
    const base = params.length;
    params.push(
      row.importJobId,
      row.sourceIndex,
      row.sourceIdentifier,
      row.displayTitle,
      row.sourceFeatureName,
      row.geometryType,
      row.geometryJson,
      JSON.stringify(row.attributes),
      row.status,
      JSON.stringify(row.validationWarnings),
      JSON.stringify(row.validationErrors),
      JSON.stringify(row.validationReport),
      row.duplicateFeatureId,
    );
    valuesSql.push(
      `(
        $${base + 1},
        $${base + 2},
        $${base + 3},
        $${base + 4},
        $${base + 5},
        $${base + 6},
        CASE WHEN $${base + 7}::text IS NULL THEN NULL ELSE ST_SetSRID(ST_GeomFromGeoJSON($${base + 7}), 4326) END,
        $${base + 8}::jsonb,
        $${base + 9}::gis_import_feature_status,
        $${base + 10}::jsonb,
        $${base + 11}::jsonb,
        $${base + 12}::jsonb,
        $${base + 13}
      )`,
    );
  }

  await client.query(
    `INSERT INTO gis_import_feature (
       import_job_id,
       source_index,
       source_identifier,
       display_title,
       source_feature_name,
       geometry_type,
       geom,
       attributes,
       status,
       validation_warnings,
       validation_errors,
       validation_report,
       duplicate_feature_id
     ) VALUES ${valuesSql.join(',')}`,
    params,
  );
};

const createImportSubmissionNotifications = async (
  client: any,
  {
    importJobId,
    projectId,
    projectName,
    uploader,
    originalFilename,
    uploaderRole,
  }: {
    importJobId: string;
    projectId: string;
    projectName: string;
    uploader: Express.UserContext;
    originalFilename: string;
    uploaderRole: string;
  },
): Promise<void> => {
  const recipients = await getImportReviewRecipients(client, projectId, {
    uploaderRole,
    uploaderEmail: uploader.email,
  });
  for (const admin of recipients) {
    await createNotification(client, {
      userId: admin.id,
      type: 'import_event',
      title: 'GIS import submitted',
      message: `${uploader.full_name} submitted ${originalFilename} for ${projectName}. The file is processing before review.`,
      metadata: {
        import_job_id: importJobId,
        project_id: projectId,
        project_name: projectName,
        status: 'uploaded',
      },
    });
  }
};

const updateImportProcessingHeartbeat = async (
  client: any,
  importJobId: string,
  processingMessage: string,
): Promise<void> => {
  await client.query(
    `UPDATE gis_import_job
     SET processing_heartbeat_at = CURRENT_TIMESTAMP,
         processing_message = $2
     WHERE id = $1`,
    [importJobId, processingMessage],
  );
};

const failImportJob = async (
  importJobId: string,
  {
    projectId,
    projectName,
    uploadedByUserId,
    originalFilename,
    message,
    sourceCrs,
    sourceLayerName,
  }: {
    projectId: string;
    projectName: string;
    uploadedByUserId: string;
    originalFilename: string;
    message: string;
    sourceCrs?: string | null;
    sourceLayerName?: string | null;
  },
): Promise<void> => {
  await transaction(async (client: any) => {
    await client.query(
      `UPDATE gis_import_job
       SET status = 'failed',
           processed_at = CURRENT_TIMESTAMP,
           processing_message = $2,
           source_crs = COALESCE($3, source_crs),
           source_layer_name = COALESCE($4, source_layer_name)
       WHERE id = $1`,
      [importJobId, message, sourceCrs ?? null, sourceLayerName ?? null],
    );

    await createNotification(client, {
      userId: uploadedByUserId,
      type: 'import_event',
      title: `Import failed in ${projectName}`,
      message: `We could not stage ${originalFilename}. ${message}`,
      metadata: {
        import_job_id: importJobId,
        project_id: projectId,
        project_name: projectName,
        status: 'failed',
      },
    });
  });
};

const processImportJob = async (importJobId: string): Promise<void> => {
  const jobResult = await query(
    `SELECT gij.*, p.name AS project_name,
            uploader.full_name AS uploaded_by_name
     FROM gis_import_job gij
     JOIN project p ON p.id = gij.project_id
     JOIN "user" uploader ON uploader.id = gij.uploaded_by_user_id
     WHERE gij.id = $1`,
    [importJobId],
  );
  if (jobResult.rows.length === 0) {
    return;
  }

  const job = jobResult.rows[0];
  let parsed: ParsedImportPayload;
  try {
    parsed = await parseImportFile(job.file_path, job.file_type);
  } catch (error) {
    logger.warn('GIS import file parsing failed', {
      importJobId,
      fileType: job.file_type,
      error: error instanceof Error ? error.message : String(error),
    });
    const message =
      error instanceof AppError
        ? error.message
        : error instanceof Error && error.message.trim().length > 0
          ? error.message.trim()
          : 'The uploaded GIS file could not be processed.';
    await failImportJob(importJobId, {
      projectId: job.project_id,
      projectName: job.project_name,
      uploadedByUserId: job.uploaded_by_user_id,
      originalFilename: job.original_filename,
      message,
    });
    return;
  }

  if (parsed.features.length === 0) {
    await failImportJob(importJobId, {
      projectId: job.project_id,
      projectName: job.project_name,
      uploadedByUserId: job.uploaded_by_user_id,
      originalFilename: job.original_filename,
      message: 'The uploaded file did not contain any supported geometries.',
      sourceCrs: parsed.sourceCrs,
      sourceLayerName: parsed.sourceLayerName,
    });
    return;
  }

  if (parsed.features.length > env.IMPORT_MAX_FEATURES) {
    await failImportJob(importJobId, {
      projectId: job.project_id,
      projectName: job.project_name,
      uploadedByUserId: job.uploaded_by_user_id,
      originalFilename: job.original_filename,
      message: `This import contains ${parsed.features.length} features. The limit is ${env.IMPORT_MAX_FEATURES}.`,
      sourceCrs: parsed.sourceCrs,
      sourceLayerName: parsed.sourceLayerName,
    });
    return;
  }

  const project = await getProjectForImport(job.project_id);
  const formSchema =
    project.collection_form_schema && typeof project.collection_form_schema === 'object'
      ? (project.collection_form_schema as Record<string, unknown>)
      : {};

  try {
    await transaction(async (client: any) => {
      await client.query(
        `DELETE FROM gis_import_feature
         WHERE import_job_id = $1`,
        [importJobId],
      );

      let reviewableCount = 0;
      let failedCount = 0;
      let warningCount = 0;
      let errorCount = 0;
      const warningBreakdown = new Map<string, number>();
      const errorBreakdown = new Map<string, number>();
      const stagedRows: StagedImportInsertRow[] = [];

      for (let index = 0; index < parsed.features.length; index += 1) {
        const incoming = parsed.features[index];
        const validation = await validateImportedFeature(client, {
          projectId: job.project_id,
          formSchema,
          incoming,
        });
        warningCount += validation.warnings.length;
        errorCount += validation.errors.length;
        for (const warning of validation.warnings) {
          warningBreakdown.set(warning, (warningBreakdown.get(warning) ?? 0) + 1);
        }
        for (const error of validation.errors) {
          errorBreakdown.set(error, (errorBreakdown.get(error) ?? 0) + 1);
        }
        const featureStatus = validation.errors.length > 0 ? 'failed' : 'pending_review';
        if (featureStatus === 'failed') {
          failedCount += 1;
        } else {
          reviewableCount += 1;
        }

        stagedRows.push({
          importJobId,
          sourceIndex: incoming.sourceIndex,
          sourceIdentifier: incoming.sourceIdentifier,
          displayTitle: incoming.displayTitle,
          sourceFeatureName: incoming.sourceFeatureName,
          geometryType: validation.geometryType,
          geometryJson: validation.geometryJson,
          attributes: validation.attributes,
          status: featureStatus,
          validationWarnings: validation.warnings,
          validationErrors: validation.errors,
          validationReport: validation.report,
          duplicateFeatureId: validation.duplicateFeatureId,
        });

        if (stagedRows.length >= IMPORT_INSERT_BATCH_SIZE) {
          await insertStagedImportFeaturesBatch(client, stagedRows);
          stagedRows.length = 0;
          await updateImportProcessingHeartbeat(
            client,
            importJobId,
            `Processing imported features ${Math.min(index + 1, parsed.features.length)}/${parsed.features.length}`,
          );
        }
      }

      if (stagedRows.length > 0) {
        await insertStagedImportFeaturesBatch(client, stagedRows);
      }

      const finalStatus = reviewableCount > 0 ? 'pending_review' : 'failed';
      const geometryTypes = [
        ...new Set(
          parsed.features
            .map((feature) => feature.geometryType)
            .filter((value): value is GeometryType => value != null),
        ),
      ];
      const validationSummary = buildValidationSummary({
        parsed,
        reviewableCount,
        failedCount,
        warningCount,
        errorCount,
        duplicateOfImportJobId: job.duplicate_of_import_job_id,
        warningBreakdown,
        errorBreakdown,
      });
      const processingMessage =
        finalStatus === 'failed'
          ? 'Import processing finished, but no staged features were eligible for review.'
          : `Import ready for admin review with ${reviewableCount} staged feature(s).`;

      await client.query(
        `UPDATE gis_import_job
         SET status = $2::gis_import_status,
             geometry_count = $3,
             pending_feature_count = $4,
             approved_feature_count = 0,
             rejected_feature_count = 0,
             failed_feature_count = $5,
             warning_count = $6,
             error_count = $7,
             geometry_types = $8::text[],
             file_metadata = $9::jsonb,
             validation_summary = $10::jsonb,
             processed_at = CURRENT_TIMESTAMP,
             processing_message = $11,
             source_crs = COALESCE($12, source_crs),
             source_layer_name = COALESCE($13, source_layer_name),
             processing_heartbeat_at = CURRENT_TIMESTAMP
         WHERE id = $1`,
        [
          importJobId,
          finalStatus,
          parsed.features.length,
          reviewableCount,
          failedCount,
          warningCount,
          errorCount,
          geometryTypes,
          JSON.stringify(parsed.fileMetadata),
          JSON.stringify(validationSummary),
          processingMessage,
          parsed.sourceCrs,
          parsed.sourceLayerName,
        ],
      );

      if (finalStatus === 'failed') {
        await createNotification(client, {
          userId: job.uploaded_by_user_id,
          type: 'import_event',
          title: `Import failed in ${job.project_name}`,
          message: `We could not stage any reviewable features from ${job.original_filename}. Check the validation summary for details.`,
          metadata: {
            import_job_id: importJobId,
            project_id: job.project_id,
            project_name: job.project_name,
            status: finalStatus,
            warning_count: warningCount,
            error_count: errorCount,
          },
        });
      }
    });
  } catch (error) {
    const message =
      error instanceof Error && error.message.trim().length > 0
        ? error.message.trim()
        : 'The uploaded GIS file could not be processed.';
    await failImportJob(importJobId, {
      projectId: job.project_id,
      projectName: job.project_name,
      uploadedByUserId: job.uploaded_by_user_id,
      originalFilename: job.original_filename,
      message,
      sourceCrs: parsed.sourceCrs,
      sourceLayerName: parsed.sourceLayerName,
    });
    return;
  }
};

const claimNextImportJob = async (): Promise<string | null> => {
  return transaction(async (client: any) => {
    const staleCutoff = new Date(Date.now() - IMPORT_PROCESSING_STALE_AFTER_MS).toISOString();
    const result = await client.query(
      `WITH candidate AS (
         SELECT id
         FROM gis_import_job
         WHERE status = 'uploaded'
            OR (
              status = 'processing'
              AND (
                processing_heartbeat_at IS NULL
                OR processing_heartbeat_at < $1::timestamptz
              )
            )
         ORDER BY uploaded_at ASC
         FOR UPDATE SKIP LOCKED
         LIMIT 1
       )
       UPDATE gis_import_job gij
       SET status = 'processing',
           processing_attempt_count = gij.processing_attempt_count + 1,
           processing_started_at = COALESCE(gij.processing_started_at, CURRENT_TIMESTAMP),
           processing_heartbeat_at = CURRENT_TIMESTAMP,
           processing_message = 'Processing uploaded GIS data'
       FROM candidate
       WHERE gij.id = candidate.id
       RETURNING gij.id`,
      [staleCutoff],
    );
    return result.rows[0]?.id ?? null;
  });
};

const drainImportProcessingQueue = async (): Promise<void> => {
  if (importProcessingDrainRunning) {
    return;
  }

  importProcessingDrainRunning = true;
  try {
    for (;;) {
      const nextJobId = await claimNextImportJob();
      if (!nextJobId) {
        break;
      }

      try {
        await processImportJob(nextJobId);
      } catch (error) {
        logger.error('Background GIS import processing failed', {
          importJobId: nextJobId,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }
  } finally {
    importProcessingDrainRunning = false;
  }
};

const scheduleImportProcessing = (): void => {
  if (importProcessingDrainScheduled) {
    return;
  }

  importProcessingDrainScheduled = true;
  importProcessingDrainTimeout = setTimeout(() => {
    importProcessingDrainTimeout = null;
    importProcessingDrainScheduled = false;
    void drainImportProcessingQueue();
  }, 0);
};

const startImportProcessingLoop = (): void => {
  if (importProcessingLoop) {
    return;
  }

  importProcessingLoop = setInterval(() => {
    void drainImportProcessingQueue();
  }, IMPORT_PROCESSING_POLL_INTERVAL_MS);
  scheduleImportProcessing();
};

const stopImportProcessingLoop = (): void => {
  if (importProcessingLoop) {
    clearInterval(importProcessingLoop);
    importProcessingLoop = null;
  }
  if (importProcessingDrainTimeout) {
    clearTimeout(importProcessingDrainTimeout);
    importProcessingDrainTimeout = null;
  }
  importProcessingDrainScheduled = false;
};

const waitForImportProcessingIdle = async (): Promise<void> => {
  for (let attempts = 0; attempts < 200; attempts += 1) {
    if (
      !importProcessingDrainRunning &&
      !importProcessingDrainScheduled &&
      importProcessingDrainTimeout == null
    ) {
      return;
    }

    await new Promise((resolve) => setTimeout(resolve, 25));
  }
};

const fetchImportJobWithAccess = async (importId: string, user: Express.UserContext) => {
  const result = await query(
    `SELECT gij.*, p.name AS project_name,
            p.collection_form_schema AS project_collection_form_schema,
            uploader.full_name AS uploaded_by_name,
            uploader.email AS uploaded_by_email,
            uploader.role AS uploaded_by_role,
            reviewer.full_name AS reviewed_by_name
     FROM gis_import_job gij
     JOIN project p ON p.id = gij.project_id
     JOIN "user" uploader ON uploader.id = gij.uploaded_by_user_id
     LEFT JOIN "user" reviewer ON reviewer.id = gij.reviewed_by_user_id
     WHERE gij.id = $1`,
    [importId],
  );
  if (result.rows.length === 0) {
    throw new AppError('Import job not found', 404);
  }
  const job = result.rows[0] as ImportJobAccessRow;
  if (user.role === 'admin') {
    return job;
  }
  if (job.uploaded_by_user_id === user.id) {
    return job;
  }
  const canReview = await hasProjectImportReviewAccess(job.project_id, user);
  if (!canReview) {
    throw new AppError('You do not have access to this import job', 403);
  }
  return job;
};

const listImports = async (req: Request, res: Response): Promise<void> => {
  const { page, limit, offset } = getPagination(req.query.page, req.query.limit);
  const status = typeof req.query.status === 'string' ? req.query.status.trim() : '';
  const projectId = typeof req.query.project_id === 'string' ? req.query.project_id.trim() : '';
  const categoryId = typeof req.query.category_id === 'string' ? req.query.category_id.trim() : '';

  const whereClauses = ['1=1'];
  const params: unknown[] = [];
  let paramIndex = 1;

  if (req.user?.role !== 'admin') {
    whereClauses.push(`gij.uploaded_by_user_id = $${paramIndex}`);
    params.push(req.user?.id);
    paramIndex += 1;
  }

  if (status) {
    const statusFilter = status === 'processing' ? ['uploaded', 'processing'] : [status];
    whereClauses.push(`gij.status = ANY($${paramIndex}::gis_import_status[])`);
    params.push(statusFilter);
    paramIndex += 1;
  }

  if (projectId) {
    whereClauses.push(`gij.project_id = $${paramIndex}`);
    params.push(projectId);
    paramIndex += 1;
  }

  if (categoryId) {
    whereClauses.push(`p.category_id = $${paramIndex}`);
    params.push(categoryId);
    paramIndex += 1;
  }

  const whereSql = whereClauses.join(' AND ');
  const listSql = `
    SELECT gij.*, p.name AS project_name,
           uploader.full_name AS uploaded_by_name,
           reviewer.full_name AS reviewed_by_name
    FROM gis_import_job gij
    JOIN project p ON p.id = gij.project_id
    JOIN "user" uploader ON uploader.id = gij.uploaded_by_user_id
    LEFT JOIN "user" reviewer ON reviewer.id = gij.reviewed_by_user_id
    WHERE ${whereSql}
    ORDER BY gij.uploaded_at DESC
    LIMIT $${paramIndex} OFFSET $${paramIndex + 1}
  `;
  const countSql = `
    SELECT COUNT(*)::int AS total
    FROM gis_import_job gij
    JOIN project p ON p.id = gij.project_id
    WHERE ${whereSql}
  `;

  const [itemsResult, countResult] = await Promise.all([
    query(listSql, [...params, limit, offset]),
    query(countSql, params),
  ]);

  const total = countResult.rows[0]?.total ?? 0;
  res.json({
    success: true,
    data: itemsResult.rows.map(mapImportJobRow),
    pagination: {
      page,
      limit,
      total,
      totalPages: Math.max(1, Math.ceil(total / limit)),
      has_more: offset + itemsResult.rows.length < total,
    },
  });
};

const getImportDetails = async (req: Request, res: Response): Promise<void> => {
  const importId = req.params.importId;
  const job = await fetchImportJobWithAccess(importId, req.user as Express.UserContext);
  const lebanonEnvelopeSql = `ST_MakeEnvelope(${LEBANON_BOUNDS.minLon - LEBANON_BUFFER_DEGREES}, ${LEBANON_BOUNDS.minLat - LEBANON_BUFFER_DEGREES}, ${LEBANON_BOUNDS.maxLon + LEBANON_BUFFER_DEGREES}, ${LEBANON_BOUNDS.maxLat + LEBANON_BUFFER_DEGREES}, 4326)`;

  const previewResult = await query(
    `SELECT gif.*, reviewer.full_name AS reviewed_by_name,
            CASE WHEN gif.geom IS NULL THEN NULL ELSE ST_AsGeoJSON(gif.geom) END AS geometry
     FROM gis_import_feature gif
     LEFT JOIN "user" reviewer ON reviewer.id = gif.reviewed_by_user_id
     WHERE gif.import_job_id = $1
     ORDER BY gif.source_index ASC
     LIMIT $2`,
    [importId, IMPORT_DETAIL_PREVIEW_LIMIT],
  );

  const previewSummaryResult = await query(
    `SELECT
         COUNT(*) FILTER (WHERE geom IS NOT NULL)::int AS geometry_feature_count,
         COUNT(*) FILTER (
           WHERE geom IS NOT NULL
         )::int AS preview_feature_count,
         COUNT(*) FILTER (
           WHERE geom IS NOT NULL
             AND NOT ST_Intersects(geom, ${lebanonEnvelopeSql})
         )::int AS outside_workspace_feature_count
       FROM gis_import_feature
       WHERE import_job_id = $1`,
    [importId],
  );
  const previewSummaryRow = previewSummaryResult.rows[0] ?? {};
  const geometryFeatureCount = Number(previewSummaryRow.geometry_feature_count ?? 0);
  const previewFeatureCount = Math.min(
    Number(previewSummaryRow.preview_feature_count ?? 0),
    IMPORT_DETAIL_PREVIEW_LIMIT,
  );
  const outsideWorkspaceFeatureCount = Number(
    previewSummaryRow.outside_workspace_feature_count ?? 0,
  );
  const commentsResult = await query(
    `SELECT gic.id,
            gic.import_job_id,
            gic.import_feature_id,
            gif.display_title AS feature_display_title,
            gic.author_user_id,
            gic.comment_text,
            gic.created_at,
            u.full_name AS author_name,
            u.role AS author_role
     FROM gis_import_comment gic
     LEFT JOIN gis_import_feature gif ON gif.id = gic.import_feature_id
     JOIN "user" u ON u.id = gic.author_user_id
     WHERE gic.import_job_id = $1
     ORDER BY gic.created_at ASC`,
    [importId],
  );

  res.json({
    success: true,
    data: {
      job: mapImportJobRow(job),
      preview_features: previewResult.rows.map(mapImportFeatureRow),
      preview_summary: {
        geometry_feature_count: geometryFeatureCount,
        preview_feature_count: previewFeatureCount,
        outside_workspace_feature_count: outsideWorkspaceFeatureCount,
      },
      comments: commentsResult.rows.map((row) => mapImportCommentRow(row as ImportCommentRow)),
    },
  });
};

const fetchImportQuickMapPreview = async (importId: string): Promise<ImportQuickMapPreview> => {
  const statsResult = await query(
    `SELECT COUNT(*)::int AS total_feature_count,
            COUNT(geom)::int AS geometry_feature_count,
            ST_XMin(ST_Extent(geom))::float AS min_lon,
            ST_YMin(ST_Extent(geom))::float AS min_lat,
            ST_XMax(ST_Extent(geom))::float AS max_lon,
            ST_YMax(ST_Extent(geom))::float AS max_lat
     FROM gis_import_feature
     WHERE import_job_id = $1`,
    [importId],
  );
  const stats = statsResult.rows[0] ?? {};
  const totalFeatureCount = Number(stats.total_feature_count ?? 0);
  const geometryFeatureCount = Number(stats.geometry_feature_count ?? 0);
  const bounds =
    Number.isFinite(Number(stats.min_lon)) &&
    Number.isFinite(Number(stats.min_lat)) &&
    Number.isFinite(Number(stats.max_lon)) &&
    Number.isFinite(Number(stats.max_lat))
      ? {
          min_lon: Number(stats.min_lon),
          min_lat: Number(stats.min_lat),
          max_lon: Number(stats.max_lon),
          max_lat: Number(stats.max_lat),
        }
      : null;
  const simplifyToleranceDegrees = bounds
    ? Math.min(
        0.00025,
        Math.max(
          IMPORT_QUICK_MAP_SIMPLIFY_TOLERANCE_DEGREES,
          Math.max(bounds.max_lon - bounds.min_lon, bounds.max_lat - bounds.min_lat) / 2500,
        ),
      )
    : IMPORT_QUICK_MAP_SIMPLIFY_TOLERANCE_DEGREES;

  const statusResult = await query(
    `SELECT status::text AS status, COUNT(*)::int AS total
     FROM gis_import_feature
     WHERE import_job_id = $1
     GROUP BY status
     ORDER BY status ASC`,
    [importId],
  );
  const statusCounts = Object.fromEntries(
    statusResult.rows.map((row) => [String(row.status), Number(row.total ?? 0)]),
  ) as Record<string, number>;

  if (geometryFeatureCount === 0) {
    return {
      total_feature_count: totalFeatureCount,
      geometry_feature_count: geometryFeatureCount,
      rendered_feature_count: 0,
      is_clustered: false,
      bounds,
      status_counts: statusCounts,
      features: [],
    };
  }

  const result = await query(
    `WITH prepared AS (
       SELECT gif.id,
              gif.import_job_id,
              gif.source_index,
              gif.source_identifier,
              gif.display_title,
              gif.source_feature_name,
              gif.geometry_type,
              gif.status,
              gif.duplicate_feature_id,
              gif.approved_feature_id,
              gif.reviewed_by_user_id,
              NULL::text AS reviewed_by_name,
              gif.reviewed_at,
              gif.approved_at,
              gif.review_reason,
              gif.created_at,
              gif.updated_at,
              gif.geom,
              CASE
                WHEN GeometryType(gif.geom) IN ('POLYGON', 'MULTIPOLYGON') THEN ST_PointOnSurface(gif.geom)
                WHEN GeometryType(gif.geom) = 'POINT' THEN gif.geom
                ELSE ST_Centroid(gif.geom)
              END AS overview_geom
       FROM gis_import_feature gif
       WHERE gif.import_job_id = $1
         AND gif.geom IS NOT NULL
     ),
     numbered AS (
       SELECT *,
              ROW_NUMBER() OVER (ORDER BY ST_Y(overview_geom), ST_X(overview_geom), source_index) AS quick_row,
              COUNT(*) OVER () AS quick_total
       FROM prepared
     ),
     sampled AS (
       SELECT *,
              CASE
                WHEN quick_total <= $2::int THEN quick_row
                ELSE FLOOR(((quick_row - 1)::double precision * $2::double precision) / quick_total)::int
              END AS quick_bucket
       FROM numbered
     ),
     ranked AS (
       SELECT *,
              ROW_NUMBER() OVER (PARTITION BY quick_bucket ORDER BY quick_row) AS bucket_row,
              COUNT(*) OVER (PARTITION BY quick_bucket)::int AS represented_count
       FROM sampled
     )
     SELECT id::text,
            import_job_id::text,
            source_index,
            source_identifier,
            display_title,
            source_feature_name,
            geometry_type,
            status,
            duplicate_feature_id,
            approved_feature_id,
            reviewed_by_user_id,
            reviewed_by_name,
            reviewed_at,
            approved_at,
            review_reason,
            created_at,
            updated_at,
            ST_AsGeoJSON(
              CASE
                WHEN $3::double precision > 0
                  AND GeometryType(geom) IN ('POLYGON', 'MULTIPOLYGON', 'LINESTRING', 'MULTILINESTRING')
                  THEN
                    CASE
                      WHEN geometry_type = 'MultiPolygon' THEN
                        ST_Multi(
                          ST_CollectionExtract(
                            ST_SimplifyPreserveTopology(geom, $3::double precision),
                            3
                          )
                        )
                      WHEN geometry_type = 'MultiLineString' THEN
                        ST_Multi(
                          ST_CollectionExtract(
                            ST_SimplifyPreserveTopology(geom, $3::double precision),
                            2
                          )
                        )
                      ELSE ST_SimplifyPreserveTopology(geom, $3::double precision)
                    END
                ELSE geom
              END
            ) AS geometry,
            (represented_count > 1) AS is_aggregate,
            represented_count AS cluster_count
     FROM ranked
     WHERE bucket_row = 1
     ORDER BY quick_row ASC`,
    [importId, IMPORT_QUICK_MAP_PREVIEW_LIMIT, simplifyToleranceDegrees],
  );

  return {
    total_feature_count: totalFeatureCount,
    geometry_feature_count: geometryFeatureCount,
    rendered_feature_count: result.rows.length,
    is_clustered: result.rows.some((row) => Number(row.cluster_count ?? 0) > 1),
    bounds,
    status_counts: statusCounts,
    features: result.rows.map((row) => mapImportMapFeatureRow(row as ImportFeatureRow)),
  };
};

const getImportQuickMapPreview = async (req: Request, res: Response): Promise<void> => {
  const importId = req.params.importId;
  await fetchImportJobWithAccess(importId, req.user as Express.UserContext);
  const preview = await fetchImportQuickMapPreview(importId);
  res.json({
    success: true,
    data: preview,
  });
};

const getImportMapData = async (req: Request, res: Response): Promise<void> => {
  const importId = req.params.importId;
  const job = await fetchImportJobWithAccess(importId, req.user as Express.UserContext);
  const bounds = parseViewportBounds({
    minLon: req.query.minLon,
    minLat: req.query.minLat,
    maxLon: req.query.maxLon,
    maxLat: req.query.maxLat,
  });
  const zoom = normalizeMapZoom(req.query.zoom, 11);
  const mapData = await fetchImportMapLayerData({
    importId,
    projectId: job.project_id,
    bounds,
    zoom,
    cacheVersion: job.updated_at,
  });

  res.json({
    success: true,
    data: mapData,
  });
};

const fetchImportMapLayerData = async ({
  importId,
  projectId,
  bounds,
  zoom,
  cacheVersion,
}: {
  importId: string;
  projectId: string;
  bounds: { minLon: number; minLat: number; maxLon: number; maxLat: number };
  zoom: number;
  cacheVersion: string | null;
}): Promise<ImportMapLayerData> => {
  const cacheKey = importMapLayerCacheKey({
    importId,
    projectId,
    bounds,
    zoom,
    cacheVersion,
  });
  const cached = getCachedImportMapLayer(cacheKey);
  if (cached) {
    return cached;
  }

  const simplifyTolerance = mapSimplifyTolerance(zoom);
  const stagedGeometrySql = mapRenderGeometrySql('gif.geom', zoom, simplifyTolerance);
  const projectGeometrySql = mapRenderGeometrySql('sf.geom', zoom, simplifyTolerance);
  const tileFeatureLimit =
    zoom < 10.5 ? IMPORT_MAP_TILE_LOW_ZOOM_LIMIT : IMPORT_MAP_TILE_HIGH_ZOOM_LIMIT;

  const stagedResult =
    zoom < 10.5
      ? await query(
          `WITH prepared AS (
             SELECT gif.id,
                    gif.import_job_id,
                    gif.source_index,
                    gif.source_identifier,
                    gif.display_title,
                    gif.source_feature_name,
                    gif.geometry_type,
                    gif.status,
                    gif.approved_feature_id,
                    gif.reviewed_at,
                    gif.approved_at,
                    gif.review_reason,
                    gif.created_at,
                    gif.updated_at,
                    CASE
                      WHEN GeometryType(gif.geom) IN ('POLYGON', 'MULTIPOLYGON') THEN ST_PointOnSurface(gif.geom)
                      WHEN GeometryType(gif.geom) IN ('LINESTRING', 'MULTILINESTRING') THEN ST_Centroid(gif.geom)
                      ELSE gif.geom
                    END AS marker_geom
             FROM gis_import_feature gif
             WHERE gif.import_job_id = $1
               AND gif.geom IS NOT NULL
               AND gif.geom && ST_MakeEnvelope($2, $3, $4, $5, 4326)
           ),
           marker_filtered AS (
             SELECT *
             FROM prepared
             WHERE marker_geom && ST_MakeEnvelope($2, $3, $4, $5, 4326)
           ),
           bucketed AS (
             SELECT *,
                    FLOOR(ST_Y(marker_geom) / $6) AS lat_bucket,
                    FLOOR(ST_X(marker_geom) / $6) AS lon_bucket
             FROM marker_filtered
           )
           SELECT CASE
                    WHEN COUNT(*) = 1 THEN (ARRAY_AGG(id::text ORDER BY source_index))[1]
                    ELSE CONCAT('cluster:', status, ':', lat_bucket, ':', lon_bucket)
                  END AS id,
                  (ARRAY_AGG(import_job_id::text ORDER BY source_index))[1] AS import_job_id,
                  MIN(source_index) AS source_index,
                  CASE
                    WHEN COUNT(*) = 1 THEN (ARRAY_AGG(source_identifier ORDER BY source_index))[1]
                    ELSE NULL
                  END AS source_identifier,
                  CASE
                    WHEN COUNT(*) = 1 THEN (ARRAY_AGG(display_title ORDER BY source_index))[1]
                    ELSE CONCAT(COUNT(*)::text, ' imported features')
                  END AS display_title,
                  CASE
                    WHEN COUNT(*) = 1 THEN (ARRAY_AGG(source_feature_name ORDER BY source_index))[1]
                    ELSE NULL
                  END AS source_feature_name,
                  CASE
                    WHEN COUNT(DISTINCT geometry_type) = 1 THEN MIN(geometry_type)
                    ELSE NULL
                  END AS geometry_type,
                  status,
                  NULL::text AS duplicate_feature_id,
                  CASE
                    WHEN COUNT(*) = 1 THEN (ARRAY_AGG(approved_feature_id::text ORDER BY source_index))[1]
                    ELSE NULL
                  END AS approved_feature_id,
                  NULL::text AS reviewed_by_user_id,
                  NULL::text AS reviewed_by_name,
                  CASE
                    WHEN COUNT(*) = 1 THEN (ARRAY_AGG(reviewed_at ORDER BY source_index))[1]
                    ELSE NULL
                  END AS reviewed_at,
                  CASE
                    WHEN COUNT(*) = 1 THEN (ARRAY_AGG(approved_at ORDER BY source_index))[1]
                    ELSE NULL
                  END AS approved_at,
                  CASE
                    WHEN COUNT(*) = 1 THEN (ARRAY_AGG(review_reason ORDER BY source_index))[1]
                    ELSE NULL
                  END AS review_reason,
                  MIN(created_at) AS created_at,
                  MAX(updated_at) AS updated_at,
                  ST_AsGeoJSON(ST_Centroid(ST_Collect(marker_geom))) AS geometry,
                  (COUNT(*) > 1) AS is_aggregate,
                  COUNT(*)::int AS cluster_count
           FROM bucketed
           GROUP BY status, lat_bucket, lon_bucket
           ORDER BY MIN(source_index) ASC`,
          [
            importId,
            bounds.minLon,
            bounds.minLat,
            bounds.maxLon,
            bounds.maxLat,
            mapClusterCellSizeDegrees(zoom),
          ],
        )
      : await query(
          `SELECT gif.id,
                  gif.import_job_id,
                  gif.source_index,
                  gif.source_identifier,
                  gif.display_title,
                  gif.source_feature_name,
                  gif.geometry_type,
                  gif.status,
                  gif.duplicate_feature_id,
                  gif.approved_feature_id,
                  gif.reviewed_by_user_id,
                  reviewer.full_name AS reviewed_by_name,
                  gif.reviewed_at,
                  gif.approved_at,
                  gif.review_reason,
                  gif.created_at,
                  gif.updated_at,
                  ${stagedGeometrySql} AS geometry,
                  false AS is_aggregate,
                  1 AS cluster_count
           FROM gis_import_feature gif
           LEFT JOIN "user" reviewer ON reviewer.id = gif.reviewed_by_user_id
           WHERE gif.import_job_id = $1
             AND gif.geom IS NOT NULL
             AND gif.geom && ST_MakeEnvelope($2, $3, $4, $5, 4326)
           ORDER BY gif.source_index ASC
           LIMIT $6`,
          [importId, bounds.minLon, bounds.minLat, bounds.maxLon, bounds.maxLat, tileFeatureLimit],
        );

  const approvedProjectResult =
    zoom < 10.5
      ? await query(
          `WITH visible AS (
             SELECT sf.id,
                    sf.status,
                    GeometryType(sf.geom) AS source_geometry_type,
                    sf.attributes,
                    collector.full_name AS collected_by,
                    reviewer.full_name AS reviewed_by,
                    sf.review_notes,
                    sf.collected_at,
                    sf.submitted_at,
                    sf.reviewed_at,
                    (SELECT COUNT(*) FROM photo WHERE feature_id = sf.id) AS photo_count,
                    CASE
                      WHEN GeometryType(sf.geom) IN ('POLYGON', 'MULTIPOLYGON') THEN ST_PointOnSurface(sf.geom)
                      WHEN GeometryType(sf.geom) IN ('LINESTRING', 'MULTILINESTRING') THEN ST_Centroid(sf.geom)
                      ELSE sf.geom
                    END AS marker_geom
             FROM spatial_feature sf
             LEFT JOIN "user" collector ON collector.id = sf.collected_by_user_id
             LEFT JOIN "user" reviewer ON reviewer.id = sf.reviewed_by_user_id
             WHERE sf.project_id = $1
               AND sf.status = 'approved'
               AND NOT EXISTS (
                 SELECT 1
                 FROM gis_import_feature source_feature
                 WHERE source_feature.import_job_id = $7
                   AND source_feature.approved_feature_id = sf.id
               )
               AND sf.geom && ST_MakeEnvelope($2, $3, $4, $5, 4326)
           ),
           marker_filtered AS (
             SELECT *
             FROM visible
             WHERE marker_geom && ST_MakeEnvelope($2, $3, $4, $5, 4326)
           ),
           bucketed AS (
             SELECT *,
                    FLOOR(ST_Y(marker_geom) / $6)::int AS lat_bucket,
                    FLOOR(ST_X(marker_geom) / $6)::int AS lon_bucket
             FROM marker_filtered
           )
           SELECT CASE
                    WHEN COUNT(*) = 1 THEN (ARRAY_AGG(id::text ORDER BY reviewed_at DESC NULLS LAST, submitted_at DESC NULLS LAST, id ASC))[1]
                    ELSE CONCAT('project-context-cluster:', lat_bucket::text, ':', lon_bucket::text)
                  END AS id,
                  'approved'::text AS status,
                  CASE
                    WHEN COUNT(DISTINCT source_geometry_type) = 1 THEN MIN(source_geometry_type)
                    ELSE 'Geometry'
                  END AS source_geometry_type,
                  ST_AsGeoJSON(ST_Centroid(ST_Collect(marker_geom))) AS geometry,
                  CASE
                    WHEN COUNT(*) = 1 THEN (ARRAY_AGG(attributes ORDER BY reviewed_at DESC NULLS LAST, submitted_at DESC NULLS LAST, id ASC))[1]
                    ELSE jsonb_build_object('cluster_count', COUNT(*))
                  END AS attributes,
                  CASE
                    WHEN COUNT(*) = 1 THEN (ARRAY_AGG(collected_by ORDER BY reviewed_at DESC NULLS LAST, submitted_at DESC NULLS LAST, id ASC))[1]
                    ELSE NULL
                  END AS collected_by,
                  CASE
                    WHEN COUNT(*) = 1 THEN (ARRAY_AGG(reviewed_by ORDER BY reviewed_at DESC NULLS LAST, submitted_at DESC NULLS LAST, id ASC))[1]
                    ELSE NULL
                  END AS reviewed_by,
                  CASE
                    WHEN COUNT(*) = 1 THEN (ARRAY_AGG(review_notes ORDER BY reviewed_at DESC NULLS LAST, submitted_at DESC NULLS LAST, id ASC))[1]
                    ELSE NULL
                  END AS review_notes,
                  MIN(collected_at) AS collected_at,
                  MAX(submitted_at) AS submitted_at,
                  MAX(reviewed_at) AS reviewed_at,
                  SUM(photo_count)::int AS photo_count,
                  (COUNT(*) > 1) AS is_aggregate,
                  COUNT(*)::int AS cluster_count
           FROM bucketed
           GROUP BY lat_bucket, lon_bucket
           ORDER BY MAX(reviewed_at) DESC NULLS LAST, MAX(submitted_at) DESC NULLS LAST
           LIMIT $8`,
          [
            projectId,
            bounds.minLon,
            bounds.minLat,
            bounds.maxLon,
            bounds.maxLat,
            mapClusterCellSizeDegrees(zoom),
            importId,
            tileFeatureLimit,
          ],
        )
      : await query(
          `SELECT sf.id,
                  sf.status,
                  GeometryType(sf.geom) AS source_geometry_type,
                  ${projectGeometrySql} AS geometry,
                  sf.attributes,
                  collector.full_name AS collected_by,
                  reviewer.full_name AS reviewed_by,
                  sf.review_notes,
                  sf.collected_at,
                  sf.submitted_at,
                  sf.reviewed_at,
                  (SELECT COUNT(*) FROM photo WHERE feature_id = sf.id) AS photo_count,
                  false AS is_aggregate,
                  1 AS cluster_count
           FROM spatial_feature sf
           LEFT JOIN "user" collector ON collector.id = sf.collected_by_user_id
           LEFT JOIN "user" reviewer ON reviewer.id = sf.reviewed_by_user_id
           WHERE sf.project_id = $1
             AND sf.status = 'approved'
             AND NOT EXISTS (
               SELECT 1
               FROM gis_import_feature source_feature
               WHERE source_feature.import_job_id = $6
                 AND source_feature.approved_feature_id = sf.id
             )
             AND sf.geom && ST_MakeEnvelope($2, $3, $4, $5, 4326)
           ORDER BY sf.reviewed_at DESC NULLS LAST, sf.submitted_at DESC NULLS LAST, sf.id ASC
           LIMIT $7`,
          [
            projectId,
            bounds.minLon,
            bounds.minLat,
            bounds.maxLon,
            bounds.maxLat,
            importId,
            tileFeatureLimit,
          ],
        );

  const data = {
    staged_features: stagedResult.rows.map((row) =>
      mapImportMapFeatureRow(row as ImportFeatureRow),
    ),
    approved_project_features: approvedProjectResult.rows.map(mapImportMapProjectFeatureRow),
  };
  rememberImportMapLayer(cacheKey, data);
  return data;
};

const getImportMapTileData = async (req: Request, res: Response): Promise<void> => {
  const importId = req.params.importId;
  const job = await fetchImportJobWithAccess(importId, req.user as Express.UserContext);
  const zoom = normalizeMapZoom(req.query.zoom ?? req.params.z, 11);
  const bounds = getTileBounds(req.params.z, req.params.x, req.params.y);
  const data = await fetchImportMapLayerData({
    importId,
    projectId: job.project_id,
    bounds,
    zoom,
    cacheVersion: job.updated_at,
  });

  res.json({
    success: true,
    data,
  });
};

const getImportFeatureDetails = async (req: Request, res: Response): Promise<void> => {
  const importId = req.params.importId;
  const featureId = req.params.featureId;
  await fetchImportJobWithAccess(importId, req.user as Express.UserContext);

  const result = await query(
    `SELECT gif.*, reviewer.full_name AS reviewed_by_name,
            CASE WHEN gif.geom IS NULL THEN NULL ELSE ST_AsGeoJSON(gif.geom) END AS geometry
     FROM gis_import_feature gif
     LEFT JOIN "user" reviewer ON reviewer.id = gif.reviewed_by_user_id
     WHERE gif.import_job_id = $1
       AND gif.id = $2
     LIMIT 1`,
    [importId, featureId],
  );

  const row = result.rows[0] as ImportFeatureRow | undefined;
  if (!row) {
    throw new AppError('The imported feature was not found for this import.', 404);
  }

  res.json({
    success: true,
    data: mapImportFeatureRow(row),
  });
};

const normalizeImportReviewFilters = (input: unknown): ImportReviewFilters => {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    return {};
  }
  const raw = input as Record<string, unknown>;
  const readString = (key: keyof ImportReviewFilters): string | undefined => {
    const value = raw[key];
    if (typeof value !== 'string') {
      return undefined;
    }
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : undefined;
  };
  return {
    status: readString('status'),
    issue: readString('issue'),
    search: readString('search'),
    geometry_type: readString('geometry_type'),
    feature_type: readString('feature_type'),
  };
};

const appendImportFeatureFilters = ({
  whereClauses,
  params,
  paramIndex,
  filters,
}: {
  whereClauses: string[];
  params: unknown[];
  paramIndex: number;
  filters: ImportReviewFilters;
}): number => {
  if (filters.status) {
    whereClauses.push(`gif.status = $${paramIndex}`);
    params.push(filters.status);
    paramIndex += 1;
  }
  if (filters.issue) {
    whereClauses.push(
      `(gif.validation_errors @> to_jsonb(ARRAY[$${paramIndex}]::text[]) OR gif.validation_warnings @> to_jsonb(ARRAY[$${paramIndex}]::text[]))`,
    );
    params.push(filters.issue);
    paramIndex += 1;
  }
  if (filters.geometry_type) {
    switch (filters.geometry_type) {
      case 'point':
        whereClauses.push(
          `(gif.geometry_type = $${paramIndex} OR gif.geometry_type = $${paramIndex + 1})`,
        );
        params.push('Point', 'MultiPoint');
        paramIndex += 2;
        break;
      case 'line':
        whereClauses.push(
          `(gif.geometry_type = $${paramIndex} OR gif.geometry_type = $${paramIndex + 1})`,
        );
        params.push('LineString', 'MultiLineString');
        paramIndex += 2;
        break;
      case 'polygon':
        whereClauses.push(
          `(gif.geometry_type = $${paramIndex} OR gif.geometry_type = $${paramIndex + 1})`,
        );
        params.push('Polygon', 'MultiPolygon');
        paramIndex += 2;
        break;
      default:
        whereClauses.push(`gif.geometry_type = $${paramIndex}`);
        params.push(filters.geometry_type);
        paramIndex += 1;
        break;
    }
  }
  if (filters.feature_type) {
    whereClauses.push(
      `EXISTS (
        SELECT 1
        FROM jsonb_each_text(COALESCE(gif.attributes, '{}'::jsonb)) AS attr(key, value)
        WHERE (
          LOWER(attr.key) LIKE '%type%'
          OR LOWER(attr.key) LIKE '%species%'
          OR LOWER(attr.key) LIKE '%crop%'
          OR LOWER(attr.key) LIKE '%tree%'
          OR LOWER(attr.key) LIKE '%orchard%'
        )
          AND LOWER(BTRIM(attr.value)) = LOWER($${paramIndex})
      )`,
    );
    params.push(filters.feature_type);
    paramIndex += 1;
  }
  if (filters.search) {
    whereClauses.push(
      `(gif.display_title ILIKE $${paramIndex}
        OR COALESCE(gif.source_feature_name, '') ILIKE $${paramIndex}
        OR gif.attributes::text ILIKE $${paramIndex})`,
    );
    params.push(`%${filters.search}%`);
    paramIndex += 1;
  }
  return paramIndex;
};

const listImportFeatures = async (req: Request, res: Response): Promise<void> => {
  const importId = req.params.importId;
  const job = await fetchImportJobWithAccess(importId, req.user as Express.UserContext);
  const { page, limit, offset } = getPagination(req.query.page, req.query.limit);
  const filters = normalizeImportReviewFilters({
    status: req.query.status,
    issue: req.query.issue,
    search: req.query.search,
    geometry_type: req.query.geometry_type,
    feature_type: req.query.feature_type,
  });
  const whereClauses = ['gif.import_job_id = $1'];
  const params: unknown[] = [importId];
  let paramIndex = appendImportFeatureFilters({
    whereClauses,
    params,
    paramIndex: 2,
    filters,
  });

  const whereSql = whereClauses.join(' AND ');
  const listSql = `
    SELECT gif.id,
           gif.import_job_id,
           gif.source_index,
           gif.source_identifier,
           gif.display_title,
           gif.source_feature_name,
           gif.geometry_type,
           NULL::text AS geometry,
           gif.attributes,
           gif.status,
           gif.validation_warnings,
           gif.validation_errors,
           gif.validation_report,
           gif.duplicate_feature_id,
           gif.approved_feature_id,
           gif.reviewed_by_user_id,
           reviewer.full_name AS reviewed_by_name,
           gif.reviewed_at,
           gif.approved_at,
           gif.review_reason,
           gif.created_at,
           gif.updated_at
    FROM gis_import_feature gif
    LEFT JOIN "user" reviewer ON reviewer.id = gif.reviewed_by_user_id
    WHERE ${whereSql}
    ORDER BY gif.source_index ASC
    LIMIT $${paramIndex} OFFSET $${paramIndex + 1}
  `;
  const countSql = `SELECT COUNT(*)::int AS total FROM gis_import_feature gif WHERE ${whereSql}`;

  const [itemsResult, countResult] = await Promise.all([
    query(listSql, [...params, limit, offset]),
    query(countSql, params),
  ]);

  const total = countResult.rows[0]?.total ?? 0;
  res.json({
    success: true,
    data: itemsResult.rows.map((row) =>
      mapImportFeatureSummaryRow(row as ImportFeatureRow, job.project_collection_form_schema ?? {}),
    ),
    pagination: {
      page,
      limit,
      total,
      totalPages: Math.max(1, Math.ceil(total / limit)),
      has_more: offset + itemsResult.rows.length < total,
    },
  });
};

const uploadImport = async (req: Request, res: Response): Promise<void> => {
  const projectId = req.params.projectId;
  const currentUser = req.user as Express.UserContext;
  if (!req.file) {
    throw new AppError('A GIS file is required.', 400);
  }

  const hasAccess = await hasProjectImportAccess(projectId, currentUser);
  if (!hasAccess) {
    throw new AppError('You do not have permission to import data into this project.', 403);
  }

  await assertProjectAllowsImport(projectId);
  const project = await getProjectForImport(projectId);
  const fileType = inferImportFileType(req.file.originalname);
  const fileChecksum = await sha256File(req.file.path);
  const duplicateImportResult = await query(
    `SELECT id
     FROM gis_import_job
     WHERE project_id = $1
       AND file_checksum_sha256 = $2
     ORDER BY uploaded_at DESC
     LIMIT 1`,
    [projectId, fileChecksum],
  );
  const duplicateOfImportJobId = duplicateImportResult.rows[0]?.id ?? null;

  const createdJob = await transaction(async (client: any) => {
    const insertedJob = await client.query(
      `INSERT INTO gis_import_job (
         project_id,
         uploaded_by_user_id,
         duplicate_of_import_job_id,
         original_filename,
         stored_filename,
         file_path,
         file_size_bytes,
         file_checksum_sha256,
         file_type,
         source_crs,
         source_layer_name,
         status,
         file_metadata,
         validation_summary,
         processing_message
       ) VALUES (
         $1, $2, $3, $4, $5, $6, $7, $8, $9::gis_import_file_type, NULL, NULL, 'uploaded', $10::jsonb, '{}'::jsonb, 'Import queued for background processing'
       )
       RETURNING id`,
      [
        projectId,
        currentUser.id,
        duplicateOfImportJobId,
        req.file.originalname,
        req.file.filename,
        req.file.path,
        req.file.size,
        fileChecksum,
        fileType,
        JSON.stringify({
          file_name: req.file.originalname,
          file_size_bytes: req.file.size,
          queued_at: new Date().toISOString(),
        }),
      ],
    );

    const importJobId = insertedJob.rows[0].id;

    await createImportSubmissionNotifications(client, {
      importJobId,
      projectId,
      projectName: project.name,
      uploader: currentUser,
      originalFilename: req.file.originalname,
      uploaderRole: currentUser.role,
    });

    const detailResult = await client.query(
      `SELECT gij.*, p.name AS project_name,
              uploader.full_name AS uploaded_by_name,
              reviewer.full_name AS reviewed_by_name
       FROM gis_import_job gij
       JOIN project p ON p.id = gij.project_id
       JOIN "user" uploader ON uploader.id = gij.uploaded_by_user_id
       LEFT JOIN "user" reviewer ON reviewer.id = gij.reviewed_by_user_id
      WHERE gij.id = $1`,
      [importJobId],
    );

    return detailResult.rows[0];
  });

  scheduleImportProcessing();

  logger.info('GIS import uploaded and queued', {
    importJobId: createdJob.id,
    projectId,
    userId: currentUser.id,
    fileType,
    originalFilename: req.file.originalname,
  });

  res.status(202).json({
    success: true,
    message: 'GIS import uploaded successfully.',
    data: mapImportJobRow(createdJob),
  });
};

const downloadImport = async (req: Request, res: Response): Promise<void> => {
  const importId = req.params.importId;
  const currentUser = req.user as Express.UserContext;
  const job = await fetchImportJobWithAccess(importId, currentUser);
  const canDownload = await canDownloadImportJob(job, currentUser);
  if (!canDownload) {
    throw new AppError('You are not allowed to download this import file.', 403);
  }
  const filePath = path.resolve(job.file_path);

  try {
    await fs.access(filePath);
  } catch (_error) {
    throw new AppError('The original import file is no longer available for download.', 404);
  }

  res.download(filePath, job.original_filename);
};

const listImportComments = async (req: Request, res: Response): Promise<void> => {
  const importId = req.params.importId;
  await fetchImportJobWithAccess(importId, req.user as Express.UserContext);

  const result = await query(
    `SELECT gic.id,
            gic.import_job_id,
            gic.import_feature_id,
            gif.display_title AS feature_display_title,
            gic.author_user_id,
            gic.comment_text,
            gic.created_at,
            u.full_name AS author_name,
            u.role AS author_role
     FROM gis_import_comment gic
     LEFT JOIN gis_import_feature gif ON gif.id = gic.import_feature_id
     JOIN "user" u ON u.id = gic.author_user_id
     WHERE gic.import_job_id = $1
     ORDER BY gic.created_at ASC`,
    [importId],
  );

  res.json({
    success: true,
    data: result.rows.map((row) => mapImportCommentRow(row as ImportCommentRow)),
  });
};

const addImportComment = async (req: Request, res: Response): Promise<void> => {
  const importId = req.params.importId;
  const currentUser = req.user as Express.UserContext;
  const commentText = String(req.body?.comment ?? '').trim();
  const rawFeatureId = typeof req.body?.feature_id === 'string' ? req.body.feature_id.trim() : '';
  const featureId = rawFeatureId.length > 0 ? rawFeatureId : null;
  if (!commentText) {
    throw new AppError('A comment is required.', 400);
  }

  const job = await fetchImportJobWithAccess(importId, currentUser);
  const canComment = await canCommentOnImportJob(job, currentUser);
  if (!canComment) {
    throw new AppError('You are not allowed to comment on this import.', 403);
  }

  let linkedFeature: { id: string; display_title: string } | null = null;
  if (featureId) {
    const featureResult = await query(
      `SELECT id, display_title
       FROM gis_import_feature
       WHERE id = $1
         AND import_job_id = $2
       LIMIT 1`,
      [featureId, importId],
    );
    linkedFeature = featureResult.rows[0] ?? null;
    if (!linkedFeature) {
      throw new AppError('The selected imported feature was not found for this import.', 404);
    }
  }

  const createdComment = await transaction(async (client: any) => {
    const insertResult = await client.query(
      `INSERT INTO gis_import_comment (
         import_job_id,
         import_feature_id,
         author_user_id,
         comment_text
       ) VALUES ($1, $2, $3, $4)
       RETURNING id, import_job_id, import_feature_id, author_user_id, comment_text, created_at`,
      [importId, linkedFeature?.id ?? null, currentUser.id, commentText],
    );

    if (job.uploaded_by_user_id !== currentUser.id) {
      await createNotification(client, {
        userId: job.uploaded_by_user_id,
        type: 'import_event',
        title: `Import comment added in ${job.project_name}`,
        message: linkedFeature
          ? `${currentUser.full_name} added a comment on ${linkedFeature.display_title} in ${job.original_filename}.`
          : `${currentUser.full_name} added a comment on ${job.original_filename}.`,
        metadata: {
          import_job_id: job.id,
          project_id: job.project_id,
          project_name: job.project_name,
          status: job.status,
          feature_id: linkedFeature?.id ?? null,
          feature_display_title: linkedFeature?.display_title ?? null,
          comment_preview: commentText.slice(0, 240),
        },
      });
    }

    const commentResult = await client.query(
      `SELECT gic.id,
              gic.import_job_id,
              gic.import_feature_id,
              gif.display_title AS feature_display_title,
              gic.author_user_id,
              gic.comment_text,
              gic.created_at,
              u.full_name AS author_name,
              u.role AS author_role
       FROM gis_import_comment gic
       LEFT JOIN gis_import_feature gif ON gif.id = gic.import_feature_id
       JOIN "user" u ON u.id = gic.author_user_id
       WHERE gic.id = $1`,
      [insertResult.rows[0].id],
    );

    return commentResult.rows[0] as ImportCommentRow;
  });

  res.status(201).json({
    success: true,
    message: 'Import comment saved successfully.',
    data: mapImportCommentRow(createdComment),
  });
};

const reviewImport = async (req: Request, res: Response): Promise<void> => {
  const importId = req.params.importId;
  const {
    status,
    reason,
    feature_ids: featureIds,
    filters: rawFilters,
  } = req.body as {
    status: 'approved' | 'rejected';
    reason?: string;
    feature_ids?: string[];
    filters?: ImportReviewFilters;
  };

  const currentUser = req.user as Express.UserContext;
  const job = await fetchImportJobWithAccess(importId, currentUser);
  const canReview = await canReviewImportJob(job, currentUser);
  if (!canReview) {
    throw new AppError('You are not allowed to review this import.', 403);
  }

  const normalizedReason =
    typeof reason === 'string' && reason.trim().length > 0 ? reason.trim() : null;
  const selectedFeatureIds = Array.isArray(featureIds)
    ? [...new Set(featureIds.map((value) => String(value).trim()).filter(Boolean))]
    : [];
  const reviewFilters = normalizeImportReviewFilters(rawFilters);

  const updatedJob = await transaction(async (client: any) => {
    const allowedStatuses =
      status === 'approved' ? ['pending_review', 'rejected'] : ['pending_review', 'approved'];

    const targetParams: unknown[] = [importId, allowedStatuses];
    const targetWhereClauses = [
      'gif.import_job_id = $1',
      'gif.status = ANY($2::gis_import_feature_status[])',
    ];
    if (selectedFeatureIds.length > 0) {
      targetParams.push(selectedFeatureIds);
      targetWhereClauses.push(`gif.id = ANY($3::uuid[])`);
    } else {
      appendImportFeatureFilters({
        whereClauses: targetWhereClauses,
        params: targetParams,
        paramIndex: 3,
        filters: reviewFilters,
      });
    }
    const targetWhereSql = targetWhereClauses.join(' AND ');

    const targetResult = await client.query(
      `SELECT COUNT(*)::int AS total
       FROM gis_import_feature gif
       WHERE ${targetWhereSql}`,
      targetParams,
    );

    if ((targetResult.rows[0]?.total ?? 0) === 0) {
      throw new AppError('No staged import features matched this review action.', 409);
    }

    if (status === 'approved') {
      const baseParamIndex = targetParams.length;
      const approvalParams = [
        ...targetParams,
        job.project_id,
        job.uploaded_by_user_id,
        currentUser.id,
        `Imported from ${job.original_filename}${normalizedReason ? ` (${normalizedReason})` : ''}`,
        normalizedReason,
        SUPPORTED_SPATIAL_FEATURE_GEOMETRY_TYPES,
      ];
      await client.query(
        `WITH target AS (
           SELECT gif.id,
                  gif.display_title,
                  gif.geometry_type,
                  gif.geom,
                  gif.attributes
           FROM gis_import_feature gif
           WHERE ${targetWhereSql}
           ORDER BY gif.source_index ASC
           FOR UPDATE
         ),
         invalid_target AS (
           SELECT target.id,
                  CASE
                    WHEN target.geom IS NULL THEN
                      'Missing geometry: this imported feature cannot be approved.'
                    WHEN GeometryType(target.geom) <> ALL($${baseParamIndex + 6}::text[]) THEN
                      'Unsupported geometry type: ' || COALESCE(GeometryType(target.geom), target.geometry_type, 'unknown') || '.'
                    WHEN ST_IsValid(target.geom) IS DISTINCT FROM TRUE
                      AND (
                        LOWER(ST_IsValidReason(target.geom)) LIKE '%ring self-intersection%'
                        OR LOWER(ST_IsValidReason(target.geom)) LIKE '%self-intersection%'
                      ) THEN
                      'Invalid polygon geometry: ring self-intersection. Fix the geometry in GIS software or exclude this feature.'
                    WHEN ST_IsValid(target.geom) IS DISTINCT FROM TRUE THEN
                      'Invalid geometry: ' || ST_IsValidReason(target.geom) || '.'
                    ELSE
                      'Invalid geometry: this imported feature cannot be approved.'
                  END AS error_message
           FROM target
           WHERE target.geom IS NULL
              OR GeometryType(target.geom) <> ALL($${baseParamIndex + 6}::text[])
              OR ST_IsValid(target.geom) IS DISTINCT FROM TRUE
         ),
         invalid_update AS (
           UPDATE gis_import_feature gif
           SET status = 'failed',
               approved_feature_id = NULL,
               validation_errors = COALESCE(gif.validation_errors, '[]'::jsonb)
                 || jsonb_build_array(invalid_target.error_message),
               reviewed_by_user_id = $${baseParamIndex + 3},
               reviewed_at = CURRENT_TIMESTAMP,
               approved_at = NULL,
               review_reason = $${baseParamIndex + 5}
           FROM invalid_target
           WHERE gif.id = invalid_target.id
           RETURNING gif.id
         ),
         valid_target AS (
           SELECT uuid_generate_v4() AS approved_feature_id,
                  target.id AS import_feature_id,
                  target.geom,
                  target.attributes
           FROM target
           WHERE NOT EXISTS (
             SELECT 1
             FROM invalid_target
             WHERE invalid_target.id = target.id
           )
         ),
         inserted AS (
           INSERT INTO spatial_feature (
             id,
             project_id,
             collected_by_user_id,
             geom,
             attributes,
             status,
             source,
             submitted_at,
             reviewed_by_user_id,
             review_notes,
             reviewed_at,
             collected_offline
           )
           SELECT valid_target.approved_feature_id,
                  $${baseParamIndex + 1},
                  $${baseParamIndex + 2},
                  valid_target.geom,
                  COALESCE((
                    SELECT jsonb_object_agg(attr.key, attr.value)
                    FROM jsonb_each(COALESCE(valid_target.attributes, '{}'::jsonb)) AS attr(key, value)
                    WHERE regexp_replace(LOWER(BTRIM(attr.key)), '[^a-z0-9]', '', 'g')
                      NOT IN ('accuracy', 'accuracymeter', 'accuracymeters')
                  ), '{}'::jsonb),
                  'approved',
                  'import',
                  CURRENT_TIMESTAMP,
                  $${baseParamIndex + 3},
                  $${baseParamIndex + 4},
                  CURRENT_TIMESTAMP,
                  FALSE
           FROM valid_target
           RETURNING id
         ),
         approved_update AS (
           UPDATE gis_import_feature gif
           SET status = 'approved',
               approved_feature_id = valid_target.approved_feature_id,
               reviewed_by_user_id = $${baseParamIndex + 3},
               reviewed_at = CURRENT_TIMESTAMP,
               approved_at = CURRENT_TIMESTAMP,
               review_reason = $${baseParamIndex + 5}
           FROM valid_target
           JOIN inserted ON inserted.id = valid_target.approved_feature_id
           WHERE gif.id = valid_target.import_feature_id
           RETURNING gif.id
         )
         SELECT
           (SELECT COUNT(*)::int FROM approved_update) AS approved_count,
           (SELECT COUNT(*)::int FROM invalid_update) AS failed_count`,
        approvalParams,
      );
    } else {
      const baseParamIndex = targetParams.length;
      const rejectParams = [...targetParams, job.project_id, currentUser.id, normalizedReason];
      await client.query(
        `WITH target AS (
           SELECT gif.id,
                  gif.approved_feature_id
           FROM gis_import_feature gif
           WHERE ${targetWhereSql}
           ORDER BY gif.source_index ASC
           FOR UPDATE
         ),
         deleted AS (
           DELETE FROM spatial_feature sf
           USING target
           WHERE sf.id = target.approved_feature_id
             AND sf.project_id = $${baseParamIndex + 1}
           RETURNING sf.id
         ),
         rejected_update AS (
           UPDATE gis_import_feature gif
           SET status = 'rejected',
               approved_feature_id = NULL,
               reviewed_by_user_id = $${baseParamIndex + 2},
               reviewed_at = CURRENT_TIMESTAMP,
               approved_at = NULL,
               review_reason = $${baseParamIndex + 3}
           FROM target
           WHERE gif.id = target.id
           RETURNING gif.id
         )
         SELECT
           (SELECT COUNT(*)::int FROM rejected_update) AS rejected_count,
           (SELECT COUNT(*)::int FROM deleted) AS deleted_approved_count`,
        rejectParams,
      );
    }

    const refreshedResult = await client.query(
      `SELECT gij.*, p.name AS project_name,
              uploader.full_name AS uploaded_by_name,
              reviewer.full_name AS reviewed_by_name
       FROM gis_import_job gij
       JOIN project p ON p.id = gij.project_id
       JOIN "user" uploader ON uploader.id = gij.uploaded_by_user_id
       LEFT JOIN "user" reviewer ON reviewer.id = gij.reviewed_by_user_id
       WHERE gij.id = $1`,
      [importId],
    );

    const refreshedJob = refreshedResult.rows[0];
    await client.query(
      `UPDATE gis_import_job
       SET reviewed_by_user_id = $2,
           reviewed_at = CURRENT_TIMESTAMP,
           rejection_reason = $3
       WHERE id = $1`,
      [
        importId,
        currentUser.id,
        refreshedJob.status === 'rejected' || refreshedJob.status === 'partially_approved'
          ? normalizedReason
          : null,
      ],
    );

    const finalJobResult = await client.query(
      `SELECT gij.*, p.name AS project_name,
              uploader.full_name AS uploaded_by_name,
              reviewer.full_name AS reviewed_by_name
       FROM gis_import_job gij
       JOIN project p ON p.id = gij.project_id
       JOIN "user" uploader ON uploader.id = gij.uploaded_by_user_id
       LEFT JOIN "user" reviewer ON reviewer.id = gij.reviewed_by_user_id
       WHERE gij.id = $1`,
      [importId],
    );
    const finalJob = finalJobResult.rows[0];

    if (finalJob.status !== 'pending_review') {
      const title =
        finalJob.status === 'approved'
          ? `Import approved in ${finalJob.project_name}`
          : finalJob.status === 'partially_approved'
            ? `Import partially approved in ${finalJob.project_name}`
            : `Import rejected in ${finalJob.project_name}`;
      const message =
        finalJob.status === 'approved'
          ? `${finalJob.original_filename} was approved and the imported geometries are now official project features.`
          : finalJob.status === 'partially_approved'
            ? `${finalJob.original_filename} was partially approved. ${finalJob.approved_feature_count} staged feature(s) were approved and ${finalJob.rejected_feature_count + finalJob.failed_feature_count} were not approved.${normalizedReason ? ` Reason: ${normalizedReason}` : ''}`
            : `${finalJob.original_filename} was rejected.${normalizedReason ? ` Reason: ${normalizedReason}` : ''}`;

      await createNotification(client, {
        userId: finalJob.uploaded_by_user_id,
        type: 'import_event',
        title,
        message,
        metadata: {
          import_job_id: finalJob.id,
          project_id: finalJob.project_id,
          project_name: finalJob.project_name,
          status: finalJob.status,
          approved_feature_count: finalJob.approved_feature_count,
          rejected_feature_count: finalJob.rejected_feature_count,
          failed_feature_count: finalJob.failed_feature_count,
          reason: normalizedReason,
        },
      });
    }

    return finalJob;
  });

  logger.info('GIS import reviewed', {
    importJobId: importId,
    status,
    reviewerId: currentUser.id,
    selectedCount: Array.isArray(featureIds) ? featureIds.length : 'all-pending',
  });

  res.json({
    success: true,
    message: `Import ${status === 'approved' ? 'approval' : 'rejection'} recorded successfully.`,
    data: mapImportJobRow(updatedJob),
  });
};

module.exports = {
  listImports,
  getImportDetails,
  getImportQuickMapPreview,
  getImportMapData,
  getImportMapTileData,
  getImportFeatureDetails,
  listImportFeatures,
  uploadImport,
  downloadImport,
  listImportComments,
  addImportComment,
  reviewImport,
  startImportProcessingLoop,
  stopImportProcessingLoop,
  waitForImportProcessingIdle,
};

export {};
