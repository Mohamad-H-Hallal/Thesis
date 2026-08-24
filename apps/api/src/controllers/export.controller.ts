const { query, transaction } = require('../config/database');
const { AppError } = require('../middleware/error');
const logger = require('../utils/logger');
const fs = require('fs').promises;
const path = require('path');
const AdmZip = require('adm-zip');
import { sanitizeManagedFeatureAttributes } from '../lib/featureAttributes';
import { isProtectedSuperAdminEmail } from '../lib/userWorkflow';
import { resolveStoredPhotoPath } from '../services/featurePhotoSecurity.service';
import { storageAdapter } from '../services/storageAdapter.service';
import { enqueueWorkloadJob } from '../services/workloadQueue.service';
import { publishRealtimeChanges } from '../realtime/realtimeEvents';
import type { RealtimePublishInput } from '../realtime/realtimeProtocol';

// For shapefile generation
const shpwrite = require('@mapbox/shp-write');

// Export directory
const EXPORT_DIR = process.env.EXPORT_DIR ?? './exports';
const RETENTION_DAYS = Number.parseInt(process.env.EXPORT_RETENTION_DAYS ?? '7', 10);
const EXPORT_FILE_EXPIRED_MESSAGE =
  'This export completed successfully, but the download file was removed after the retention period to save storage. Regenerate the export to download it again.';

const exportRealtimeInputs = ({
  exportId,
  projectId,
  requestedByUserId,
  action,
  originSessionId,
  notificationChanged = false,
}: {
  exportId: string;
  projectId: string;
  requestedByUserId: string;
  action: string;
  originSessionId?: string | null;
  notificationChanged?: boolean;
}): RealtimePublishInput[] => [
  {
    scopeType: 'export',
    scopeId: exportId,
    action,
    entityType: 'export',
    entityId: exportId,
    projectId,
    originSessionId,
    audience: { kind: 'scope_subscribers' },
  },
  {
    scopeType: 'exports',
    scopeId: requestedByUserId,
    action,
    entityType: 'export',
    entityId: exportId,
    projectId,
    originSessionId,
    audience: { kind: 'user', userId: requestedByUserId },
  },
  {
    scopeType: 'exports',
    scopeId: 'all',
    action,
    entityType: 'export',
    entityId: exportId,
    projectId,
    originSessionId,
    audience: { kind: 'admins' },
  },
  ...(notificationChanged
    ? [
        {
          scopeType: 'notifications',
          scopeId: requestedByUserId,
          action: 'created',
          entityType: 'notification',
          entityId: exportId,
          projectId,
          originSessionId,
          audience: { kind: 'user' as const, userId: requestedByUserId },
        },
      ]
    : []),
];

// Ensure export directory exists
const ensureExportDir = async () => {
  try {
    await fs.mkdir(EXPORT_DIR, { recursive: true });
  } catch (error: unknown) {
    logger.error('Error creating export directory:', error);
  }
};

const normalizeOptionalString = (value: unknown) => {
  if (value === null || value === undefined) {
    return undefined;
  }
  const normalized = String(value).trim();
  return normalized.length === 0 ? undefined : normalized;
};

const exportLifecycleFields = `
  se.status AS job_status,
  se.file_status,
  CASE
    WHEN se.status = 'completed' AND se.file_status IN ('expired', 'deleted') THEN 'expired'
    ELSE se.status::text
  END AS display_status,
  CASE
    WHEN se.status = 'completed'
      AND se.file_status = 'available'
      AND se.file_path IS NOT NULL
    THEN TRUE
    ELSE FALSE
  END AS is_downloadable,
  CASE
    WHEN se.status = 'completed' AND se.file_status IN ('expired', 'deleted')
    THEN '${EXPORT_FILE_EXPIRED_MESSAGE.replace(/'/g, "''")}'
    ELSE se.error_message
  END AS display_message,
  CASE
    WHEN se.status = 'failed' OR (
      se.status = 'completed' AND se.file_status IN ('expired', 'deleted')
    )
    THEN TRUE
    ELSE FALSE
  END AS can_regenerate
`;

const markExportFileExpired = async (exportId: string, fileDeletedAt = new Date()) => {
  await transaction(async (client) => {
    const result = await client.query(
      `UPDATE shapefile_export
       SET file_status = 'expired',
           file_path = NULL,
           file_deleted_at = COALESCE(file_deleted_at, $2),
           retention_expired_at = COALESCE(retention_expired_at, $2),
           retention_expires_at = COALESCE(retention_expires_at, $2),
           error_message = $3
       WHERE id = $1
         AND status = 'completed'
       RETURNING requested_by_user_id, project_id`,
      [exportId, fileDeletedAt, 'Export completed, but the file expired. Regenerate it to download again.'],
    );
    if (result.rowCount === 1) {
      await publishRealtimeChanges(
        exportRealtimeInputs({
          exportId,
          projectId: result.rows[0].project_id,
          requestedByUserId: result.rows[0].requested_by_user_id,
          action: 'expired',
        }),
        client,
      );
    }
  });
};

const parseBbox = (value: unknown) => {
  if (value === null || value === undefined) {
    return undefined;
  }

  const parts = Array.isArray(value) ? value : String(value).split(',');
  if (parts.length !== 4) {
    return undefined;
  }

  const numbers = parts.map((item) => Number.parseFloat(String(item).trim()));
  if (numbers.some((item) => Number.isNaN(item))) {
    return undefined;
  }

  const [minLon, minLat, maxLon, maxLat] = numbers;
  if (!(minLon < maxLon && minLat < maxLat)) {
    return undefined;
  }

  return {
    minLon,
    minLat,
    maxLon,
    maxLat,
  };
};

const sanitizeZipSegment = (value: unknown) =>
  String(value ?? 'file')
    .trim()
    .replace(/[^a-zA-Z0-9._-]/g, '_')
    .slice(0, 120) || 'file';

const LEBANON_TIME_ZONE = 'Asia/Beirut';

const lebanonDateTimeFormatter = new Intl.DateTimeFormat('en-CA', {
  timeZone: LEBANON_TIME_ZONE,
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  hourCycle: 'h23',
  timeZoneName: 'shortOffset',
});

const formatLebanonDateTime = (value: unknown): string | null => {
  if (!value) {
    return null;
  }
  const date = value instanceof Date ? value : new Date(String(value));
  if (Number.isNaN(date.getTime())) {
    return null;
  }
  const parts = Object.fromEntries(
    lebanonDateTimeFormatter.formatToParts(date).map((part) => [part.type, part.value]),
  );
  return `${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute} ${parts.timeZoneName} (${LEBANON_TIME_ZONE})`;
};

const formatLebanonDate = (value: unknown): string =>
  formatLebanonDateTime(value)?.slice(0, 10) ?? '';

const parsePolygonFilter = (value: unknown) => {
  if (value === null || value === undefined) {
    return undefined;
  }
  let parsed;
  try {
    parsed = typeof value === 'string' ? JSON.parse(value) : value;
  } catch (_error) {
    throw new AppError('export_polygon must be a valid GeoJSON Polygon.', 400);
  }
  if (
    !parsed ||
    typeof parsed !== 'object' ||
    parsed.type !== 'Polygon' ||
    !Array.isArray(parsed.coordinates)
  ) {
    throw new AppError('export_polygon must be a GeoJSON Polygon in EPSG:4326.', 400);
  }
  return parsed;
};

const normalizeFeatureType = (value: unknown) => {
  const normalized = normalizeOptionalString(value);
  return normalized && normalized.toLowerCase() !== 'all' ? normalized : undefined;
};

const normalizeBooleanFlag = (value: unknown): boolean =>
  value === true || value === 'true' || value === 1 || value === '1';

const isProtectedSuperAdminUser = (user: any): boolean =>
  user?.role === 'admin' && isProtectedSuperAdminEmail(user?.email);

