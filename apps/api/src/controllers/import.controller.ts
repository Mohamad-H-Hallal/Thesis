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
import { createNotification, isProtectedSuperAdminEmail } from '../lib/userWorkflow';
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
const IMPORT_PROCESSING_POLL_INTERVAL_MS = Number.parseInt(
  process.env.IMPORT_PROCESSING_POLL_INTERVAL_MS ??
    (process.env.NODE_ENV === 'test' ? '250' : '2000'),
  10,
);
const IMPORT_PROCESSING_STALE_AFTER_MS = Number.parseInt(
  process.env.IMPORT_PROCESSING_STALE_AFTER_MS ?? String(5 * 60 * 1000),
  10,
);

type ImportFileType = 'geojson' | 'shapefile_zip' | 'kml' | 'kmz';
type GeometryType =
  | 'Point'
  | 'MultiPoint'
  | 'LineString'
  | 'MultiLineString'
  | 'Polygon'
  | 'MultiPolygon';
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

type ImportJobAccessRow = ImportJobRow & {
  uploaded_by_email: string;
  uploaded_by_role: string;
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

type ImportCommentRow = {
  id: string;
  import_job_id: string;
  author_user_id: string;
  author_name: string;
  author_role: string;
  comment_text: string;
  created_at: string;
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
      return Array.isArray(coordinates) && coordinates.length > 0 && coordinates.every(validateLinearRing);
    case 'MultiPolygon':
      return (
        Array.isArray(coordinates) &&
        coordinates.length > 0 &&
        coordinates.every(
          (polygon) =>
            Array.isArray(polygon) &&
            polygon.length > 0 &&
            polygon.every(validateLinearRing),
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
      return transformMultiPointCoordinates(
        coordinates as Array<[number, number]>,
        projector,
      );
    case 'LineString':
      return transformMultiPointCoordinates(
        coordinates as Array<[number, number]>,
        projector,
      );
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
    ![
      'Point',
      'MultiPoint',
      'LineString',
      'MultiLineString',
      'Polygon',
      'MultiPolygon',
    ].includes(geometryType)
  ) {
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
    case 'MultiPoint':
      return `Imported points ${sourceIndex + 1}`;
    case 'LineString':
      return `Imported line ${sourceIndex + 1}`;
    case 'MultiLineString':
      return `Imported lines ${sourceIndex + 1}`;
    case 'Polygon':
      return `Imported area ${sourceIndex + 1}`;
    case 'MultiPolygon':
      return `Imported areas ${sourceIndex + 1}`;
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
    const protectedEmail = String(process.env.SUPER_ADMIN_EMAIL ?? '').trim().toLowerCase();
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

const mapImportCommentRow = (row: ImportCommentRow) => ({
  id: row.id,
  import_job_id: row.import_job_id,
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
  attributes: row.attributes ?? {},
  collected_by: row.collected_by ?? null,
  reviewed_by: row.reviewed_by ?? null,
  review_notes: row.review_notes ?? null,
  accuracy_meters: row.accuracy_meters ?? null,
  collected_at: row.collected_at ?? null,
  submitted_at: row.submitted_at ?? null,
  reviewed_at: row.reviewed_at ?? null,
  photo_count: row.photo_count ?? 0,
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
    const message =
      error instanceof AppError
        ? error.message
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
    whereClauses.push(`gij.status = $${paramIndex}`);
    params.push(status);
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
       AND gif.geom IS NOT NULL
       AND ST_CoveredBy(gif.geom, ${lebanonEnvelopeSql})
     ORDER BY gif.source_index ASC
     LIMIT $2`,
    [importId, IMPORT_PREVIEW_LIMIT],
  );

  const previewSummaryResult = await query(
    `SELECT
        COUNT(*) FILTER (WHERE geom IS NOT NULL)::int AS geometry_feature_count,
        COUNT(*) FILTER (
          WHERE geom IS NOT NULL
            AND ST_CoveredBy(geom, ${lebanonEnvelopeSql})
        )::int AS preview_feature_count
     FROM gis_import_feature
     WHERE import_job_id = $1`,
    [importId],
  );
  const previewSummaryRow = previewSummaryResult.rows[0] ?? {};
  const geometryFeatureCount = Number(previewSummaryRow.geometry_feature_count ?? 0);
  const previewFeatureCount = Number(previewSummaryRow.preview_feature_count ?? 0);
  const commentsResult = await query(
    `SELECT gic.id,
            gic.import_job_id,
            gic.author_user_id,
            gic.comment_text,
            gic.created_at,
            u.full_name AS author_name,
            u.role AS author_role
     FROM gis_import_comment gic
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
        outside_workspace_feature_count: Math.max(geometryFeatureCount - previewFeatureCount, 0),
      },
      comments: commentsResult.rows.map((row) => mapImportCommentRow(row as ImportCommentRow)),
    },
  });
};

const getImportMapData = async (req: Request, res: Response): Promise<void> => {
  const importId = req.params.importId;
  const job = await fetchImportJobWithAccess(importId, req.user as Express.UserContext);

  const stagedResult = await query(
    `SELECT gif.*, reviewer.full_name AS reviewed_by_name,
            CASE WHEN gif.geom IS NULL THEN NULL ELSE ST_AsGeoJSON(gif.geom) END AS geometry
     FROM gis_import_feature gif
     LEFT JOIN "user" reviewer ON reviewer.id = gif.reviewed_by_user_id
     WHERE gif.import_job_id = $1
       AND gif.geom IS NOT NULL
     ORDER BY gif.source_index ASC`,
    [importId],
  );

  const approvedProjectResult = await query(
    `SELECT sf.id,
            sf.status,
            ST_AsGeoJSON(sf.geom) AS geometry,
            sf.attributes,
            collector.full_name AS collected_by,
            reviewer.full_name AS reviewed_by,
            sf.review_notes,
            sf.accuracy_meters,
            sf.collected_at,
            sf.submitted_at,
            sf.reviewed_at,
            (SELECT COUNT(*) FROM photo WHERE feature_id = sf.id) AS photo_count
     FROM spatial_feature sf
     LEFT JOIN "user" collector ON collector.id = sf.collected_by_user_id
     LEFT JOIN "user" reviewer ON reviewer.id = sf.reviewed_by_user_id
     WHERE sf.project_id = $1
       AND sf.status = 'approved'
     ORDER BY sf.reviewed_at DESC NULLS LAST, sf.submitted_at DESC NULLS LAST, sf.id ASC`,
    [job.project_id],
  );

  res.json({
    success: true,
    data: {
      staged_features: stagedResult.rows.map((row) => mapImportFeatureRow(row as ImportFeatureRow)),
      approved_project_features: approvedProjectResult.rows.map(mapImportMapProjectFeatureRow),
    },
  });
};

const listImportFeatures = async (req: Request, res: Response): Promise<void> => {
  const importId = req.params.importId;
  await fetchImportJobWithAccess(importId, req.user as Express.UserContext);
  const { page, limit, offset } = getPagination(req.query.page, req.query.limit);
  const status = typeof req.query.status === 'string' ? req.query.status.trim() : '';
  const issue = typeof req.query.issue === 'string' ? req.query.issue.trim() : '';

  const whereClauses = ['gif.import_job_id = $1'];
  const params: unknown[] = [importId];
  let paramIndex = 2;
  if (status) {
    whereClauses.push(`gif.status = $${paramIndex}`);
    params.push(status);
    paramIndex += 1;
  }
  if (issue) {
    whereClauses.push(
      `(gif.validation_errors @> to_jsonb(ARRAY[$${paramIndex}]::text[]) OR gif.validation_warnings @> to_jsonb(ARRAY[$${paramIndex}]::text[]))`,
    );
    params.push(issue);
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
            gic.author_user_id,
            gic.comment_text,
            gic.created_at,
            u.full_name AS author_name,
            u.role AS author_role
     FROM gis_import_comment gic
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
  if (!commentText) {
    throw new AppError('A comment is required.', 400);
  }

  const job = await fetchImportJobWithAccess(importId, currentUser);
  const canComment = await canCommentOnImportJob(job, currentUser);
  if (!canComment) {
    throw new AppError('You are not allowed to comment on this import.', 403);
  }

  const createdComment = await transaction(async (client: any) => {
    const insertResult = await client.query(
      `INSERT INTO gis_import_comment (
         import_job_id,
         author_user_id,
         comment_text
       ) VALUES ($1, $2, $3)
       RETURNING id, import_job_id, author_user_id, comment_text, created_at`,
      [importId, currentUser.id, commentText],
    );

    if (job.uploaded_by_user_id !== currentUser.id) {
      await createNotification(client, {
        userId: job.uploaded_by_user_id,
        type: 'import_event',
        title: `Import comment added in ${job.project_name}`,
        message: `${currentUser.full_name} added a comment on ${job.original_filename}.`,
        metadata: {
          import_job_id: job.id,
          project_id: job.project_id,
          project_name: job.project_name,
          status: job.status,
          comment_preview: commentText.slice(0, 240),
        },
      });
    }

    const commentResult = await client.query(
      `SELECT gic.id,
              gic.import_job_id,
              gic.author_user_id,
              gic.comment_text,
              gic.created_at,
              u.full_name AS author_name,
              u.role AS author_role
       FROM gis_import_comment gic
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
  } = req.body as {
    status: 'approved' | 'rejected';
    reason?: string;
    feature_ids?: string[];
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

  const updatedJob = await transaction(async (client: any) => {
    const allowedStatuses =
      status === 'approved'
        ? ['pending_review', 'rejected']
        : ['pending_review', 'approved'];

    const targetParams: unknown[] = [importId, allowedStatuses];
    let targetFilter = `import_job_id = $1 AND status = ANY($2::gis_import_feature_status[])`;
    if (selectedFeatureIds.length > 0) {
      targetParams.push(selectedFeatureIds);
      targetFilter += ` AND id = ANY($3::uuid[])`;
    }

    const targetResult = await client.query(
      `SELECT id, display_title, geometry_type,
              CASE WHEN geom IS NULL THEN NULL ELSE ST_AsGeoJSON(geom) END AS geometry,
              attributes, status, approved_feature_id
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
        if (row.status === 'approved' && row.approved_feature_id) {
          await client.query(
            `DELETE FROM spatial_feature
             WHERE id = $1
               AND project_id = $2`,
            [row.approved_feature_id, job.project_id],
          );
        }
        await client.query(
          `UPDATE gis_import_feature
           SET status = 'rejected',
               approved_feature_id = NULL,
               reviewed_by_user_id = $2,
               reviewed_at = CURRENT_TIMESTAMP,
               approved_at = NULL,
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
  getImportMapData,
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
