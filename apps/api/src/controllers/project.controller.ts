const { query, transaction } = require('../config/database');
const { AppError } = require('../middleware/error');
const logger = require('../utils/logger');
import { sanitizeManagedFeatureAttributes } from '../lib/featureAttributes';
import {
  assertProjectStatusTransition,
  normalizeProjectDateInput,
  publicVisibleStatuses,
  resolveProjectScheduleForMutation,
  synchronizeProjectStatuses,
} from '../lib/projectLifecycle';
import { normalizeCollectionFormSchema } from '../lib/projectSchema';

const projectAccessScopes = ['public', 'assigned', 'all'] as const;
type ProjectAccessScope = (typeof projectAccessScopes)[number];

const publicVisibilityColumnForRole = (role: string): 'visible_to_viewers' | 'visible_to_contributors' =>
  role === 'viewer' ? 'visible_to_viewers' : 'visible_to_contributors';

const ensureCategoryExists = async (categoryId: string): Promise<void> => {
  const categoryCheck = await query('SELECT id FROM project_category WHERE id = $1', [categoryId]);
  if (categoryCheck.rows.length === 0) {
    throw new AppError('Project category not found', 404);
  }
};

// Get all projects (filtered by user access)
const getAllProjects = async (req, res) => {
  await synchronizeProjectStatuses();
  const { page = 1, limit = 20, status, category_id, q } = req.query;
  const requestedScope =
    typeof req.query.access_scope === 'string' ? req.query.access_scope : undefined;
  const offset = (page - 1) * limit;
  const userId = req.user.id;
  const isAdmin = req.user.role === 'admin';
  const isViewer = req.user.role === 'viewer';
  const publicVisibilityColumn = publicVisibilityColumnForRole(req.user.role);
  const scope: ProjectAccessScope = (() => {
    if (requestedScope && projectAccessScopes.includes(requestedScope as ProjectAccessScope)) {
      return requestedScope as ProjectAccessScope;
    }
    if (isAdmin) {
      return 'all';
    }
    if (isViewer) {
      return 'public';
    }
    return 'assigned';
  })();

  let queryText = `
    SELECT DISTINCT p.*, pc.name as category_name,
           u.full_name as created_by_name,
           (SELECT COUNT(*)
            FROM spatial_feature sf
            WHERE sf.project_id = p.id
              AND sf.status = 'approved') as approved_features,
           (SELECT COUNT(*)
            FROM spatial_feature sf
            WHERE sf.project_id = p.id
              AND sf.status = 'pending_review') as pending_features,
           (SELECT COUNT(*)
            FROM project_assignment pac
            WHERE pac.project_id = p.id
              AND pac.role = 'contributor'
              AND pac.status = 'approved') as contributor_count,
           (SELECT COUNT(*)
            FROM project_assignment pac
            WHERE pac.project_id = p.id
              AND pac.role = 'contributor'
              AND pac.status = 'pending') as pending_assignment_requests,
           (SELECT COUNT(*)
            FROM project_assignment pac
            WHERE pac.project_id = p.id
              AND pac.role = 'contributor'
              AND pac.status = 'rejected') as rejected_assignment_requests,
           pa_user.role as current_user_assignment_role,
           pa_user.status as current_user_assignment_status
    FROM project p
    LEFT JOIN project_category pc ON p.category_id = pc.id
    LEFT JOIN "user" u ON p.created_by_user_id = u.id
    LEFT JOIN project_assignment pa ON p.id = pa.project_id
    LEFT JOIN project_assignment pa_user
      ON p.id = pa_user.project_id
     AND pa_user.user_id = $1
    WHERE 1=1
  `;

  const params: unknown[] = [userId];
  let paramIndex = 2;

  if (isAdmin && scope === 'all') {
    // No additional access filter.
  } else if (scope === 'public') {
    queryText += ` AND p.${publicVisibilityColumn} = TRUE AND p.status = ANY($${paramIndex}::project_status[])`;
    params.push(publicVisibleStatuses);
    paramIndex++;
  } else if (scope === 'assigned') {
    queryText += ` AND (
      pa.user_id = $${paramIndex}
      AND pa.role = 'contributor'
      AND pa.status = 'approved'
    )`;
    params.push(userId);
    paramIndex++;
  } else {
    throw new AppError('Unsupported project access scope', 400);
  }

  // Filter by status
  if (status) {
    queryText += ` AND p.status = $${paramIndex}`;
    params.push(status);
    paramIndex++;
  }

  if (q) {
    queryText += ` AND (
      p.name ILIKE $${paramIndex}
      OR COALESCE(p.description, '') ILIKE $${paramIndex}
      OR COALESCE(pc.name, '') ILIKE $${paramIndex}
    )`;
    params.push(`%${String(q).trim()}%`);
    paramIndex++;
  }

  // Filter by category
  if (category_id) {
    queryText += ` AND p.category_id = $${paramIndex}`;
    params.push(category_id);
    paramIndex++;
  }

  // Add pagination
  queryText += ` ORDER BY p.created_at DESC LIMIT $${paramIndex} OFFSET $${paramIndex + 1}`;
  params.push(limit, offset);

  const result = await query(queryText, params);

  // Get total count
  let countQuery = `
    SELECT COUNT(DISTINCT p.id) as total
    FROM project p
    LEFT JOIN project_category pc ON p.category_id = pc.id
    LEFT JOIN project_assignment pa ON p.id = pa.project_id
    LEFT JOIN project_assignment pa_user
      ON p.id = pa_user.project_id
     AND pa_user.user_id = $1
    WHERE 1=1
  `;

  const countParams: unknown[] = [userId];
  let countParamIndex = 2;

  if (isAdmin && scope === 'all') {
    // No additional access filter.
  } else if (scope === 'public') {
    countQuery += ` AND p.${publicVisibilityColumn} = TRUE AND p.status = ANY($${countParamIndex}::project_status[])`;
    countParams.push(publicVisibleStatuses);
    countParamIndex++;
  } else if (scope === 'assigned') {
    countQuery += ` AND (
      pa.user_id = $${countParamIndex}
      AND pa.role = 'contributor'
      AND pa.status = 'approved'
    )`;
    countParams.push(userId);
    countParamIndex++;
  } else {
    throw new AppError('Unsupported project access scope', 400);
  }

  if (status) {
    countQuery += ` AND p.status = $${countParamIndex}`;
    countParams.push(status);
    countParamIndex++;
  }

  if (q) {
    countQuery += ` AND (
      p.name ILIKE $${countParamIndex}
      OR COALESCE(p.description, '') ILIKE $${countParamIndex}
      OR COALESCE(pc.name, '') ILIKE $${countParamIndex}
    )`;
    countParams.push(`%${String(q).trim()}%`);
    countParamIndex++;
  }

  if (category_id) {
    countQuery += ` AND p.category_id = $${countParamIndex}`;
    countParams.push(category_id);
  }

  const countResult = await query(countQuery, countParams);
  const total = parseInt(countResult.rows[0].total);

  res.json({
    success: true,
    data: result.rows,
    pagination: {
      page: parseInt(page),
      limit: parseInt(limit),
      total,
      pages: Math.ceil(total / limit),
      has_more: offset + result.rows.length < total,
    },
    access_scope: scope,
  });
};

