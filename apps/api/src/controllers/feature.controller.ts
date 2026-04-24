import type { Request, Response } from 'express';
const { query, transaction } = require('../config/database');
const { AppError } = require('../middleware/error');
const logger = require('../utils/logger');
import { synchronizeProjectStatuses } from '../lib/projectLifecycle';

type GeometryType = 'Point' | 'LineString' | 'Polygon';

interface GeoJsonGeometry {
  type: GeometryType;
  coordinates: unknown;
  crs?: {
    type?: string;
    properties?: {
      name?: string;
    };
  };
}

interface Pagination {
  page: number;
  limit: number;
  offset: number;
}

interface FormSchemaField {
  key?: string;
  name?: string;
  type?: string;
  required?: boolean;
  options?: unknown[];
  enum?: unknown[];
}

const MAX_PAGE_LIMIT = 500;

const getPagination = (pageRaw: unknown, limitRaw: unknown): Pagination => {
  const page = Math.max(1, Number.parseInt(String(pageRaw ?? '1'), 10) || 1);
  const requestedLimit = Math.max(1, Number.parseInt(String(limitRaw ?? '50'), 10) || 50);
  const limit = Math.min(requestedLimit, MAX_PAGE_LIMIT);
  const offset = (page - 1) * limit;

  return { page, limit, offset };
};

