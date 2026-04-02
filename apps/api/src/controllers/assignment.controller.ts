const { query, transaction } = require('../config/database');
const { AppError } = require('../middleware/error');
const logger = require('../utils/logger');
import { createNotification, getActiveAdminUsers } from '../lib/userWorkflow';
import { synchronizeProjectStatuses } from '../lib/projectLifecycle';

const getProjectOrFail = async (projectId: string) => {
  await synchronizeProjectStatuses(projectId);
  const projectResult = await query(
    `SELECT id, name, status, visible_to_viewers
     FROM project
     WHERE id = $1`,
    [projectId],
  );

  if (projectResult.rows.length === 0) {
    throw new AppError('Project not found', 404);
  }

  return projectResult.rows[0];
};

const getContributorOrFail = async (userId: string) => {
  const userResult = await query(
    `SELECT id, email, full_name, phone, role, is_active
     FROM "user"
     WHERE id = $1`,
    [userId],
  );

  if (userResult.rows.length === 0) {
    throw new AppError('Contributor not found', 404);
  }

  const contributor = userResult.rows[0];
  if (contributor.role !== 'contributor') {
    throw new AppError('Only accepted contributors can be assigned to projects', 409);
  }
  if (!contributor.is_active) {
    throw new AppError('Contributor account must be active before assignment', 409);
  }

  return contributor;
};

const loadAssignmentOrFail = async (assignmentId: string) => {
  const assignmentResult = await query(
    `SELECT pa.*, p.name AS project_name, p.status AS project_status, u.full_name, u.email, u.phone
     FROM project_assignment pa
     JOIN project p ON p.id = pa.project_id
     JOIN "user" u ON u.id = pa.user_id
     WHERE pa.id = $1
       AND pa.role = 'contributor'`,
    [assignmentId],
  );

  if (assignmentResult.rows.length === 0) {
    throw new AppError('Assignment not found', 404);
  }

  return assignmentResult.rows[0];
};

const assertProjectAssignmentsMutable = (
  project: { status?: string; name?: string },
  action: 'assign' | 'review_request' | 'remove_assignment',
) => {
  if (project.status !== 'completed' && project.status !== 'archived') {
    return;
  }

  const projectLabel = project.name ? `"${project.name}"` : 'This project';
  const reason =
    project.status === 'completed'
      ? `${projectLabel} is completed, so assignments are view-only.`
      : `${projectLabel} is archived, so assignments are view-only.`;

  switch (action) {
    case 'assign':
      throw new AppError(
        `${reason} Contributors cannot be assigned or reassigned in this status.`,
        409,
      );
    case 'review_request':
      throw new AppError(
        `${reason} Project access requests cannot be changed in this status.`,
        409,
      );
    case 'remove_assignment':
      throw new AppError(
        `${reason} Existing assignments cannot be removed in this status.`,
        409,
      );
  }
};