// Get single project
const getProject = async (req, res) => {
  const { projectId } = req.params;
  const userId = req.user.id;
  await synchronizeProjectStatuses(projectId);

  const result = await query(
    `SELECT p.*, pc.name as category_name,
            u.full_name as created_by_name,
            (SELECT COUNT(*) FROM spatial_feature WHERE project_id = p.id AND status = 'approved') as approved_features,
            (SELECT COUNT(*) FROM spatial_feature WHERE project_id = p.id AND status = 'pending_review') as pending_features,
            (SELECT COUNT(*) FROM project_assignment WHERE project_id = p.id AND role = 'contributor' AND status = 'approved') as contributor_count,
            (SELECT COUNT(*) FROM project_assignment WHERE project_id = p.id AND role = 'contributor' AND status = 'pending') as pending_assignment_requests,
            (SELECT COUNT(*) FROM project_assignment WHERE project_id = p.id AND role = 'contributor' AND status = 'rejected') as rejected_assignment_requests,
            pa_user.role as current_user_assignment_role,
            pa_user.status as current_user_assignment_status
     FROM project p
     LEFT JOIN project_category pc ON p.category_id = pc.id
     LEFT JOIN "user" u ON p.created_by_user_id = u.id
     LEFT JOIN project_assignment pa_user
       ON p.id = pa_user.project_id
      AND pa_user.user_id = $2
     WHERE p.id = $1`,
    [projectId, userId],
  );

  if (result.rows.length === 0) {
    throw new AppError('Project not found', 404);
  }

  res.json({
    success: true,
    data: result.rows[0],
  });
};

