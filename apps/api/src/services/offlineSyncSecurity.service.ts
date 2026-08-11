import { createHash } from 'node:crypto';
import type { Request } from 'express';
import {
  sanitizeManagedFeatureAttributes,
  shouldStripManagedFeatureAttributeKey,
} from '../lib/featureAttributes';
import { AppError, permanentOfflineSyncError } from '../middleware/error';
import { normalizeEmailAddress, normalizeLebaneseMobile } from './contactIdentity.service';

export type GeometryType = 'Point' | 'LineString' | 'Polygon';

export interface GeoJsonGeometry {
  type: GeometryType;
  coordinates: unknown;
  crs?: {
    type?: string;
    properties?: {
      name?: string;
    };
  };
}

interface FormSchemaField {
  key?: string;
  name?: string;
  type?: string;
  required?: boolean;
  options?: unknown[];
  enum?: unknown[];
  min?: number;
  max?: number;
}

export interface QueryExecutor {
  query: (sql: string, params?: unknown[]) => Promise<{ rows: any[]; rowCount?: number | null }>;
}

export type OfflineReceiptOperation =
  | 'create'
  | 'update'
  | 'submit'
  | 'batch_create'
  | 'photo_upload'
  | 'offline_bundle';

const MAX_OFFLINE_PAYLOAD_BYTES = 256 * 1024;
const MAX_OFFLINE_SERIALIZATION_DEPTH = 16;
const MAX_OFFLINE_ATTRIBUTE_BYTES = 128 * 1024;
const MAX_OFFLINE_NESTING_DEPTH = 8;
const MAX_OFFLINE_OBJECT_KEYS = 100;
const MAX_OFFLINE_ARRAY_ITEMS = 200;
const MAX_OFFLINE_STRING_LENGTH = 4096;
const MAX_OFFLINE_GEOMETRY_VERTICES = 10000;
const MAX_OFFLINE_POLYGON_RINGS = 100;
const SAFE_IDEMPOTENCY_KEY = /^[A-Za-z0-9][A-Za-z0-9._:-]{15,127}$/;
export const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const UNSAFE_JSON_KEYS = new Set(['__proto__', 'prototype', 'constructor']);
const DANGEROUS_MARKUP =
  /<\s*\/?\s*(?:script|iframe|object|embed|svg|math|style|link|meta)\b|\bon[a-z]+\s*=|javascript\s*:|data\s*:\s*text\/html/i;

export const offlinePayloadRejected = (
  message = 'Offline submission payload was rejected.',
): Error => permanentOfflineSyncError(message, 'OFFLINE_SYNC_PAYLOAD_REJECTED', 422);

export const assertPlainObject = (value: unknown, label: string): Record<string, unknown> => {
  if (
    !value ||
    typeof value !== 'object' ||
    Array.isArray(value) ||
    Object.getPrototypeOf(value) !== Object.prototype
  ) {
    throw offlinePayloadRejected(`${label} must be a JSON object.`);
  }
  return value as Record<string, unknown>;
};

export const assertOnlyAllowedKeys = (
  value: Record<string, unknown>,
  allowedKeys: ReadonlySet<string>,
  label: string,
): void => {
  const unknownKey = Object.keys(value).find(
    (key) => UNSAFE_JSON_KEYS.has(key) || !allowedKeys.has(key),
  );
  if (unknownKey) {
    throw offlinePayloadRejected(`${label} contains an unsupported field.`);
  }
};

const containsUnpairedSurrogate = (value: string): boolean => {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) {
        return true;
      }
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      return true;
    }
  }
  return false;
};

const containsDangerousControlCharacter = (value: string): boolean =>
  Array.from(value).some((character) => {
    const code = character.codePointAt(0) ?? 0;
    return (
      (code <= 0x1f && code !== 0x09 && code !== 0x0a && code !== 0x0d) ||
      code === 0x7f ||
      (code >= 0x202a && code <= 0x202e) ||
      (code >= 0x2066 && code <= 0x2069) ||
      code === 0xfffd
    );
  });

export const assertSafeOfflineJson = (value: unknown, depth = 0): void => {
  if (depth > MAX_OFFLINE_NESTING_DEPTH) {
    throw offlinePayloadRejected('Offline submission payload is nested too deeply.');
  }

  if (typeof value === 'string') {
    if (
      value.length > MAX_OFFLINE_STRING_LENGTH ||
      containsDangerousControlCharacter(value) ||
      DANGEROUS_MARKUP.test(value) ||
      containsUnpairedSurrogate(value)
    ) {
      throw offlinePayloadRejected('Offline submission contains unsafe text.');
    }
    return;
  }

  if (typeof value === 'number' && !Number.isFinite(value)) {
    throw offlinePayloadRejected('Offline submission contains an invalid number.');
  }

  if (Array.isArray(value)) {
    if (value.length > MAX_OFFLINE_ARRAY_ITEMS) {
      throw offlinePayloadRejected('Offline submission contains too many values.');
    }
    for (const item of value) {
      assertSafeOfflineJson(item, depth + 1);
    }
    return;
  }

  if (value && typeof value === 'object') {
    const objectValue = assertPlainObject(value, 'Offline submission value');
    const keys = Object.keys(objectValue);
    if (keys.length > MAX_OFFLINE_OBJECT_KEYS || keys.some((key) => UNSAFE_JSON_KEYS.has(key))) {
      throw offlinePayloadRejected('Offline submission contains unsupported object fields.');
    }
    for (const [key, nestedValue] of Object.entries(objectValue)) {
      if (
        key.length > 128 ||
        containsDangerousControlCharacter(key) ||
        containsUnpairedSurrogate(key)
      ) {
        throw offlinePayloadRejected('Offline submission contains an unsafe field name.');
      }
      assertSafeOfflineJson(nestedValue, depth + 1);
    }
  }
};

