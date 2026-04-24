import type { Request, Response } from 'express';
import path from 'node:path';
import fs from 'node:fs/promises';
import crypto from 'node:crypto';

const AdmZip = require('adm-zip');
const { DOMParser } = require('@xmldom/xmldom');
const toGeoJSON = require('@tmcw/togeojson');
const { query, transaction } = require('../config/database');
const { AppError } = require('../middleware/error');
const logger = require('../utils/logger');
import { validateEnv } from '../config/env';
import { createNotification } from '../lib/userWorkflow';
import { synchronizeProjectStatuses } from '../lib/projectLifecycle';

const LEBANON_BOUNDS = {
  minLon: 35.094,
  minLat: 33.045,
  maxLon: 36.645,
  maxLat: 34.695,
};
const LEBANON_BUFFER_DEGREES = 0.2;
const IMPORT_PREVIEW_LIMIT = 500;
const PAGE_MAX_LIMIT = 200;
const IMPORT_INSERT_BATCH_SIZE = 250;

type ImportFileType = 'geojson' | 'shapefile_zip' | 'kml' | 'kmz';
type GeometryType = 'Point' | 'LineString' | 'Polygon';
type PlainObject = Record<string, unknown>;

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
  created_at: string;
  updated_at: string;
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
  throw new AppError(
    'Unsupported GIS file type. Upload GeoJSON, zipped shapefile, KML, or KMZ.',
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

const isPosition = (value: unknown): value is [number, number] => {
  if (!Array.isArray(value) || value.length < 2) {
    return false;
  }

  const lon = Number(value[0]);
  const lat = Number(value[1]);

  return Number.isFinite(lon) && Number.isFinite(lat);
};

const validateCoordinates = (type: GeometryType, coordinates: unknown): boolean => {
  if (type === 'Point') {
    return isPosition(coordinates);
  }

  if (type === 'LineString') {
    return Array.isArray(coordinates) && coordinates.length >= 2 && coordinates.every(isPosition);
  }

  if (type === 'Polygon') {
    if (!Array.isArray(coordinates) || coordinates.length === 0) {
      return false;
    }

    return coordinates.every((ring) => {
      if (!Array.isArray(ring) || ring.length < 4 || !ring.every(isPosition)) {
        return false;
      }

      const first = ring[0] as [number, number];
      const last = ring[ring.length - 1] as [number, number];
      return first[0] === last[0] && first[1] === last[1];
    });
  }

  return false;
};

const mercatorToWgs84 = ([x, y]: [number, number]): [number, number] => {
  const lon = (x / 20037508.34) * 180;
  const lat = (Math.atan(Math.exp((y / 20037508.34) * Math.PI)) * 360) / Math.PI - 90;
  return [Number(lon.toFixed(8)), Number(lat.toFixed(8))];
};

const transformGeometryCoordinates = (
  geometryType: GeometryType,
  coordinates: unknown,
  projector: (value: [number, number]) => [number, number],
): unknown => {
  if (geometryType === 'Point') {
    return projector(coordinates as [number, number]);
  }

  if (geometryType === 'LineString') {
    return (coordinates as Array<[number, number]>).map(projector);
  }

  return (coordinates as Array<Array<[number, number]>>).map((ring) => ring.map(projector));
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
  if (!geometryType || !['Point', 'LineString', 'Polygon'].includes(geometryType)) {
    return {
      geometryType: null,
      geometry: null,
    };
  }

  let coordinates = geometry.coordinates;
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
    return `${featureType.trim()} ${geometryType ?? 'feature'}`;
  }

  switch (geometryType) {
    case 'Point':
      return `Imported point ${sourceIndex + 1}`;
    case 'LineString':
      return `Imported line ${sourceIndex + 1}`;
    case 'Polygon':
      return `Imported area ${sourceIndex + 1}`;
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
    const properties = ensureAttributesObject(feature?.properties);
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

const parseShapefileZip = async (filePath: string): Promise<ParsedImportPayload> => {
  const buffer = await fs.readFile(filePath);
  const zip = new AdmZip(buffer);
  const entries = zip.getEntries().map((entry: any) => entry.entryName.toLowerCase());
  const hasShp = entries.some((entry: string) => entry.endsWith('.shp'));
  const hasShx = entries.some((entry: string) => entry.endsWith('.shx'));
  const hasDbf = entries.some((entry: string) => entry.endsWith('.dbf'));
  if (!hasShp || !hasShx || !hasDbf) {
    throw new AppError('A zipped shapefile must include .shp, .shx, and .dbf files.', 400);
  }

  const shpModule = await import('shpjs');
  const parsed = await (shpModule.default as any)(buffer);
  const flattened = flattenShpParsed(parsed);
  const normalized = flattened.features.map((feature: any, index: number) => {
    const properties = ensureAttributesObject(feature?.properties);
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
  const document = new DOMParser().parseFromString(xml, 'text/xml');
  const featureCollection = toGeoJSON.kml(document);
  const features = Array.isArray(featureCollection?.features) ? featureCollection.features : [];
  const normalized = features.map((feature: any, index: number) => {
    const properties = ensureAttributesObject(feature?.properties);
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
  const zip = new AdmZip(buffer);
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
  }
};

const validateType = (value: unknown, expectedType: string): boolean => {
  if (value === null || value === undefined || expectedType === 'select') {
    return true;
  }
  switch (expectedType) {
    case 'string':
    case 'text':
    case 'multiline':
    case 'date':
      return typeof value === 'string';
    case 'number':
    case 'integer':
      return typeof value === 'number' && Number.isFinite(value);
    case 'boolean':
      return typeof value === 'boolean';
    case 'object':
      return typeof value === 'object' && !Array.isArray(value);
    case 'array':
      return Array.isArray(value);
    default:
      return true;
  }
};

const validateAttributesAgainstSchema = (
  attributesInput: Record<string, unknown>,
  schema: Record<string, unknown>,
): { warnings: string[]; errors: string[]; report: Record<string, unknown> } => {
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
    if (
      attributesInput[requiredKey] === undefined ||
      attributesInput[requiredKey] === null ||
      attributesInput[requiredKey] === ''
    ) {
      missingRequired.push(requiredKey);
      errors.push(`Missing required attribute: ${requiredKey}`);
    }
  }

  for (const [key, propSchema] of Object.entries(jsonSchemaProps)) {
    if (attributesInput[key] === undefined) {
      continue;
    }
    const expectedType = typeof propSchema?.type === 'string' ? propSchema.type : null;
    if (expectedType && !validateType(attributesInput[key], expectedType)) {
      invalidFields.push(key);
      errors.push(`Invalid type for attribute "${key}"`);
    }
  }

  const fields = Array.isArray(schema.fields)
    ? (schema.fields as Array<Record<string, unknown>>)
    : [];
  for (const field of fields) {
    const fieldKey =
      typeof field.key === 'string'
        ? field.key
        : typeof field.name === 'string'
          ? field.name
          : null;
    if (!fieldKey) {
      continue;
    }

    const value = attributesInput[fieldKey];
    if (field.required === true && (value === undefined || value === null || value === '')) {
      if (!missingRequired.includes(fieldKey)) {
        missingRequired.push(fieldKey);
        errors.push(`Missing required attribute: ${fieldKey}`);
      }
    }

    if (field.type && typeof field.type === 'string' && !validateType(value, field.type)) {
      if (!invalidFields.includes(fieldKey)) {
        invalidFields.push(fieldKey);
      }
      errors.push(`Invalid type for attribute "${fieldKey}"`);
    }

    const allowedValues =
      Array.isArray(field.options) && field.options.length > 0
        ? field.options
        : Array.isArray(field.enum) && field.enum.length > 0
          ? field.enum
          : null;
    if (
      allowedValues &&
      value !== undefined &&
      value !== null &&
      value !== '' &&
      !allowedValues.includes(value)
    ) {
      errors.push(`Invalid value for attribute "${fieldKey}"`);
    }
  }

  const unknownKeys = Object.keys(attributesInput).filter((key) => {
    if (jsonSchemaProps[key]) {
      return false;
    }
    return !fields.some((field) => field.key === key || field.name === key);
  });
  if (unknownKeys.length > 0) {
    warnings.push(
      `Attributes not defined in the project form were kept: ${unknownKeys.join(', ')}`,
    );
  }

  return {
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
    return true;
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

const getImportReviewRecipients = async (executor: any, projectId: string) => {
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

  if (!incoming.geometryType || !incoming.geometry) {
    errors.push('Geometry is missing or unsupported.');
    report.geometry = {
      valid: false,
      reason: 'missing_or_unsupported',
    };
    return {
      geometryType: incoming.geometryType,
      geometryJson: null,
      attributes: incoming.attributes,
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
       ST_IsValid(geom) AS is_valid,
       ST_IsValidReason(geom) AS valid_reason,
       ST_Intersects(
         geom,
         ST_MakeEnvelope($2, $3, $4, $5, 4326)
       ) AS intersects_lebanon,
       EXISTS (
         SELECT 1
         FROM spatial_feature sf
         WHERE sf.project_id = $6
           AND sf.status = 'approved'
           AND ST_Equals(sf.geom, geom)
       ) AS exact_duplicate,
       (
         SELECT sf.id
         FROM spatial_feature sf
         WHERE sf.project_id = $6
           AND sf.status = 'approved'
           AND ST_Equals(sf.geom, geom)
         LIMIT 1
       ) AS duplicate_feature_id,
       EXISTS (
         SELECT 1
         FROM spatial_feature sf
         WHERE sf.project_id = $6
           AND sf.status = 'approved'
           AND ST_DWithin(
             sf.geom::geography,
             geom::geography,
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
    errors.push(String(geoRow.valid_reason ?? 'Geometry is invalid.'));
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
    attributes: incoming.attributes,
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
}: {
  parsed: ParsedImportPayload;
  reviewableCount: number;
  failedCount: number;
  warningCount: number;
  errorCount: number;
  duplicateOfImportJobId: string | null;
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
});

const mapImportJobRow = (row: ImportJobRow) => ({
  id: row.id,
  project_id: row.project_id,
  project_name: row.project_name,
  uploaded_by_user_id: row.uploaded_by_user_id,
  uploaded_by_name: row.uploaded_by_name,
  reviewed_by_user_id: row.reviewed_by_user_id,
  reviewed_by_name: row.reviewed_by_name,
  duplicate_of_import_job_id: row.duplicate_of_import_job_id,
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
  created_at: row.created_at,
  updated_at: row.updated_at,
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

const fetchImportJobWithAccess = async (importId: string, user: Express.UserContext) => {
  const result = await query(
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
  if (result.rows.length === 0) {
    throw new AppError('Import job not found', 404);
  }
  const job = result.rows[0];
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

  const whereClauses = ['1=1'];
  const params: unknown[] = [];
  let paramIndex = 1;

  if (req.user?.role !== 'admin') {
    whereClauses.push(`gij.uploaded_by_user_id = $${paramIndex}`);
    params.push(req.user?.id);
    paramIndex += 1;
  }

  if (status) {
    whereClauses.push(`gij.status = $${paramIndex}`);
    params.push(status);
    paramIndex += 1;
  }

  if (projectId) {
    whereClauses.push(`gij.project_id = $${paramIndex}`);
    params.push(projectId);
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
  const countSql = `SELECT COUNT(*)::int AS total FROM gis_import_job gij WHERE ${whereSql}`;

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
    },
  });
};

const getImportDetails = async (req: Request, res: Response): Promise<void> => {
  const importId = req.params.importId;
  const job = await fetchImportJobWithAccess(importId, req.user as Express.UserContext);

  const previewResult = await query(
    `SELECT gif.*, reviewer.full_name AS reviewed_by_name,
            CASE WHEN gif.geom IS NULL THEN NULL ELSE ST_AsGeoJSON(gif.geom) END AS geometry
     FROM gis_import_feature gif
     LEFT JOIN "user" reviewer ON reviewer.id = gif.reviewed_by_user_id
     WHERE gif.import_job_id = $1
     ORDER BY gif.source_index ASC
     LIMIT $2`,
    [importId, IMPORT_PREVIEW_LIMIT],
  );

  res.json({
    success: true,
    data: {
      job: mapImportJobRow(job),
      preview_features: previewResult.rows.map(mapImportFeatureRow),
    },
  });
};

const listImportFeatures = async (req: Request, res: Response): Promise<void> => {
  const importId = req.params.importId;
  await fetchImportJobWithAccess(importId, req.user as Express.UserContext);
  const { page, limit, offset } = getPagination(req.query.page, req.query.limit);
  const status = typeof req.query.status === 'string' ? req.query.status.trim() : '';

  const whereClauses = ['gif.import_job_id = $1'];
  const params: unknown[] = [importId];
  let paramIndex = 2;
  if (status) {
    whereClauses.push(`gif.status = $${paramIndex}`);
    params.push(status);
    paramIndex += 1;
  }

  const whereSql = whereClauses.join(' AND ');
  const listSql = `
    SELECT gif.*, reviewer.full_name AS reviewed_by_name,
           CASE WHEN gif.geom IS NULL THEN NULL ELSE ST_AsGeoJSON(gif.geom) END AS geometry
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
    data: itemsResult.rows.map(mapImportFeatureRow),
    pagination: {
      page,
      limit,
      total,
      totalPages: Math.max(1, Math.ceil(total / limit)),
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

  let parsed: ParsedImportPayload;
  try {
    parsed = await parseImportFile(req.file.path, fileType);
  } catch (error) {
    await fs.unlink(req.file.path).catch(() => undefined);
    throw error;
  }
  if (parsed.features.length === 0) {
    await fs.unlink(req.file.path).catch(() => undefined);
    throw new AppError('The uploaded file did not contain any supported geometries.', 400);
  }
  if (parsed.features.length > env.IMPORT_MAX_FEATURES) {
    await fs.unlink(req.file.path).catch(() => undefined);
    throw new AppError(
      `This import contains ${parsed.features.length} features. The limit is ${env.IMPORT_MAX_FEATURES}.`,
      400,
    );
  }

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
         $1, $2, $3, $4, $5, $6, $7, $8, $9::gis_import_file_type, $10, $11, 'processing', $12::jsonb, '{}'::jsonb, 'Validating imported geometries'
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
        parsed.fileType,
        parsed.sourceCrs,
        parsed.sourceLayerName,
        JSON.stringify(parsed.fileMetadata),
      ],
    );

    const importJobId = insertedJob.rows[0].id;
    const formSchema =
      project.collection_form_schema && typeof project.collection_form_schema === 'object'
        ? (project.collection_form_schema as Record<string, unknown>)
        : {};

    let reviewableCount = 0;
    let failedCount = 0;
    let warningCount = 0;
    let errorCount = 0;
    const stagedRows: StagedImportInsertRow[] = [];

    for (const incoming of parsed.features) {
      const validation = await validateImportedFeature(client, {
        projectId,
        formSchema,
        incoming,
      });
      warningCount += validation.warnings.length;
      errorCount += validation.errors.length;
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
      duplicateOfImportJobId,
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
           source_layer_name = COALESCE($13, source_layer_name)
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

    if (finalStatus === 'pending_review') {
      const recipients = await getImportReviewRecipients(client, projectId);
      for (const admin of recipients) {
        await createNotification(client, {
          userId: admin.id,
          type: 'import_event',
          title: 'GIS import review pending',
          message: `${currentUser.full_name} submitted ${req.file.originalname} for ${project.name}.${warningCount > 0 ? ` ${warningCount} warning(s) were detected.` : ''}`,
          metadata: {
            import_job_id: importJobId,
            project_id: projectId,
            project_name: project.name,
            status: finalStatus,
            warning_count: warningCount,
            error_count: errorCount,
          },
        });
      }
    } else {
      await createNotification(client, {
        userId: currentUser.id,
        type: 'import_event',
        title: `Import failed in ${project.name}`,
        message: `We could not stage any reviewable features from ${req.file.originalname}. Check the validation summary for details.`,
        metadata: {
          import_job_id: importJobId,
          project_id: projectId,
          project_name: project.name,
          status: finalStatus,
          warning_count: warningCount,
          error_count: errorCount,
        },
      });
    }

    return detailResult.rows[0];
  });

  logger.info('GIS import uploaded and processed', {
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

const reviewImport = async (req: Request, res: Response): Promise<void> => {
  const importId = req.params.importId;
  const {
    status,
    reason,
    feature_ids: featureIds,
  } = req.body as {
    status: 'approved' | 'rejected';
    reason?: string;
    feature_ids?: string[];
  };

  const currentUser = req.user as Express.UserContext;
  const job = await fetchImportJobWithAccess(importId, currentUser);
  const canReview = await hasProjectImportReviewAccess(job.project_id, currentUser);
  if (!canReview) {
    throw new AppError('You are not allowed to review this import.', 403);
  }

  const normalizedReason =
    typeof reason === 'string' && reason.trim().length > 0 ? reason.trim() : null;
  const selectedFeatureIds = Array.isArray(featureIds)
    ? [...new Set(featureIds.map((value) => String(value).trim()).filter(Boolean))]
    : [];

  const updatedJob = await transaction(async (client: any) => {
    const allowedStatuses =
      status === 'approved' && selectedFeatureIds.length > 0
        ? ['pending_review', 'rejected']
        : ['pending_review'];

    const targetParams: unknown[] = [importId, allowedStatuses];
    let targetFilter = `import_job_id = $1 AND status = ANY($2::gis_import_feature_status[])`;
    if (selectedFeatureIds.length > 0) {
      targetParams.push(selectedFeatureIds);
      targetFilter += ` AND id = ANY($3::uuid[])`;
    }

    const targetResult = await client.query(
      `SELECT id, display_title, geometry_type,
              CASE WHEN geom IS NULL THEN NULL ELSE ST_AsGeoJSON(geom) END AS geometry,
              attributes, status
       FROM gis_import_feature
       WHERE ${targetFilter}
       ORDER BY source_index ASC`,
      targetParams,
    );

    if (targetResult.rows.length === 0) {
      throw new AppError('No staged import features matched this review action.', 409);
    }

    if (status === 'approved') {
      for (const row of targetResult.rows) {
        if (!row.geometry) {
          throw new AppError(
            `Imported feature ${row.display_title} has no valid geometry to approve.`,
            409,
          );
        }
        const featureInsert = await client.query(
          `INSERT INTO spatial_feature (
             project_id,
             collected_by_user_id,
             geom,
             attributes,
             status,
             submitted_at,
             reviewed_by_user_id,
             review_notes,
             reviewed_at,
             collected_offline
           ) VALUES (
             $1,
             $2,
             ST_SetSRID(ST_GeomFromGeoJSON($3), 4326),
             $4::jsonb,
             'approved',
             CURRENT_TIMESTAMP,
             $5,
             $6,
             CURRENT_TIMESTAMP,
             FALSE
           )
           RETURNING id`,
          [
            job.project_id,
            job.uploaded_by_user_id,
            row.geometry,
            JSON.stringify(row.attributes ?? {}),
            currentUser.id,
            `Imported from ${job.original_filename}${normalizedReason ? ` (${normalizedReason})` : ''}`,
          ],
        );

        await client.query(
          `UPDATE gis_import_feature
           SET status = 'approved',
               approved_feature_id = $2,
               reviewed_by_user_id = $3,
               reviewed_at = CURRENT_TIMESTAMP,
               approved_at = CURRENT_TIMESTAMP,
               review_reason = $4
           WHERE id = $1`,
          [row.id, featureInsert.rows[0].id, currentUser.id, normalizedReason],
        );
      }
    } else {
      for (const row of targetResult.rows) {
        await client.query(
          `UPDATE gis_import_feature
           SET status = 'rejected',
               reviewed_by_user_id = $2,
               reviewed_at = CURRENT_TIMESTAMP,
               review_reason = $3
           WHERE id = $1`,
          [row.id, currentUser.id, normalizedReason],
        );
      }
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
  listImportFeatures,
  uploadImport,
  reviewImport,
};

export {};