// Create new project
const createProject = async (req, res) => {
  const {
    name,
    description,
    objectives,
    category_id,
    status = 'draft',
    start_date,
    end_date,
    collection_form_schema,
    requires_photos = false,
    min_photos = 0,
    max_photos = 10,
    visible_to_viewers = false,
    visible_to_contributors = true,
  } = req.body;

  if (status !== 'draft') {
    throw new AppError('Project status must start as draft', 400);
  }
  const normalizedCollectionFormSchema =
    normalizeCollectionFormSchema(collection_form_schema);
  await ensureCategoryExists(category_id);
  const normalizedSchedule = resolveProjectScheduleForMutation({
    currentStatus: 'draft',
    nextStatus: 'draft',
    currentStartDate: null,
    currentEndDate: null,
    startDateProvided: start_date !== undefined,
    endDateProvided: end_date !== undefined,
    requestedStartDate: start_date,
    requestedEndDate: end_date,
  });

  const createdProjectResult = await query(
      `INSERT INTO project (
        created_by_user_id, category_id, name, description, objectives,
        status, start_date, end_date, collection_form_schema,
        requires_photos, min_photos, max_photos, visible_to_viewers, visible_to_contributors
      ) VALUES ($1, $2, $3, $4, $5, 'draft', $6, $7, $8, $9, $10, $11, $12, $13)
      RETURNING *`,
      [
        req.user.id,
        category_id,
        name,
        description,
        objectives,
        normalizedSchedule.startDate,
        normalizedSchedule.endDate,
        JSON.stringify(normalizedCollectionFormSchema),
        requires_photos,
        min_photos,
        max_photos,
        visible_to_viewers,
        visible_to_contributors,
      ],
    );
  const createdProject = createdProjectResult.rows[0];
  await synchronizeProjectStatuses(createdProject.id);
  const synchronizedProjectResult = await query(
    'SELECT * FROM project WHERE id = $1',
    [createdProject.id],
  );
  const synchronizedProject =
    synchronizedProjectResult.rows[0] ?? createdProject;

  logger.info('Project created:', {
    projectId: synchronizedProject.id,
    userId: req.user.id,
  });

  res.status(201).json({
    success: true,
    message: 'Project created successfully',
    data: synchronizedProject,
  });
};