const canonicalizeJson = (value: unknown): unknown => {
  if (Array.isArray(value)) {
    return value.map(canonicalizeJson);
  }
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([left], [right]) => left.localeCompare(right, 'en'))
        .map(([key, nestedValue]) => [key, canonicalizeJson(nestedValue)]),
    );
  }
  return value;
};

export const sha256Json = (value: unknown): string =>
  createHash('sha256')
    .update(JSON.stringify(canonicalizeJson(value)))
    .digest('hex');

export const assertOfflinePayloadSize = (payload: unknown): void => {
  const pending: Array<{ value: unknown; depth: number }> = [{ value: payload, depth: 0 }];
  const visited = new WeakSet<object>();
  while (pending.length > 0) {
    const current = pending.pop();
    if (!current) {
      break;
    }
    if (current.depth > MAX_OFFLINE_SERIALIZATION_DEPTH) {
      throw offlinePayloadRejected('Offline submission payload is nested too deeply.');
    }
    if (current.value && typeof current.value === 'object') {
      if (visited.has(current.value)) {
        throw offlinePayloadRejected('Offline submission payload is malformed.');
      }
      visited.add(current.value);
      for (const nestedValue of Object.values(current.value)) {
        pending.push({ value: nestedValue, depth: current.depth + 1 });
      }
    }
  }

  let serialized: string | undefined;
  try {
    serialized = JSON.stringify(payload);
  } catch {
    throw offlinePayloadRejected('Offline submission payload is malformed.');
  }
  if (serialized === undefined) {
    throw offlinePayloadRejected('Offline submission payload is malformed.');
  }
  const size = Buffer.byteLength(serialized, 'utf8');
  if (size > MAX_OFFLINE_PAYLOAD_BYTES) {
    throw offlinePayloadRejected('Offline submission payload is too large.');
  }
};

const readRequiredOfflineHeader = (req: Request, name: string): string => {
  const value = req.headers[name.toLowerCase()];
  if (typeof value !== 'string' || !value.trim()) {
    throw offlinePayloadRejected(`Required ${name} header is missing.`);
  }
  return value.trim();
};

export const assertOfflineRequestBinding = ({
  req,
  projectId,
  userId,
}: {
  req: Request;
  projectId: string;
  userId: string;
}): { idempotencyKeyHash: string } => {
  const ownerId = readRequiredOfflineHeader(req, 'X-Offline-Owner-Id');
  const assertedProjectId = readRequiredOfflineHeader(req, 'X-Offline-Project-Id');
  const idempotencyKey = readRequiredOfflineHeader(req, 'Idempotency-Key');

  if (!UUID_PATTERN.test(ownerId) || ownerId !== userId) {
    throw permanentOfflineSyncError(
      'Offline submission discarded because it belongs to another account.',
      'OFFLINE_SYNC_OWNER_MISMATCH',
    );
  }
  if (!UUID_PATTERN.test(assertedProjectId) || assertedProjectId !== projectId) {
    throw permanentOfflineSyncError(
      'Offline submission discarded because its project does not match.',
      'OFFLINE_SYNC_PROJECT_MISMATCH',
    );
  }
  if (!SAFE_IDEMPOTENCY_KEY.test(idempotencyKey)) {
    throw offlinePayloadRejected('Offline submission idempotency key is invalid.');
  }

  return {
    idempotencyKeyHash: createHash('sha256').update(idempotencyKey).digest('hex'),
  };
};

export const requestHasOfflineSyncBinding = (req: Request): boolean =>
  ['x-offline-owner-id', 'x-offline-project-id', 'idempotency-key'].some((headerName) => {
    const value = req.headers[headerName];
    return typeof value === 'string' && value.trim().length > 0;
  });

const payloadHasOfflineSyncSignal = (value: unknown): boolean => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return false;
  }
  const payload = value as Record<string, unknown>;
  return (
    payload.collected_offline === true ||
    Object.prototype.hasOwnProperty.call(payload, 'offline_owner_user_id') ||
    Object.prototype.hasOwnProperty.call(payload, 'client_offline_id') ||
    Object.prototype.hasOwnProperty.call(payload, 'expected_version')
  );
};

export const requestHasOfflineSyncSignal = (req: Request): boolean =>
  requestHasOfflineSyncBinding(req) ||
  payloadHasOfflineSyncSignal(req.body) ||
  (Array.isArray(req.body?.features) && req.body.features.some(payloadHasOfflineSyncSignal));