const appendExportFilters = ({ sql, params, paramIndex, filters, tableAlias = 'sf' }) => {
  let queryText = sql;
  let nextParamIndex = paramIndex;
  if (filters.status_filter && filters.status_filter.length > 0) {
    queryText += ` AND ${tableAlias}.status = ANY($${nextParamIndex}::feature_status[])`;
    params.push(filters.status_filter);
    nextParamIndex++;
  }
  if (filters.date_from) {
    queryText += ` AND ${tableAlias}.collected_at >= ($${nextParamIndex}::date)`;
    params.push(filters.date_from);
    nextParamIndex++;
  }
  if (filters.date_to) {
    queryText += ` AND ${tableAlias}.collected_at < (($${nextParamIndex}::date) + INTERVAL '1 day')`;
    params.push(filters.date_to);
    nextParamIndex++;
  }
  if (filters.bbox) {
    queryText += `
      AND ST_Intersects(
        ${tableAlias}.geom,
        ST_MakeEnvelope($${nextParamIndex}, $${nextParamIndex + 1}, $${nextParamIndex + 2}, $${nextParamIndex + 3}, 4326)
      )`;
    params.push(filters.bbox.minLon, filters.bbox.minLat, filters.bbox.maxLon, filters.bbox.maxLat);
    nextParamIndex += 4;
  }
  if (filters.export_polygon) {
    queryText += `
      AND ST_Intersects(
        ${tableAlias}.geom,
        ST_SetSRID(ST_GeomFromGeoJSON($${nextParamIndex}), 4326)
      )`;
    params.push(JSON.stringify(filters.export_polygon));
    nextParamIndex++;
  }
  if (filters.feature_type) {
    queryText += ` AND LOWER(BTRIM(COALESCE(${tableAlias}.attributes->>'feature_type', ${tableAlias}.attributes->>'type', ${tableAlias}.attributes->>'class', ''))) = LOWER($${nextParamIndex})`;
    params.push(filters.feature_type);
    nextParamIndex++;
  }
  if (filters.collector_user_id) {
    queryText += ` AND ${tableAlias}.collected_by_user_id = $${nextParamIndex}::uuid`;
    params.push(filters.collector_user_id);
    nextParamIndex++;
  }
  if (filters.geometry_types && filters.geometry_types.length > 0) {
    const geomTypes = filters.geometry_types.map((t) => `ST_${t}`);
    queryText += ` AND ST_GeometryType(${tableAlias}.geom) = ANY($${nextParamIndex}::text[])`;
    params.push(geomTypes);
    nextParamIndex++;
  }
  return { sql: queryText, paramIndex: nextParamIndex };
};

const appendAiPredictionExportFilters = ({ sql, params, paramIndex, filters }) => {
  let queryText = sql;
  let nextParamIndex = paramIndex;
  if (filters.bbox) {
    queryText += `
      AND ST_Intersects(
        p.geom,
        ST_MakeEnvelope($${nextParamIndex}, $${nextParamIndex + 1}, $${nextParamIndex + 2}, $${nextParamIndex + 3}, 4326)
      )`;
    params.push(filters.bbox.minLon, filters.bbox.minLat, filters.bbox.maxLon, filters.bbox.maxLat);
    nextParamIndex += 4;
  }
  if (filters.export_polygon) {
    queryText += `
      AND ST_Intersects(
        p.geom,
        ST_SetSRID(ST_GeomFromGeoJSON($${nextParamIndex}), 4326)
      )`;
    params.push(JSON.stringify(filters.export_polygon));
    nextParamIndex++;
  }
  if (filters.geometry_types && filters.geometry_types.length > 0) {
    const geomTypes = filters.geometry_types.map((t) => String(t).replace(/^ST_/i, ''));
    queryText += ` AND REPLACE(ST_GeometryType(COALESCE(p.processed_geom, p.geom)), 'ST_', '') = ANY($${nextParamIndex}::text[])`;
    params.push(geomTypes);
    nextParamIndex++;
  }
  return { sql: queryText, paramIndex: nextParamIndex };
};

const findPublishedAiLayerForExport = async (projectId: string) => {
  const result = await query(
    `SELECT l.id,
            l.ai_run_id,
            l.name,
            l.published_at,
            COUNT(p.id)::int AS prediction_count
     FROM ai_output_layer l
     JOIN ai_run ar ON ar.id = l.ai_run_id
     JOIN ai_project_settings aps ON aps.project_id = l.project_id
     LEFT JOIN ai_prediction_feature p ON p.ai_output_layer_id = l.id
     WHERE l.project_id = $1
       AND aps.is_enabled = true
       AND l.status = 'published'
       AND l.published_at IS NOT NULL
       AND l.layer_type = 'classification'
       AND ar.published_at IS NOT NULL
       AND ar.unpublished_at IS NULL
     GROUP BY l.id
     ORDER BY l.published_at DESC
     LIMIT 1`,
    [projectId],
  );
  return result.rows[0] ?? null;
};

const getPagination = (pageRaw: unknown, limitRaw: unknown) => {
  const page = Math.max(1, Number.parseInt(String(pageRaw ?? '1'), 10) || 1);
  const requestedLimit = Math.max(1, Number.parseInt(String(limitRaw ?? '20'), 10) || 20);
  const limit = Math.min(requestedLimit, 100);
  const offset = (page - 1) * limit;

  return { page, limit, offset };
};

// List only people who have approved contributions in this project.
const getProjectExportCollectors = async (req, res) => {
  const { projectId } = req.params;
  const result = await query(
    `SELECT sf.collected_by_user_id AS user_id,
            COALESCE(
              NULLIF(BTRIM(u.full_name), ''),
              NULLIF(BTRIM(u.masked_contributor_label), ''),
              'Former contributor'
            ) AS display_name,
            COUNT(*)::INT AS contribution_count
     FROM spatial_feature sf
     JOIN "user" u ON u.id = sf.collected_by_user_id
     WHERE sf.project_id = $1
       AND sf.status = 'approved'
     GROUP BY sf.collected_by_user_id, u.full_name, u.masked_contributor_label
     ORDER BY LOWER(COALESCE(
                NULLIF(BTRIM(u.full_name), ''),
                NULLIF(BTRIM(u.masked_contributor_label), ''),
                'Former contributor'
              )), sf.collected_by_user_id`,
    [projectId],
  );

  res.json({ success: true, data: result.rows });
};