// Update project
const updateProject = async (req, res) => {
  const { projectId } = req.params;
  const {
    name,
    description,
    objectives,
    category_id,
    status,
    start_date,
    end_date,
    collection_form_schema,
    requires_photos,
    min_photos,
    max_photos,
    visible_to_viewers,
    visible_to_contributors,
  } = req.body;

  await synchronizeProjectStatuses(projectId);
  // Build dynamic update query
  const updates: string[] = [];
  const params: unknown[] = [];
  let paramIndex = 1;

  const currentProjectResult = await query(
    'SELECT id, status, category_id, start_date, end_date FROM project WHERE id = $1',
    [projectId],
  );
  if (currentProjectResult.rows.length === 0) {
    throw new AppError('Project not found', 404);
  }

  const currentProject = currentProjectResult.rows[0];
  const currentStartDate = normalizeProjectDateInput(currentProject.start_date);
  const currentEndDate = normalizeProjectDateInput(currentProject.end_date);
  const nextStatus = status ?? currentProject.status;

  if (status !== undefined) {
    assertProjectStatusTransition(currentProject.status, status);
  }

  const normalizedSchedule = resolveProjectScheduleForMutation({
    currentStatus: currentProject.status,
    nextStatus,
    currentStartDate: currentStartDate,
    currentEndDate: currentEndDate,
    startDateProvided: start_date !== undefined,
    endDateProvided: end_date !== undefined,
    requestedStartDate: start_date,
    requestedEndDate: end_date,
  });

  if (category_id !== undefined) {
    await ensureCategoryExists(category_id);
    updates.push(`category_id = $${paramIndex}`);
    params.push(category_id);
    paramIndex++;
  }
  if (name !== undefined) {
    updates.push(`name = $${paramIndex}`);
    params.push(name);
    paramIndex++;
  }
  if (description !== undefined) {
    updates.push(`description = $${paramIndex}`);
    params.push(description);
    paramIndex++;
  }
  if (objectives !== undefined) {
    updates.push(`objectives = $${paramIndex}`);
    params.push(objectives);
    paramIndex++;
  }
  if (status !== undefined) {
    updates.push(`status = $${paramIndex}`);
    params.push(status);
    paramIndex++;
  }
  if (
    start_date !== undefined ||
    (status !== undefined && normalizedSchedule.startDate !== currentStartDate)
  ) {
    updates.push(`start_date = $${paramIndex}`);
    params.push(normalizedSchedule.startDate);
    paramIndex++;
  }
  if (
    end_date !== undefined ||
    (status !== undefined && normalizedSchedule.endDate !== currentEndDate)
  ) {
    updates.push(`end_date = $${paramIndex}`);
    params.push(normalizedSchedule.endDate);
    paramIndex++;
  }
  if (collection_form_schema !== undefined) {
    const normalizedCollectionFormSchema =
      normalizeCollectionFormSchema(collection_form_schema);
    updates.push(`collection_form_schema = $${paramIndex}`);
    params.push(JSON.stringify(normalizedCollectionFormSchema));
    paramIndex++;
  }
  if (requires_photos !== undefined) {
    updates.push(`requires_photos = $${paramIndex}`);
    params.push(requires_photos);
    paramIndex++;
  }
  if (min_photos !== undefined) {
    updates.push(`min_photos = $${paramIndex}`);
    params.push(min_photos);
    paramIndex++;
  }
  if (max_photos !== undefined) {
    updates.push(`max_photos = $${paramIndex}`);
    params.push(max_photos);
    paramIndex++;
  }
  if (visible_to_viewers !== undefined) {
    updates.push(`visible_to_viewers = $${paramIndex}`);
    params.push(visible_to_viewers);
    paramIndex++;
  }
  if (visible_to_contributors !== undefined) {
    updates.push(`visible_to_contributors = $${paramIndex}`);
    params.push(visible_to_contributors);
    paramIndex++;
  }

  if (updates.length === 0) {
    throw new AppError('No fields to update', 400);
  }

  params.push(projectId);
  const queryText = `
    UPDATE project
    SET ${updates.join(', ')}
    WHERE id = $${paramIndex}
    RETURNING *
  `;

  const result = await query(queryText, params);
  await synchronizeProjectStatuses(projectId);
  const synchronizedProjectResult = await query(
    'SELECT * FROM project WHERE id = $1',
    [projectId],
  );
  const synchronizedProject =
    synchronizedProjectResult.rows[0] ?? result.rows[0];

  logger.info('Project updated:', { projectId, userId: req.user.id });

  res.json({
    success: true,
    message: 'Project updated successfully',
    data: synchronizedProject,
  });
};