export const assertCurrentOfflineAuthorization = async ({
  executor,
  userId,
  projectId,
  allowAdmin = false,
}: {
  executor: QueryExecutor;
  userId: string;
  projectId: string;
  allowAdmin?: boolean;
}): Promise<'admin' | 'contributor'> => {
  const userResult = await executor.query(
    `SELECT id, role, is_active
     FROM "user"
     WHERE id = $1
     FOR SHARE`,
    [userId],
  );
  const currentUser = userResult.rows[0];
  if (!currentUser || currentUser.is_active !== true) {
    throw permanentOfflineSyncError(
      'Offline submission discarded because this account is no longer active.',
      'OFFLINE_SYNC_ACCOUNT_INACTIVE',
    );
  }
  const currentRole = currentUser.role;
  const isAllowedAdmin = allowAdmin && currentRole === 'admin';
  if (!isAllowedAdmin && currentRole !== 'contributor') {
    throw permanentOfflineSyncError(
      'Offline submission discarded because the current role cannot perform this operation.',
      'OFFLINE_SYNC_ROLE_FORBIDDEN',
    );
  }

  const projectResult = await executor.query(
    `SELECT id,
            status,
            (
              status = 'active'
              AND (start_date IS NULL OR start_date <= CURRENT_DATE)
              AND (end_date IS NULL OR end_date > CURRENT_DATE)
            ) AS accepts_contributions
     FROM project
     WHERE id = $1
     FOR SHARE`,
    [projectId],
  );
  if (!projectResult.rows[0] || projectResult.rows[0].accepts_contributions !== true) {
    throw permanentOfflineSyncError(
      'Offline submission discarded because this project is no longer accepting contributions.',
      'OFFLINE_SYNC_PROJECT_UNAVAILABLE',
    );
  }
  if (isAllowedAdmin) {
    return 'admin';
  }

  const assignmentResult = await executor.query(
    `SELECT id, role, status
     FROM project_assignment
     WHERE project_id = $1
       AND user_id = $2
     FOR SHARE`,
    [projectId, userId],
  );
  const assignment = assignmentResult.rows[0];
  if (!assignment || assignment.status !== 'approved') {
    throw permanentOfflineSyncError(
      'Offline submission discarded because you no longer have access to this project.',
      'OFFLINE_SYNC_ACCESS_REVOKED',
    );
  }
  if (assignment.role !== 'contributor') {
    throw permanentOfflineSyncError(
      'Offline submission discarded because the current role cannot perform this operation.',
      'OFFLINE_SYNC_ROLE_FORBIDDEN',
    );
  }
  return 'contributor';
};

export const getOfflineReceipt = async ({
  executor,
  userId,
  projectId,
  operation,
  idempotencyKeyHash,
}: {
  executor: QueryExecutor;
  userId: string;
  projectId: string;
  operation: OfflineReceiptOperation;
  idempotencyKeyHash: string;
}): Promise<any | null> => {
  await executor.query('SELECT pg_advisory_xact_lock(hashtextextended($1, 0))', [
    `${userId}:${projectId}:${operation}:${idempotencyKeyHash}`,
  ]);
  const result = await executor.query(
    `SELECT payload_hash, entity_ids, outcome
     FROM offline_sync_receipt
     WHERE user_id = $1
       AND project_id = $2
       AND operation = $3
       AND idempotency_key_hash = $4
     FOR UPDATE`,
    [userId, projectId, operation, idempotencyKeyHash],
  );
  return result.rows[0] ?? null;
};

export const assertMatchingOfflineReceipt = (
  receipt: any,
  payloadHash: string,
  entityIds: string[],
): void => {
  const receiptIds = Array.isArray(receipt.entity_ids) ? receipt.entity_ids.map(String) : [];
  if (
    receipt.payload_hash !== payloadHash ||
    receiptIds.length !== entityIds.length ||
    receiptIds.some((id: string, index: number) => id !== entityIds[index])
  ) {
    throw permanentOfflineSyncError(
      'Offline submission idempotency key does not match the original operation.',
      'OFFLINE_SYNC_IDEMPOTENCY_MISMATCH',
      409,
    );
  }
};

export const insertOfflineReceipt = async ({
  executor,
  userId,
  projectId,
  operation,
  idempotencyKeyHash,
  payloadHash,
  entityIds,
}: {
  executor: QueryExecutor;
  userId: string;
  projectId: string;
  operation: OfflineReceiptOperation;
  idempotencyKeyHash: string;
  payloadHash: string;
  entityIds: string[];
}): Promise<void> => {
  await executor.query(
    `INSERT INTO offline_sync_receipt (
       user_id, project_id, operation, idempotency_key_hash, payload_hash, entity_ids
     ) VALUES ($1, $2, $3, $4, $5, $6::uuid[])`,
    [userId, projectId, operation, idempotencyKeyHash, payloadHash, entityIds],
  );
};

export const lockOfflineFeatureIds = async (
  executor: QueryExecutor,
  entityIds: string[],
): Promise<void> => {
  for (const entityId of [...entityIds].sort()) {
    await executor.query('SELECT pg_advisory_xact_lock(hashtextextended($1, 0))', [
      `offline-feature:${entityId}`,
    ]);
  }
};

const isPosition = (value: unknown, exactLength = false): value is [number, number] => {
  if (!Array.isArray(value) || value.length < 2 || (exactLength && value.length !== 2)) {
    return false;
  }

  if (typeof value[0] !== 'number' || typeof value[1] !== 'number') {
    return false;
  }

  const lon = value[0];
  const lat = value[1];

  return (
    Number.isFinite(lon) &&
    Number.isFinite(lat) &&
    lon >= -180 &&
    lon <= 180 &&
    lat >= -90 &&
    lat <= 90
  );
};