// Request export for a project
const requestExport = async (req, res) => {
  const { projectId } = req.params;
  const {
    status_filter = ['approved'],
    date_from,
    date_to,
    bbox,
    export_polygon,
    feature_type,
    geometry_types,
    include_photos = true,
    coordinate_system = 'EPSG:4326',
    format = 'geojson', // Default to geojson
    category_id,
    collector_user_id,
    export_ai_predictions,
    regenerated_from_export_id,
  } = req.body;
  const useAiPredictions = normalizeBooleanFlag(export_ai_predictions);

  // Validate format
  const validFormats = ['shapefile', 'geojson'];
  if (!validFormats.includes(format)) {
    throw new AppError(`Invalid format. Must be one of: ${validFormats.join(', ')}`, 400);
  }

  if (useAiPredictions && !isProtectedSuperAdminUser(req.user)) {
    throw new AppError(
      'Only the protected super administrator can export AI prediction features.',
      403,
    );
  }

  // Validate project exists and user has access
  const projectCheck = await query('SELECT id, name, category_id FROM project WHERE id = $1', [
    projectId,
  ]);

  if (projectCheck.rows.length === 0) {
    throw new AppError('Project not found', 404);
  }

  const project = projectCheck.rows[0];
  const normalizedCategoryId = normalizeOptionalString(category_id);
  const regeneratedFromExportId = normalizeOptionalString(regenerated_from_export_id);
  if (normalizedCategoryId && project.category_id !== normalizedCategoryId) {
    throw new AppError('Selected project does not belong to the selected export category.', 400);
  }

  const normalizedDateFrom = normalizeOptionalString(date_from);
  const normalizedDateTo = normalizeOptionalString(date_to);
  const normalizedBbox = parseBbox(bbox);
  const normalizedPolygon = parsePolygonFilter(export_polygon);
  const normalizedFeatureType = normalizeFeatureType(feature_type);
  const normalizedCollectorUserId = normalizeOptionalString(collector_user_id);
  const publishedAiLayer = useAiPredictions ? await findPublishedAiLayerForExport(projectId) : null;
  if (useAiPredictions && !publishedAiLayer) {
    throw new AppError(
      'This project does not have a published AI prediction layer to export.',
      409,
    );
  }
  if (useAiPredictions && normalizedCollectorUserId) {
    throw new AppError('Collector filtering is only available for collected project data.', 400);
  }
  let selectedCollector: { display_name: string } | null = null;
  if (normalizedCollectorUserId) {
    const collectorResult = await query(
      `SELECT COALESCE(
                NULLIF(BTRIM(u.full_name), ''),
                NULLIF(BTRIM(u.masked_contributor_label), ''),
                'Former contributor'
              ) AS display_name
       FROM spatial_feature sf
       JOIN "user" u ON u.id = sf.collected_by_user_id
       WHERE sf.project_id = $1
         AND sf.collected_by_user_id = $2::uuid
         AND sf.status = 'approved'
       LIMIT 1`,
      [projectId, normalizedCollectorUserId],
    );
    selectedCollector = collectorResult.rows[0] ?? null;
    if (!selectedCollector) {
      throw new AppError(
        'The selected collector has no approved contributions in this project.',
        409,
      );
    }
  }

  // Build export parameters
  const exportParams = {
    source: useAiPredictions ? 'ai_predictions' : 'project_features',
    status_filter: Array.isArray(status_filter) ? status_filter : [status_filter],
    date_from: normalizedDateFrom,
    date_to: normalizedDateTo,
    bbox: normalizedBbox,
    export_polygon: normalizedPolygon,
    feature_type: useAiPredictions ? undefined : normalizedFeatureType,
    collector_user_id: useAiPredictions ? undefined : normalizedCollectorUserId,
    collector_display_name: selectedCollector?.display_name,
    geometry_types,
    include_photos: useAiPredictions ? false : include_photos,
    coordinate_system,
    format, // Store user's format preference
    category_id: normalizedCategoryId,
    ai_output_layer_id: publishedAiLayer?.id,
    ai_run_id: publishedAiLayer?.ai_run_id,
  };

  if (useAiPredictions) {
    let availabilityQuery = `
      SELECT COUNT(*)::int AS feature_count
      FROM ai_prediction_feature p
      WHERE p.project_id = $1
        AND p.ai_output_layer_id = $2
    `;
    const availabilityParams: unknown[] = [projectId, publishedAiLayer.id];
    const availabilityFilter = appendAiPredictionExportFilters({
      sql: availabilityQuery,
      params: availabilityParams,
      paramIndex: 3,
      filters: exportParams,
    });
    availabilityQuery = availabilityFilter.sql;
    const availabilityResult = await query(availabilityQuery, availabilityParams);
    const featureCount = availabilityResult.rows[0]?.feature_count ?? 0;
    if (featureCount <= 0) {
      throw new AppError(
        'No AI prediction features are available for the current published AI layer and selected area.',
        409,
      );
    }
  } else {
    let availabilityQuery = `
      SELECT COUNT(*)::int AS feature_count
      FROM spatial_feature sf
      WHERE sf.project_id = $1
    `;
    const availabilityParams: unknown[] = [projectId];
    let availabilityParamIndex = 2;

    const availabilityFilter = appendExportFilters({
      sql: availabilityQuery,
      params: availabilityParams,
      paramIndex: availabilityParamIndex,
      filters: exportParams,
    });
    availabilityQuery = availabilityFilter.sql;

    const availabilityResult = await query(availabilityQuery, availabilityParams);
    const featureCount = availabilityResult.rows[0]?.feature_count ?? 0;
    if (featureCount <= 0) {
      throw new AppError(
        'Exports can be requested after this project has at least one approved feature that matches the selected filters.',
        409,
      );
    }
  }

  // Create export request
  const result = await transaction(async (client) => {
    const inserted = await client.query(
      `INSERT INTO shapefile_export (
        project_id,
        requested_by_user_id,
        export_parameters,
        status,
        file_status,
        regenerated_from_export_id
      ) VALUES ($1, $2, $3, 'pending', 'missing', $4)
      RETURNING id, requested_at`,
      [projectId, req.user.id, JSON.stringify(exportParams), regeneratedFromExportId ?? null],
    );
    await enqueueWorkloadJob(client, {
      kind: 'project_export',
      entityId: inserted.rows[0].id,
      maxAttempts: Math.max(
        1,
        Number.parseInt(process.env.WORKLOAD_MAX_ATTEMPTS ?? '3', 10) || 3,
      ),
    });
    await publishRealtimeChanges(
      exportRealtimeInputs({
        exportId: inserted.rows[0].id,
        projectId,
        requestedByUserId: req.user.id,
        action: 'created',
        originSessionId: req.authSessionId,
      }),
      client,
    );
    return inserted;
  });

  const exportId = result.rows[0].id;

  logger.info('Export requested:', {
    exportId,
    projectId,
    userId: req.user.id,
    format,
    source: exportParams.source,
  });

  res.status(202).json({
    success: true,
    message: `Export request created (${format} format). Processing in background.`,
    data: {
      export_id: exportId,
      status: 'pending',
      format: format,
      requested_at: result.rows[0].requested_at,
    },
  });
};