// Delete/Archive project
const deleteProject = async (req, res) => {
  const { projectId } = req.params;
  await synchronizeProjectStatuses(projectId);

  await transaction(async (client) => {
    const projectStatusResult = await client.query(
      'SELECT id, status, name FROM project WHERE id = $1',
      [projectId],
    );

    if (projectStatusResult.rows.length === 0) {
      throw new AppError('Project not found', 404);
    }

    assertProjectStatusTransition(projectStatusResult.rows[0].status, 'archived');

    const archived = await client.query(
      `UPDATE project SET status = 'archived' WHERE id = $1 RETURNING id, name`,
      [projectId],
    );

    await client.query(
      `INSERT INTO notification (user_id, type, title, message, metadata)
       SELECT pa.user_id,
              'assignment',
              'Project archived',
              $2,
              $3::jsonb
       FROM project_assignment pa
       WHERE pa.project_id = $1
         AND pa.status = 'approved'`,
      [
        projectId,
        `${projectStatusResult.rows[0].name} was archived and moved out of active operations.`,
        JSON.stringify({
          project_id: projectId,
          project_name: projectStatusResult.rows[0].name,
          status: 'archived',
        }),
      ],
    );

    return archived.rows[0];
  });

  logger.info('Project archived:', { projectId, userId: req.user.id });
  await synchronizeProjectStatuses(projectId);

  res.json({
    success: true,
    message: 'Project archived successfully',
  });
};

// Get project statistics
const getProjectStats = async (req, res) => {
  const { projectId } = req.params;
  await synchronizeProjectStatuses(projectId);

  const result = await query('SELECT * FROM project_statistics WHERE project_id = $1', [projectId]);

  if (result.rows.length === 0) {
    throw new AppError('Project not found', 404);
  }

  res.json({
    success: true,
    data: result.rows[0],
  });
};