const validateCoordinates = (
  type: GeometryType,
  coordinates: unknown,
  strictOffline = false,
): boolean => {
  if (type === 'Point') {
    return isPosition(coordinates, strictOffline);
  }

  if (type === 'LineString') {
    return (
      Array.isArray(coordinates) &&
      coordinates.length >= 2 &&
      (!strictOffline || coordinates.length <= MAX_OFFLINE_GEOMETRY_VERTICES) &&
      coordinates.every((position) => isPosition(position, strictOffline))
    );
  }

  if (type === 'Polygon') {
    if (
      !Array.isArray(coordinates) ||
      coordinates.length === 0 ||
      (strictOffline && coordinates.length > MAX_OFFLINE_POLYGON_RINGS)
    ) {
      return false;
    }

    let vertexCount = 0;
    return coordinates.every((ring) => {
      if (!Array.isArray(ring) || ring.length < 4) {
        return false;
      }
      vertexCount += ring.length;
      if (
        (strictOffline && vertexCount > MAX_OFFLINE_GEOMETRY_VERTICES) ||
        !ring.every((position) => isPosition(position, strictOffline))
      ) {
        return false;
      }

      const first = ring[0] as [number, number];
      const last = ring[ring.length - 1] as [number, number];
      return first[0] === last[0] && first[1] === last[1];
    });
  }

  return false;
};

export const validateGeoJsonGeometry = (
  geom: unknown,
  { strictOffline = false }: { strictOffline?: boolean } = {},
): GeoJsonGeometry => {
  const rejectGeometry = (message: string): never => {
    if (strictOffline) {
      throw offlinePayloadRejected('Offline submission geometry is invalid.');
    }
    throw new AppError(message, 400);
  };

  if (!geom || typeof geom !== 'object') {
    return rejectGeometry('Geometry is required');
  }

  const geometry = geom as GeoJsonGeometry;
  const allowedTypes: GeometryType[] = ['Point', 'LineString', 'Polygon'];

  if (!allowedTypes.includes(geometry.type)) {
    return rejectGeometry('Geometry type must be Point, LineString, or Polygon');
  }

  if (strictOffline) {
    const geometryObject = assertPlainObject(geom, 'Geometry');
    assertOnlyAllowedKeys(geometryObject, new Set(['type', 'coordinates', 'crs']), 'Geometry');
    if (geometry.crs !== undefined) {
      const crs = assertPlainObject(geometry.crs, 'Geometry CRS');
      assertOnlyAllowedKeys(crs, new Set(['type', 'properties']), 'Geometry CRS');
      if (crs.type !== undefined && crs.type !== 'name') {
        throw offlinePayloadRejected('Geometry CRS is invalid.');
      }
      const properties = assertPlainObject(crs.properties, 'Geometry CRS properties');
      assertOnlyAllowedKeys(properties, new Set(['name']), 'Geometry CRS properties');
      if (properties.name !== undefined && typeof properties.name !== 'string') {
        throw offlinePayloadRejected('Geometry CRS is invalid.');
      }
    }
  }

  if (!validateCoordinates(geometry.type, geometry.coordinates, strictOffline)) {
    return rejectGeometry('Invalid geometry coordinates for the provided geometry type');
  }

  const crsNameValue = geometry.crs?.properties?.name;
  if (crsNameValue !== undefined) {
    if (typeof crsNameValue !== 'string') {
      return rejectGeometry('Geometry CRS name must be a string');
    }
    const crsName = crsNameValue.toUpperCase();
    const allowedCrsNames = ['EPSG:4326', 'URN:OGC:DEF:CRS:EPSG::4326'];
    if (!allowedCrsNames.includes(crsName)) {
      return rejectGeometry('Only EPSG:4326 geometry is supported');
    }
  }

  return geometry;
};

export const assertGeometryAcceptedByPostgis = async (
  executor: QueryExecutor,
  geometry: GeoJsonGeometry,
): Promise<void> => {
  const result = await executor.query(
    `SELECT ST_IsValid(candidate) AS is_valid,
            ST_IsEmpty(candidate) AS is_empty,
            ST_NPoints(candidate) AS point_count
     FROM (
       SELECT ST_SetSRID(ST_GeomFromGeoJSON($1), 4326) AS candidate
     ) geometry_check`,
    [JSON.stringify(geometry)],
  );
  const validation = result.rows[0];
  if (
    !validation ||
    validation.is_valid !== true ||
    validation.is_empty === true ||
    Number(validation.point_count) > MAX_OFFLINE_GEOMETRY_VERTICES
  ) {
    throw offlinePayloadRejected('Offline submission geometry is invalid.');
  }
};

const ensureAttributesObject = (attributes: unknown): Record<string, unknown> => {
  if (!attributes || typeof attributes !== 'object' || Array.isArray(attributes)) {
    throw new AppError('attributes must be a JSON object', 422);
  }
  return attributes as Record<string, unknown>;
};

export const normalizeOfflineAttributesForReceipt = (
  attributesInput: unknown,
): Record<string, unknown> => {
  const attributes = ensureAttributesObject(attributesInput);
  assertSafeOfflineJson(attributes);
  if (Buffer.byteLength(JSON.stringify(attributes), 'utf8') > MAX_OFFLINE_ATTRIBUTE_BYTES) {
    throw offlinePayloadRejected('Offline submission attributes are too large.');
  }
  if (Object.keys(attributes).some(shouldStripManagedFeatureAttributeKey)) {
    throw offlinePayloadRejected('Offline submission cannot set server-managed attributes.');
  }
  return sanitizeManagedFeatureAttributes(attributes);
};