// Process the export (background job)
const processExport = async (exportId, projectName) => {
  let workingExportPath: string | null = null;
  let workingZipPath: string | null = null;
  let publishedExportReference: string | null = null;
  try {
    // Update status to processing
    await transaction(async (client) => {
      const result = await client.query(
        `UPDATE shapefile_export
         SET status = 'processing',
             file_status = 'missing',
             file_deleted_at = NULL,
             retention_expired_at = NULL
         WHERE id = $1
         RETURNING requested_by_user_id, project_id`,
        [exportId],
      );
      if (result.rowCount === 1) {
        await publishRealtimeChanges(
          exportRealtimeInputs({
            exportId,
            projectId: result.rows[0].project_id,
            requestedByUserId: result.rows[0].requested_by_user_id,
            action: 'processing',
          }),
          client,
        );
      }
    });

    logger.info('Starting export processing:', { exportId });

    // Get export details
    const exportDetails = await query(
      `SELECT se.*, p.collection_form_schema
       FROM shapefile_export se
       JOIN project p ON se.project_id = p.id
       WHERE se.id = $1`,
      [exportId],
    );

    if (exportDetails.rows.length === 0) {
      throw new Error('Export request not found');
    }

    const exportData = exportDetails.rows[0];
    const params = exportData.export_parameters;
    const projectId = exportData.project_id;
    const format = params.format || 'geojson';
    const exportSource = params.source === 'ai_predictions' ? 'ai_predictions' : 'project_features';

    let featureQuery;
    let queryParams;
    if (exportSource === 'ai_predictions') {
      featureQuery = `
        SELECT
          p.id,
          ST_AsGeoJSON(COALESCE(p.processed_geom, p.geom)) as geojson_geometry,
          COALESCE(
            NULLIF(BTRIM(p.geometry_type), ''),
            REPLACE(ST_GeometryType(COALESCE(p.processed_geom, p.geom)), 'ST_', '')
          ) as geometry_type,
          '{}'::jsonb AS attributes,
          p.created_at AS collected_at,
          NULL::text AS collected_by,
          0::int AS photo_count,
          '[]'::json AS photos,
          p.artifact_feature_id,
          p.predicted_class,
          p.confidence,
          p.uncertainty_score,
          p.model_name,
          p.source,
          p.status,
          p.admin_validation_status,
          p.approved_class,
          p.ai_run_id,
          p.ai_output_layer_id,
          l.name AS layer_name,
          l.published_at,
          p.metadata,
          p.source_resolution_m,
          p.raw_area_m2,
          p.processed_area_m2,
          p.area_change_percent,
          p.processing_method,
          p.minimum_mapping_unit_m2,
          p.simplification_tolerance_m,
          p.smoothing_iterations,
          p.geometry_quality,
          'ai_predictions' AS export_source
        FROM ai_prediction_feature p
        JOIN ai_output_layer l ON l.id = p.ai_output_layer_id
        WHERE p.project_id = $1
          AND p.ai_output_layer_id = $2
      `;
      queryParams = [projectId, params.ai_output_layer_id];
      const featureFilter = appendAiPredictionExportFilters({
        sql: featureQuery,
        params: queryParams,
        paramIndex: 3,
        filters: params,
      });
      featureQuery = featureFilter.sql;
    } else {
      // Build query to get project map features.
      featureQuery = `
        SELECT
          sf.id,
          ST_AsGeoJSON(sf.geom) as geojson_geometry,
          ST_GeometryType(sf.geom) as geometry_type,
           sf.attributes,
           sf.source,
           sf.source_provenance,
           sf.collected_at,
          COALESCE(u.full_name, u.masked_contributor_label, 'Former contributor') as collected_by,
          COALESCE(photo_rollup.photo_count, 0)::int AS photo_count,
          COALESCE(photo_rollup.photos, '[]'::json) AS photos,
          'project_features' AS export_source
        FROM spatial_feature sf
        JOIN "user" u ON sf.collected_by_user_id = u.id
        LEFT JOIN LATERAL (
          SELECT
            COUNT(*)::int AS photo_count,
            json_agg(
              json_build_object(
                'id', ph.id,
                'feature_id', ph.feature_id,
                'file_path', ph.file_path,
                'thumbnail_path', ph.thumbnail_path,
                'status', ph.status,
                'display_order', ph.display_order,
                'taken_at', ph.taken_at,
                'uploaded_at', ph.uploaded_at,
                'file_size_bytes', ph.file_size_bytes
              )
              ORDER BY ph.display_order ASC, ph.uploaded_at ASC
            ) AS photos
          FROM photo ph
          WHERE ph.feature_id = sf.id
            AND ph.status <> 'rejected'
        ) photo_rollup ON TRUE
        WHERE sf.project_id = $1
      `;

      queryParams = [projectId];

      const featureFilter = appendExportFilters({
        sql: featureQuery,
        params: queryParams,
        paramIndex: 2,
        filters: params,
      });
      featureQuery = featureFilter.sql;
    }

    logger.info('Querying features:', { exportId, format, source: exportSource });

    const features = await query(featureQuery, queryParams);

    logger.info('Features found:', { exportId, count: features.rows.length, format });

    if (features.rows.length === 0) {
      throw new Error('No features found matching the export criteria');
    }

    // Create export directory for this request
    const exportTimestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const sourceSuffix = exportSource === 'ai_predictions' ? '_ai_predictions' : '';
    const exportName =
      `${projectName.replace(/[^a-zA-Z0-9]/g, '_')}` +
      `${sourceSuffix}_${exportTimestamp}_${exportId}`;
    const exportPath = path.join(EXPORT_DIR, exportId);
    workingExportPath = exportPath;
    await fs.mkdir(exportPath, { recursive: true });

    logger.info('Created export directory:', { exportId, path: exportPath });

    const photoManifest =
      params.include_photos && exportSource !== 'ai_predictions'
        ? await attachExportPhotos(exportPath, features.rows)
        : [];

    // Group features by geometry type
    const featuresByType: Record<string, any[]> = {};
    features.rows.forEach((feature: any) => {
      const type = feature.geometry_type.replace('ST_', '');
      if (!featuresByType[type]) {
        featuresByType[type] = [];
      }
      featuresByType[type].push(feature);
    });

    logger.info('Features grouped by type:', {
      exportId,
      types: Object.keys(featuresByType),
      format,
    });

    // Generate files based on format
    const generatedFiles: Array<{ name: string; type: string; count: number; format: string }> = [];

    if (format === 'shapefile') {
      // Generate shapefiles
      for (const [geomType, typeFeatures] of Object.entries(featuresByType)) {
        const fileName = `${exportName}_${geomType}`;

        try {
          await createShapefile(exportPath, fileName, typeFeatures, geomType);

          logger.info('Created shapefile:', { exportId, file: fileName });

          generatedFiles.push({
            name: `${fileName}.shp`,
            type: geomType,
            count: typeFeatures.length,
            format: 'shapefile',
          });
        } catch (error: any) {
          logger.error('Shapefile creation error:', { exportId, geomType, error });
          throw error;
        }
      }
    } else {
      // Generate GeoJSON files
      for (const [geomType, typeFeatures] of Object.entries(featuresByType)) {
        const fileName = `${exportName}_${geomType}`;
        const geojsonPath = path.join(exportPath, `${fileName}.geojson`);
        const geojson = createGeoJSON(typeFeatures, projectName, geomType);

        await fs.writeFile(geojsonPath, JSON.stringify(geojson, null, 2));

        logger.info('Created GeoJSON:', { exportId, file: `${fileName}.geojson` });

        generatedFiles.push({
          name: `${fileName}.geojson`,
          type: geomType,
          count: typeFeatures.length,
          format: 'geojson',
        });
      }
    }

    const sourceProvenance = Array.from(
      new Map(
        features.rows
          .map((feature: any) => feature.source_provenance)
          .filter(
            (item: unknown) =>
              item && typeof item === 'object' && !Array.isArray(item) && Object.keys(item).length > 0,
          )
          .map((item: unknown) => [JSON.stringify(item), item]),
      ).values(),
    );

    // Create metadata file
    const metadata = {
      project_name: projectName,
      source: exportSource,
      export_date: formatLebanonDateTime(new Date()),
      time_zone: LEBANON_TIME_ZONE,
      feature_count: features.rows.length,
      geometry_types: Object.keys(featuresByType),
      coordinate_system: params.coordinate_system,
      format: format,
      filters: {
        status: params.status_filter,
        date_from: params.date_from,
        date_to: params.date_to,
        bbox: params.bbox,
        export_polygon: params.export_polygon ? 'GeoJSON Polygon filter applied' : null,
        feature_type: params.feature_type,
        include_photos: params.include_photos === true && exportSource !== 'ai_predictions',
      },
      ai_output_layer_id: params.ai_output_layer_id ?? null,
      ai_run_id: params.ai_run_id ?? null,
      files: generatedFiles,
      photo_manifest: photoManifest.length > 0 ? 'photos_manifest.json' : null,
      source_provenance: sourceProvenance,
      important_notices: [
        'This export is not a cadastral record, land-title authority, professional legal survey, emergency-navigation product, or guarantee of GPS, imagery, source-data, or AI accuracy.',
        'Recipients must preserve required source attribution and comply with the recorded redistribution rules.',
      ],
      notes:
        exportSource === 'ai_predictions'
          ? 'AI-derived polygons are post-processed from satellite classification. Raw pixel geometry is retained for audit when available; default exports use processed polygons.'
          : format === 'shapefile'
            ? 'Shapefile format: Field names limited to 10 characters, strings to 254 characters (DBF limitations)'
            : 'GeoJSON format: Modern, web-friendly format compatible with all GIS software',
    };

    await fs.writeFile(path.join(exportPath, 'metadata.json'), JSON.stringify(metadata, null, 2));
    if (params.include_photos && exportSource !== 'ai_predictions') {
      await fs.writeFile(
        path.join(exportPath, 'photos_manifest.json'),
        JSON.stringify(photoManifest, null, 2),
      );
      await fs.writeFile(
        path.join(exportPath, 'photos_manifest.csv'),
        createPhotoManifestCsv(photoManifest),
      );
      await fs.writeFile(path.join(exportPath, 'README_PHOTOS.txt'), generatePhotoReadme(format));
    }

    logger.info('Created metadata:', { exportId });

    // Create README
    const readme = generateReadme(metadata, projectName, format);
    await fs.writeFile(path.join(exportPath, 'README.txt'), readme);

    logger.info('Created README:', { exportId });

    // Zip everything
    const zipPath = path.join(EXPORT_DIR, `${exportName}.zip`);
    workingZipPath = zipPath;
    await zipDirectory(exportPath, zipPath);

    const stagedZip = await storageAdapter.info(zipPath, ['exports']);
    publishedExportReference = storageAdapter.reference(
      'exports',
      `completed/${exportName}.zip`,
    );
    const publishedZip = await storageAdapter.copyVerified(
      stagedZip.reference,
      publishedExportReference,
      {
        size: stagedZip.size,
        sha256: stagedZip.sha256,
      },
    );
    const fileSizeBytes = publishedZip.destination.size;

    logger.info('Created and verified export package', { exportId });

    await transaction(async (client) => {
      await client.query(
        `UPDATE shapefile_export 
         SET status = 'completed',
             file_status = 'available',
             completed_at = CURRENT_TIMESTAMP,
             file_path = $1,
             feature_count = $2,
             file_size_bytes = $3,
             error_message = NULL,
             file_deleted_at = NULL,
             retention_expired_at = NULL,
             retention_expires_at = CURRENT_TIMESTAMP + ($4::int * INTERVAL '1 day')
         WHERE id = $5`,
        [
          publishedExportReference,
          features.rows.length,
          fileSizeBytes,
          RETENTION_DAYS,
          exportId,
        ],
      );

      await client.query(
        `INSERT INTO notification (user_id, type, title, message, metadata)
         VALUES ($1, 'export_ready', 'Export ready for download',
                 $2, $3)`,
        [
          exportData.requested_by_user_id,
          `${projectName} export (${format.toUpperCase()}) is ready for download.`,
          JSON.stringify({
            export_id: exportId,
            project_id: projectId,
            project_name: projectName,
            format: format,
            status: 'completed',
          }),
          ],
      );
      await publishRealtimeChanges(
        exportRealtimeInputs({
          exportId,
          projectId,
          requestedByUserId: exportData.requested_by_user_id,
          action: 'completed',
          notificationChanged: true,
        }),
        client,
      );
    });
    publishedExportReference = null;

    // Cleanup failures must not turn a committed, verified export into a failed job.
    await fs.rm(exportPath, { recursive: true, force: true }).catch((cleanupError) => {
      logger.warn('Committed export retained a temporary working directory', {
        exportId,
        errorCode: cleanupError?.code ?? 'UNKNOWN',
      });
    });
    workingExportPath = null;
    await storageAdapter.remove(zipPath).catch((cleanupError) => {
      logger.warn('Committed export retained a staged ZIP copy', {
        exportId,
        errorCode: cleanupError?.code ?? 'UNKNOWN',
      });
    });
    workingZipPath = null;

    logger.info('Export completed:', {
      exportId,
      featureCount: features.rows.length,
      fileSize: fileSizeBytes,
      format,
    });
  } catch (error: any) {
    logger.error('Export processing failed:', {
      exportId,
      error: error.message,
      stack: error.stack,
    });
    if (publishedExportReference) {
      await storageAdapter.remove(publishedExportReference).catch((cleanupError) => {
        logger.error('Failed to remove an uncommitted export package', {
          exportId,
          errorCode: cleanupError?.code ?? 'UNKNOWN',
        });
      });
    }
    if (workingZipPath) {
      await storageAdapter.remove(workingZipPath).catch(() => undefined);
    }
    if (workingExportPath) {
      await fs.rm(workingExportPath, { recursive: true, force: true }).catch(() => undefined);
    }

    throw error;
  }
};

