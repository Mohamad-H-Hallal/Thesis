const { query, transaction } = require('../config/database');
const { AppError } = require('../middleware/error');
const logger = require('../utils/logger');

const viewerVisibleStatuses = ['active', 'completed'];
const projectAccessScopes = ['public', 'assigned', 'all'] as const;
type ProjectAccessScope = (typeof projectAccessScopes)[number];

const projectStatusTransitions: Record<string, string[]> = {
  draft: ['active'],
  active: ['completed'],
  completed: ['archived'],
  paused: [],
  archived: [],
};

const assertProjectStatusTransition = (currentStatus: string, nextStatus: string): void => {
  if (currentStatus === nextStatus) {
    return;
  }

  const allowed =
    projectStatusTransitions[currentStatus as keyof typeof projectStatusTransitions] ?? [];
  if (!allowed.includes(nextStatus)) {
    throw new AppError(
      `Invalid project status transition from ${currentStatus} to ${nextStatus}`,
      400,
    );
  }
};

const ensureCategoryExists = async (categoryId: string): Promise<void> => {
  const categoryCheck = await query('SELECT id FROM project_category WHERE id = $1', [categoryId]);
  if (categoryCheck.rows.length === 0) {
    throw new AppError('Project category not found', 404);
  }
};

const ensureSchemaObject = (schema: unknown): void => {
  if (!schema || typeof schema !== 'object' || Array.isArray(schema)) {
    throw new AppError('collection_form_schema must be a JSON object', 422);
  }
};

// Get all projects (filtered by user access)
const getAllProjects = async (req, res) => {
  const { page = 1, limit = 20, status, category_id } = req.query;
  const requestedScope =
    typeof req.query.access_scope === 'string' ? req.query.access_scope : undefined;
  const offset = (page - 1) * limit;
  const userId = req.user.id;
  const isAdmin = req.user.role === 'admin';
  const isViewer = req.user.role === 'viewer';
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
    queryText += ` AND p.visible_to_viewers = TRUE AND p.status = ANY($${paramIndex}::project_status[])`;
    params.push(viewerVisibleStatuses);
    paramIndex++;
  } else if (scope === 'assigned') {
    queryText += ` AND (pa.user_id = $${paramIndex} AND pa.status = 'approved')`;
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
    countQuery += ` AND p.visible_to_viewers = TRUE AND p.status = ANY($${countParamIndex}::project_status[])`;
    countParams.push(viewerVisibleStatuses);
    countParamIndex++;
  } else if (scope === 'assigned') {
    countQuery += ` AND (pa.user_id = $${countParamIndex} AND pa.status = 'approved')`;
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
    },
    access_scope: scope,
  });
};

// Get single project
const getProject = async (req, res) => {
  const { projectId } = req.params;
  const userId = req.user.id;

  const result = await query(
    `SELECT p.*, pc.name as category_name,
            u.full_name as created_by_name,
            (SELECT COUNT(*) FROM spatial_feature WHERE project_id = p.id AND status = 'approved') as approved_features,
            (SELECT COUNT(*) FROM spatial_feature WHERE project_id = p.id AND status = 'pending_review') as pending_features,
            (SELECT COUNT(*) FROM project_assignment WHERE project_id = p.id AND status = 'approved') as contributor_count,
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
  } = req.body;

  if (status !== 'draft') {
    throw new AppError('Project status must start as draft', 400);
  }
  ensureSchemaObject(collection_form_schema);
  await ensureCategoryExists(category_id);

  const createdProject = await transaction(async (client) => {
    const insertResult = await client.query(
      `INSERT INTO project (
        created_by_user_id, category_id, name, description, objectives,
        status, start_date, end_date, collection_form_schema,
        requires_photos, min_photos, max_photos, visible_to_viewers
      ) VALUES ($1, $2, $3, $4, $5, 'draft', $6, $7, $8, $9, $10, $11, $12)
      RETURNING *`,
      [
        req.user.id,
        category_id,
        name,
        description,
        objectives,
        start_date,
        end_date,
        JSON.stringify(collection_form_schema),
        requires_photos,
        min_photos,
        max_photos,
        visible_to_viewers,
      ],
    );

    await client.query(
      `INSERT INTO project_assignment (
        project_id, user_id, role, status, approved_by_user_id, approved_date
      )
      VALUES ($1, $2, 'admin', 'approved', $2, CURRENT_DATE)`,
      [insertResult.rows[0].id, req.user.id],
    );

    return insertResult.rows[0];
  });

  logger.info('Project created:', {
    projectId: createdProject.id,
    userId: req.user.id,
  });

  res.status(201).json({
    success: true,
    message: 'Project created successfully',
    data: createdProject,
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
  } = req.body;

  // Build dynamic update query
  const updates: string[] = [];
  const params: unknown[] = [];
  let paramIndex = 1;

  const currentProjectResult = await query(
    'SELECT id, status, category_id FROM project WHERE id = $1',
    [projectId],
  );
  if (currentProjectResult.rows.length === 0) {
    throw new AppError('Project not found', 404);
  }

  const currentProject = currentProjectResult.rows[0];

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
    assertProjectStatusTransition(currentProject.status, status);
    updates.push(`status = $${paramIndex}`);
    params.push(status);
    paramIndex++;
  }
  if (start_date !== undefined) {
    updates.push(`start_date = $${paramIndex}`);
    params.push(start_date);
    paramIndex++;
  }
  if (end_date !== undefined) {
    updates.push(`end_date = $${paramIndex}`);
    params.push(end_date);
    paramIndex++;
  }
  if (collection_form_schema !== undefined) {
    ensureSchemaObject(collection_form_schema);
    updates.push(`collection_form_schema = $${paramIndex}`);
    params.push(JSON.stringify(collection_form_schema));
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

  logger.info('Project updated:', { projectId, userId: req.user.id });

  res.json({
    success: true,
    message: 'Project updated successfully',
    data: result.rows[0],
  });
};

// Delete/Archive project
const deleteProject = async (req, res) => {
  const { projectId } = req.params;

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
        'A project was archived and moved out of active operations.',
        JSON.stringify({ project_id: projectId, status: 'archived' }),
      ],
    );

    return archived.rows[0];
  });

  logger.info('Project archived:', { projectId, userId: req.user.id });

  res.json({
    success: true,
    message: 'Project archived successfully',
  });
};

// Get project statistics
const getProjectStats = async (req, res) => {
  const { projectId } = req.params;

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
  const { status, page = 1, limit = 50 } = req.query;
  const offset = (page - 1) * limit;

  let queryText = `
    SELECT sf.id, sf.status, sf.attributes, sf.accuracy_meters,
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

  queryText += ` ORDER BY sf.collected_at DESC LIMIT $${paramIndex} OFFSET $${paramIndex + 1}`;
  params.push(limit, offset);

  const result = await query(queryText, params);

  // Parse geometry JSON
  const features = result.rows.map((row) => ({
    ...row,
    geometry: JSON.parse(row.geometry),
    photos: Array.isArray(row.photos) ? row.photos : [],
  }));

  res.json({
    success: true,
    data: features,
    pagination: {
      page: parseInt(page),
      limit: parseInt(limit),
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