const isPosition = (value: unknown): value is [number, number] => {
  if (!Array.isArray(value) || value.length < 2) {
    return false;
  }

  const lon = Number(value[0]);
  const lat = Number(value[1]);

  return Number.isFinite(lon) && Number.isFinite(lat) && lon >= -180 && lon <= 180 && lat >= -90 && lat <= 90;
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

const validateGeoJsonGeometry = (geom: unknown): GeoJsonGeometry => {
  if (!geom || typeof geom !== 'object') {
    throw new AppError('Geometry is required', 400);
  }

  const geometry = geom as GeoJsonGeometry;
  const allowedTypes: GeometryType[] = ['Point', 'LineString', 'Polygon'];

  if (!allowedTypes.includes(geometry.type)) {
    throw new AppError('Geometry type must be Point, LineString, or Polygon', 400);
  }

  if (!validateCoordinates(geometry.type, geometry.coordinates)) {
    throw new AppError('Invalid geometry coordinates for the provided geometry type', 400);
  }

  if (geometry.crs?.properties?.name) {
    const crsName = geometry.crs.properties.name.toUpperCase();
    const allowedCrsNames = ['EPSG:4326', 'URN:OGC:DEF:CRS:EPSG::4326'];
    if (!allowedCrsNames.includes(crsName)) {
      throw new AppError('Only EPSG:4326 geometry is supported', 400);
    }
  }

  return geometry;
};

const hasProjectAccess = async (projectId: string, user: Express.UserContext): Promise<boolean> => {
  if (user.role === 'admin') {
    return true;
  }

  const accessCheck = await query(
    `SELECT 1 FROM project_assignment
     WHERE project_id = $1 AND user_id = $2 AND status = 'approved'
     LIMIT 1`,
    [projectId, user.id]
  );

  return accessCheck.rows.length > 0;
};

const hasProjectAdminAccess = async (projectId: string, user: Express.UserContext): Promise<boolean> => {
  if (user.role === 'admin') {
    return true;
  }

  const accessCheck = await query(
    `SELECT 1 FROM project_assignment
     WHERE project_id = $1
       AND user_id = $2
       AND role = 'admin'
       AND status = 'approved'
     LIMIT 1`,
    [projectId, user.id]
  );

  return accessCheck.rows.length > 0;
};

const canAccessFeatureForUser = ({
  featureStatus,
  collectedByUserId,
  projectId,
  user,
}: {
  featureStatus: string;
  collectedByUserId: string;
  projectId: string;
  user: Express.UserContext;
}): Promise<boolean> | boolean => {
  if (user.role === 'admin') {
    return true;
  }

  if (user.role === 'viewer') {
    return featureStatus === 'approved';
  }

  if (featureStatus === 'approved') {
    return true;
  }

  if (collectedByUserId === user.id) {
    return true;
  }

  return hasProjectAdminAccess(projectId, user);
};

const ensureAttributesObject = (attributes: unknown): Record<string, unknown> => {
  if (!attributes || typeof attributes !== 'object' || Array.isArray(attributes)) {
    throw new AppError('attributes must be a JSON object', 422);
  }
  return attributes as Record<string, unknown>;
};

const getProjectFormSchema = async (projectId: string): Promise<Record<string, unknown>> => {
  const projectResult = await query(
    'SELECT id, collection_form_schema FROM project WHERE id = $1',
    [projectId]
  );
  if (projectResult.rows.length === 0) {
    throw new AppError('Project not found', 404);
  }

  const schema = projectResult.rows[0].collection_form_schema;
  if (!schema || typeof schema !== 'object' || Array.isArray(schema)) {
    throw new AppError('Project collection_form_schema is invalid', 422);
  }

  return schema as Record<string, unknown>;
};

const assertProjectAllowsCollectionMutations = async (projectId: string): Promise<void> => {
  await synchronizeProjectStatuses(projectId);
  const projectResult = await query(
    'SELECT id, name, status FROM project WHERE id = $1',
    [projectId]
  );

  if (projectResult.rows.length === 0) {
    throw new AppError('Project not found', 404);
  }

  const project = projectResult.rows[0];
  if (project.status === 'active') {
    return;
  }

  if (project.status === 'paused') {
    throw new AppError(
      'This project is paused. Feature collection is view-only until the project is reactivated.',
      409
    );
  }

  throw new AppError(
    `Feature collection is unavailable while the project status is ${project.status}.`,
    409
  );
};

const validateType = (value: unknown, expectedType: string): boolean => {
  if (value === null || value === undefined) {
    return true;
  }

  switch (expectedType) {
    case 'string':
    case 'text':
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
  attributesInput: unknown,
  schema: Record<string, unknown>
): Record<string, unknown> => {
  const attributes = ensureAttributesObject(attributesInput);

  const jsonSchemaRequired = Array.isArray(schema.required)
    ? (schema.required as string[])
    : [];
  const jsonSchemaProps =
    schema.properties && typeof schema.properties === 'object' && !Array.isArray(schema.properties)
      ? (schema.properties as Record<string, Record<string, unknown>>)
      : {};

  for (const requiredKey of jsonSchemaRequired) {
    if (attributes[requiredKey] === undefined || attributes[requiredKey] === null || attributes[requiredKey] === '') {
      throw new AppError(`Missing required attribute: ${requiredKey}`, 422);
    }
  }

  for (const [key, propSchema] of Object.entries(jsonSchemaProps)) {
    if (attributes[key] === undefined) {
      continue;
    }
    const expectedType = typeof propSchema?.type === 'string' ? propSchema.type : null;
    if (expectedType && !validateType(attributes[key], expectedType)) {
      throw new AppError(`Invalid type for attribute "${key}"`, 422);
    }
  }

  const fields = Array.isArray(schema.fields) ? (schema.fields as FormSchemaField[]) : [];
  for (const field of fields) {
    const fieldKey = field.key || field.name;
    if (!fieldKey) {
      continue;
    }

    const value = attributes[fieldKey];
    if (field.required && (value === undefined || value === null || value === '')) {
      throw new AppError(`Missing required attribute: ${fieldKey}`, 422);
    }

    if (field.type && !validateType(value, field.type)) {
      throw new AppError(`Invalid type for attribute "${fieldKey}"`, 422);
    }

    const allowedValues =
      Array.isArray(field.options) && field.options.length > 0
        ? field.options
        : Array.isArray(field.enum) && field.enum.length > 0
          ? field.enum
          : null;
    if (allowedValues && value !== undefined && !allowedValues.includes(value)) {
      throw new AppError(`Invalid value for attribute "${fieldKey}"`, 422);
    }
  }

  return attributes;
};

const getAllFeatures = async (req: Request, res: Response): Promise<void> => {
  await synchronizeProjectStatuses(
    typeof req.query.project_id === 'string' ? req.query.project_id : undefined
  );
  const { project_id, status } = req.query;
  const { page, limit, offset } = getPagination(req.query.page, req.query.limit);

  if (project_id && req.user?.role !== 'admin') {
    const canAccessProject = await hasProjectAccess(String(project_id), req.user as Express.UserContext);
    if (!canAccessProject) {
      throw new AppError('You do not have access to this project', 403);
    }
  }

  let queryText = `
    SELECT sf.id, sf.project_id, p.name as project_name, sf.status, sf.attributes,
           sf.accuracy_meters, sf.collected_at, sf.submitted_at,
           ST_AsGeoJSON(sf.geom) as geometry,
           u.full_name as collected_by,
           (SELECT COUNT(*) FROM photo WHERE feature_id = sf.id) as photo_count
    FROM spatial_feature sf
    JOIN project p ON sf.project_id = p.id
    LEFT JOIN "user" u ON sf.collected_by_user_id = u.id
    WHERE 1=1
  `;

  const params: unknown[] = [];
  let paramIndex = 1;

  if (project_id) {
    queryText += ` AND sf.project_id = $${paramIndex}`;
    params.push(project_id);
    paramIndex += 1;
  }

  if (status) {
    queryText += ` AND sf.status = $${paramIndex}`;
    params.push(status);
    paramIndex += 1;
  }

  if (req.user?.role !== 'admin') {
    queryText += `
      AND EXISTS (
        SELECT 1 FROM project_assignment pa
        WHERE pa.project_id = sf.project_id
          AND pa.user_id = $${paramIndex}
          AND pa.status = 'approved'
      )
      AND (sf.status = 'approved' OR sf.collected_by_user_id = $${paramIndex})
    `;
    params.push(req.user?.id);
    paramIndex += 1;
  }

  queryText += ` ORDER BY sf.collected_at DESC LIMIT $${paramIndex} OFFSET $${paramIndex + 1}`;
  params.push(limit, offset);

  const result = await query(queryText, params);

  let countQuery = `
    SELECT COUNT(*)::int AS total
    FROM spatial_feature sf
    JOIN project p ON sf.project_id = p.id
    WHERE 1=1
  `;
  const countParams: unknown[] = [];
  let countParamIndex = 1;

  if (project_id) {
    countQuery += ` AND sf.project_id = $${countParamIndex}`;
    countParams.push(project_id);
    countParamIndex += 1;
  }

  if (status) {
    countQuery += ` AND sf.status = $${countParamIndex}`;
    countParams.push(status);
    countParamIndex += 1;
  }

  if (req.user?.role !== 'admin') {
    countQuery += `
      AND EXISTS (
        SELECT 1 FROM project_assignment pa
        WHERE pa.project_id = sf.project_id
          AND pa.user_id = $${countParamIndex}
          AND pa.status = 'approved'
      )
      AND (sf.status = 'approved' OR sf.collected_by_user_id = $${countParamIndex})
    `;
    countParams.push(req.user?.id);
    countParamIndex += 1;
  }

  const countResult = await query(countQuery, countParams);
  const total = countResult.rows[0]?.total ?? 0;

  const features = result.rows.map((row: any) => ({
    ...row,
    geometry: JSON.parse(row.geometry),
  }));

  res.json({
    success: true,
    data: features,
    pagination: {
      page,
      limit,
      total,
      totalPages: Math.max(1, Math.ceil(total / limit)),
      has_more: offset + features.length < total,
    },
  });
};

const getFeature = async (req: Request, res: Response): Promise<void> => {
  const { featureId } = req.params;

  const result = await query(
    `SELECT sf.*,
            ST_AsGeoJSON(sf.geom) as geometry,
            u.full_name as collected_by,
            r.full_name as reviewed_by,
            p.name as project_name
     FROM spatial_feature sf
     LEFT JOIN "user" u ON sf.collected_by_user_id = u.id
     LEFT JOIN "user" r ON sf.reviewed_by_user_id = r.id
     LEFT JOIN project p ON sf.project_id = p.id
     WHERE sf.id = $1`,
    [featureId]
  );

  if (result.rows.length === 0) {
    throw new AppError('Feature not found', 404);
  }

  const canAccessProject = await hasProjectAccess(result.rows[0].project_id, req.user as Express.UserContext);
  if (!canAccessProject) {
    throw new AppError('You do not have access to this feature', 403);
  }

  const canAccessFeature = await canAccessFeatureForUser({
    featureStatus: result.rows[0].status,
    collectedByUserId: result.rows[0].collected_by_user_id,
    projectId: result.rows[0].project_id,
    user: req.user as Express.UserContext,
  });
  if (!canAccessFeature) {
    throw new AppError('You do not have access to this feature', 403);
  }

  const feature = {
    ...result.rows[0],
    geometry: JSON.parse(result.rows[0].geometry),
  };

  res.json({
    success: true,
    data: feature,
  });
};

const createFeature = async (req: Request, res: Response): Promise<void> => {
  const { id, project_id, geom, attributes, accuracy_meters, collected_offline = false } = req.body;

  await assertProjectAllowsCollectionMutations(project_id);
  const normalizedGeometry = validateGeoJsonGeometry(geom);
  const formSchema = await getProjectFormSchema(project_id);
  const normalizedAttributes = validateAttributesAgainstSchema(attributes, formSchema);

  const accessCheck = await query(
    `SELECT id FROM project_assignment
     WHERE project_id = $1 AND user_id = $2 AND status = 'approved'`,
    [project_id, req.user?.id]
  );

  if (accessCheck.rows.length === 0 && req.user?.role !== 'admin') {
    throw new AppError('You do not have access to this project', 403);
  }

  const result = await query(
    `INSERT INTO spatial_feature (
      id, project_id, collected_by_user_id, geom, attributes,
      accuracy_meters, collected_offline, status
    ) VALUES (
      COALESCE($1::uuid, uuid_generate_v4()),
      $2,
      $3,
      ST_SetSRID(ST_GeomFromGeoJSON($4), 4326),
      $5,
      $6,
      $7,
      'draft'
    )
    RETURNING id, status, version, collected_at, ST_AsGeoJSON(geom) as geometry`,
    [
      id ?? null,
      project_id,
      req.user?.id,
      JSON.stringify(normalizedGeometry),
      JSON.stringify(normalizedAttributes),
      accuracy_meters,
      collected_offline,
    ]
  );

  logger.info('Feature created:', {
    featureId: result.rows[0].id,
    projectId: project_id,
    userId: req.user?.id,
  });

  res.status(201).json({
    success: true,
    message: 'Feature created successfully',
    data: {
      ...result.rows[0],
      geometry: JSON.parse(result.rows[0].geometry),
    },
  });
};

const updateFeature = async (req: Request, res: Response): Promise<void> => {
  const { featureId } = req.params;
  const { attributes, geom } = req.body;

  const featureCheck = await query(
    `SELECT id, status, collected_by_user_id, project_id
     FROM spatial_feature
     WHERE id = $1`,
    [featureId]
  );

  if (featureCheck.rows.length === 0) {
    throw new AppError('Feature not found', 404);
  }

  const feature = featureCheck.rows[0];

  if (req.user?.role !== 'admin' && feature.collected_by_user_id !== req.user?.id) {
    throw new AppError('You can only update your own features', 403);
  }

  await assertProjectAllowsCollectionMutations(feature.project_id);

  if (feature.status !== 'draft') {
    throw new AppError('Only draft features can be updated', 400);
  }

  if (attributes === undefined && geom === undefined) {
    throw new AppError('No fields to update', 400);
  }

  const normalizedGeometry = geom === undefined ? null : validateGeoJsonGeometry(geom);
  const normalizedAttributes =
    attributes === undefined
      ? null
      : validateAttributesAgainstSchema(
          attributes,
          await getProjectFormSchema(feature.project_id)
        );

  const result = await query(
    `
    UPDATE spatial_feature
    SET attributes = COALESCE($1, attributes),
        geom = CASE
          WHEN $2::text IS NULL THEN geom
          ELSE ST_SetSRID(ST_GeomFromGeoJSON($2), 4326)
        END,
        version = version + 1
    WHERE id = $3
    RETURNING id, status, version, ST_AsGeoJSON(geom) as geometry, attributes
  `,
    [
      normalizedAttributes === null ? null : JSON.stringify(normalizedAttributes),
      normalizedGeometry === null ? null : JSON.stringify(normalizedGeometry),
      featureId,
    ]
  );

  logger.info('Feature updated:', { featureId, userId: req.user?.id });

  res.json({
    success: true,
    message: 'Feature updated successfully',
    data: {
      ...result.rows[0],
      geometry: JSON.parse(result.rows[0].geometry),
    },
  });
};

const deleteFeature = async (req: Request, res: Response): Promise<void> => {
  const { featureId } = req.params;

  const featureCheck = await query(
    `SELECT id, status, collected_by_user_id, project_id
     FROM spatial_feature
     WHERE id = $1`,
    [featureId]
  );

  if (featureCheck.rows.length === 0) {
    throw new AppError('Feature not found', 404);
  }

  const feature = featureCheck.rows[0];

  if (feature.status !== 'draft') {
    throw new AppError('Only draft features can be deleted', 400);
  }

  await assertProjectAllowsCollectionMutations(feature.project_id);

  if (req.user?.role !== 'admin' && feature.collected_by_user_id !== req.user?.id) {
    throw new AppError('You can only delete your own draft features', 403);
  }

  await query('DELETE FROM spatial_feature WHERE id = $1', [featureId]);

  logger.info('Feature deleted:', { featureId, userId: req.user?.id });

  res.json({
    success: true,
    message: 'Feature deleted successfully',
  });
};

const submitFeature = async (req: Request, res: Response): Promise<void> => {
  const { featureId } = req.params;
  await transaction(async (client: any) => {
    const ownerCheck = await client.query(
      `SELECT sf.id, sf.status, sf.project_id, p.name as project_name
       FROM spatial_feature sf
       JOIN project p ON p.id = sf.project_id
       WHERE sf.id = $1 AND sf.collected_by_user_id = $2`,
      [featureId, req.user?.id]
    );

    if (ownerCheck.rows.length === 0) {
      throw new AppError('Feature not found', 404);
    }

    if (ownerCheck.rows[0].status !== 'draft') {
      throw new AppError('Only draft features can be submitted', 400);
    }

    await assertProjectAllowsCollectionMutations(ownerCheck.rows[0].project_id);

    await client.query(
      `UPDATE spatial_feature
       SET status = 'pending_review', submitted_at = NOW(), version = version + 1
       WHERE id = $1`,
      [featureId]
    );

    const adminUsers = await client.query(
      `SELECT id FROM "user" WHERE role = 'admin' AND is_active = TRUE`
    );

    for (const admin of adminUsers.rows) {
      await client.query(
        `INSERT INTO notification (user_id, type, title, message, metadata)
         VALUES ($1, 'review_completed', 'Feature review pending',
                 $2, $3)`,
        [
          admin.id,
          `A submitted feature in ${ownerCheck.rows[0].project_name} is waiting for review.`,
          JSON.stringify({
            feature_id: featureId,
            project_id: ownerCheck.rows[0].project_id,
            project_name: ownerCheck.rows[0].project_name,
            status: 'pending_review',
          }),
        ]
      );
    }
  });

  logger.info('Feature submitted for review:', { featureId, userId: req.user?.id });

  res.json({
    success: true,
    message: 'Feature submitted for review',
  });
};

const reviewFeature = async (req: Request, res: Response): Promise<void> => {
  const { featureId } = req.params;
  const { status, review_notes } = req.body;

  if (!['approved', 'rejected'].includes(status)) {
    throw new AppError('Status must be approved or rejected', 400);
  }

  const featureCheck = await query(
    `SELECT sf.id, sf.status, sf.collected_by_user_id, sf.project_id, p.name AS project_name
     FROM spatial_feature sf
     JOIN project p ON p.id = sf.project_id
     WHERE sf.id = $1`,
    [featureId]
  );

  if (featureCheck.rows.length === 0) {
    throw new AppError('Feature not found', 404);
  }

  if (!['pending_review', 'approved', 'rejected'].includes(featureCheck.rows[0].status)) {
    throw new AppError(
      'Only submitted or previously reviewed features can be reviewed through this action',
      400
    );
  }

  const canReview = await hasProjectAdminAccess(featureCheck.rows[0].project_id, req.user as Express.UserContext);
  if (!canReview) {
    throw new AppError('You are not allowed to review this feature', 403);
  }

  await transaction(async (client: any) => {
    await client.query(
      `UPDATE spatial_feature
       SET status = $1,
           reviewed_by_user_id = $2,
           review_notes = $3,
           reviewed_at = NOW(),
           version = version + 1
       WHERE id = $4`,
      [status, req.user?.id, review_notes, featureId]
    );

    await client.query(
      `INSERT INTO notification (user_id, type, title, message, metadata)
       VALUES ($1, 'review_completed', $2, $3, $4)`,
      [
        featureCheck.rows[0].collected_by_user_id,
        status === 'approved'
            ? `Feature approved in ${featureCheck.rows[0].project_name}`
            : `Feature rejected in ${featureCheck.rows[0].project_name}`,
        status === 'approved'
          ? `Your feature in ${featureCheck.rows[0].project_name} was approved${review_notes ? ` with note: ${review_notes}` : '.'}`
          : `Your feature in ${featureCheck.rows[0].project_name} was rejected${review_notes ? ` with note: ${review_notes}` : '.'}`,
        JSON.stringify({
          feature_id: featureId,
          project_id: featureCheck.rows[0].project_id,
          project_name: featureCheck.rows[0].project_name,
          status,
          review_notes,
        }),
      ]
    );
  });

  logger.info('Feature reviewed:', {
    featureId,
    status,
    reviewerId: req.user?.id,
  });

  res.json({
    success: true,
    message: `Feature ${status} successfully`,
  });
};

const findFeaturesNearby = async (req: Request, res: Response): Promise<void> => {
  const lon = Number.parseFloat(String(req.query.lon ?? ''));
  const lat = Number.parseFloat(String(req.query.lat ?? ''));
  const radius = Number.parseFloat(String(req.query.radius ?? '1000'));
  const projectId = req.query.project_id ? String(req.query.project_id) : null;
  const limit = Math.min(Math.max(1, Number.parseInt(String(req.query.limit ?? '50'), 10) || 50), 200);

  if (!Number.isFinite(lon) || !Number.isFinite(lat)) {
    throw new AppError('Longitude and latitude are required and must be valid numbers', 400);
  }

  if (lon < -180 || lon > 180 || lat < -90 || lat > 90) {
    throw new AppError('Longitude/latitude out of valid range', 400);
  }

  if (!Number.isFinite(radius) || radius <= 0) {
    throw new AppError('radius must be a positive number in meters', 400);
  }

  let queryText = `
    SELECT sf.id, sf.attributes, sf.status,
           ST_AsGeoJSON(sf.geom) as geometry,
           ST_Distance(
             sf.geom::geography,
             ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography
           ) as distance_meters
    FROM spatial_feature sf
    WHERE ST_DWithin(
      sf.geom::geography,
      ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography,
      $3
    )
    AND sf.status = 'approved'
  `;

  const params: unknown[] = [lon, lat, radius];
  let paramIndex = 4;

  if (projectId) {
    if (req.user?.role !== 'admin') {
      const canAccessProject = await hasProjectAccess(projectId, req.user as Express.UserContext);
      if (!canAccessProject) {
        throw new AppError('You do not have access to this project', 403);
      }
    }

    queryText += ` AND sf.project_id = $${paramIndex}`;
    params.push(projectId);
    paramIndex += 1;
  }

  if (req.user?.role !== 'admin') {
    queryText += `
      AND EXISTS (
        SELECT 1 FROM project_assignment pa
        WHERE pa.project_id = sf.project_id
          AND pa.user_id = $${paramIndex}
          AND pa.status = 'approved'
      )
    `;
    params.push(req.user?.id);
    paramIndex += 1;
  }

  queryText += ` ORDER BY distance_meters LIMIT $${paramIndex}`;
  params.push(limit);

  const result = await query(queryText, params);

  const features = result.rows.map((row: any) => ({
    ...row,
    geometry: JSON.parse(row.geometry),
  }));

  res.json({
    success: true,
    data: features,
    meta: {
      radius_meters: radius,
      limit,
    },
  });
};

const findFeaturesByBbox = async (req: Request, res: Response): Promise<void> => {
  const minLon = Number.parseFloat(String(req.query.minLon));
  const minLat = Number.parseFloat(String(req.query.minLat));
  const maxLon = Number.parseFloat(String(req.query.maxLon));
  const maxLat = Number.parseFloat(String(req.query.maxLat));
  const projectId = req.query.project_id ? String(req.query.project_id) : null;
  const status = req.query.status ? String(req.query.status) : null;
  const { page, limit, offset } = getPagination(req.query.page, req.query.limit);

  if (!Number.isFinite(minLon) || !Number.isFinite(minLat) || !Number.isFinite(maxLon) || !Number.isFinite(maxLat)) {
    throw new AppError('Bounding box coordinates must be valid numbers', 400);
  }

  if (minLon >= maxLon || minLat >= maxLat) {
    throw new AppError('Invalid BBOX boundaries: min values must be less than max values', 400);
  }

  if (projectId && req.user?.role !== 'admin') {
    const canAccessProject = await hasProjectAccess(projectId, req.user as Express.UserContext);
    if (!canAccessProject) {
      throw new AppError('You do not have access to this project', 403);
    }
  }

  const whereClauses: string[] = [
    'sf.geom && ST_MakeEnvelope($1, $2, $3, $4, 4326)',
  ];
  const params: unknown[] = [minLon, minLat, maxLon, maxLat];
  let paramIndex = 5;

  if (projectId) {
    whereClauses.push(`sf.project_id = $${paramIndex}`);
    params.push(projectId);
    paramIndex += 1;
  }

  if (status) {
    whereClauses.push(`sf.status = $${paramIndex}`);
    params.push(status);
    paramIndex += 1;
  }

  if (req.user?.role !== 'admin') {
    whereClauses.push(`
      EXISTS (
        SELECT 1
        FROM project_assignment pa
        WHERE pa.project_id = sf.project_id
          AND pa.user_id = $${paramIndex}
          AND pa.status = 'approved'
      )
    `);
    params.push(req.user?.id);
    paramIndex += 1;
  }

  const whereSql = whereClauses.join(' AND ');

  const dataSql = `
    SELECT sf.id,
           sf.project_id,
           sf.status,
           sf.attributes,
           sf.collected_at,
           sf.version,
           ST_AsGeoJSON(sf.geom) AS geometry
    FROM spatial_feature sf
    WHERE ${whereSql}
    ORDER BY sf.collected_at DESC
    LIMIT $${paramIndex} OFFSET $${paramIndex + 1}
  `;

  const countSql = `
    SELECT COUNT(*)::int AS total
    FROM spatial_feature sf
    WHERE ${whereSql}
  `;

  const [dataResult, countResult] = await Promise.all([
    query(dataSql, [...params, limit, offset]),
    query(countSql, params),
  ]);

  const features = dataResult.rows.map((row: any) => ({
    type: 'Feature',
    id: row.id,
    geometry: JSON.parse(row.geometry),
    properties: {
      project_id: row.project_id,
      status: row.status,
      attributes: row.attributes,
      collected_at: row.collected_at,
      version: row.version,
    },
  }));

  const total = Number(countResult.rows[0]?.total ?? 0);

  res.json({
    success: true,
    data: {
      type: 'FeatureCollection',
      bbox: [minLon, minLat, maxLon, maxLat],
      features,
    },
    pagination: {
      page,
      limit,
      total,
      totalPages: Math.max(1, Math.ceil(total / limit)),
    },
  });
};

const batchCreateFeatures = async (req: Request, res: Response): Promise<void> => {
  const { features } = req.body;

  if (!Array.isArray(features) || features.length === 0) {
    throw new AppError('Features array is required', 400);
  }

  if (features.length > 500) {
    throw new AppError('Batch size cannot exceed 500 features', 400);
  }

  const projectIds = [...new Set(features.map((f: any) => f.project_id).filter(Boolean))];

  if (req.user?.role !== 'admin') {
    if (projectIds.length === 0) {
      throw new AppError('Each feature must include project_id', 400);
    }

    const accessResult = await query(
      `SELECT DISTINCT project_id
       FROM project_assignment
       WHERE user_id = $1
         AND status = 'approved'
         AND project_id = ANY($2::uuid[])`,
      [req.user?.id, projectIds]
    );

    const accessibleProjects = new Set(accessResult.rows.map((row: any) => row.project_id));
    const unauthorizedProject = projectIds.find((projectId) => !accessibleProjects.has(projectId));
      if (unauthorizedProject) {
        throw new AppError(`You do not have access to project ${unauthorizedProject}`, 403);
      }
    }

    for (const projectId of projectIds) {
      await assertProjectAllowsCollectionMutations(projectId);
    }

  const createdFeatures = await transaction(async (client: any) => {
    const results: any[] = [];

    for (const feature of features) {
      const { id, project_id, geom, attributes, accuracy_meters, collected_offline } = feature;
      const normalizedGeometry = validateGeoJsonGeometry(geom);
      const formSchema = await getProjectFormSchema(project_id);
      const normalizedAttributes = validateAttributesAgainstSchema(attributes, formSchema);

      const result = await client.query(
        `INSERT INTO spatial_feature (
          id, project_id, collected_by_user_id, geom, attributes,
          accuracy_meters, collected_offline, status
        ) VALUES (
          COALESCE($1::uuid, uuid_generate_v4()),
          $2,
          $3,
          ST_SetSRID(ST_GeomFromGeoJSON($4), 4326),
          $5,
          $6,
          $7,
          'draft'
        )
        RETURNING id, status, version, collected_at`,
        [
          id ?? null,
          project_id,
          req.user?.id,
          JSON.stringify(normalizedGeometry),
          JSON.stringify(normalizedAttributes),
          accuracy_meters,
          collected_offline || false,
        ]
      );

      results.push(result.rows[0]);
    }

    return results;
  });

  logger.info('Batch features created:', {
    count: createdFeatures.length,
    userId: req.user?.id,
  });

  res.status(201).json({
    success: true,
    message: `${createdFeatures.length} features created successfully`,
    data: createdFeatures,
  });
};

module.exports = {
  getAllFeatures,
  getFeature,
  createFeature,
  updateFeature,
  deleteFeature,
  submitFeature,
  reviewFeature,
  findFeaturesNearby,
  findFeaturesByBbox,
  batchCreateFeatures,
};

export {};