export const normalizeOfflineAccuracyForReceipt = (accuracyMeters: unknown): number | null => {
  if (accuracyMeters === undefined || accuracyMeters === null) {
    return null;
  }
  if (
    typeof accuracyMeters !== 'number' ||
    !Number.isFinite(accuracyMeters) ||
    accuracyMeters < 0
  ) {
    throw offlinePayloadRejected('Offline submission GPS accuracy is invalid.');
  }
  return accuracyMeters;
};

const validateType = (value: unknown, expectedType: string): boolean => {
  if (value === undefined) {
    return true;
  }
  if (value === null) {
    return false;
  }

  switch (expectedType) {
    case 'string':
    case 'text':
    case 'textarea':
    case 'select':
    case 'date':
    case 'email':
    case 'phone':
    case 'mobile':
    case 'telephone':
    case 'lebaneseMobile':
    case 'lebanese_mobile':
      return typeof value === 'string';
    case 'number':
      return typeof value === 'number' && Number.isFinite(value);
    case 'integer':
      return typeof value === 'number' && Number.isFinite(value) && Number.isInteger(value);
    case 'boolean':
      return typeof value === 'boolean';
    case 'object':
      return typeof value === 'object' && !Array.isArray(value);
    case 'array':
      return Array.isArray(value);
    default:
      return false;
  }
};

const supportedJsonSchemaTypes = new Set([
  'string',
  'number',
  'integer',
  'boolean',
  'object',
  'array',
]);
const jsonSchemaAnnotationKeys = new Set([
  'title',
  'description',
  'default',
  'examples',
  'deprecated',
  'readOnly',
  'writeOnly',
]);

const schemaConfigurationError = (): Error =>
  new Error('Project collection form schema is unsupported or invalid.');

const isSchemaRecord = (value: unknown): value is Record<string, unknown> =>
  Boolean(value) && typeof value === 'object' && !Array.isArray(value);

const assertNonNegativeIntegerSchemaKeyword = (value: unknown): void => {
  if (value !== undefined && (!Number.isSafeInteger(value) || Number(value) < 0)) {
    throw schemaConfigurationError();
  }
};

const assertSupportedJsonSchemaProperty = (
  propertySchema: Record<string, unknown>,
  depth = 0,
): void => {
  if (depth > MAX_OFFLINE_NESTING_DEPTH) {
    throw schemaConfigurationError();
  }
  const type = propertySchema.type;
  if (typeof type !== 'string' || !supportedJsonSchemaTypes.has(type)) {
    throw schemaConfigurationError();
  }

  const allowedKeys = new Set<string>(['type', 'enum', ...jsonSchemaAnnotationKeys]);
  if (type === 'string') {
    ['minLength', 'maxLength', 'format'].forEach((key) => allowedKeys.add(key));
    assertNonNegativeIntegerSchemaKeyword(propertySchema.minLength);
    assertNonNegativeIntegerSchemaKeyword(propertySchema.maxLength);
    if (
      typeof propertySchema.minLength === 'number' &&
      typeof propertySchema.maxLength === 'number' &&
      propertySchema.minLength > propertySchema.maxLength
    ) {
      throw schemaConfigurationError();
    }
    if (
      propertySchema.format !== undefined &&
      !['date', 'date-time', 'uuid', 'email', 'lebanese-mobile'].includes(
        String(propertySchema.format),
      )
    ) {
      throw schemaConfigurationError();
    }
  } else if (type === 'number' || type === 'integer') {
    ['minimum', 'maximum'].forEach((key) => allowedKeys.add(key));
    for (const key of ['minimum', 'maximum']) {
      const value = propertySchema[key];
      if (value !== undefined && (typeof value !== 'number' || !Number.isFinite(value))) {
        throw schemaConfigurationError();
      }
    }
    if (
      typeof propertySchema.minimum === 'number' &&
      typeof propertySchema.maximum === 'number' &&
      propertySchema.minimum > propertySchema.maximum
    ) {
      throw schemaConfigurationError();
    }
  } else if (type === 'array') {
    ['items', 'minItems', 'maxItems', 'uniqueItems'].forEach((key) => allowedKeys.add(key));
    assertNonNegativeIntegerSchemaKeyword(propertySchema.minItems);
    assertNonNegativeIntegerSchemaKeyword(propertySchema.maxItems);
    if (
      typeof propertySchema.minItems === 'number' &&
      typeof propertySchema.maxItems === 'number' &&
      propertySchema.minItems > propertySchema.maxItems
    ) {
      throw schemaConfigurationError();
    }
    if (!isSchemaRecord(propertySchema.items)) {
      throw schemaConfigurationError();
    }
    if (
      propertySchema.uniqueItems !== undefined &&
      typeof propertySchema.uniqueItems !== 'boolean'
    ) {
      throw schemaConfigurationError();
    }
    assertSupportedJsonSchemaProperty(propertySchema.items, depth + 1);
  } else if (type === 'object') {
    ['properties', 'required', 'additionalProperties'].forEach((key) => allowedKeys.add(key));
    const properties = propertySchema.properties;
    if (!isSchemaRecord(properties)) {
      throw schemaConfigurationError();
    }
    if (
      propertySchema.additionalProperties !== undefined &&
      propertySchema.additionalProperties !== false
    ) {
      throw schemaConfigurationError();
    }
    const required = propertySchema.required;
    if (
      required !== undefined &&
      (!Array.isArray(required) ||
        required.some(
          (key) =>
            typeof key !== 'string' || !Object.prototype.hasOwnProperty.call(properties, key),
        ))
    ) {
      throw schemaConfigurationError();
    }
    for (const nestedSchema of Object.values(properties)) {
      if (!isSchemaRecord(nestedSchema)) {
        throw schemaConfigurationError();
      }
      assertSupportedJsonSchemaProperty(nestedSchema, depth + 1);
    }
  }

  if (Object.keys(propertySchema).some((key) => !allowedKeys.has(key))) {
    throw schemaConfigurationError();
  }
  if (propertySchema.enum !== undefined) {
    if (
      !Array.isArray(propertySchema.enum) ||
      propertySchema.enum.length > MAX_OFFLINE_ARRAY_ITEMS
    ) {
      throw schemaConfigurationError();
    }
  }
  for (const key of ['readOnly', 'writeOnly', 'deprecated']) {
    if (propertySchema[key] !== undefined && typeof propertySchema[key] !== 'boolean') {
      throw schemaConfigurationError();
    }
  }
};

