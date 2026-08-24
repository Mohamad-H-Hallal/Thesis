import type { Request, Response } from 'express';
const { query, transaction } = require('../config/database');
const {
  AppError,
  offlineSyncConflictError,
  permanentOfflineSyncError,
} = require('../middleware/error');
const logger = require('../utils/logger');
import {
  sanitizeManagedFeatureAttributes,
  shouldStripManagedFeatureAttributeKey,
} from '../lib/featureAttributes';
import { serializePhotoForClient } from '../lib/photoMedia';
import { publicVisibleStatuses, synchronizeProjectStatuses } from '../lib/projectLifecycle';
import {
  UUID_PATTERN,
  assertCurrentOfflineAuthorization,
  assertGeometryAcceptedByPostgis,
  assertMatchingOfflineReceipt,
  assertOfflineCollectionConstraints,
  assertOfflinePayloadSize,
  assertOfflineRequestBinding,
  assertOnlyAllowedKeys,
  assertPlainObject,
  getOfflineReceipt,
  insertOfflineReceipt,
  lockOfflineFeatureIds,
  normalizeOfflineAccuracyForReceipt,
  normalizeOfflineAttributesForReceipt,
  offlinePayloadRejected,
  requestHasOfflineSyncBinding,
  requestHasOfflineSyncSignal,
  sha256Json,
  validateAttributesAgainstSchema,
  validateGeoJsonGeometry,
} from '../services/offlineSyncSecurity.service';
import type { GeoJsonGeometry, QueryExecutor } from '../services/offlineSyncSecurity.service';
import {
  makeFeatureMediaCleanupJobsAvailable,
  processFeatureMediaCleanupJobs,
} from '../services/featureMediaCleanup.service';
import { publishRealtimeChanges } from '../realtime/realtimeEvents';
import type { RealtimePublishInput } from '../realtime/realtimeProtocol';

const featureRealtimeInputs = ({
  projectId,
  featureId,
  action,
  originSessionId,
  includeReviews = false,
}: {
  projectId: string;
  featureId?: string | null;
  action: string;
  originSessionId?: string | null;
  includeReviews?: boolean;
}): RealtimePublishInput[] => [
  {
    scopeType: 'features',
    scopeId: projectId,
    action,
    entityType: 'feature',
    entityId: featureId,
    projectId,
    originSessionId,
    audience: { kind: 'project', projectId, access: 'readers' },
  },
  ...(featureId
    ? [
        {
          scopeType: 'feature',
          scopeId: featureId,
          action,
          entityType: 'feature',
          entityId: featureId,
          projectId,
          originSessionId,
          audience: { kind: 'project' as const, projectId, access: 'readers' as const },
        },
      ]
    : []),
  {
    scopeType: 'project',
    scopeId: projectId,
    action: 'feature_changed',
    entityType: 'feature',
    entityId: featureId,
    projectId,
    originSessionId,
    audience: { kind: 'project', projectId, access: 'readers' },
  },
  ...(includeReviews
    ? [
        {
          scopeType: 'reviews',
          scopeId: projectId,
          action,
          entityType: 'feature',
          entityId: featureId,
          projectId,
          originSessionId,
          audience: { kind: 'project' as const, projectId, access: 'members' as const },
        },
        {
          scopeType: 'reviews',
          scopeId: 'all',
          action,
          entityType: 'feature',
          entityId: featureId,
          projectId,
          originSessionId,
          audience: { kind: 'admins' as const },
        },
      ]
    : []),
];

const notificationRealtimeInput = (
  userId: string,
  projectId: string,
  originSessionId?: string | null,
): RealtimePublishInput => ({
  scopeType: 'notifications',
  scopeId: userId,
  action: 'created',
  entityType: 'notification',
  projectId,
  originSessionId,
  audience: { kind: 'user', userId },
});

interface Pagination {
  page: number;
  limit: number;
  offset: number;
}

interface TileBounds {
  minLon: number;
  minLat: number;
  maxLon: number;
  maxLat: number;
}

type ProjectReadScope = 'admin' | 'project_admin' | 'assigned' | 'public' | 'none';

const publicVisibilityColumnForRole = (
  role: string,
): 'visible_to_viewers' | 'visible_to_contributors' =>
  role === 'viewer' ? 'visible_to_viewers' : 'visible_to_contributors';

const MAX_PAGE_LIMIT = 500;
const MAX_BBOX_PAGE_LIMIT = 20000;
const MAP_TILE_LOW_ZOOM_LIMIT = 300;
const MAP_TILE_HIGH_ZOOM_LIMIT = 3500;

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

const getBboxPagination = (pageRaw: unknown, limitRaw: unknown): Pagination => {
  const page = Math.max(1, Number.parseInt(String(pageRaw ?? '1'), 10) || 1);
  const requestedLimit = Math.max(
    1,
    Number.parseInt(String(limitRaw ?? String(MAX_BBOX_PAGE_LIMIT)), 10) || MAX_BBOX_PAGE_LIMIT,
  );
  const limit = Math.min(requestedLimit, MAX_BBOX_PAGE_LIMIT);
  const offset = (page - 1) * limit;
  return { page, limit, offset };
};

const getTileBounds = (zRaw: unknown, xRaw: unknown, yRaw: unknown): TileBounds => {
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

const getPagination = (pageRaw: unknown, limitRaw: unknown): Pagination => {
  const page = Math.max(1, Number.parseInt(String(pageRaw ?? '1'), 10) || 1);
  const requestedLimit = Math.max(1, Number.parseInt(String(limitRaw ?? '50'), 10) || 50);
  const limit = Math.min(requestedLimit, MAX_PAGE_LIMIT);
  const offset = (page - 1) * limit;

  return { page, limit, offset };
};

const getProjectReadScope = async (
  projectId: string,
  user: Express.UserContext,
): Promise<ProjectReadScope> => {
  if (user.role === 'admin') {
    return 'admin';
  }

  const visibilityColumn = publicVisibilityColumnForRole(user.role);
  const accessCheck = await query(
    `SELECT
       (
         SELECT role
         FROM project_assignment
         WHERE project_id = $1
           AND user_id = $2
           AND status = 'approved'
         LIMIT 1
       ) AS assignment_role,
       EXISTS (
         SELECT 1
         FROM project
         WHERE id = $1
           AND ${visibilityColumn} = TRUE
           AND status::text = ANY($3::text[])
       ) AS is_public_project`,
    [projectId, user.id, publicVisibleStatuses],
  );

  const assignmentRole = accessCheck.rows[0]?.assignment_role;
  if (assignmentRole === 'admin') {
    return 'project_admin';
  }
  if (assignmentRole) {
    return 'assigned';
  }
  if (accessCheck.rows[0]?.is_public_project === true) {
    return 'public';
  }
  return 'none';
};

const assertProjectReadable = async (
  projectId: string,
  user: Express.UserContext,
): Promise<ProjectReadScope> => {
  const scope = await getProjectReadScope(projectId, user);
  if (scope === 'none') {
    throw new AppError('You do not have access to this project', 403);
  }
  return scope;
};

const appendProjectReadVisibility = (
  whereClauses: string[],
  params: unknown[],
  paramIndex: number,
  user: Express.UserContext | undefined,
  scope?: ProjectReadScope,
): number => {
  if (!user || user.role === 'admin' || scope === 'admin') {
    return paramIndex;
  }

  if (user.role === 'viewer') {
    whereClauses.push(`sf.status = 'approved'`);
    return paramIndex;
  }

  if (scope === 'project_admin') {
    return paramIndex;
  }

  if (scope === 'assigned') {
    whereClauses.push(`(sf.status = 'approved' OR sf.collected_by_user_id = $${paramIndex})`);
    params.push(user.id);
    return paramIndex + 1;
  }

  whereClauses.push(`sf.status = 'approved'`);
  return paramIndex;
};

const appendGlobalReadVisibility = (
  whereClauses: string[],
  params: unknown[],
  paramIndex: number,
  user: Express.UserContext | undefined,
): number => {
  if (!user || user.role === 'admin') {
    return paramIndex;
  }

  const visibilityColumn = publicVisibilityColumnForRole(user.role);
  if (user.role === 'viewer') {
    whereClauses.push(`
      sf.status = 'approved'
      AND EXISTS (
        SELECT 1
        FROM project p_access
        WHERE p_access.id = sf.project_id
          AND p_access.${visibilityColumn} = TRUE
          AND p_access.status::text = ANY($${paramIndex}::text[])
      )
    `);
    params.push(publicVisibleStatuses);
    return paramIndex + 1;
  }

  whereClauses.push(`
    (
      (
        sf.status = 'approved'
        AND EXISTS (
          SELECT 1
          FROM project p_access
          WHERE p_access.id = sf.project_id
            AND p_access.${visibilityColumn} = TRUE
            AND p_access.status::text = ANY($${paramIndex}::text[])
        )
      )
      OR EXISTS (
        SELECT 1
        FROM project_assignment pa_access
        WHERE pa_access.project_id = sf.project_id
          AND pa_access.user_id = $${paramIndex + 1}
          AND pa_access.status = 'approved'
          AND (
            pa_access.role = 'admin'
            OR sf.status = 'approved'
            OR sf.collected_by_user_id = $${paramIndex + 1}
          )
      )
    )
  `);
  params.push(publicVisibleStatuses, user.id);
  return paramIndex + 2;
};

const hasProjectAdminAccess = async (
  projectId: string,
  user: Express.UserContext,
): Promise<boolean> => {
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
    [projectId, user.id],
  );

  return accessCheck.rows.length > 0;
};