const getMyAssignments = async (req, res) => {
  await synchronizeProjectStatuses();
  const { status } = req.query;

  let queryText = `
    SELECT pa.*, p.name as project_name, p.description as project_description,
           p.status as project_status, pc.name as category_name
    FROM project_assignment pa
    JOIN project p ON pa.project_id = p.id
    LEFT JOIN project_category pc ON p.category_id = pc.id
    WHERE pa.user_id = $1
      AND pa.role = 'contributor'
  `;

  const params: unknown[] = [req.user.id];

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

const getProjectAssignments = async (req, res) => {
  const { projectId } = req.params;
  await synchronizeProjectStatuses(projectId);

  const result = await query(
    `SELECT pa.*,
            p.name AS project_name,
            p.status AS project_status,
            u.full_name,
            u.email,
            u.phone
     FROM project_assignment pa
     JOIN project p ON p.id = pa.project_id
     JOIN "user" u ON pa.user_id = u.id
     WHERE pa.project_id = $1
       AND pa.role = 'contributor'
     ORDER BY
       CASE pa.status
         WHEN 'approved' THEN 0
         WHEN 'pending' THEN 1
         ELSE 2
       END,
       u.full_name ASC,
       pa.created_at DESC`,
    [projectId],
  );

  res.json({
    success: true,
    data: result.rows,
  });
};

const createAssignment = async (req, res) => {
  const { project_id, user_id } = req.body;

  const [project, contributor] = await Promise.all([
    getProjectOrFail(project_id),
    getContributorOrFail(user_id),
  ]);

  assertProjectAssignmentsMutable(project, 'assign');

  const existingAssignment = await query(
    `SELECT id, status
     FROM project_assignment
     WHERE project_id = $1
       AND user_id = $2
       AND role = 'contributor'
     LIMIT 1`,
    [project_id, user_id],
  );

  const assignment = await transaction(async (client) => {
    let row;

    if (existingAssignment.rows.length > 0) {
      const existing = existingAssignment.rows[0];
      if (existing.status === 'approved') {
        throw new AppError('Contributor is already assigned to this project', 409);
      }

      const updated = await client.query(
        `UPDATE project_assignment
         SET status = 'approved',
             role = 'contributor',
             approved_by_user_id = $1,
             approved_date = CURRENT_DATE
         WHERE id = $2
         RETURNING *`,
        [req.user.id, existing.id],
      );
      row = updated.rows[0];
    } else {
      const inserted = await client.query(
        `INSERT INTO project_assignment (
           project_id, user_id, role, status, approved_by_user_id, approved_date
         )
         VALUES ($1, $2, 'contributor', 'approved', $3, CURRENT_DATE)
         RETURNING *`,
        [project_id, user_id, req.user.id],
      );
      row = inserted.rows[0];
    }

    await createNotification(client, {
      userId: user_id,
      type: 'assignment',
      title: 'Contributor assignment approved',
      message: `You were assigned to ${project.name}. Contributor collection access is now available for this project.`,
      metadata: {
        assignment_id: row.id,
        project_id,
        project_name: project.name,
        assignment_status: 'approved',
      },
    });

    return row;
  });

  logger.info('Contributor assigned to project', {
    assignmentId: assignment.id,
    projectId: project_id,
    contributorId: contributor.id,
    assignedBy: req.user.id,
  });

  res.status(201).json({
    success: true,
    message: 'Contributor assigned successfully',
    data: assignment,
  });
};

const getManagedAssignments = async (req, res) => {
  await synchronizeProjectStatuses();
  const { status, page = 1, limit = 50 } = req.query;
  const offset = (page - 1) * limit;

  let queryText = `
    SELECT pa.*,
           p.name as project_name,
           p.status as project_status,
           u.full_name,
           u.email,
           u.phone
    FROM project_assignment pa
    JOIN project p ON p.id = pa.project_id
    JOIN "user" u ON u.id = pa.user_id
    WHERE pa.role = 'contributor'
  `;

  const params: unknown[] = [];
  let paramIndex = 1;

  if (status) {
    queryText += ` AND pa.status = $${paramIndex}`;
    params.push(status);
    paramIndex++;
  }

  queryText += ` ORDER BY pa.created_at DESC LIMIT $${paramIndex} OFFSET $${paramIndex + 1}`;
  params.push(limit, offset);

  const result = await query(queryText, params);

  res.json({
    success: true,
    data: result.rows,
    pagination: {
      page: parseInt(page),
      limit: parseInt(limit),
    },
  });
};

const requestJoinProject = async (req, res) => {
  const { projectId } = req.params;

  if (req.user?.role !== 'contributor') {
    throw new AppError('Only approved contributors can request project access', 403);
  }

  const project = await getProjectOrFail(projectId);
  if (project.status === 'draft' || project.status === 'archived') {
    throw new AppError('This project is not accepting assignment requests', 409);
  }
  if (project.status !== 'active') {
    throw new AppError(
      'Only active projects accept contributor access requests.',
      409,
    );
  }
  if (!project.visible_to_viewers) {
    throw new AppError('Only viewer-visible projects accept self-service assignment requests', 409);
  }

  const existingAssignment = await query(
    `SELECT id, status
     FROM project_assignment
     WHERE project_id = $1
       AND user_id = $2
       AND role = 'contributor'
     LIMIT 1`,
    [projectId, req.user.id],
  );

  if (existingAssignment.rows.length > 0) {
    const existing = existingAssignment.rows[0];
    if (existing.status === 'approved') {
      throw new AppError('You are already assigned to this project', 409);
    }
    if (existing.status === 'pending') {
      throw new AppError('You already have a pending request for this project', 409);
    }
    throw new AppError(
      'A rejected request already exists for this project. Ask an administrator to re-approve it from Requests.',
      409,
    );
  }

  const createdRequest = await transaction(async (client) => {
    const result = await client.query(
      `INSERT INTO project_assignment (project_id, user_id, role, status)
       VALUES ($1, $2, 'contributor', 'pending')
       RETURNING *`,
      [projectId, req.user.id],
    );

    const admins = await getActiveAdminUsers(client);
    for (const admin of admins) {
      await createNotification(client, {
        userId: admin.id,
        type: 'assignment',
        title: 'Project access request pending',
        message: `${req.user.full_name} requested contributor access to ${project.name}. Review the request to approve or reject project assignment access.`,
        metadata: {
          assignment_id: result.rows[0].id,
          project_id: projectId,
          project_name: project.name,
          requester_user_id: req.user.id,
          assignment_status: 'pending',
        },
      });
    }

    await createNotification(client, {
      userId: req.user.id,
      type: 'assignment',
      title: 'Project access request submitted',
      message: `Your request to join ${project.name} as a contributor is pending admin review. You will be notified when the request is approved or rejected.`,
      metadata: {
        assignment_id: result.rows[0].id,
        project_id: projectId,
        project_name: project.name,
        assignment_status: 'pending',
      },
    });

    return result.rows[0];
  });

  logger.info('Project access request submitted', {
    assignmentId: createdRequest.id,
    projectId,
    contributorId: req.user.id,
  });

  res.status(201).json({
    success: true,
    message: 'Project access request submitted successfully',
    data: createdRequest,
  });
};

const cancelJoinProjectRequest = async (req, res) => {
  const { projectId } = req.params;

  if (req.user?.role !== 'contributor') {
    throw new AppError('Only contributors can cancel project access requests', 403);
  }

  const existingAssignment = await query(
    `SELECT pa.id, pa.status, p.name AS project_name
     FROM project_assignment pa
     JOIN project p ON p.id = pa.project_id
     WHERE pa.project_id = $1
       AND pa.user_id = $2
       AND pa.role = 'contributor'
     LIMIT 1`,
    [projectId, req.user.id],
  );

  if (existingAssignment.rows.length === 0) {
    throw new AppError('No project access request exists for this project.', 404);
  }

  const assignment = existingAssignment.rows[0];
  if (assignment.status !== 'pending') {
    throw new AppError('Only pending project access requests can be cancelled.', 409);
  }

  await query('DELETE FROM project_assignment WHERE id = $1', [assignment.id]);

  logger.info('Contributor project access request cancelled', {
    assignmentId: assignment.id,
    projectId,
    contributorId: req.user.id,
  });

  res.json({
    success: true,
    message: 'Project access request cancelled successfully',
  });
};

const updateAssignmentStatus = async (req, res) => {
  const { assignmentId } = req.params;
  const { status } = req.body;

  if (!['approved', 'rejected'].includes(status)) {
    throw new AppError('Status must be approved or rejected', 400);
  }

  const existingAssignment = await loadAssignmentOrFail(assignmentId);
  assertProjectAssignmentsMutable(
    { status: existingAssignment.project_status, name: existingAssignment.project_name },
    'review_request',
  );

  if (existingAssignment.status === status) {
    return res.json({
      success: true,
      message:
        status === 'approved'
          ? 'Project request is already approved'
          : 'Project request is already rejected',
      data: existingAssignment,
    });
  }

  const updatedAssignment = await transaction(async (client) => {
    const result = await client.query(
      `UPDATE project_assignment
       SET status = $1::assignment_status,
           approved_by_user_id = CASE
             WHEN $1::assignment_status = 'approved' THEN $2::uuid
             ELSE NULL
           END,
           approved_date = CASE
             WHEN $1::assignment_status = 'approved' THEN CURRENT_DATE
             ELSE NULL
           END
       WHERE id = $3
       RETURNING *`,
      [status, req.user.id, assignmentId],
    );

    await createNotification(client, {
      userId: existingAssignment.user_id,
      type: 'assignment',
      title:
        status === 'approved'
          ? 'Project access approved'
          : 'Project access rejected',
      message:
        status === 'approved'
          ? `Your contributor access request for ${existingAssignment.project_name} was approved. You can now open the project with contributor access.`
          : `Your contributor access request for ${existingAssignment.project_name} was rejected. Contact an administrator if you need a review.`,
      metadata: {
        assignment_id: assignmentId,
        project_id: existingAssignment.project_id,
        project_name: existingAssignment.project_name,
        assignment_status: status,
      },
    });

    return result.rows[0];
  });

  logger.info('Project assignment request updated', {
    assignmentId,
    status,
    reviewedBy: req.user.id,
  });

  res.json({
    success: true,
    message:
      status === 'approved'
        ? 'Project request approved successfully'
        : 'Project request rejected successfully',
    data: updatedAssignment,
  });
};

const removeAssignment = async (req, res) => {
  const { assignmentId } = req.params;

  const assignment = await loadAssignmentOrFail(assignmentId);
  assertProjectAssignmentsMutable(
    { status: assignment.project_status, name: assignment.project_name },
    'remove_assignment',
  );

  await transaction(async (client) => {
    await client.query('DELETE FROM project_assignment WHERE id = $1', [assignmentId]);

    await createNotification(client, {
      userId: assignment.user_id,
      type: 'assignment',
      title: 'Project assignment removed',
      message: `You were removed from ${assignment.project_name}. You can request project access again later if you still need contributor access.`,
      metadata: {
        assignment_id: assignmentId,
        project_id: assignment.project_id,
        project_name: assignment.project_name,
        assignment_status: 'removed',
      },
    });
  });

  logger.info('Contributor unassigned from project', {
    assignmentId,
    removedBy: req.user.id,
  });

  res.json({
    success: true,
    message: 'Contributor unassigned successfully',
  });
};

module.exports = {
  getMyAssignments,
  getManagedAssignments,
  getProjectAssignments,
  createAssignment,
  requestJoinProject,
  cancelJoinProjectRequest,
  updateAssignmentStatus,
  removeAssignment,
};

export {};
