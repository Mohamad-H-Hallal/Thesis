const { query } = require('../config/database');
const { AppError } = require('../middleware/error');
const logger = require('../utils/logger');

// Get all projects (filtered by user access)
const getAllProjects = async (req, res) => {
  const { page = 1, limit = 20, status, category_id } = req.query;
  const offset = (page - 1) * limit;
  const userId = req.user.id;
  const isAdmin = req.user.role === 'admin';

  let queryText = `
    SELECT DISTINCT p.*, pc.name as category_name,
           u.full_name as created_by_name
    FROM project p
    LEFT JOIN project_category pc ON p.category_id = pc.id
    LEFT JOIN "user" u ON p.created_by_user_id = u.id
    LEFT JOIN project_assignment pa ON p.id = pa.project_id
    WHERE 1=1
  `;
  
  const params: unknown[] = [];
  let paramIndex = 1;

  // Non-admin users can only see projects they're assigned to
  if (!isAdmin) {
    queryText += ` AND (pa.user_id = $${paramIndex} AND pa.status = 'approved')`;
    params.push(userId);
    paramIndex++;
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
    WHERE 1=1
  `;
  
  const countParams: unknown[] = [];
  let countParamIndex = 1;

  if (!isAdmin) {
    countQuery += ` AND (pa.user_id = $${countParamIndex} AND pa.status = 'approved')`;
    countParams.push(userId);
    countParamIndex++;
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
  });
};

// Get single project
const getProject = async (req, res) => {
  const { projectId } = req.params;

  const result = await query(
    `SELECT p.*, pc.name as category_name,
            u.full_name as created_by_name,
            (SELECT COUNT(*) FROM spatial_feature WHERE project_id = p.id AND status = 'approved') as approved_features,
            (SELECT COUNT(*) FROM spatial_feature WHERE project_id = p.id AND status = 'pending_review') as pending_features,
            (SELECT COUNT(*) FROM project_assignment WHERE project_id = p.id AND status = 'approved') as contributor_count
     FROM project p
     LEFT JOIN project_category pc ON p.category_id = pc.id
     LEFT JOIN "user" u ON p.created_by_user_id = u.id
     WHERE p.id = $1`,
    [projectId]
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
  } = req.body;

  const result = await query(
    `INSERT INTO project (
      created_by_user_id, category_id, name, description, objectives,
      status, start_date, end_date, collection_form_schema,
      requires_photos, min_photos, max_photos
    ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
    RETURNING *`,
    [
      req.user.id,
      category_id,
      name,
      description,
      objectives,
      status,
      start_date,
      end_date,
      JSON.stringify(collection_form_schema),
      requires_photos,
      min_photos,
      max_photos,
    ]
  );

  // Automatically assign creator as project admin
  await query(
    `INSERT INTO project_assignment (project_id, user_id, role, status)
     VALUES ($1, $2, 'admin', 'approved')`,
    [result.rows[0].id, req.user.id]
  );

  logger.info('Project created:', {
    projectId: result.rows[0].id,
    userId: req.user.id,
  });

  res.status(201).json({
    success: true,
    message: 'Project created successfully',
    data: result.rows[0],
  });
};

// Update project
const updateProject = async (req, res) => {
  const { projectId } = req.params;
  const {
    name,
    description,
    objectives,
    status,
    start_date,
    end_date,
    collection_form_schema,
    requires_photos,
    min_photos,
    max_photos,
  } = req.body;

  // Build dynamic update query
  const updates: string[] = [];
  const params: unknown[] = [];
  let paramIndex = 1;

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

  if (result.rows.length === 0) {
    throw new AppError('Project not found', 404);
  }

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

  // Soft delete by archiving
  const result = await query(
    `UPDATE project SET status = 'archived' WHERE id = $1 RETURNING id`,
    [projectId]
  );

  if (result.rows.length === 0) {
    throw new AppError('Project not found', 404);
  }

  logger.info('Project archived:', { projectId, userId: req.user.id });

  res.json({
    success: true,
    message: 'Project archived successfully',
  });
};

// Get project statistics
const getProjectStats = async (req, res) => {
  const { projectId } = req.params;

  const result = await query('SELECT * FROM project_statistics WHERE project_id = $1', [
    projectId,
  ]);

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
           ST_AsGeoJSON(sf.geom) as geometry,
           u.full_name as collected_by,
           r.full_name as reviewed_by,
           (SELECT COUNT(*) FROM photo WHERE feature_id = sf.id) as photo_count
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