const canAccessFeatureForUser = ({
  featureStatus,
  collectedByUserId,
  projectReadScope,
  user,
}: {
  featureStatus: string;
  collectedByUserId: string;
  projectReadScope: ProjectReadScope;
  user: Express.UserContext;
}): Promise<boolean> | boolean => {
  if (
    user.role === 'admin' ||
    projectReadScope === 'admin' ||
    projectReadScope === 'project_admin'
  ) {
    return true;
  }

  if (user.role === 'viewer') {
    return featureStatus === 'approved';
  }

  if (featureStatus === 'approved') {
    return true;
  }

  if (projectReadScope === 'assigned' && collectedByUserId === user.id) {
    return true;
  }

  return false;
};

const getProjectFormSchema = async (
  projectId: string,
  executor?: QueryExecutor,
): Promise<Record<string, unknown>> => {
  const runQuery = executor?.query.bind(executor) ?? query;
  const projectResult = await runQuery(
    'SELECT id, collection_form_schema FROM project WHERE id = $1',
    [projectId],
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
  const projectResult = await query('SELECT id, name, status FROM project WHERE id = $1', [
    projectId,
  ]);

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
      409,
    );
  }

  throw new AppError(
    `Feature collection is unavailable while the project status is ${project.status}.`,
    409,
  );
};

const assertCurrentCollectionAuthorization = async ({
  executor,
  projectId,
  user,
}: {
  executor: QueryExecutor;
  projectId: string;
  user: Express.UserContext;
}): Promise<void> => {
  if (user.role === 'admin') {
    return;
  }
  if (user.role !== 'contributor') {
    throw new AppError('Your current role cannot collect features', 403);
  }

  const assignmentResult = await executor.query(
    `SELECT 1
     FROM project_assignment
     WHERE project_id = $1
       AND user_id = $2
       AND status = 'approved'
       AND role = 'contributor'
     LIMIT 1`,
    [projectId, user.id],
  );
  if (assignmentResult.rows.length === 0) {
    throw new AppError('You do not have permission to collect features in this project', 403);
  }
};

const assertCurrentOfflineOriginOnlineAuthorization = async ({
  executor,
  projectId,
  user,
}: {
  executor: QueryExecutor;
  projectId: string;
  user: Express.UserContext;
}): Promise<'admin' | 'contributor'> =>
  assertCurrentOfflineAuthorization({
    executor,
    userId: user.id,
    projectId,
    allowAdmin: true,
  });

