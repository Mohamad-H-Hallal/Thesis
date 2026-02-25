const { query } = require('../config/database');
const { AppError } = require('../middleware/error');
const logger = require('../utils/logger');

// Get all assignments for current user
const getMyAssignments = async (req, res) => {
  const { status } = req.query;

  let queryText = `
    SELECT pa.*, p.name as project_name, p.description as project_description,
           p.status as project_status, pc.name as category_name
    FROM project_assignment pa
    JOIN project p ON pa.project_id = p.id
    LEFT JOIN project_category pc ON p.category_id = pc.id
    WHERE pa.user_id = $1
  `;

  const params = [req.user.id];

  if (status) {
    queryText += ` AND pa.status = $2`;
    params.push(status);
  }

  queryText += ` ORDER BY pa.created_at DESC`;

  const result = await query(queryText, params);

  res.json({
    success: true,
    data: result.rows,
  });
};

// Get all assignments for a project (project admin only)
const getProjectAssignments = async (req, res) => {
  const { projectId } = req.params;
  const { status } = req.query;

  let queryText = `
    SELECT pa.*, u.full_name, u.email, u.phone
    FROM project_assignment pa
    JOIN "user" u ON pa.user_id = u.id
    WHERE pa.project_id = $1
  `;

  const params = [projectId];

  if (status) {
    queryText += ` AND pa.status = $2`;
    params.push(status);
  }

  queryText += ` ORDER BY pa.created_at DESC`;

  const result = await query(queryText, params);

  res.json({
    success: true,
    data: result.rows,
  });
};

// Create assignment (assign user to project)
const createAssignment = async (req, res) => {
  const { project_id, user_id, role = 'contributor' } = req.body;

  // Check if assignment already exists
  const existingAssignment = await query(
    'SELECT id, status FROM project_assignment WHERE project_id = $1 AND user_id = $2',
    [project_id, user_id]
  );

  if (existingAssignment.rows.length > 0) {
    throw new AppError('User is already assigned to this project', 409);
  }

  // Create assignment (pending by default)
  const result = await query(
    `INSERT INTO project_assignment (project_id, user_id, role, status)
     VALUES ($1, $2, $3, 'pending')
     RETURNING *`,
    [project_id, user_id, role]
  );

  // Create notification for the assigned user
  await query(
    `INSERT INTO notification (user_id, type, title, message, metadata)
     VALUES ($1, 'assignment', 'Project Assignment', 
             'You have been assigned to a new project', $2)`,
    [user_id, JSON.stringify({ project_id, assignment_id: result.rows[0].id })]
  );

  logger.info('Assignment created:', {
    assignmentId: result.rows[0].id,
    projectId: project_id,
    userId: user_id,
  });

  res.status(201).json({
    success: true,
    message: 'Assignment created successfully',
    data: result.rows[0],
  });
};

// Request to join project (contributor self-assignment)
const requestJoinProject = async (req, res) => {
  const { projectId } = req.params;

  // Check if user is already assigned
  const existingAssignment = await query(
    'SELECT id FROM project_assignment WHERE project_id = $1 AND user_id = $2',
    [projectId, req.user.id]
  );

  if (existingAssignment.rows.length > 0) {
    throw new AppError('You have already requested to join this project', 409);
  }

  // Create pending assignment request
  const result = await query(
    `INSERT INTO project_assignment (project_id, user_id, role, status)
     VALUES ($1, $2, 'contributor', 'pending')
     RETURNING *`,
    [projectId, req.user.id]
  );

  // Notify project admins
  const projectAdmins = await query(
    `SELECT user_id FROM project_assignment 
     WHERE project_id = $1 AND role = 'admin' AND status = 'approved'`,
    [projectId]
  );

  for (const admin of projectAdmins.rows) {
    await query(
      `INSERT INTO notification (user_id, type, title, message, metadata)
       VALUES ($1, 'assignment', 'Join Request', 
               'A user has requested to join your project', $2)`,
      [admin.user_id, JSON.stringify({ project_id: projectId, user_id: req.user.id })]
    );
  }

  logger.info('Join request created:', {
    projectId,
    userId: req.user.id,
  });

  res.status(201).json({
    success: true,
    message: 'Join request submitted successfully',
    data: result.rows[0],
  });
};

// Approve or reject assignment
const updateAssignmentStatus = async (req, res) => {
  const { assignmentId } = req.params;
  const { status } = req.body;

  if (!['approved', 'rejected'].includes(status)) {
    throw new AppError('Status must be approved or rejected', 400);
  }

  // Get assignment details
  const assignmentCheck = await query(
    'SELECT user_id FROM project_assignment WHERE id = $1',
    [assignmentId]
  );

  if (assignmentCheck.rows.length === 0) {
    throw new AppError('Assignment not found', 404);
  }

  // Update assignment status
  const result = await query(
    `UPDATE project_assignment 
     SET status = $1, approved_by_user_id = $2
     WHERE id = $3
     RETURNING *`,
    [status, req.user.id, assignmentId]
  );

  // Notify the user
  await query(
    `INSERT INTO notification (user_id, type, title, message, metadata)
     VALUES ($1, 'assignment', $2, $3, $4)`,
    [
      assignmentCheck.rows[0].user_id,
      `Assignment ${status}`,
      `Your project assignment has been ${status}`,
      JSON.stringify({ assignment_id: assignmentId, status }),
    ]
  );

  logger.info('Assignment status updated:', {
    assignmentId,
    status,
    approvedBy: req.user.id,
  });

  res.json({
    success: true,
    message: `Assignment ${status} successfully`,
    data: result.rows[0],
  });
};

// Remove assignment
const removeAssignment = async (req, res) => {
  const { assignmentId } = req.params;

  const result = await query(
    'DELETE FROM project_assignment WHERE id = $1 RETURNING user_id, project_id',
    [assignmentId]
  );

  if (result.rows.length === 0) {
    throw new AppError('Assignment not found', 404);
  }

  // Notify the user
  await query(
    `INSERT INTO notification (user_id, type, title, message, metadata)
     VALUES ($1, 'assignment', 'Assignment Removed', 
             'You have been removed from a project', $2)`,
    [
      result.rows[0].user_id,
      JSON.stringify({ project_id: result.rows[0].project_id }),
    ]
  );

  logger.info('Assignment removed:', {
    assignmentId,
    removedBy: req.user.id,
  });

  res.json({
    success: true,
    message: 'Assignment removed successfully',
  });
};

module.exports = {
  getMyAssignments,
  getProjectAssignments,
  createAssignment,
  requestJoinProject,
  updateAssignmentStatus,
  removeAssignment,
};

export {};