// Get project features
const getProjectFeatures = async (req, res) => {
  const { projectId } = req.params;
  const status = typeof req.query.status === 'string' ? req.query.status.trim() : '';
  const searchQuery = typeof req.query.q === 'string' ? req.query.q.trim() : '';
  const geometryType =
    typeof req.query.geometry_type === 'string'
      ? req.query.geometry_type.trim()
      : '';
  const featureType =
    typeof req.query.feature_type === 'string'
      ? req.query.feature_type.trim()
      : '';
  const page = Math.max(1, Number.parseInt(String(req.query.page ?? '1'), 10) || 1);
  const limit = Math.min(
    Math.max(1, Number.parseInt(String(req.query.limit ?? '50'), 10) || 50),
    100,
  );
  const offset = (page - 1) * limit;
  await synchronizeProjectStatuses(projectId);

  let queryText = `
    SELECT sf.id, sf.status, sf.attributes,
           sf.collected_at, sf.submitted_at, sf.reviewed_at,
           sf.review_notes,
           ST_AsGeoJSON(sf.geom) as geometry,
           u.full_name as collected_by,
           r.full_name as reviewed_by,
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
           ) as photos
    FROM spatial_feature sf
    LEFT JOIN "user" u ON sf.collected_by_user_id = u.id
    LEFT JOIN "user" r ON sf.reviewed_by_user_id = r.id
    WHERE sf.project_id = $1
  `;

  const params: unknown[] = [projectId];
  let paramIndex = 2;

  if (status) {
    queryText += ` AND sf.status = $${paramIndex}`;
    params.push(status);
    paramIndex++;
  }

  if (geometryType) {
    queryText += ` AND GeometryType(sf.geom) = $${paramIndex}`;
    params.push(geometryType);
    paramIndex++;
  }

  if (featureType) {
    queryText += `
      AND EXISTS (
        SELECT 1
        FROM jsonb_each_text(COALESCE(sf.attributes, '{}'::jsonb)) AS attr(key, value)
        WHERE (
          LOWER(attr.key) LIKE '%type%'
          OR LOWER(attr.key) LIKE '%species%'
          OR LOWER(attr.key) LIKE '%crop%'
          OR LOWER(attr.key) LIKE '%tree%'
          OR LOWER(attr.key) LIKE '%orchard%'
        )
          AND LOWER(BTRIM(attr.value)) = LOWER($${paramIndex})
      )
    `;
    params.push(featureType);
    paramIndex++;
  }

  if (searchQuery) {
    queryText += `
      AND (
        sf.id::text ILIKE $${paramIndex}
        OR COALESCE(u.full_name, '') ILIKE $${paramIndex}
        OR COALESCE(sf.attributes::text, '') ILIKE $${paramIndex}
        OR GeometryType(sf.geom) ILIKE $${paramIndex}
      )
    `;
    params.push(`%${searchQuery}%`);
    paramIndex++;
  }

  if (req.user?.role === 'viewer') {
    queryText += ` AND sf.status = 'approved'`;
  } else if (req.user?.role !== 'admin') {
    if (req.projectRole === 'admin') {
      // Project admins can see every feature lifecycle state for this project.
    } else {
      queryText += ` AND (
        sf.status = 'approved'
        OR sf.collected_by_user_id = $${paramIndex}
      )`;
      params.push(req.user?.id);
      paramIndex++;
    }
  }

  queryText += ` ORDER BY sf.collected_at DESC LIMIT $${paramIndex} OFFSET $${paramIndex + 1}`;
  params.push(limit, offset);

  const result = await query(queryText, params);

  let countQuery = `
    SELECT COUNT(*)::int AS total
    FROM spatial_feature sf
    WHERE sf.project_id = $1
  `;
  const countParams: unknown[] = [projectId];
  let countParamIndex = 2;

  if (status) {
    countQuery += ` AND sf.status = $${countParamIndex}`;
    countParams.push(status);
    countParamIndex++;
  }

  if (geometryType) {
    countQuery += ` AND GeometryType(sf.geom) = $${countParamIndex}`;
    countParams.push(geometryType);
    countParamIndex++;
  }

  if (featureType) {
    countQuery += `
      AND EXISTS (
        SELECT 1
        FROM jsonb_each_text(COALESCE(sf.attributes, '{}'::jsonb)) AS attr(key, value)
        WHERE (
          LOWER(attr.key) LIKE '%type%'
          OR LOWER(attr.key) LIKE '%species%'
          OR LOWER(attr.key) LIKE '%crop%'
          OR LOWER(attr.key) LIKE '%tree%'
          OR LOWER(attr.key) LIKE '%orchard%'
        )
          AND LOWER(BTRIM(attr.value)) = LOWER($${countParamIndex})
      )
    `;
    countParams.push(featureType);
    countParamIndex++;
  }

  if (searchQuery) {
    countQuery += `
      AND (
        sf.id::text ILIKE $${countParamIndex}
        OR EXISTS (
          SELECT 1
          FROM "user" u
          WHERE u.id = sf.collected_by_user_id
            AND COALESCE(u.full_name, '') ILIKE $${countParamIndex}
        )
        OR COALESCE(sf.attributes::text, '') ILIKE $${countParamIndex}
        OR GeometryType(sf.geom) ILIKE $${countParamIndex}
      )
    `;
    countParams.push(`%${searchQuery}%`);
    countParamIndex++;
  }

  if (req.user?.role === 'viewer') {
    countQuery += ` AND sf.status = 'approved'`;
  } else if (req.user?.role !== 'admin') {
    if (req.projectRole === 'admin') {
      // Project admins can see every feature lifecycle state for this project.
    } else {
      countQuery += ` AND (
        sf.status = 'approved'
        OR sf.collected_by_user_id = $${countParamIndex}
      )`;
      countParams.push(req.user?.id);
      countParamIndex++;
    }
  }

  const countResult = await query(countQuery, countParams);
  const total = countResult.rows[0]?.total ?? 0;

  // Parse geometry JSON
  const features = result.rows.map((row) => ({
    ...row,
    attributes: sanitizeManagedFeatureAttributes(row.attributes),
    geometry: JSON.parse(row.geometry),
    photos: Array.isArray(row.photos) ? row.photos : [],
  }));

  res.json({
    success: true,
    data: features,
    pagination: {
      page,
      limit,
      total,
      pages: Math.max(1, Math.ceil(total / limit)),
      has_more: offset + features.length < total,
    },
  });
};

module.exports = {
  getAllProjects,
  getProject,
  createProject,
  updateProject,
  deleteProject,
  getProjectStats,
  getProjectFeatures,
};

export {};