const isValidIsoDate = (value: string): boolean => {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) {
    return false;
  }
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const date = new Date(Date.UTC(year, month - 1, day));
  return (
    date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day
  );
};

const stringMatchesFormat = (value: string, format: unknown): boolean => {
  if (format === undefined) {
    return true;
  }
  switch (format) {
    case 'date':
      return isValidIsoDate(value);
    case 'date-time':
      return (
        /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value) &&
        isValidIsoDate(value.slice(0, 10)) &&
        !Number.isNaN(Date.parse(value))
      );
    case 'uuid':
      return UUID_PATTERN.test(value);
    case 'email':
      return normalizeEmailAddress(value) != null;
    case 'lebanese-mobile':
      return normalizeLebaneseMobile(value) != null;
    default:
      return false;
  }
};

const normalizeSchemaContactValue = (
  value: unknown,
  propertySchema: Record<string, unknown>,
): unknown => {
  if (typeof value === 'string' && propertySchema.format === 'email') {
    return normalizeEmailAddress(value)?.delivery ?? value;
  }
  if (typeof value === 'string' && propertySchema.format === 'lebanese-mobile') {
    return normalizeLebaneseMobile(value)?.e164 ?? value;
  }
  if (Array.isArray(value) && isSchemaRecord(propertySchema.items)) {
    return value.map((item) =>
      normalizeSchemaContactValue(item, propertySchema.items as Record<string, unknown>),
    );
  }
  if (isSchemaRecord(value) && isSchemaRecord(propertySchema.properties)) {
    const properties = propertySchema.properties as Record<string, Record<string, unknown>>;
    return Object.fromEntries(
      Object.entries(value).map(([key, nestedValue]) => [
        key,
        properties[key] == null
          ? nestedValue
          : normalizeSchemaContactValue(nestedValue, properties[key]),
      ]),
    );
  }
  return value;
};

const jsonValuesEqual = (left: unknown, right: unknown): boolean =>
  JSON.stringify(canonicalizeJson(left)) === JSON.stringify(canonicalizeJson(right));

const validateStrictJsonSchemaValue = (
  value: unknown,
  propertySchema: Record<string, unknown>,
  depth = 0,
): void => {
  assertSupportedJsonSchemaProperty(propertySchema, depth);
  const type = propertySchema.type as string;
  if (propertySchema.readOnly === true) {
    throw offlinePayloadRejected('Offline submission cannot set a server-managed attribute.');
  }
  if (!validateType(value, type)) {
    throw offlinePayloadRejected('Offline submission attribute type is invalid.');
  }
  if (
    Array.isArray(propertySchema.enum) &&
    !propertySchema.enum.some((candidate) => jsonValuesEqual(candidate, value))
  ) {
    throw offlinePayloadRejected('Offline submission attribute value is invalid.');
  }

  if (typeof value === 'string') {
    if (
      (typeof propertySchema.minLength === 'number' && value.length < propertySchema.minLength) ||
      (typeof propertySchema.maxLength === 'number' && value.length > propertySchema.maxLength)
    ) {
      throw offlinePayloadRejected('Offline submission attribute length is invalid.');
    }
    if (!stringMatchesFormat(value, propertySchema.format)) {
      throw offlinePayloadRejected('Offline submission attribute format is invalid.');
    }
  } else if (typeof value === 'number') {
    if (
      (typeof propertySchema.minimum === 'number' && value < propertySchema.minimum) ||
      (typeof propertySchema.maximum === 'number' && value > propertySchema.maximum)
    ) {
      throw offlinePayloadRejected('Offline submission attribute range is invalid.');
    }
  } else if (Array.isArray(value)) {
    if (
      (typeof propertySchema.minItems === 'number' && value.length < propertySchema.minItems) ||
      (typeof propertySchema.maxItems === 'number' && value.length > propertySchema.maxItems)
    ) {
      throw offlinePayloadRejected('Offline submission attribute collection size is invalid.');
    }
    if (
      propertySchema.uniqueItems === true &&
      new Set(value.map((item) => JSON.stringify(canonicalizeJson(item)))).size !== value.length
    ) {
      throw offlinePayloadRejected('Offline submission attribute values must be unique.');
    }
    for (const item of value) {
      validateStrictJsonSchemaValue(
        item,
        propertySchema.items as Record<string, unknown>,
        depth + 1,
      );
    }
  } else if (value && typeof value === 'object') {
    const objectValue = value as Record<string, unknown>;
    const properties = propertySchema.properties as Record<string, Record<string, unknown>>;
    const unknownKey = Object.keys(objectValue).find(
      (key) => !Object.prototype.hasOwnProperty.call(properties, key),
    );
    if (unknownKey) {
      throw offlinePayloadRejected('Offline submission contains an unknown project attribute.');
    }
    const required = Array.isArray(propertySchema.required)
      ? (propertySchema.required as string[])
      : [];
    for (const requiredKey of required) {
      if (
        objectValue[requiredKey] === undefined ||
        objectValue[requiredKey] === null ||
        objectValue[requiredKey] === ''
      ) {
        throw offlinePayloadRejected('Offline submission is missing a required project attribute.');
      }
    }
    for (const [key, nestedValue] of Object.entries(objectValue)) {
      validateStrictJsonSchemaValue(nestedValue, properties[key], depth + 1);
    }
  }
};