// Create shapefile using shp-write
const createShapefile = async (outputDir, fileName, features, _geometryType) => {
  const geojsonFeatures = features.map((f) => {
    const geom = JSON.parse(f.geojson_geometry);
    if (f.export_source === 'ai_predictions') {
      const properties = {
        pred_id: String(f.id ?? '').substring(0, 10),
        art_id: String(f.artifact_feature_id ?? '').substring(0, 20),
        pred_cls: String(f.predicted_class ?? '').substring(0, 80),
        conf: typeof f.confidence === 'number' ? f.confidence : null,
        uncert: typeof f.uncertainty_score === 'number' ? f.uncertainty_score : null,
        model: String(f.model_name ?? '').substring(0, 80),
        status: String(f.status ?? '').substring(0, 32),
        val_stat: String(f.admin_validation_status ?? '').substring(0, 32),
        appr_cls: String(f.approved_class ?? '').substring(0, 80),
        run_id: String(f.ai_run_id ?? '').substring(0, 36),
        layer_id: String(f.ai_output_layer_id ?? '').substring(0, 36),
        res_m: typeof f.source_resolution_m === 'number' ? f.source_resolution_m : null,
        area_m2: typeof f.processed_area_m2 === 'number' ? f.processed_area_m2 : null,
        area_ha: typeof f.processed_area_m2 === 'number' ? f.processed_area_m2 / 10000 : null,
        geom_q: String(f.geometry_quality ?? '').substring(0, 32),
        proc: String(f.processing_method ?? '').substring(0, 80),
        source: 'ai_prediction',
      };
      return {
        type: 'Feature',
        geometry: geom,
        properties,
      };
    }

    const properties = {
      feat_id: f.id.substring(0, 10),
      collect_at: formatLebanonDate(f.collected_at),
      collect_by: f.collected_by ? f.collected_by.substring(0, 50) : '',
      photo_cnt: Number(f.photo_count ?? 0),
      photo_ref:
        Array.isArray(f.photo_paths) && f.photo_paths.length > 0
          ? String(f.photo_paths[0]).substring(0, 254)
          : '',
      src_kind: String(f.source ?? 'field').substring(0, 32),
      src_name: String(f.source_provenance?.dataset_name ?? '').substring(0, 80),
      src_attr: String(f.source_provenance?.attribution ?? '').substring(0, 254),
    };

    const sanitizedAttributes = sanitizeManagedFeatureAttributes(f.attributes);
    if (sanitizedAttributes) {
      Object.keys(sanitizedAttributes).forEach((key) => {
        const truncatedKey = key.substring(0, 10);
        if (Object.prototype.hasOwnProperty.call(properties, truncatedKey)) {
          return;
        }
        let value = sanitizedAttributes[key];

        if (typeof value === 'string') {
          properties[truncatedKey] = value.substring(0, 254);
        } else if (typeof value === 'number') {
          properties[truncatedKey] = value;
        } else if (typeof value === 'boolean') {
          properties[truncatedKey] = value ? 1 : 0;
        } else if (value != null) {
          properties[truncatedKey] = String(value).substring(0, 254);
        }
      });
    }

    return {
      type: 'Feature',
      geometry: geom,
      properties,
    };
  });

  const geojson = {
    type: 'FeatureCollection',
    features: geojsonFeatures,
  };

  try {
    const zipBuffer = await shpwrite.zip(geojson, {
      outputType: 'nodebuffer',
    });

    // Write temp ZIP
    const tempZip = path.join(outputDir, `${fileName}_temp.zip`);
    await fs.writeFile(tempZip, zipBuffer);

    // Extract shapefile components
    const zip = new AdmZip(tempZip);
    zip.extractAllTo(outputDir, true);

    // Clean up
    await fs.unlink(tempZip);

    logger.info('Shapefile created:', { fileName, size: zipBuffer.length });
  } catch (error: any) {
    logger.error('Shapefile error:', error);
    throw new Error(`Shapefile creation failed: ${error.message}`);
  }
};