const getAllFeatures = async (req: Request, res: Response): Promise<void> => {
  await synchronizeProjectStatuses(
    typeof req.query.project_id === 'string' ? req.query.project_id : undefined,
  );
  const { project_id, status } = req.query;
  const searchQuery = typeof req.query.q === 'string' ? req.query.q.trim() : '';
  const { page, limit, offset } = getPagination(req.query.page, req.query.limit);
  let projectReadScope: ProjectReadScope | undefined;

  if (project_id && req.user?.role !== 'admin') {
    projectReadScope = await assertProjectReadable(
      String(project_id),
      req.user as Express.UserContext,
    );
  }

  let queryText = `
    SELECT sf.id, sf.project_id, p.name as project_name, sf.status, sf.attributes,
           sf.collected_at, sf.submitted_at,
           ST_AsGeoJSON(sf.geom) as geometry,
           COALESCE(u.full_name, u.masked_contributor_label, 'Former contributor') as collected_by,
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

  if (searchQuery) {
    queryText += `
      AND (
        sf.id::text ILIKE $${paramIndex}
        OR p.name ILIKE $${paramIndex}
        OR COALESCE(u.full_name, '') ILIKE $${paramIndex}
      )
    `;
    params.push(`%${searchQuery}%`);
    paramIndex += 1;
  }

  if (req.user?.role !== 'admin') {
    if (project_id) {
      if (req.user?.role === 'viewer') {
        queryText += ` AND sf.status = 'approved'`;
      } else if (projectReadScope === 'assigned') {
        queryText += ` AND (sf.status = 'approved' OR sf.collected_by_user_id = $${paramIndex})`;
        params.push(req.user?.id);
        paramIndex += 1;
      } else if (projectReadScope !== 'project_admin') {
        queryText += ` AND sf.status = 'approved'`;
      }
    } else {
      const visibilityColumn = publicVisibilityColumnForRole(req.user?.role ?? 'viewer');
      if (req.user?.role === 'viewer') {
        queryText += `
          AND sf.status = 'approved'
          AND EXISTS (
            SELECT 1
            FROM project p_access
            WHERE p_access.id = sf.project_id
              AND p_access.${visibilityColumn} = TRUE
              AND p_access.status::text = ANY($${paramIndex}::text[])
          )
        `;
        params.push(publicVisibleStatuses);
        paramIndex += 1;
      } else {
        queryText += `
        AND (
          (
            sf.status = 'approved'
            AND EXISTS (
              SELECT 1
              FROM project p_access
              WHERE p_access.id = sf.project_id
                AND p_access.${visibilityColumn} = TRUE
                AND p_access.status::text = ANY($${paramIndex}::text[])
            )
          )
          OR EXISTS (
            SELECT 1
            FROM project_assignment pa_access
            WHERE pa_access.project_id = sf.project_id
              AND pa_access.user_id = $${paramIndex + 1}
              AND pa_access.status = 'approved'
              AND (
                pa_access.role = 'admin'
                OR sf.status = 'approved'
                OR sf.collected_by_user_id = $${paramIndex + 1}
              )
          )
        )
      `;
        params.push(publicVisibleStatuses, req.user?.id);
        paramIndex += 2;
      }
    }
  }

  queryText += ` ORDER BY sf.collected_at DESC LIMIT $${paramIndex} OFFSET $${paramIndex + 1}`;
  params.push(limit, offset);

  const result = await query(queryText, params);

  let countQuery = `
    SELECT COUNT(*)::int AS total
    FROM spatial_feature sf
    JOIN project p ON sf.project_id = p.id
    LEFT JOIN "user" u ON sf.collected_by_user_id = u.id
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

  if (searchQuery) {
    countQuery += `
      AND (
        sf.id::text ILIKE $${countParamIndex}
        OR p.name ILIKE $${countParamIndex}
        OR COALESCE(u.full_name, '') ILIKE $${countParamIndex}
      )
    `;
    countParams.push(`%${searchQuery}%`);
    countParamIndex += 1;
  }

  if (req.user?.role !== 'admin') {
    if (project_id) {
      if (req.user?.role === 'viewer') {
        countQuery += ` AND sf.status = 'approved'`;
      } else if (projectReadScope === 'assigned') {
        countQuery += ` AND (sf.status = 'approved' OR sf.collected_by_user_id = $${countParamIndex})`;
        countParams.push(req.user?.id);
        countParamIndex += 1;
      } else if (projectReadScope !== 'project_admin') {
        countQuery += ` AND sf.status = 'approved'`;
      }
    } else {
      const visibilityColumn = publicVisibilityColumnForRole(req.user?.role ?? 'viewer');
      if (req.user?.role === 'viewer') {
        countQuery += `
          AND sf.status = 'approved'
          AND EXISTS (
            SELECT 1
            FROM project p_access
            WHERE p_access.id = sf.project_id
              AND p_access.${visibilityColumn} = TRUE
              AND p_access.status::text = ANY($${countParamIndex}::text[])
          )
        `;
        countParams.push(publicVisibleStatuses);
        countParamIndex += 1;
      } else {
        countQuery += `
        AND (
          (
            sf.status = 'approved'
            AND EXISTS (
              SELECT 1
              FROM project p_access
              WHERE p_access.id = sf.project_id
                AND p_access.${visibilityColumn} = TRUE
                AND p_access.status::text = ANY($${countParamIndex}::text[])
            )
          )
          OR EXISTS (
            SELECT 1
            FROM project_assignment pa_access
            WHERE pa_access.project_id = sf.project_id
              AND pa_access.user_id = $${countParamIndex + 1}
              AND pa_access.status = 'approved'
              AND (
                pa_access.role = 'admin'
                OR sf.status = 'approved'
                OR sf.collected_by_user_id = $${countParamIndex + 1}
              )
          )
        )
      `;
        countParams.push(publicVisibleStatuses, req.user?.id);
        countParamIndex += 2;
      }
    }
  }

  const countResult = await query(countQuery, countParams);
  const total = countResult.rows[0]?.total ?? 0;

  const features = result.rows.map((row: any) => ({
    ...row,
    attributes: sanitizeManagedFeatureAttributes(row.attributes),
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
            (SELECT COUNT(*) FROM photo WHERE feature_id = sf.id) as photo_count,
            COALESCE(
              (
                SELECT json_agg(
                  json_build_object(
                    'id', ph.id,
                    'file_path', ph.file_path,
                    'thumbnail_path', ph.thumbnail_path,
                    'status', ph.status,
                    'taken_at', ph.taken_at,
                    'display_order', ph.display_order
                  )
                  ORDER BY ph.display_order ASC, ph.uploaded_at ASC
                )
                FROM photo ph
                WHERE ph.feature_id = sf.id
              ),
              '[]'::json
            ) as photos,
            COALESCE(u.full_name, u.masked_contributor_label, 'Former contributor') as collected_by,
            COALESCE(r.full_name, r.masked_contributor_label, 'Former reviewer') as reviewed_by,
            p.name as project_name
     FROM spatial_feature sf
     LEFT JOIN "user" u ON sf.collected_by_user_id = u.id
     LEFT JOIN "user" r ON sf.reviewed_by_user_id = r.id
     LEFT JOIN project p ON sf.project_id = p.id
     WHERE sf.id = $1`,
    [featureId],
  );

  if (result.rows.length === 0) {
    throw new AppError('Feature not found', 404);
  }

  const projectReadScope = await getProjectReadScope(
    result.rows[0].project_id,
    req.user as Express.UserContext,
  );
  if (projectReadScope === 'none') {
    throw new AppError('You do not have access to this feature', 403);
  }

  const canAccessFeature = await canAccessFeatureForUser({
    featureStatus: result.rows[0].status,
    collectedByUserId: result.rows[0].collected_by_user_id,
    projectReadScope,
    user: req.user as Express.UserContext,
  });
  if (!canAccessFeature) {
    throw new AppError('You do not have access to this feature', 403);
  }

  const feature = {
    ...result.rows[0],
    attributes: sanitizeManagedFeatureAttributes(result.rows[0].attributes),
    geometry: JSON.parse(result.rows[0].geometry),
    photos: Array.isArray(result.rows[0].photos)
      ? result.rows[0].photos.map((photo: Record<string, unknown>) =>
          serializePhotoForClient(req, photo),
        )
      : [],
  };
  delete feature.accuracy_meters;

  res.json({
    success: true,
    data: feature,
  });
};

const createFeature = async (req: Request, res: Response): Promise<void> => {
  const {
    id,
    client_offline_id,
    offline_owner_user_id,
    project_id,
    geom,
    attributes,
    accuracy_meters,
    collected_offline = false,
  } = req.body;
  const isOfflineSyncRequest = requestHasOfflineSyncSignal(req);

  if (isOfflineSyncRequest) {
    const userId = req.user?.id;
    if (!userId) {
      throw permanentOfflineSyncError(
        'Offline submission discarded because its owner could not be verified.',
        'OFFLINE_SYNC_OWNER_MISMATCH',
      );
    }

    const body = assertPlainObject(req.body, 'Offline submission');
    assertOnlyAllowedKeys(
      body,
      new Set([
        'id',
        'client_offline_id',
        'offline_owner_user_id',
        'project_id',
        'geom',
        'attributes',
        'accuracy_meters',
        'collected_offline',
      ]),
      'Offline submission',
    );
    assertOfflinePayloadSize(body);

    if (collected_offline !== true) {
      throw offlinePayloadRejected(
        'Offline submission must explicitly identify itself as collected offline.',
      );
    }

    if (typeof id !== 'string' || !UUID_PATTERN.test(id)) {
      throw offlinePayloadRejected('Offline submission requires a valid stable feature ID.');
    }
    if (client_offline_id !== undefined && client_offline_id !== id) {
      throw offlinePayloadRejected('Offline submission identifiers do not match.');
    }
    if (typeof offline_owner_user_id !== 'string' || offline_owner_user_id !== userId) {
      throw permanentOfflineSyncError(
        'Offline submission discarded because it belongs to another account.',
        'OFFLINE_SYNC_OWNER_MISMATCH',
      );
    }

    const { idempotencyKeyHash } = assertOfflineRequestBinding({
      req,
      projectId: project_id,
      userId,
    });

    const normalizedGeometry = validateGeoJsonGeometry(geom, { strictOffline: true });
    const receiptAttributes = normalizeOfflineAttributesForReceipt(attributes);
    const receiptAccuracy = normalizeOfflineAccuracyForReceipt(accuracy_meters);
    const payloadHash = sha256Json({
      id,
      project_id,
      geom: normalizedGeometry,
      attributes: receiptAttributes,
      accuracy_meters: receiptAccuracy,
      collected_offline: true,
    });
    const outcome = await transaction(async (client: QueryExecutor) => {
      await assertCurrentOfflineAuthorization({ executor: client, userId, projectId: project_id });
      await lockOfflineFeatureIds(client, [id]);
      const receipt = await getOfflineReceipt({
        executor: client,
        userId,
        projectId: project_id,
        operation: 'create',
        idempotencyKeyHash,
      });
      if (receipt) {
        assertMatchingOfflineReceipt(receipt, payloadHash, [id]);
        const replay = await client.query(
          `SELECT id, status, version, collected_at, ST_AsGeoJSON(geom) AS geometry
           FROM spatial_feature
           WHERE id = $1 AND project_id = $2 AND collected_by_user_id = $3`,
          [id, project_id, userId],
        );
        if (!replay.rows[0]) {
          throw permanentOfflineSyncError(
            'Offline submission parent record is no longer accessible.',
            'OFFLINE_SYNC_PARENT_INACCESSIBLE',
          );
        }
        return { row: replay.rows[0], alreadySynchronized: true };
      }

      const formSchema = await getProjectFormSchema(project_id, client);
      const normalizedAttributes = validateAttributesAgainstSchema(attributes, formSchema, {
        strictOffline: true,
      });
      const normalizedAccuracy = assertOfflineCollectionConstraints({
        schema: formSchema,
        geometry: normalizedGeometry,
        accuracyMeters: accuracy_meters,
      });
      await assertGeometryAcceptedByPostgis(client, normalizedGeometry);

      const existing = await client.query(
        `SELECT id, project_id, collected_by_user_id, collected_offline,
                status, version, collected_at, ST_AsGeoJSON(geom) AS geometry,
                ST_Equals(
                  geom,
                  ST_SetSRID(ST_GeomFromGeoJSON($2), 4326)
                ) AS geometry_matches,
                attributes = $3::jsonb AS attributes_match,
                accuracy_meters IS NOT DISTINCT FROM $4::double precision AS accuracy_matches
         FROM spatial_feature
         WHERE id = $1
         FOR UPDATE`,
        [
          id,
          JSON.stringify(normalizedGeometry),
          JSON.stringify(normalizedAttributes),
          normalizedAccuracy,
        ],
      );
      if (existing.rows[0]) {
        const feature = existing.rows[0];
        const isSameOfflineContribution =
          feature.project_id === project_id &&
          feature.collected_by_user_id === userId &&
          feature.collected_offline === true &&
          feature.geometry_matches === true &&
          feature.attributes_match === true &&
          feature.accuracy_matches === true;
        if (!isSameOfflineContribution) {
          throw permanentOfflineSyncError(
            'Offline submission identifiers or idempotency data do not match.',
            'OFFLINE_SYNC_IDEMPOTENCY_MISMATCH',
            409,
          );
        }
        await insertOfflineReceipt({
          executor: client,
          userId,
          projectId: project_id,
          operation: 'create',
          idempotencyKeyHash,
          payloadHash,
          entityIds: [id],
        });
        return {
          row: {
            id: feature.id,
            status: feature.status,
            version: feature.version,
            collected_at: feature.collected_at,
            geometry: feature.geometry,
          },
          alreadySynchronized: true,
        };
      }

      const inserted = await client.query(
        `INSERT INTO spatial_feature (
          id, project_id, collected_by_user_id, geom, attributes,
          accuracy_meters, collected_offline, status
        ) VALUES (
          $1::uuid,
          $2,
          $3,
          ST_SetSRID(ST_GeomFromGeoJSON($4), 4326),
          $5,
          $6,
          TRUE,
          'draft'
        )
        RETURNING id, status, version, collected_at, ST_AsGeoJSON(geom) AS geometry`,
        [
          id,
          project_id,
          userId,
          JSON.stringify(normalizedGeometry),
          JSON.stringify(normalizedAttributes),
          normalizedAccuracy,
        ],
      );
      await insertOfflineReceipt({
        executor: client,
        userId,
        projectId: project_id,
        operation: 'create',
        idempotencyKeyHash,
        payloadHash,
        entityIds: [id],
      });
      await publishRealtimeChanges(
        featureRealtimeInputs({
          projectId: project_id,
          featureId: id,
          action: 'created',
          originSessionId: req.authSessionId,
        }),
        client,
      );
      return { row: inserted.rows[0], alreadySynchronized: false };
    });

    logger.info(
      outcome.alreadySynchronized
        ? 'Offline feature create replay confirmed:'
        : 'Offline feature created:',
      { featureId: outcome.row.id, projectId: project_id, userId },
    );
    res.status(outcome.alreadySynchronized ? 200 : 201).json({
      success: true,
      message: outcome.alreadySynchronized
        ? 'Feature already created'
        : 'Feature created successfully',
      data: {
        ...outcome.row,
        outcome: outcome.alreadySynchronized ? 'already_synchronized' : 'accepted',
        geometry: JSON.parse(outcome.row.geometry),
      },
    });
    return;
  }

  const onlineBody = assertPlainObject(req.body, 'Feature submission');
  assertOnlyAllowedKeys(
    onlineBody,
    new Set(['id', 'project_id', 'geom', 'attributes', 'accuracy_meters', 'collected_offline']),
    'Feature submission',
  );
  assertOfflinePayloadSize(onlineBody);
  if (collected_offline !== false) {
    throw new AppError('Online feature submissions cannot set offline collection state', 422);
  }
  if (
    attributes &&
    typeof attributes === 'object' &&
    !Array.isArray(attributes) &&
    Object.keys(attributes).some(shouldStripManagedFeatureAttributeKey)
  ) {
    throw offlinePayloadRejected('Feature submission cannot set server-managed attributes.');
  }
  await assertProjectAllowsCollectionMutations(project_id);
  const normalizedGeometry = validateGeoJsonGeometry(geom);
  const formSchema = await getProjectFormSchema(project_id);
  const normalizedAttributes = validateAttributesAgainstSchema(attributes, formSchema);
  await assertGeometryAcceptedByPostgis({ query }, normalizedGeometry);
  await assertCurrentCollectionAuthorization({
    executor: { query },
    projectId: project_id,
    user: req.user as Express.UserContext,
  });

  const result = await transaction(async (client: QueryExecutor) => {
    const inserted = await client.query(
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
      FALSE,
      'draft'
    )
    RETURNING id, status, version, collected_at, ST_AsGeoJSON(geom) AS geometry`,
      [
        id ?? null,
        project_id,
        req.user?.id,
        JSON.stringify(normalizedGeometry),
        JSON.stringify(normalizedAttributes),
        null,
      ],
    );
    await publishRealtimeChanges(
      featureRealtimeInputs({
        projectId: project_id,
        featureId: inserted.rows[0].id,
        action: 'created',
        originSessionId: req.authSessionId,
      }),
      client,
    );
    return inserted;
  });

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
  const { attributes, geom, expected_version } = req.body;
  const isOfflineSyncRequest = requestHasOfflineSyncSignal(req);

  const featureCheck = await query(
    `SELECT id, status, version, collected_by_user_id, project_id, collected_offline
     FROM spatial_feature
     WHERE id = $1`,
    [featureId],
  );

  if (featureCheck.rows.length === 0) {
    if (isOfflineSyncRequest) {
      throw permanentOfflineSyncError(
        'Offline submission parent record is no longer accessible.',
        'OFFLINE_SYNC_PARENT_INACCESSIBLE',
      );
    }
    throw new AppError('Feature not found', 404);
  }

  const feature = featureCheck.rows[0];

  if (isOfflineSyncRequest) {
    const userId = req.user?.id;
    if (!userId) {
      throw permanentOfflineSyncError(
        'Offline submission discarded because its owner could not be verified.',
        'OFFLINE_SYNC_OWNER_MISMATCH',
      );
    }
    const body = assertPlainObject(req.body, 'Offline update');
    assertOnlyAllowedKeys(
      body,
      new Set(['attributes', 'geom', 'expected_version']),
      'Offline update',
    );
    assertOfflinePayloadSize(body);
    if (!Number.isSafeInteger(expected_version) || expected_version < 1) {
      throw offlinePayloadRejected('Offline synchronization version is invalid.');
    }
    if (attributes === undefined && geom === undefined) {
      throw offlinePayloadRejected('Offline update does not contain editable fields.');
    }
    const { idempotencyKeyHash } = assertOfflineRequestBinding({
      req,
      projectId: feature.project_id,
      userId,
    });

    const outcome = await transaction(async (client: QueryExecutor) => {
      const lockedFeatureResult = await client.query(
        `SELECT id, status, version, collected_by_user_id, project_id, collected_offline
         FROM spatial_feature
         WHERE id = $1
         FOR UPDATE`,
        [featureId],
      );
      const lockedFeature = lockedFeatureResult.rows[0];
      if (!lockedFeature) {
        throw permanentOfflineSyncError(
          'Offline submission parent record is no longer accessible.',
          'OFFLINE_SYNC_PARENT_INACCESSIBLE',
        );
      }
      if (lockedFeature.collected_offline !== true) {
        throw permanentOfflineSyncError(
          'Offline submission parent record is no longer accessible.',
          'OFFLINE_SYNC_PARENT_INACCESSIBLE',
        );
      }
      if (lockedFeature.project_id !== feature.project_id) {
        throw permanentOfflineSyncError(
          'Offline submission discarded because its project does not match.',
          'OFFLINE_SYNC_PROJECT_MISMATCH',
        );
      }
      if (lockedFeature.collected_by_user_id !== userId) {
        throw permanentOfflineSyncError(
          'Offline submission discarded because it belongs to another account.',
          'OFFLINE_SYNC_OWNER_MISMATCH',
        );
      }
      await assertCurrentOfflineAuthorization({
        executor: client,
        userId,
        projectId: lockedFeature.project_id,
      });
      const receiptGeometry =
        geom === undefined ? null : validateGeoJsonGeometry(geom, { strictOffline: true });
      const receiptAttributes =
        attributes === undefined ? null : normalizeOfflineAttributesForReceipt(attributes);

      const payloadHash = sha256Json({
        feature_id: featureId,
        project_id: lockedFeature.project_id,
        geom: receiptGeometry,
        attributes: receiptAttributes,
        expected_version,
      });
      const receipt = await getOfflineReceipt({
        executor: client,
        userId,
        projectId: lockedFeature.project_id,
        operation: 'update',
        idempotencyKeyHash,
      });
      if (receipt) {
        assertMatchingOfflineReceipt(receipt, payloadHash, [featureId]);
        const replay = await client.query(
          `SELECT id, status, version, ST_AsGeoJSON(geom) AS geometry, attributes
           FROM spatial_feature
           WHERE id = $1`,
          [featureId],
        );
        return { row: replay.rows[0], alreadySynchronized: true };
      }

      if (lockedFeature.version !== expected_version) {
        throw offlineSyncConflictError(lockedFeature.version);
      }
      if (lockedFeature.status !== 'draft') {
        throw permanentOfflineSyncError(
          'Offline submission parent record is no longer editable.',
          'OFFLINE_SYNC_PARENT_INACCESSIBLE',
          409,
        );
      }
      const formSchema = await getProjectFormSchema(lockedFeature.project_id, client);
      const normalizedGeometry = receiptGeometry;
      const normalizedAttributes =
        attributes === undefined
          ? null
          : validateAttributesAgainstSchema(attributes, formSchema, { strictOffline: true });
      if (normalizedGeometry) {
        assertOfflineCollectionConstraints({
          schema: formSchema,
          geometry: normalizedGeometry,
          accuracyMeters: null,
        });
        await assertGeometryAcceptedByPostgis(client, normalizedGeometry);
      }

      const updated = await client.query(
        `UPDATE spatial_feature
         SET attributes = COALESCE($1, attributes),
             geom = CASE
               WHEN $2::text IS NULL THEN geom
               ELSE ST_SetSRID(ST_GeomFromGeoJSON($2), 4326)
             END,
             version = version + 1
         WHERE id = $3
           AND status = 'draft'
           AND version = $4
           AND project_id = $5
           AND collected_by_user_id = $6
           AND collected_offline = TRUE
         RETURNING id, status, version, ST_AsGeoJSON(geom) AS geometry, attributes`,
        [
          normalizedAttributes === null ? null : JSON.stringify(normalizedAttributes),
          normalizedGeometry === null ? null : JSON.stringify(normalizedGeometry),
          featureId,
          expected_version,
          lockedFeature.project_id,
          userId,
        ],
      );
      if (!updated.rows[0]) {
        throw offlineSyncConflictError(lockedFeature.version);
      }
      await insertOfflineReceipt({
        executor: client,
        userId,
        projectId: lockedFeature.project_id,
        operation: 'update',
        idempotencyKeyHash,
        payloadHash,
        entityIds: [featureId],
      });
      await publishRealtimeChanges(
        featureRealtimeInputs({
          projectId: lockedFeature.project_id,
          featureId,
          action: 'updated',
          originSessionId: req.authSessionId,
        }),
        client,
      );
      return { row: updated.rows[0], alreadySynchronized: false };
    });

    logger.info(
      outcome.alreadySynchronized
        ? 'Offline feature update replay confirmed:'
        : 'Offline feature updated:',
      { featureId, userId },
    );
    res.json({
      success: true,
      message: outcome.alreadySynchronized
        ? 'Feature update already synchronized'
        : 'Feature updated successfully',
      data: {
        ...outcome.row,
        outcome: outcome.alreadySynchronized ? 'already_synchronized' : 'accepted',
        geometry: JSON.parse(outcome.row.geometry),
      },
    });
    return;
  }

  if (feature.collected_offline === true) {
    const user = req.user as Express.UserContext;
    const outcome = await transaction(async (client: QueryExecutor) => {
      const lockedResult = await client.query(
        `SELECT id, status, collected_by_user_id, project_id, collected_offline
         FROM spatial_feature
         WHERE id = $1
         FOR UPDATE`,
        [featureId],
      );
      const lockedFeature = lockedResult.rows[0];
      if (!lockedFeature || lockedFeature.collected_offline !== true) {
        throw permanentOfflineSyncError(
          'Offline-origin feature is no longer accessible.',
          'OFFLINE_SYNC_PARENT_INACCESSIBLE',
        );
      }
      const currentRole = await assertCurrentOfflineOriginOnlineAuthorization({
        executor: client,
        projectId: lockedFeature.project_id,
        user,
      });
      if (currentRole !== 'admin' && lockedFeature.collected_by_user_id !== user.id) {
        throw permanentOfflineSyncError(
          'Offline-origin feature belongs to another account.',
          'OFFLINE_SYNC_OWNER_MISMATCH',
        );
      }
      if (lockedFeature.status !== 'draft') {
        throw permanentOfflineSyncError(
          'Offline-origin feature is no longer editable.',
          'OFFLINE_SYNC_PARENT_INACCESSIBLE',
          409,
        );
      }
      const body = assertPlainObject(req.body, 'Offline-origin feature update');
      assertOnlyAllowedKeys(body, new Set(['attributes', 'geom']), 'Offline-origin feature update');
      assertOfflinePayloadSize(body);
      if (attributes === undefined && geom === undefined) {
        throw offlinePayloadRejected('Offline-origin update does not contain editable fields.');
      }

      const formSchema = await getProjectFormSchema(lockedFeature.project_id, client);
      const normalizedGeometry =
        geom === undefined ? null : validateGeoJsonGeometry(geom, { strictOffline: true });
      const normalizedAttributes =
        attributes === undefined
          ? null
          : validateAttributesAgainstSchema(attributes, formSchema, { strictOffline: true });
      if (normalizedGeometry) {
        assertOfflineCollectionConstraints({
          schema: formSchema,
          geometry: normalizedGeometry,
          accuracyMeters: null,
        });
        await assertGeometryAcceptedByPostgis(client, normalizedGeometry);
      }

      const updated = await client.query(
        `UPDATE spatial_feature
         SET attributes = COALESCE($1, attributes),
             geom = CASE
               WHEN $2::text IS NULL THEN geom
               ELSE ST_SetSRID(ST_GeomFromGeoJSON($2), 4326)
             END,
             version = version + 1
         WHERE id = $3 AND project_id = $4 AND status = 'draft'
         RETURNING id, status, version, ST_AsGeoJSON(geom) AS geometry, attributes`,
        [
          normalizedAttributes === null ? null : JSON.stringify(normalizedAttributes),
          normalizedGeometry === null ? null : JSON.stringify(normalizedGeometry),
          featureId,
          lockedFeature.project_id,
        ],
      );
      if (!updated.rows[0]) {
        throw permanentOfflineSyncError(
          'Offline-origin feature is no longer editable.',
          'OFFLINE_SYNC_PARENT_INACCESSIBLE',
          409,
        );
      }
      await publishRealtimeChanges(
        featureRealtimeInputs({
          projectId: lockedFeature.project_id,
          featureId,
          action: 'updated',
          originSessionId: req.authSessionId,
        }),
        client,
      );
      return updated.rows[0];
    });

    logger.info('Offline-origin feature edited online:', { featureId, userId: user.id });
    res.json({
      success: true,
      message: 'Feature updated successfully',
      data: { ...outcome, geometry: JSON.parse(outcome.geometry) },
    });
    return;
  }

  if (req.user?.role !== 'admin' && feature.collected_by_user_id !== req.user?.id) {
    throw new AppError('You can only update your own features', 403);
  }

  await assertProjectAllowsCollectionMutations(feature.project_id);

  await assertCurrentCollectionAuthorization({
    executor: { query },
    projectId: feature.project_id,
    user: req.user as Express.UserContext,
  });

  if (feature.status !== 'draft') {
    throw new AppError('Only draft features can be updated', 400);
  }

  if (attributes === undefined && geom === undefined) {
    throw new AppError('No fields to update', 400);
  }

  const onlineBody = assertPlainObject(req.body, 'Feature update');
  assertOnlyAllowedKeys(
    onlineBody,
    new Set(['attributes', 'geom', 'expected_version']),
    'Feature update',
  );
  assertOfflinePayloadSize(onlineBody);
  if (
    expected_version !== undefined &&
    (!Number.isSafeInteger(expected_version) || expected_version < 1)
  ) {
    throw new AppError('Feature version is invalid.', 422);
  }
  if (
    attributes &&
    typeof attributes === 'object' &&
    !Array.isArray(attributes) &&
    Object.keys(attributes).some(shouldStripManagedFeatureAttributeKey)
  ) {
    throw offlinePayloadRejected('Feature update cannot set server-managed attributes.');
  }
  const formSchema = await getProjectFormSchema(feature.project_id);
  const normalizedGeometry =
    geom === undefined ? null : validateGeoJsonGeometry(geom);
  const normalizedAttributes =
    attributes === undefined
      ? null
      : validateAttributesAgainstSchema(attributes, formSchema);
  if (normalizedGeometry) {
    await assertGeometryAcceptedByPostgis({ query }, normalizedGeometry);
  }

  const result = await transaction(async (client: QueryExecutor) => {
    const updated = await client.query(
      `UPDATE spatial_feature
       SET attributes = COALESCE($1, attributes),
           geom = CASE
             WHEN $2::text IS NULL THEN geom
             ELSE ST_SetSRID(ST_GeomFromGeoJSON($2), 4326)
           END,
           version = version + 1
       WHERE id = $3
         AND ($4::integer IS NULL OR version = $4)
       RETURNING id, status, version, ST_AsGeoJSON(geom) as geometry, attributes`,
      [
        normalizedAttributes === null ? null : JSON.stringify(normalizedAttributes),
        normalizedGeometry === null ? null : JSON.stringify(normalizedGeometry),
        featureId,
        expected_version ?? null,
      ],
    );
    if (!updated.rows[0]) {
      const current = await client.query('SELECT version FROM spatial_feature WHERE id = $1', [
        featureId,
      ]);
      if (current.rows[0]) {
        throw new AppError(
          'This feature changed after the form was opened. Review the latest server version before saving again.',
          409,
          {
            code: 'ENTITY_VERSION_CONFLICT',
            disposition: 'conflict',
            retryable: false,
            currentVersion: Number(current.rows[0].version),
          },
        );
      }
      throw new AppError('Feature not found', 404);
    }
    await publishRealtimeChanges(
      featureRealtimeInputs({
        projectId: feature.project_id,
        featureId,
        action: 'updated',
        originSessionId: req.authSessionId,
      }),
      client,
    );
    return updated;
  });

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
  const initialFeature = await query(
    `SELECT project_id, collected_offline
     FROM spatial_feature
     WHERE id = $1`,
    [featureId],
  );

  if (initialFeature.rows.length === 0) {
    throw new AppError('Feature not found', 404);
  }

  if (initialFeature.rows[0].collected_offline !== true) {
    await assertProjectAllowsCollectionMutations(initialFeature.rows[0].project_id);
  }

  const user = req.user as Express.UserContext;
  const deletedMediaPaths = await transaction(async (client: QueryExecutor) => {
    const featureCheck = await client.query(
      `SELECT id, status, collected_by_user_id, project_id, collected_offline
       FROM spatial_feature
       WHERE id = $1
       FOR UPDATE`,
      [featureId],
    );
    const feature = featureCheck.rows[0];
    if (!feature) {
      if (initialFeature.rows[0].collected_offline === true) {
        throw permanentOfflineSyncError(
          'Offline-origin feature is no longer accessible.',
          'OFFLINE_SYNC_PARENT_INACCESSIBLE',
        );
      }
      throw new AppError('Feature not found', 404);
    }

    if (feature.collected_offline === true) {
      const currentRole = await assertCurrentOfflineOriginOnlineAuthorization({
        executor: client,
        projectId: feature.project_id,
        user,
      });
      if (currentRole !== 'admin' && feature.collected_by_user_id !== user.id) {
        throw permanentOfflineSyncError(
          'Offline-origin feature belongs to another account.',
          'OFFLINE_SYNC_OWNER_MISMATCH',
        );
      }
      if (feature.status !== 'draft') {
        throw permanentOfflineSyncError(
          'Offline-origin feature is no longer editable.',
          'OFFLINE_SYNC_PARENT_INACCESSIBLE',
          409,
        );
      }
    } else {
      if (feature.status !== 'draft') {
        throw new AppError('Only draft features can be deleted', 400);
      }
      if (user.role !== 'admin' && feature.collected_by_user_id !== user.id) {
        throw new AppError('You can only delete your own draft features', 403);
      }
    }

    const photoPaths = await client.query(
      `SELECT file_path, thumbnail_path
       FROM photo
       WHERE feature_id = $1
       FOR UPDATE`,
      [featureId],
    );
    await client.query('DELETE FROM spatial_feature WHERE id = $1', [featureId]);
    await publishRealtimeChanges(
      featureRealtimeInputs({
        projectId: feature.project_id,
        featureId,
        action: 'deleted',
        originSessionId: req.authSessionId,
        includeReviews: feature.status !== 'draft',
      }),
      client,
    );
    return photoPaths.rows
      .flatMap((photo) => [photo.file_path, photo.thumbnail_path])
      .filter(
        (filePath): filePath is string => typeof filePath === 'string' && filePath.length > 0,
      );
  });

  try {
    await makeFeatureMediaCleanupJobsAvailable({ paths: deletedMediaPaths });
    await processFeatureMediaCleanupJobs({ paths: deletedMediaPaths });
  } catch (cleanupError: unknown) {
    logger.error('Feature deletion media cleanup deferred', {
      featureId,
      errorCode: String((cleanupError as { code?: unknown })?.code ?? 'CLEANUP_DEFERRED'),
    });
  }

  logger.info('Feature deleted:', { featureId, userId: user.id });
  res.json({
    success: true,
    message: 'Feature deleted successfully',
  });
};