const assertSupportedLegacyJsonSchema = (
  schema: Record<string, unknown>,
  properties: Record<string, Record<string, unknown>>,
): void => {
  const allowedRootKeys = new Set([
    '$schema',
    '$id',
    'title',
    'description',
    'type',
    'properties',
    'required',
    'additionalProperties',
    'version',
    'schemaVersion',
    'fields',
    'allowedGeometryTypes',
    'maxGpsAccuracyMeters',
  ]);
  if (Object.keys(schema).some((key) => !allowedRootKeys.has(key))) {
    throw schemaConfigurationError();
  }
  if (schema.type !== undefined && schema.type !== 'object') {
    throw schemaConfigurationError();
  }
  if (schema.additionalProperties !== undefined && schema.additionalProperties !== false) {
    throw schemaConfigurationError();
  }
  const required = schema.required ?? [];
  if (
    !Array.isArray(required) ||
    required.some(
      (key) => typeof key !== 'string' || !Object.prototype.hasOwnProperty.call(properties, key),
    )
  ) {
    throw schemaConfigurationError();
  }
  for (const propertySchema of Object.values(properties)) {
    if (!isSchemaRecord(propertySchema)) {
      throw schemaConfigurationError();
    }
    assertSupportedJsonSchemaProperty(propertySchema);
  }
};