// Create GeoJSON from features
const createGeoJSON = (features, projectName, geometryType) => {
  return {
    type: 'FeatureCollection',
    name: `${projectName} - ${geometryType}`,
    crs: {
      type: 'name',
      properties: {
        name: 'urn:ogc:def:crs:OGC:1.3:CRS84',
      },
    },
    features: features.map((f) => {
      const geom = JSON.parse(f.geojson_geometry);
      if (f.export_source === 'ai_predictions') {
        return {
          type: 'Feature',
          geometry: geom,
          properties: {
            prediction_feature_id: f.id,
            artifact_feature_id: f.artifact_feature_id,
            predicted_class: f.predicted_class,
            confidence: f.confidence,
            uncertainty_score: f.uncertainty_score,
            model_name: f.model_name,
            status: f.status,
            validation_status: f.admin_validation_status,
            approved_class: f.approved_class,
            ai_run_id: f.ai_run_id,
            ai_output_layer_id: f.ai_output_layer_id,
            layer_name: f.layer_name,
            published_at: formatLebanonDateTime(f.published_at),
            source_resolution_m: f.source_resolution_m,
            raw_area_m2: f.raw_area_m2,
            processed_area_m2: f.processed_area_m2,
            processed_area_ha:
              typeof f.processed_area_m2 === 'number' ? f.processed_area_m2 / 10000 : null,
            area_change_percent: f.area_change_percent,
            processing_method: f.processing_method,
            minimum_mapping_unit_m2: f.minimum_mapping_unit_m2,
            simplification_tolerance_m: f.simplification_tolerance_m,
            smoothing_iterations: f.smoothing_iterations,
            geometry_quality: f.geometry_quality,
            source: 'ai_prediction',
            note: 'AI-derived polygon, post-processed from satellite classification.',
          },
        };
      }
      return {
        type: 'Feature',
        geometry: geom,
        properties: {
          ...sanitizeManagedFeatureAttributes(f.attributes),
          feature_id: f.id,
          collected_at: formatLebanonDateTime(f.collected_at),
          collected_by: f.collected_by,
          photo_count: Number(f.photo_count ?? 0),
          primary_photo_path:
            Array.isArray(f.photo_paths) && f.photo_paths.length > 0 ? f.photo_paths[0] : null,
          photo_paths: Array.isArray(f.photo_paths) ? f.photo_paths : [],
          photo_manifest_ref: Number(f.photo_count ?? 0) > 0 ? 'photos_manifest.json' : null,
          source: f.source ?? 'field',
          source_provenance:
            f.source_provenance && typeof f.source_provenance === 'object'
              ? f.source_provenance
              : {},
        },
      };
    }),
  };
};

const normalizePhotoRows = (feature: any): any[] => {
  if (Array.isArray(feature.photos)) {
    return feature.photos;
  }
  return [];
};

const attachExportPhotos = async (exportPath: string, features: any[]) => {
  const manifest: any[] = [];
  for (const feature of features) {
    const photoRows = normalizePhotoRows(feature);
    const paths: string[] = [];
    for (const photo of photoRows) {
      const sourcePath = resolveStoredPhotoPath(photo.file_path);
      if (!sourcePath) {
        logger.warn('Skipping export photo outside managed storage', {
          featureId: feature.id,
          photoId: photo.id,
        });
        continue;
      }
      try {
        const source = await storageAdapter.locate(sourcePath, ['uploads']);
        const extension = path.extname(source.localPath).toLowerCase() || '.jpg';
        const fileName = `${sanitizeZipSegment(photo.id)}${extension}`;
        const relativePath = path.posix.join(
          'photos',
          sanitizeZipSegment(feature.id),
          fileName,
        );
        const destinationPath = path.join(
          exportPath,
          'photos',
          sanitizeZipSegment(feature.id),
          fileName,
        );
        await fs.mkdir(path.dirname(destinationPath), { recursive: true });
        await fs.copyFile(source.localPath, destinationPath);
        paths.push(relativePath);
        manifest.push({
          feature_id: feature.id,
          photo_id: photo.id,
          path: relativePath,
          display_order: photo.display_order,
          taken_at: formatLebanonDateTime(photo.taken_at),
          uploaded_at: formatLebanonDateTime(photo.uploaded_at),
          file_size_bytes: photo.file_size_bytes,
        });
      } catch (error: any) {
        logger.warn('Skipping export photo that could not be copied', {
          featureId: feature.id,
          photoId: photo.id,
          error: error.message,
        });
      }
    }
    feature.photo_paths = paths;
    feature.photo_count = paths.length;
  }
  return manifest;
};