const submitFeature = async (req: Request, res: Response): Promise<void> => {
  const { featureId } = req.params;
  const isOfflineSyncRequest = requestHasOfflineSyncBinding(req);
  const projectLookup = await query('SELECT project_id FROM spatial_feature WHERE id = $1', [
    featureId,
  ]);
  if (projectLookup.rows[0] && !isOfflineSyncRequest) {
    await synchronizeProjectStatuses(projectLookup.rows[0].project_id);
  }

  const result = await transaction(async (client: QueryExecutor) => {
    const ownerCheck = await client.query(
      `SELECT sf.id, sf.status, sf.project_id, sf.collected_offline, p.name as project_name
       FROM spatial_feature sf
       JOIN project p ON p.id = sf.project_id
       WHERE sf.id = $1
       FOR UPDATE OF sf`,
      [featureId],
    );

    if (ownerCheck.rows.length === 0) {
      if (isOfflineSyncRequest) {
        throw permanentOfflineSyncError(
          'Offline submission parent record is no longer accessible.',
          'OFFLINE_SYNC_PARENT_INACCESSIBLE',
        );
      }
      throw new AppError('Feature not found', 404);
    }

    const feature = ownerCheck.rows[0];
    const userId = req.user?.id;
    const isOfflineSync = isOfflineSyncRequest;
    if (isOfflineSync) {
      if (!userId) {
        throw permanentOfflineSyncError(
          'Offline submission discarded because its owner could not be verified.',
          'OFFLINE_SYNC_OWNER_MISMATCH',
        );
      }
      const body = assertPlainObject(req.body ?? {}, 'Offline submission');
      assertOnlyAllowedKeys(body, new Set(), 'Offline submission');
      assertOfflinePayloadSize(body);
      if (feature.collected_offline !== true) {
        throw permanentOfflineSyncError(
          'Offline submission parent record is no longer accessible.',
          'OFFLINE_SYNC_PARENT_INACCESSIBLE',
        );
      }
      const { idempotencyKeyHash } = assertOfflineRequestBinding({
        req,
        projectId: feature.project_id,
        userId,
      });
      const ownership = await client.query(
        `SELECT 1
         FROM spatial_feature
         WHERE id = $1 AND collected_by_user_id = $2`,
        [featureId, userId],
      );
      if (ownership.rows.length === 0) {
        throw permanentOfflineSyncError(
          'Offline submission discarded because it belongs to another account.',
          'OFFLINE_SYNC_OWNER_MISMATCH',
        );
      }
      await assertCurrentOfflineAuthorization({
        executor: client,
        userId,
        projectId: feature.project_id,
      });

      const payloadHash = sha256Json({
        feature_id: featureId,
        project_id: feature.project_id,
        operation: 'submit',
      });
      const receipt = await getOfflineReceipt({
        executor: client,
        userId,
        projectId: feature.project_id,
        operation: 'submit',
        idempotencyKeyHash,
      });
      if (receipt) {
        assertMatchingOfflineReceipt(receipt, payloadHash, [featureId]);
        return { alreadySubmitted: true, offline: true };
      }

      if (feature.status === 'pending_review') {
        await insertOfflineReceipt({
          executor: client,
          userId,
          projectId: feature.project_id,
          operation: 'submit',
          idempotencyKeyHash,
          payloadHash,
          entityIds: [featureId],
        });
        return { alreadySubmitted: true, offline: true };
      }
      if (feature.status !== 'draft') {
        throw permanentOfflineSyncError(
          'Offline submission parent record is no longer submittable.',
          'OFFLINE_SYNC_PARENT_INACCESSIBLE',
          409,
        );
      }

      const photoPolicyResult = await client.query(
        `SELECT p.requires_photos,
                p.min_photos,
                p.max_photos,
                (SELECT COUNT(*)::int FROM photo WHERE feature_id = $2) AS photo_count
         FROM project p
         WHERE p.id = $1`,
        [feature.project_id, featureId],
      );
      const photoPolicy = photoPolicyResult.rows[0];
      const photoCount = Number(photoPolicy?.photo_count);
      const minPhotos = Number(photoPolicy?.min_photos);
      const maxPhotos = Number(photoPolicy?.max_photos);
      if (
        !photoPolicy ||
        !Number.isSafeInteger(photoCount) ||
        !Number.isSafeInteger(minPhotos) ||
        !Number.isSafeInteger(maxPhotos)
      ) {
        throw new Error('Project attachment policy could not be evaluated.');
      }
      if (
        photoCount > maxPhotos ||
        (photoPolicy.requires_photos === true && photoCount < minPhotos)
      ) {
        throw permanentOfflineSyncError(
          'Offline submission does not meet the project attachment requirements.',
          'OFFLINE_SYNC_ATTACHMENT_REJECTED',
          422,
        );
      }

      await client.query(
        `UPDATE spatial_feature
         SET status = 'pending_review', submitted_at = NOW(), version = version + 1
         WHERE id = $1 AND status = 'draft'`,
        [featureId],
      );
      const adminUsers = await client.query(
        `SELECT id FROM "user" WHERE role = 'admin' AND is_active = TRUE`,
      );
      for (const admin of adminUsers.rows) {
        await client.query(
          `INSERT INTO notification (user_id, type, title, message, metadata)
           VALUES ($1, 'review_completed', 'Feature review pending', $2, $3)`,
          [
            admin.id,
            `A submitted feature in ${feature.project_name} is waiting for review.`,
            JSON.stringify({
              feature_id: featureId,
              project_id: feature.project_id,
              project_name: feature.project_name,
              status: 'pending_review',
            }),
          ],
        );
      }
      await insertOfflineReceipt({
        executor: client,
        userId,
        projectId: feature.project_id,
        operation: 'submit',
        idempotencyKeyHash,
        payloadHash,
        entityIds: [featureId],
      });
      await publishRealtimeChanges(
        [
          ...featureRealtimeInputs({
            projectId: feature.project_id,
            featureId,
            action: 'submitted',
            originSessionId: req.authSessionId,
            includeReviews: true,
          }),
          ...adminUsers.rows.map((admin) =>
            notificationRealtimeInput(admin.id, feature.project_id, req.authSessionId),
          ),
        ],
        client,
      );
      return { alreadySubmitted: false, offline: true };
    }

    if (feature.collected_offline === true) {
      const body = assertPlainObject(req.body ?? {}, 'Offline-origin submission');
      assertOnlyAllowedKeys(body, new Set(), 'Offline-origin submission');
      assertOfflinePayloadSize(body);
    }

    const owner = await client.query(
      `SELECT 1 FROM spatial_feature WHERE id = $1 AND collected_by_user_id = $2`,
      [featureId, req.user?.id],
    );
    if (owner.rows.length === 0) {
      throw new AppError('Feature not found', 404);
    }

    if (feature.collected_offline === true) {
      await assertCurrentOfflineOriginOnlineAuthorization({
        executor: client,
        projectId: feature.project_id,
        user: req.user as Express.UserContext,
      });
    } else {
      await assertCurrentCollectionAuthorization({
        executor: client,
        projectId: feature.project_id,
        user: req.user as Express.UserContext,
      });
    }

    if (feature.status === 'pending_review') {
      return { alreadySubmitted: true, offline: false };
    }

    if (feature.status !== 'draft') {
      throw new AppError('Only draft features can be submitted', 400);
    }

    if (feature.collected_offline === true) {
      const photoPolicyResult = await client.query(
        `SELECT p.requires_photos,
                p.min_photos,
                p.max_photos,
                (SELECT COUNT(*)::int FROM photo WHERE feature_id = $2) AS photo_count
         FROM project p
         WHERE p.id = $1`,
        [feature.project_id, featureId],
      );
      const photoPolicy = photoPolicyResult.rows[0];
      const photoCount = Number(photoPolicy?.photo_count);
      const minPhotos = Number(photoPolicy?.min_photos);
      const maxPhotos = Number(photoPolicy?.max_photos);
      if (
        !photoPolicy ||
        !Number.isSafeInteger(photoCount) ||
        !Number.isSafeInteger(minPhotos) ||
        !Number.isSafeInteger(maxPhotos)
      ) {
        throw new Error('Project attachment policy could not be evaluated.');
      }
      if (
        photoCount > maxPhotos ||
        (photoPolicy.requires_photos === true && photoCount < minPhotos)
      ) {
        throw new AppError('This feature does not meet the project attachment requirements.', 422);
      }
    }

    if (feature.collected_offline !== true) {
      await assertProjectAllowsCollectionMutations(feature.project_id);
    }

    await client.query(
      `UPDATE spatial_feature
       SET status = 'pending_review', submitted_at = NOW(), version = version + 1
       WHERE id = $1`,
      [featureId],
    );

    const adminUsers = await client.query(
      `SELECT id FROM "user" WHERE role = 'admin' AND is_active = TRUE`,
    );

    for (const admin of adminUsers.rows) {
      await client.query(
        `INSERT INTO notification (user_id, type, title, message, metadata)
         VALUES ($1, 'review_completed', 'Feature review pending',
                 $2, $3)`,
        [
          admin.id,
          `A submitted feature in ${feature.project_name} is waiting for review.`,
          JSON.stringify({
            feature_id: featureId,
            project_id: feature.project_id,
            project_name: feature.project_name,
            status: 'pending_review',
          }),
        ],
      );
    }
    await publishRealtimeChanges(
      [
        ...featureRealtimeInputs({
          projectId: feature.project_id,
          featureId,
          action: 'submitted',
          originSessionId: req.authSessionId,
          includeReviews: true,
        }),
        ...adminUsers.rows.map((admin) =>
          notificationRealtimeInput(admin.id, feature.project_id, req.authSessionId),
        ),
      ],
      client,
    );
    return { alreadySubmitted: false, offline: false };
  });

  logger.info(
    result.alreadySubmitted ? 'Feature submit replay confirmed:' : 'Feature submitted for review:',
    {
      featureId,
      userId: req.user?.id,
    },
  );

  res.json({
    success: true,
    message: result.alreadySubmitted
      ? 'Feature already submitted for review'
      : 'Feature submitted for review',
    data: {
      outcome: result.alreadySubmitted ? 'already_synchronized' : 'accepted',
    },
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
    [featureId],
  );

  if (featureCheck.rows.length === 0) {
    throw new AppError('Feature not found', 404);
  }

  if (!['pending_review', 'approved', 'rejected'].includes(featureCheck.rows[0].status)) {
    throw new AppError(
      'Only submitted or previously reviewed features can be reviewed through this action',
      400,
    );
  }

  const canReview = await hasProjectAdminAccess(
    featureCheck.rows[0].project_id,
    req.user as Express.UserContext,
  );
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
      [status, req.user?.id, review_notes, featureId],
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
      ],
    );
    await publishRealtimeChanges(
      [
        ...featureRealtimeInputs({
          projectId: featureCheck.rows[0].project_id,
          featureId,
          action: status,
          originSessionId: req.authSessionId,
          includeReviews: true,
        }),
        notificationRealtimeInput(
          featureCheck.rows[0].collected_by_user_id,
          featureCheck.rows[0].project_id,
          req.authSessionId,
        ),
      ],
      client,
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
  const limit = Math.min(
    Math.max(1, Number.parseInt(String(req.query.limit ?? '50'), 10) || 50),
    200,
  );

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
      await assertProjectReadable(projectId, req.user as Express.UserContext);
    }

    queryText += ` AND sf.project_id = $${paramIndex}`;
    params.push(projectId);
    paramIndex += 1;
  }

  if (req.user?.role !== 'admin' && !projectId) {
    const visibilityColumn = publicVisibilityColumnForRole(req.user?.role ?? 'viewer');
    queryText += `
      AND (
        EXISTS (
          SELECT 1
          FROM project p_access
          WHERE p_access.id = sf.project_id
            AND p_access.${visibilityColumn} = TRUE
            AND p_access.status::text = ANY($${paramIndex}::text[])
        )
        OR EXISTS (
          SELECT 1 FROM project_assignment pa
          WHERE pa.project_id = sf.project_id
            AND pa.user_id = $${paramIndex + 1}
            AND pa.status = 'approved'
        )
      )
    `;
    params.push(publicVisibleStatuses, req.user?.id);
    paramIndex += 2;
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
  const requestedStatus = req.query.status ? String(req.query.status) : null;
  const status = req.user?.role === 'viewer' ? 'approved' : requestedStatus;
  const zoom = normalizeMapZoom(req.query.zoom, 11);
  const simplifyTolerance = mapSimplifyTolerance(zoom);
  const { page, limit, offset } = getBboxPagination(req.query.page, req.query.limit);
  let projectReadScope: ProjectReadScope | undefined;

  if (
    !Number.isFinite(minLon) ||
    !Number.isFinite(minLat) ||
    !Number.isFinite(maxLon) ||
    !Number.isFinite(maxLat)
  ) {
    throw new AppError('Bounding box coordinates must be valid numbers', 400);
  }

  if (minLon >= maxLon || minLat >= maxLat) {
    throw new AppError('Invalid BBOX boundaries: min values must be less than max values', 400);
  }

  if (projectId) {
    if (req.user?.role !== 'admin') {
      projectReadScope = await assertProjectReadable(projectId, req.user as Express.UserContext);
    }
  }

  const whereClauses: string[] = ['sf.geom && ST_MakeEnvelope($1, $2, $3, $4, 4326)'];
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
    paramIndex = projectId
      ? appendProjectReadVisibility(
          whereClauses,
          params,
          paramIndex,
          req.user as Express.UserContext,
          projectReadScope,
        )
      : appendGlobalReadVisibility(
          whereClauses,
          params,
          paramIndex,
          req.user as Express.UserContext,
        );
  }

  const whereSql = whereClauses.join(' AND ');
  const geometrySql = mapRenderGeometrySql('sf.geom', zoom, simplifyTolerance);

  const dataSql = `
    SELECT sf.id,
           sf.project_id,
           sf.status,
           sf.attributes,
           GeometryType(sf.geom) AS source_geometry_type,
           sf.collected_at,
           sf.submitted_at,
           sf.reviewed_at,
           sf.review_notes,
           sf.version,
           COALESCE(collector.full_name, collector.masked_contributor_label, 'Former contributor') AS collected_by,
           COALESCE(reviewer.full_name, reviewer.masked_contributor_label, 'Former reviewer') AS reviewed_by,
           (SELECT COUNT(*) FROM photo WHERE feature_id = sf.id) AS photo_count,
           ${geometrySql} AS geometry
    FROM spatial_feature sf
    LEFT JOIN "user" collector ON collector.id = sf.collected_by_user_id
    LEFT JOIN "user" reviewer ON reviewer.id = sf.reviewed_by_user_id
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
      attributes: sanitizeManagedFeatureAttributes(row.attributes),
      source_geometry_type: row.source_geometry_type,
      collected_at: row.collected_at,
      submitted_at: row.submitted_at,
      reviewed_at: row.reviewed_at,
      review_notes: row.review_notes,
      collected_by: row.collected_by,
      reviewed_by: row.reviewed_by,
      photo_count: Number(row.photo_count ?? 0),
      version: row.version,
      is_summary: true,
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

const findFeaturesTile = async (req: Request, res: Response): Promise<void> => {
  const projectId = String(req.query.project_id ?? '');
  const requestedStatus = req.query.status ? String(req.query.status) : null;
  const status = req.user?.role === 'viewer' ? 'approved' : requestedStatus;
  const featureType =
    typeof req.query.feature_type === 'string' ? req.query.feature_type.trim() : '';
  const zoom = normalizeMapZoom(req.query.zoom ?? req.params.z, 11);
  const simplifyTolerance = mapSimplifyTolerance(zoom);
  const bounds = getTileBounds(req.params.z, req.params.x, req.params.y);
  let projectReadScope: ProjectReadScope | undefined;

  if (req.user?.role !== 'admin') {
    projectReadScope = await assertProjectReadable(projectId, req.user as Express.UserContext);
  }

  const whereClauses: string[] = [
    'sf.geom && ST_MakeEnvelope($1, $2, $3, $4, 4326)',
    'sf.project_id = $5',
  ];
  const params: unknown[] = [bounds.minLon, bounds.minLat, bounds.maxLon, bounds.maxLat, projectId];
  let paramIndex = 6;

  if (status) {
    whereClauses.push(`sf.status = $${paramIndex}`);
    params.push(status);
    paramIndex += 1;
  }

  if (featureType) {
    whereClauses.push(`
      EXISTS (
        SELECT 1
        FROM jsonb_each_text(COALESCE(sf.attributes, '{}'::jsonb)) AS attr(key, value)
        WHERE LOWER(BTRIM(attr.value)) = LOWER($${paramIndex})
      )
    `);
    params.push(featureType);
    paramIndex += 1;
  }

  if (req.user?.role !== 'admin') {
    paramIndex = appendProjectReadVisibility(
      whereClauses,
      params,
      paramIndex,
      req.user as Express.UserContext,
      projectReadScope,
    );
  }

  const geometrySql = mapRenderGeometrySql('sf.geom', zoom, simplifyTolerance);
  const tileFeatureLimit = zoom < 10.5 ? MAP_TILE_LOW_ZOOM_LIMIT : MAP_TILE_HIGH_ZOOM_LIMIT;
  const lowZoom = zoom < 10.5;
  const lowZoomUnclusteredThreshold = 50;
  const result = lowZoom
    ? await query(
        `WITH visible AS (
           SELECT sf.id,
                  sf.project_id,
                  sf.status,
                  sf.attributes,
                  GeometryType(sf.geom) AS source_geometry_type,
                  sf.collected_at,
                  sf.submitted_at,
                  sf.reviewed_at,
                  sf.review_notes,
                  sf.version,
                  COALESCE(collector.full_name, collector.masked_contributor_label, 'Former contributor') AS collected_by,
                  COALESCE(reviewer.full_name, reviewer.masked_contributor_label, 'Former reviewer') AS reviewed_by,
                  (SELECT COUNT(*) FROM photo WHERE feature_id = sf.id) AS photo_count,
                  CASE
                    WHEN GeometryType(sf.geom) IN ('POLYGON', 'MULTIPOLYGON') THEN ST_PointOnSurface(sf.geom)
                    WHEN GeometryType(sf.geom) IN ('LINESTRING', 'MULTILINESTRING') THEN ST_Centroid(sf.geom)
                    ELSE sf.geom
                  END AS marker_geom
           FROM spatial_feature sf
           LEFT JOIN "user" collector ON collector.id = sf.collected_by_user_id
           LEFT JOIN "user" reviewer ON reviewer.id = sf.reviewed_by_user_id
           WHERE ${whereClauses.join(' AND ')}
         ),
         marker_filtered AS (
           SELECT *
           FROM visible
           WHERE marker_geom && ST_MakeEnvelope($1, $2, $3, $4, 4326)
         ),
         counted AS (
           SELECT *,
                  COUNT(*) OVER ()::int AS visible_marker_count
           FROM marker_filtered
         ),
         bucketed AS (
           SELECT *,
                  FLOOR(ST_Y(marker_geom) / $${paramIndex})::int AS lat_bucket,
                  FLOOR(ST_X(marker_geom) / $${paramIndex})::int AS lon_bucket,
                  CASE
                    WHEN visible_marker_count <= $${paramIndex + 1} THEN id::text
                    ELSE CONCAT('bucket:', status, ':',
                      FLOOR(ST_Y(marker_geom) / $${paramIndex})::int::text, ':',
                      FLOOR(ST_X(marker_geom) / $${paramIndex})::int::text
                    )
                  END AS grouping_key
            FROM counted
         )
         SELECT CASE
                  WHEN COUNT(*) = 1 THEN (ARRAY_AGG(id::text ORDER BY collected_at DESC NULLS LAST, id ASC))[1]
                  ELSE CONCAT('project-cluster:', status, ':', lat_bucket::text, ':', lon_bucket::text)
                END AS id,
                MIN(project_id::text) AS project_id,
                status,
                CASE
                  WHEN COUNT(*) = 1 THEN (ARRAY_AGG(attributes ORDER BY collected_at DESC NULLS LAST, id ASC))[1]
                  ELSE jsonb_build_object('cluster_count', COUNT(*))
                END AS attributes,
                CASE
                  WHEN COUNT(DISTINCT source_geometry_type) = 1 THEN MIN(source_geometry_type)
                  ELSE 'Geometry'
                END AS source_geometry_type,
                MIN(collected_at) AS collected_at,
                MAX(submitted_at) AS submitted_at,
                MAX(reviewed_at) AS reviewed_at,
                CASE
                  WHEN COUNT(*) = 1 THEN (ARRAY_AGG(review_notes ORDER BY collected_at DESC NULLS LAST, id ASC))[1]
                  ELSE NULL
                END AS review_notes,
                NULL::int AS version,
                CASE
                  WHEN COUNT(*) = 1 THEN (ARRAY_AGG(collected_by ORDER BY collected_at DESC NULLS LAST, id ASC))[1]
                  ELSE NULL
                END AS collected_by,
                CASE
                  WHEN COUNT(*) = 1 THEN (ARRAY_AGG(reviewed_by ORDER BY collected_at DESC NULLS LAST, id ASC))[1]
                  ELSE NULL
                END AS reviewed_by,
                SUM(photo_count)::int AS photo_count,
                ST_AsGeoJSON(ST_Centroid(ST_Collect(marker_geom))) AS geometry,
                (COUNT(*) > 1) AS is_aggregate,
                COUNT(*)::int AS cluster_count
         FROM bucketed
         GROUP BY status, lat_bucket, lon_bucket, grouping_key
         ORDER BY MIN(collected_at) DESC NULLS LAST
         LIMIT $${paramIndex + 2}`,
        [...params, mapClusterCellSizeDegrees(zoom), lowZoomUnclusteredThreshold, tileFeatureLimit],
      )
    : await query(
        `SELECT sf.id,
                sf.project_id,
                sf.status,
                sf.attributes,
                GeometryType(sf.geom) AS source_geometry_type,
                sf.collected_at,
                sf.submitted_at,
                sf.reviewed_at,
                sf.review_notes,
                sf.version,
                COALESCE(collector.full_name, collector.masked_contributor_label, 'Former contributor') AS collected_by,
                COALESCE(reviewer.full_name, reviewer.masked_contributor_label, 'Former reviewer') AS reviewed_by,
                (SELECT COUNT(*) FROM photo WHERE feature_id = sf.id) AS photo_count,
                ${geometrySql} AS geometry,
                false AS is_aggregate,
                1 AS cluster_count
         FROM spatial_feature sf
         LEFT JOIN "user" collector ON collector.id = sf.collected_by_user_id
         LEFT JOIN "user" reviewer ON reviewer.id = sf.reviewed_by_user_id
         WHERE ${whereClauses.join(' AND ')}
         ORDER BY sf.collected_at DESC
         LIMIT $${paramIndex}`,
        [...params, tileFeatureLimit],
      );

  const features = result.rows.map((row: any) => ({
    type: 'Feature',
    id: row.id,
    geometry: JSON.parse(row.geometry),
    properties: {
      project_id: row.project_id,
      status: row.status,
      attributes: sanitizeManagedFeatureAttributes(row.attributes),
      source_geometry_type: row.source_geometry_type,
      collected_at: row.collected_at,
      submitted_at: row.submitted_at,
      reviewed_at: row.reviewed_at,
      review_notes: row.review_notes,
      collected_by: row.collected_by,
      reviewed_by: row.reviewed_by,
      photo_count: Number(row.photo_count ?? 0),
      version: row.version,
      is_summary: true,
      is_aggregate: row.is_aggregate ?? false,
      cluster_count: Number(row.cluster_count ?? 1),
    },
  }));

  res.json({
    success: true,
    data: {
      type: 'FeatureCollection',
      bbox: [bounds.minLon, bounds.minLat, bounds.maxLon, bounds.maxLat],
      features,
    },
  });
};

const batchCreateFeatures = async (req: Request, res: Response): Promise<void> => {
  const { features } = req.body;

  if (!Array.isArray(features) || features.length === 0) {
    throw offlinePayloadRejected('Offline feature batch is required.');
  }

  if (features.length > 100) {
    throw offlinePayloadRejected('Offline feature batch cannot exceed 100 features.');
  }

  const userId = req.user?.id;
  if (!userId) {
    throw permanentOfflineSyncError(
      'Offline submission discarded because its owner could not be verified.',
      'OFFLINE_SYNC_OWNER_MISMATCH',
    );
  }
  const envelope = assertPlainObject(req.body, 'Offline batch');
  assertOnlyAllowedKeys(envelope, new Set(['features']), 'Offline batch');
  assertOfflinePayloadSize(envelope);

  const allowedFeatureKeys = new Set([
    'id',
    'client_offline_id',
    'offline_owner_user_id',
    'project_id',
    'geom',
    'attributes',
    'accuracy_meters',
    'collected_offline',
  ]);
  for (const feature of features) {
    const featureObject = assertPlainObject(feature, 'Offline batch feature');
    assertOnlyAllowedKeys(featureObject, allowedFeatureKeys, 'Offline batch feature');
    if (
      featureObject.collected_offline !== true ||
      typeof featureObject.id !== 'string' ||
      !UUID_PATTERN.test(featureObject.id)
    ) {
      throw offlinePayloadRejected('Every offline batch feature requires a stable feature ID.');
    }
    if (
      featureObject.client_offline_id !== undefined &&
      featureObject.client_offline_id !== featureObject.id
    ) {
      throw offlinePayloadRejected('Offline batch feature identifiers do not match.');
    }
    if (
      typeof featureObject.offline_owner_user_id !== 'string' ||
      featureObject.offline_owner_user_id !== userId
    ) {
      throw permanentOfflineSyncError(
        'Offline submission discarded because it belongs to another account.',
        'OFFLINE_SYNC_OWNER_MISMATCH',
      );
    }
  }

  const projectIds = [...new Set(features.map((feature: any) => feature.project_id))];
  if (projectIds.length !== 1 || typeof projectIds[0] !== 'string') {
    throw permanentOfflineSyncError(
      'Offline submission discarded because its project does not match.',
      'OFFLINE_SYNC_PROJECT_MISMATCH',
    );
  }
  const projectId = projectIds[0];
  const { idempotencyKeyHash } = assertOfflineRequestBinding({ req, projectId, userId });
  const receiptFeatures = features.map((feature: any) => ({
    id: feature.id,
    project_id: projectId,
    geom: validateGeoJsonGeometry(feature.geom, { strictOffline: true }),
    attributes: normalizeOfflineAttributesForReceipt(feature.attributes),
    accuracy_meters: normalizeOfflineAccuracyForReceipt(feature.accuracy_meters),
  }));
  const entityIds = receiptFeatures.map((feature) => feature.id);
  if (new Set(entityIds).size !== entityIds.length) {
    throw offlinePayloadRejected('Offline feature batch contains duplicate identifiers.');
  }
  const payloadHash = sha256Json(receiptFeatures);

  const outcome = await transaction(async (client: QueryExecutor) => {
    await assertCurrentOfflineAuthorization({ executor: client, userId, projectId });
    await lockOfflineFeatureIds(client, entityIds);
    const receipt = await getOfflineReceipt({
      executor: client,
      userId,
      projectId,
      operation: 'batch_create',
      idempotencyKeyHash,
    });
    if (receipt) {
      assertMatchingOfflineReceipt(receipt, payloadHash, entityIds);
      const replay = await client.query(
        `SELECT id, status, version, collected_at
         FROM spatial_feature
         WHERE project_id = $1
           AND collected_by_user_id = $2
           AND id = ANY($3::uuid[])
         ORDER BY array_position($3::uuid[], id)`,
        [projectId, userId, entityIds],
      );
      if (replay.rows.length !== entityIds.length) {
        throw permanentOfflineSyncError(
          'Offline submission parent record is no longer accessible.',
          'OFFLINE_SYNC_PARENT_INACCESSIBLE',
        );
      }
      return { rows: replay.rows, alreadySynchronized: true };
    }

    const formSchema = await getProjectFormSchema(projectId, client);
    const normalizedFeatures: Array<{
      id: string;
      project_id: string;
      geom: GeoJsonGeometry;
      attributes: Record<string, unknown>;
      accuracy_meters: number | null;
    }> = [];

    for (const feature of features) {
      const normalizedGeometry = validateGeoJsonGeometry(feature.geom, { strictOffline: true });
      const normalizedAttributes = validateAttributesAgainstSchema(feature.attributes, formSchema, {
        strictOffline: true,
      });
      const normalizedAccuracy = assertOfflineCollectionConstraints({
        schema: formSchema,
        geometry: normalizedGeometry,
        accuracyMeters: feature.accuracy_meters,
      });
      await assertGeometryAcceptedByPostgis(client, normalizedGeometry);
      normalizedFeatures.push({
        id: feature.id,
        project_id: projectId,
        geom: normalizedGeometry,
        attributes: normalizedAttributes,
        accuracy_meters: normalizedAccuracy,
      });
    }

    const collision = await client.query(
      `SELECT id FROM spatial_feature WHERE id = ANY($1::uuid[]) LIMIT 1 FOR UPDATE`,
      [entityIds],
    );
    if (collision.rows[0]) {
      throw permanentOfflineSyncError(
        'Offline submission identifiers or idempotency data do not match.',
        'OFFLINE_SYNC_IDEMPOTENCY_MISMATCH',
        409,
      );
    }

    const results: any[] = [];
    for (const feature of normalizedFeatures) {
      const inserted = await client.query(
        `INSERT INTO spatial_feature (
          id, project_id, collected_by_user_id, geom, attributes,
          accuracy_meters, collected_offline, status
        ) VALUES (
          $1::uuid,
          $2,
          $3,
          ST_SetSRID(ST_GeomFromGeoJSON($4), 4326),
          $5,
          $6,
          TRUE,
          'draft'
        )
        RETURNING id, status, version, collected_at`,
        [
          feature.id,
          projectId,
          userId,
          JSON.stringify(feature.geom),
          JSON.stringify(feature.attributes),
          feature.accuracy_meters,
        ],
      );
      results.push(inserted.rows[0]);
    }
    await insertOfflineReceipt({
      executor: client,
      userId,
      projectId,
      operation: 'batch_create',
      idempotencyKeyHash,
      payloadHash,
      entityIds,
    });
    await publishRealtimeChanges(
      featureRealtimeInputs({
        projectId,
        action: 'bulk_created',
        originSessionId: req.authSessionId,
      }),
      client,
    );
    return { rows: results, alreadySynchronized: false };
  });

  logger.info(
    outcome.alreadySynchronized
      ? 'Offline feature batch replay confirmed:'
      : 'Offline feature batch created:',
    {
      count: outcome.rows.length,
      projectId,
      userId,
    },
  );
  res.status(outcome.alreadySynchronized ? 200 : 201).json({
    success: true,
    message: outcome.alreadySynchronized
      ? `${outcome.rows.length} features already synchronized`
      : `${outcome.rows.length} features created successfully`,
    data: outcome.rows,
    outcome: outcome.alreadySynchronized ? 'already_synchronized' : 'accepted',
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
  findFeaturesTile,
  batchCreateFeatures,
};

export {};