export const validateAttributesAgainstSchema = (
  attributesInput: unknown,
  schema: Record<string, unknown>,
  { strictOffline = false }: { strictOffline?: boolean } = {},
): Record<string, unknown> => {
  const attributes = strictOffline
    ? normalizeOfflineAttributesForReceipt(attributesInput)
    : ensureAttributesObject(attributesInput);

  const jsonSchemaRequired = Array.isArray(schema.required) ? (schema.required as string[]) : [];
  const jsonSchemaProps =
    schema.properties && typeof schema.properties === 'object' && !Array.isArray(schema.properties)
      ? (schema.properties as Record<string, Record<string, unknown>>)
      : {};
  const fields = Array.isArray(schema.fields) ? (schema.fields as FormSchemaField[]) : [];

  if (strictOffline) {
    if (schema.properties !== undefined) {
      if (!isSchemaRecord(schema.properties)) {
        throw schemaConfigurationError();
      }
      assertSupportedLegacyJsonSchema(schema, jsonSchemaProps);
    }
    const configuredAttributeKeys = [
      ...Object.keys(jsonSchemaProps),
      ...fields
        .map((field) => field.key || field.name)
        .filter((key): key is string => typeof key === 'string' && key.length > 0),
    ];
    if (configuredAttributeKeys.some(shouldStripManagedFeatureAttributeKey)) {
      throw schemaConfigurationError();
    }
    const allowedAttributeKeys = new Set([...configuredAttributeKeys]);
    const unknownAttribute = Object.keys(attributes).find(
      (key) => UNSAFE_JSON_KEYS.has(key) || !allowedAttributeKeys.has(key),
    );
    if (unknownAttribute) {
      throw offlinePayloadRejected('Offline submission contains an unknown project attribute.');
    }
  }

  for (const requiredKey of jsonSchemaRequired) {
    if (
      attributes[requiredKey] === undefined ||
      attributes[requiredKey] === null ||
      attributes[requiredKey] === ''
    ) {
      if (strictOffline) {
        throw offlinePayloadRejected('Offline submission is missing a required project attribute.');
      }
      throw new AppError(`Missing required attribute: ${requiredKey}`, 422);
    }
  }

  for (const [key, propSchema] of Object.entries(jsonSchemaProps)) {
    if (strictOffline) {
      if (!isSchemaRecord(propSchema)) {
        throw schemaConfigurationError();
      }
      assertSupportedJsonSchemaProperty(propSchema);
    }
    if (attributes[key] === undefined) {
      continue;
    }
    if (attributes[key] === '' && !jsonSchemaRequired.includes(key)) {
      delete attributes[key];
      continue;
    }
    if (strictOffline) {
      validateStrictJsonSchemaValue(attributes[key], propSchema);
      attributes[key] = normalizeSchemaContactValue(attributes[key], propSchema);
      continue;
    }
    const expectedType = typeof propSchema?.type === 'string' ? propSchema.type : null;
    if (expectedType && !validateType(attributes[key], expectedType)) {
      if (strictOffline) {
        throw offlinePayloadRejected('Offline submission attribute type is invalid.');
      }
      throw new AppError(`Invalid type for attribute "${key}"`, 422);
    }
    if (
      typeof attributes[key] === 'string' &&
      !stringMatchesFormat(attributes[key] as string, propSchema?.format)
    ) {
      throw new AppError(`Invalid format for attribute "${key}"`, 422);
    }
    attributes[key] = normalizeSchemaContactValue(attributes[key], propSchema);
  }

  for (const field of fields) {
    const fieldKey = field.key || field.name;
    if (!fieldKey) {
      continue;
    }

    if (
      strictOffline &&
      field.type !== undefined &&
      ![
        'string',
        'text',
        'textarea',
        'select',
        'date',
        'number',
        'integer',
        'boolean',
        'email',
        'phone',
        'mobile',
        'telephone',
        'lebaneseMobile',
        'lebanese_mobile',
      ].includes(field.type)
    ) {
      throw schemaConfigurationError();
    }

    const value = attributes[fieldKey];
    if (field.required && (value === undefined || value === null || value === '')) {
      if (strictOffline) {
        throw offlinePayloadRejected('Offline submission is missing a required project attribute.');
      }
      throw new AppError(`Missing required attribute: ${fieldKey}`, 422);
    }

    if (!field.required && value === '') {
      delete attributes[fieldKey];
      continue;
    }

    if (field.type && !validateType(value, field.type)) {
      if (strictOffline) {
        throw offlinePayloadRejected('Offline submission attribute type is invalid.');
      }
      throw new AppError(`Invalid type for attribute "${fieldKey}"`, 422);
    }

    if (field.type === 'email' && typeof value === 'string') {
      const normalized = normalizeEmailAddress(value);
      if (!normalized) {
        throw strictOffline
          ? offlinePayloadRejected('Offline submission attribute format is invalid.')
          : new AppError(`Invalid email for attribute "${fieldKey}"`, 422);
      }
      attributes[fieldKey] = normalized.delivery;
    }

    if (
      ['phone', 'mobile', 'telephone', 'lebaneseMobile', 'lebanese_mobile'].includes(
        field.type ?? '',
      ) &&
      typeof value === 'string'
    ) {
      const normalized = normalizeLebaneseMobile(value);
      if (!normalized) {
        throw strictOffline
          ? offlinePayloadRejected('Offline submission attribute format is invalid.')
          : new AppError(`Invalid Lebanese mobile number for attribute "${fieldKey}"`, 422);
      }
      attributes[fieldKey] = normalized.e164;
    }

    const allowedValues =
      Array.isArray(field.options) && field.options.length > 0
        ? field.options
        : Array.isArray(field.enum) && field.enum.length > 0
          ? field.enum
          : null;
    if (allowedValues && value !== undefined && !allowedValues.includes(value)) {
      if (strictOffline) {
        throw offlinePayloadRejected('Offline submission attribute value is invalid.');
      }
      throw new AppError(`Invalid value for attribute "${fieldKey}"`, 422);
    }

    if (strictOffline && typeof value === 'number') {
      if (
        (typeof field.min === 'number' && value < field.min) ||
        (typeof field.max === 'number' && value > field.max)
      ) {
        throw offlinePayloadRejected('Offline submission attribute range is invalid.');
      }
    }

    if (strictOffline && field.type === 'date' && value !== undefined) {
      const match = typeof value === 'string' ? /^(\d{4})-(\d{2})-(\d{2})$/.exec(value) : null;
      const year = Number(match?.[1]);
      const month = Number(match?.[2]);
      const day = Number(match?.[3]);
      const isLeapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
      const daysInMonth = [31, isLeapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
      if (
        !match ||
        year < 1 ||
        month < 1 ||
        month > 12 ||
        day < 1 ||
        day > daysInMonth[month - 1]
      ) {
        throw offlinePayloadRejected('Offline submission date attribute is invalid.');
      }
    }
  }

  return sanitizeManagedFeatureAttributes(attributes);
};

export const assertOfflineCollectionConstraints = ({
  schema,
  geometry,
  accuracyMeters,
}: {
  schema: Record<string, unknown>;
  geometry: GeoJsonGeometry;
  accuracyMeters: unknown;
}): number | null => {
  const allowedGeometryTypes = Array.isArray(schema.allowedGeometryTypes)
    ? schema.allowedGeometryTypes.map(String)
    : ['Point', 'LineString', 'Polygon'];
  if (!allowedGeometryTypes.includes(geometry.type)) {
    throw offlinePayloadRejected(
      'Offline submission geometry type is not allowed for this project.',
    );
  }

  if (accuracyMeters === undefined || accuracyMeters === null) {
    return null;
  }
  if (
    typeof accuracyMeters !== 'number' ||
    !Number.isFinite(accuracyMeters) ||
    accuracyMeters < 0
  ) {
    throw offlinePayloadRejected('Offline submission GPS accuracy is invalid.');
  }
  const configuredMaximum = Number(schema.maxGpsAccuracyMeters);
  if (Number.isFinite(configuredMaximum) && accuracyMeters > configuredMaximum) {
    throw offlinePayloadRejected('Offline submission GPS accuracy exceeds the project limit.');
  }
  return accuracyMeters;
};