const csvEscape = (value: unknown) => {
  const raw = String(value ?? '');
  return /[",\r\n]/.test(raw) ? `"${raw.replace(/"/g, '""')}"` : raw;
};

const createPhotoManifestCsv = (manifest: any[]) => {
  const headers = [
    'feature_id',
    'photo_id',
    'path',
    'display_order',
    'taken_at',
    'uploaded_at',
    'file_size_bytes',
  ];
  return [
    headers.join(','),
    ...manifest.map((row) => headers.map((header) => csvEscape(row[header])).join(',')),
  ].join('\n');
};

const generatePhotoReadme = (format: string) => `Exported Feature Photos
=======================

Photos are stored inside the photos/ folder using relative ZIP paths.

Photo linkage files:
- photos_manifest.json maps feature_id and photo_id to each exported photo path.
- photos_manifest.csv contains the same mapping in spreadsheet-friendly form.
- All timestamps are in Lebanon time (${LEBANON_TIME_ZONE}) and are converted only for exported/user-facing files.

GIS attributes:
${
  format === 'shapefile'
    ? '- Shapefile DBF attributes include photo_cnt and photo_ref. Use the manifest for full photo mapping.'
    : '- GeoJSON properties include photo_count, primary_photo_path, photo_paths, and photo_manifest_ref.'
}

The photo paths are relative to this extracted export package. In GIS software, inspect the attribute path or configure a hyperlink/action if you want one-click photo opening.
`;

// Generate README for export
const generateReadme = (metadata, projectName, format) => {
  const formatSpecificInfo =
    format === 'shapefile'
      ? `
Shapefile Components:
=====================
For each geometry type, you'll find 4 files:

1. .shp - Geometry data (shapes)
2. .dbf - Attribute data (feature properties)
3. .shx - Index file (links geometry to attributes)
4. .prj - Projection information

⚠️  ALL FOUR FILES ARE REQUIRED - Keep them together!

Shapefile Limitations:
- Field names: Maximum 10 characters (automatically truncated)
- Text fields: Maximum 254 characters
- Check metadata.json for full field names

How to Use Shapefiles:
======================
1. Open QGIS or ArcGIS
2. Add Data > Select the .shp file
3. All 4 files must be in the same folder
4. Features will display on the map
`
      : `
GeoJSON Format:
===============
Modern, web-friendly geospatial format.

Advantages:
- Single file (not 4 like shapefiles)
- No field name limitations
- No string length limitations
- Human-readable JSON format
- Works with web mapping libraries

How to Use GeoJSON:
===================
METHOD 1: Open in QGIS
1. Drag and drop .geojson file into QGIS
2. Features will display immediately

METHOD 2: Open in ArcGIS
1. Add Data > Select .geojson file
2. Features will display on the map

METHOD 3: Convert to Shapefile (if needed)
1. Open in QGIS
2. Right-click layer > Export > Save Features As...
3. Format: ESRI Shapefile
4. Click OK

METHOD 4: View Online
1. Go to http://geojson.io
2. Drag and drop .geojson file
3. View and edit in browser
`;

  return `Lebanese GIS Mobile Application - Data Export
=====================================

Project: ${projectName}
Export Date: ${metadata.export_date}
Time Zone: ${metadata.time_zone}
Total Features: ${metadata.feature_count}
Format: ${format.toUpperCase()}

Geometry Types:
${metadata.geometry_types.map((t) => `  - ${t}`).join('\n')}

Coordinate System: ${metadata.coordinate_system}

Filters Applied:
  - Status: ${metadata.filters.status.join(', ')}
  - Date From: ${metadata.filters.date_from || 'Not specified'}
  - Date To: ${metadata.filters.date_to || 'Not specified'}
  - BBOX: ${
    metadata.filters.bbox
      ? `${metadata.filters.bbox.minLon}, ${metadata.filters.bbox.minLat}, ${metadata.filters.bbox.maxLon}, ${metadata.filters.bbox.maxLat}`
      : 'Not specified'
  }

Files Included:
${metadata.files.map((f) => `  - ${f.name} (${f.count} features)`).join('\n')}

Source and Redistribution:
==========================
- metadata.json contains source_provenance records carried from governed GIS imports.
- Preserve every recorded attribution and follow the corresponding redistribution rules.
- Missing historical provenance is not proof that unrestricted reuse is allowed.

Important Notices:
==================
${metadata.important_notices.map((notice) => `- ${notice}`).join('\n')}

${formatSpecificInfo}

Format Information:
===================
You requested: ${format.toUpperCase()}

${
  format === 'shapefile'
    ? `
Shapefile is the traditional GIS format (1990s):
✓ Widely supported in all GIS software
✓ Industry standard
✗ Multiple files required
✗ Field name limitations (10 chars)
✗ String length limitations (254 chars)
`
    : `
GeoJSON is the modern web format (2016):
✓ Single file
✓ No field limitations
✓ Human-readable JSON
✓ Web-friendly
✓ Works in all modern GIS software
`
}

Attribute Information:
======================
${
  format === 'shapefile'
    ? `
DBF file contains feature attributes:
- feat_id: Feature identifier (truncated)
- collect_at: Collection date
- collect_by: Collector name (truncated to 50 chars)
- Plus all custom fields from your survey form (names truncated to 10 chars)

⚠️  Check metadata.json for full field names
`
    : `
GeoJSON contains all feature attributes:
- feature_id: Complete feature identifier
- collected_at: Full ISO timestamp
- collected_by: Complete collector name
- Plus all custom fields with full names (no truncation)
`
}

Technical Details:
==================
- Format: ${format === 'shapefile' ? 'ESRI Shapefile' : 'GeoJSON (RFC 7946)'}
- Coordinate System: ${metadata.coordinate_system}
- Geometry Types: Separated by type (${metadata.geometry_types.join(', ')})
- Encoding: UTF-8

Common GIS Software:
====================
✓ QGIS (free, open source): https://qgis.org
✓ ArcGIS Pro
✓ ArcGIS Desktop
✓ Google Earth Pro
✓ MapInfo
✓ GRASS GIS
✓ AutoCAD Map 3D

Web Mapping Libraries:
=======================
${
  format === 'geojson'
    ? `
✓ Leaflet
✓ Mapbox GL JS
✓ OpenLayers
✓ Google Maps API
✓ deck.gl
✓ Turf.js (for analysis)
`
    : `
For web use, convert to GeoJSON:
1. Open in QGIS
2. Export as GeoJSON
3. Use in web applications
`
}

Need Help?
==========
For questions or issues:
- Check metadata.json for export details
- Contact: Lebanese GIS Application Support
- Documentation: See project README

${
  format === 'shapefile'
    ? `
Common Shapefile Issues:
========================
Q: Why multiple .shp files?
A: Shapefiles can only contain one geometry type. Points, Lines, and 
   Polygons must be in separate files.

Q: Can I open just the .shp file?
A: No, you need ALL files (.shp, .dbf, .shx, .prj) in the same folder.

Q: Why are my field names truncated?
A: DBF format limits field names to 10 characters. Check metadata.json
   for full field names.

Q: How do I convert to GeoJSON?
A: Use QGIS: Right-click layer > Save As > GeoJSON
`
    : `
Common GeoJSON Questions:
=========================
Q: Can I open this in older GIS software?
A: Yes! QGIS, ArcGIS 10.1+, and most modern GIS software support GeoJSON.

Q: How do I convert to Shapefile?
A: Use QGIS: Right-click layer > Save As > ESRI Shapefile

Q: Can I edit GeoJSON in a text editor?
A: Yes! It's human-readable JSON. But use GIS software for complex edits.

Q: Is this compatible with web maps?
A: Absolutely! GeoJSON is the standard format for Leaflet, Mapbox, etc.
`
}

Export Configuration:
=====================
This export was generated with these settings:
- Status filter: ${metadata.filters.status.join(', ')}
- Date range: ${metadata.filters.date_from || 'All'} to ${metadata.filters.date_to || 'All'}
- BBOX: ${
    metadata.filters.bbox
      ? `${metadata.filters.bbox.minLon}, ${metadata.filters.bbox.minLat}, ${metadata.filters.bbox.maxLon}, ${metadata.filters.bbox.maxLat}`
      : 'All approved project features'
  }
- Format: ${format}
- Coordinate system: ${metadata.coordinate_system}

For different export options, request a new export with different parameters.
`;
};

// Zip directory
const zipDirectory = async (sourceDir, outPath) => {
  try {
    const zip = new AdmZip();
    zip.addLocalFolder(sourceDir);
    zip.writeZip(outPath);
    const stats = await fs.stat(outPath);
    logger.info('ZIP created:', { size: stats.size });
  } catch (error: any) {
    logger.error('ZIP creation error:', error);
    throw error;
  }
};

// Get all exports for current user
const getMyExports = async (req, res) => {
  const status = normalizeOptionalString(req.query.status);
  const format = normalizeOptionalString(req.query.format);
  const categoryId = normalizeOptionalString(req.query.category_id);
  const projectId = normalizeOptionalString(req.query.project_id);
  const { page, limit, offset } = getPagination(req.query.page, req.query.limit);
  const isAdmin = req.user?.role === 'admin';

  let queryText = `
    SELECT se.*, p.name as project_name, ${exportLifecycleFields}
    FROM shapefile_export se
    JOIN project p ON se.project_id = p.id
    WHERE 1=1
  `;

  const params: unknown[] = [];
  let paramIndex = 1;

  if (!isAdmin) {
    queryText += ` AND se.requested_by_user_id = $${paramIndex}`;
    params.push(req.user.id);
    paramIndex++;
  }

  if (status === 'expired') {
    queryText += ` AND se.status = 'completed' AND se.file_status IN ('expired', 'deleted')`;
  } else if (status) {
    queryText += ` AND se.status = $${paramIndex}`;
    params.push(status);
    paramIndex++;
  }

  if (format) {
    queryText += ` AND se.export_parameters->>'format' = $${paramIndex}`;
    params.push(format);
    paramIndex++;
  }

  if (categoryId) {
    queryText += ` AND p.category_id = $${paramIndex}`;
    params.push(categoryId);
    paramIndex++;
  }

  if (projectId) {
    queryText += ` AND se.project_id = $${paramIndex}`;
    params.push(projectId);
    paramIndex++;
  }

  queryText += ` ORDER BY se.requested_at DESC LIMIT $${paramIndex} OFFSET $${paramIndex + 1}`;
  params.push(limit, offset);

  const result = await query(queryText, params);

  let countQuery = `
    SELECT COUNT(*)::int AS total
    FROM shapefile_export se
    JOIN project p ON se.project_id = p.id
    WHERE 1=1
  `;
  const countParams: unknown[] = [];
  let countParamIndex = 1;

  if (!isAdmin) {
    countQuery += ` AND se.requested_by_user_id = $${countParamIndex}`;
    countParams.push(req.user.id);
    countParamIndex++;
  }

  if (status === 'expired') {
    countQuery += ` AND se.status = 'completed' AND se.file_status IN ('expired', 'deleted')`;
  } else if (status) {
    countQuery += ` AND se.status = $${countParamIndex}`;
    countParams.push(status);
    countParamIndex++;
  }

  if (format) {
    countQuery += ` AND se.export_parameters->>'format' = $${countParamIndex}`;
    countParams.push(format);
    countParamIndex++;
  }

  if (categoryId) {
    countQuery += ` AND p.category_id = $${countParamIndex}`;
    countParams.push(categoryId);
    countParamIndex++;
  }

  if (projectId) {
    countQuery += ` AND se.project_id = $${countParamIndex}`;
    countParams.push(projectId);
    countParamIndex++;
  }

  const countResult = await query(countQuery, countParams);
  const total = countResult.rows[0]?.total ?? 0;

  let summaryQuery = `
    SELECT
      COUNT(*)::int AS total,
      COUNT(*) FILTER (WHERE se.status = 'pending')::int AS pending,
      COUNT(*) FILTER (WHERE se.status = 'processing')::int AS processing,
      COUNT(*) FILTER (WHERE se.status = 'completed' AND se.file_status NOT IN ('expired', 'deleted'))::int AS completed,
      COUNT(*) FILTER (WHERE se.status = 'failed')::int AS failed,
      COUNT(*) FILTER (WHERE se.status = 'completed' AND se.file_status IN ('expired', 'deleted'))::int AS expired
    FROM shapefile_export se
    JOIN project p ON se.project_id = p.id
    WHERE 1=1
  `;
  const summaryParams: unknown[] = [];
  let summaryParamIndex = 1;

  if (!isAdmin) {
    summaryQuery += ` AND se.requested_by_user_id = $${summaryParamIndex}`;
    summaryParams.push(req.user.id);
    summaryParamIndex++;
  }

  if (status === 'expired') {
    summaryQuery += ` AND se.status = 'completed' AND se.file_status IN ('expired', 'deleted')`;
  } else if (status) {
    summaryQuery += ` AND se.status = $${summaryParamIndex}`;
    summaryParams.push(status);
    summaryParamIndex++;
  }

  if (format) {
    summaryQuery += ` AND se.export_parameters->>'format' = $${summaryParamIndex}`;
    summaryParams.push(format);
    summaryParamIndex++;
  }

  if (categoryId) {
    summaryQuery += ` AND p.category_id = $${summaryParamIndex}`;
    summaryParams.push(categoryId);
    summaryParamIndex++;
  }

  if (projectId) {
    summaryQuery += ` AND se.project_id = $${summaryParamIndex}`;
    summaryParams.push(projectId);
    summaryParamIndex++;
  }

  const summaryResult = await query(summaryQuery, summaryParams);
  const summary = summaryResult.rows[0] ?? {
    total: 0,
    pending: 0,
    processing: 0,
    completed: 0,
    failed: 0,
    expired: 0,
  };

  res.json({
    success: true,
    data: result.rows,
    pagination: {
      page,
      limit,
      total,
      totalPages: Math.max(1, Math.ceil(total / limit)),
      has_more: offset + result.rows.length < total,
    },
    summary: {
      total: summary.total ?? 0,
      pending: summary.pending ?? 0,
      processing: summary.processing ?? 0,
      completed: summary.completed ?? 0,
      failed: summary.failed ?? 0,
      expired: summary.expired ?? 0,
    },
  });
};

// Get single export status
const getExportStatus = async (req, res) => {
  const { exportId } = req.params;
  const isAdmin = req.user?.role === 'admin';

  const result = await query(
    `SELECT se.*, p.name as project_name, ${exportLifecycleFields}
     FROM shapefile_export se
     JOIN project p ON se.project_id = p.id
     WHERE se.id = $1
       AND ($2::boolean = TRUE OR se.requested_by_user_id = $3)`,
    [exportId, isAdmin, req.user.id],
  );

  if (result.rows.length === 0) {
    throw new AppError('Export not found', 404);
  }

  res.json({
    success: true,
    data: result.rows[0],
  });
};

// Download export file
const downloadExport = async (req, res) => {
  const { exportId } = req.params;
  const isAdmin = req.user?.role === 'admin';

  const result = await query(
    `SELECT se.file_path,
            se.status,
            se.file_status,
            se.project_id,
            se.export_parameters,
            se.completed_at,
            se.retention_expires_at,
            se.retention_expired_at
     FROM shapefile_export se
     WHERE se.id = $1
       AND ($2::boolean = TRUE OR se.requested_by_user_id = $3)`,
    [exportId, isAdmin, req.user.id],
  );

  if (result.rows.length === 0) {
    throw new AppError('Export not found', 404);
  }

  const exportData = result.rows[0];

  if (exportData.status !== 'completed') {
    throw new AppError(`Export is not ready. Current status: ${exportData.status}`, 400);
  }

  if (['expired', 'deleted'].includes(String(exportData.file_status))) {
    res.status(410).json({
      success: false,
      code: 'EXPORT_FILE_EXPIRED',
      message: EXPORT_FILE_EXPIRED_MESSAGE,
      data: {
        export_id: exportId,
        job_status: exportData.status,
        file_status: exportData.file_status,
        retention_expires_at: exportData.retention_expires_at,
        retention_expired_at: exportData.retention_expired_at,
        can_regenerate: true,
      },
    });
    return;
  }

  if (!exportData.file_path) {
    throw new AppError('Export file not found', 404);
  }
  if (!storageAdapter.resolve(exportData.file_path, ['exports'])) {
    logger.error('Rejected export reference outside configured storage', { exportId });
    throw new AppError('Export file no longer available', 404);
  }

  // Check if file exists
  let resolvedExport: Awaited<ReturnType<typeof storageAdapter.locate>>;
  try {
    resolvedExport = await storageAdapter.locate(exportData.file_path, ['exports']);
  } catch (_error) {
    logger.error('Export file not accessible:', { exportId });
    const completedAt = exportData.completed_at ? new Date(exportData.completed_at) : null;
    const retentionExpired =
      exportData.retention_expires_at && new Date(exportData.retention_expires_at) <= new Date();
    const oldEnoughForRetention =
      completedAt !== null &&
      completedAt.getTime() < Date.now() - RETENTION_DAYS * 24 * 60 * 60 * 1000;
    if (retentionExpired || oldEnoughForRetention) {
      await markExportFileExpired(exportId);
      res.status(410).json({
        success: false,
        code: 'EXPORT_FILE_EXPIRED',
        message: EXPORT_FILE_EXPIRED_MESSAGE,
        data: {
          export_id: exportId,
          job_status: 'completed',
          file_status: 'expired',
          can_regenerate: true,
        },
      });
      return;
    }
    throw new AppError('Export file no longer available', 404);
  }

  const format = exportData.export_parameters?.format || 'geojson';
  logger.info('Downloading export:', { exportId, format });

  // Send file
  res.download(resolvedExport.localPath, (err) => {
    if (err) {
      logger.error('Download error:', { exportId, error: err });
    }
  });
};

// Delete old exports (cleanup job)
const cleanupOldExports = async () => {
  try {
    const cutoffDate = new Date();
    cutoffDate.setDate(cutoffDate.getDate() - RETENTION_DAYS);

    const tableCheck = await query(`SELECT to_regclass('public.shapefile_export') AS table_name`);
    if (!tableCheck.rows[0] || !tableCheck.rows[0].table_name) {
      logger.warn('Skipping export cleanup: shapefile_export table does not exist yet');
      return;
    }

    const oldExports = await query(
      `SELECT id, file_path, requested_by_user_id, project_id FROM shapefile_export
       WHERE completed_at < $1
         AND status = 'completed'
         AND file_status = 'available'`,
      [cutoffDate],
    );

    for (const exp of oldExports.rows) {
      if (exp.file_path) {
        await storageAdapter.remove(exp.file_path).catch((err) => {
          logger.error('Error deleting export file:', err);
        });
      }

      await transaction(async (client) => {
        await client.query(
          `UPDATE shapefile_export
           SET file_status = 'expired',
               file_path = NULL,
               file_deleted_at = CURRENT_TIMESTAMP,
               retention_expired_at = CURRENT_TIMESTAMP,
               retention_expires_at = COALESCE(retention_expires_at, completed_at + ($2::int * INTERVAL '1 day')),
               error_message = 'Export completed, but the file expired. Regenerate it to download again.'
           WHERE id = $1`,
          [exp.id, RETENTION_DAYS],
        );
        await publishRealtimeChanges(
          exportRealtimeInputs({
            exportId: exp.id,
            projectId: exp.project_id,
            requestedByUserId: exp.requested_by_user_id,
            action: 'expired',
          }),
          client,
        );
      });
    }

    logger.info('Old exports cleaned up:', { count: oldExports.rows.length });
  } catch (error: any) {
    logger.error('Export cleanup error:', error);
  }
};

module.exports = {
  getProjectExportCollectors,
  requestExport,
  getMyExports,
  getExportStatus,
  downloadExport,
  cleanupOldExports,
  ensureExportDir,
  processExport,
};

export {};
