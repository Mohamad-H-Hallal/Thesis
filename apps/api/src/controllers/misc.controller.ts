const bcrypt = require('bcryptjs');
const { query, transaction } = require('../config/database');
const { AppError } = require('../middleware/error');
const logger = require('../utils/logger');
import {
  createNotification,
  getLatestAccountState,
  isProtectedSuperAdminEmail,
  normalizeEmail,
  getUserAccessState,
} from '../lib/userWorkflow';

const getUserForAdminMutation = async (userId: string) => {
  const result = await query(
    `SELECT id, email, full_name, phone, role, is_active
     FROM "user"
     WHERE id = $1`,
    [userId],
  );

  if (result.rows.length === 0) {
    throw new AppError('User not found', 404);
  }

  return result.rows[0];
};

const assertAdminManagementAllowed = ({
  actorEmail,
  targetEmail,
  targetRole,
  nextRole,
  nextIsActive,
}: {
  actorEmail?: string | null;
  targetEmail?: string | null;
  targetRole: string;
  nextRole?: string;
  nextIsActive?: boolean;
}): void => {
  const actorIsProtectedSuperAdmin = isProtectedSuperAdminEmail(actorEmail);
  const targetIsProtectedSuperAdmin = isProtectedSuperAdminEmail(targetEmail);

  if (targetIsProtectedSuperAdmin) {
    throw new AppError(
      'The protected super administrator cannot be modified through this action.',
      403,
    );
  }

  const touchesAdminPrivileges = targetRole === 'admin' || nextRole === 'admin';
  if (touchesAdminPrivileges && !actorIsProtectedSuperAdmin) {
    throw new AppError('Only the protected super administrator can manage admin accounts.', 403);
  }

  if (targetRole === 'admin' && nextIsActive === false && !actorIsProtectedSuperAdmin) {
    throw new AppError(
      'Only the protected super administrator can deactivate admin accounts.',
      403,
    );
  }
};

// ============================================================================
// CATEGORY CONTROLLER
// ============================================================================

const categoryController = {
  // Get all categories
  getAll: async (req, res) => {
    const result = await query('SELECT * FROM project_category ORDER BY name ASC');

    res.json({
      success: true,
      data: result.rows,
    });
  },

  // Get single category
  getOne: async (req, res) => {
    const { categoryId } = req.params;

    const result = await query('SELECT * FROM project_category WHERE id = $1', [categoryId]);

    if (result.rows.length === 0) {
      throw new AppError('Category not found', 404);
    }

    res.json({
      success: true,
      data: result.rows[0],
    });
  },

  // Create category (admin only)
  create: async (req, res) => {
    const { name, description, icon_url } = req.body;

    const result = await query(
      `INSERT INTO project_category (name, description, icon_url)
       VALUES ($1, $2, $3)
       RETURNING *`,
      [name, description, icon_url],
    );

    logger.info('Category created:', { categoryId: result.rows[0].id });

    res.status(201).json({
      success: true,
      message: 'Category created successfully',
      data: result.rows[0],
    });
  },

  // Update category (admin only)
  update: async (req, res) => {
    const { categoryId } = req.params;
    const { name, description, icon_url } = req.body;

    const updates: string[] = [];
    const params: unknown[] = [];
    let paramIndex = 1;

    if (name) {
      updates.push(`name = $${paramIndex}`);
      params.push(name);
      paramIndex++;
    }
    if (description !== undefined) {
      updates.push(`description = $${paramIndex}`);
      params.push(description);
      paramIndex++;
    }
    if (icon_url !== undefined) {
      updates.push(`icon_url = $${paramIndex}`);
      params.push(icon_url);
      paramIndex++;
    }

    if (updates.length === 0) {
      throw new AppError('No fields to update', 400);
    }

    params.push(categoryId);
    const result = await query(
      `UPDATE project_category SET ${updates.join(', ')} WHERE id = $${paramIndex} RETURNING *`,
      params,
    );

    if (result.rows.length === 0) {
      throw new AppError('Category not found', 404);
    }

    res.json({
      success: true,
      message: 'Category updated successfully',
      data: result.rows[0],
    });
  },

  // Delete category (admin only)
  delete: async (req, res) => {
    const { categoryId } = req.params;

    const result = await query('DELETE FROM project_category WHERE id = $1 RETURNING id', [
      categoryId,
    ]);

    if (result.rows.length === 0) {
      throw new AppError('Category not found', 404);
    }

    res.json({
      success: true,
      message: 'Category deleted successfully',
    });
  },
};

// ============================================================================
// NOTIFICATION CONTROLLER
// ============================================================================

const notificationController = {
  // Get user notifications
  getAll: async (req, res) => {
    const { is_read, page = 1, limit = 20 } = req.query;
    const offset = (page - 1) * limit;

    let queryText = `
      SELECT * FROM notification
      WHERE user_id = $1
    `;

    const params = [req.user.id];
    let paramIndex = 2;

    if (is_read !== undefined) {
      queryText += ` AND is_read = $${paramIndex}`;
      params.push(is_read === 'true');
      paramIndex++;
    }

    queryText += ` ORDER BY created_at DESC LIMIT $${paramIndex} OFFSET $${paramIndex + 1}`;
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
  },

  // Mark notification as read
  markAsRead: async (req, res) => {
    const { notificationId } = req.params;

    const result = await query(
      `UPDATE notification SET is_read = true 
       WHERE id = $1 AND user_id = $2 
       RETURNING *`,
      [notificationId, req.user.id],
    );

    if (result.rows.length === 0) {
      throw new AppError('Notification not found', 404);
    }

    res.json({
      success: true,
      message: 'Notification marked as read',
      data: result.rows[0],
    });
  },

  // Mark all notifications as read
  markAllAsRead: async (req, res) => {
    await query('UPDATE notification SET is_read = true WHERE user_id = $1 AND is_read = false', [
      req.user.id,
    ]);

    res.json({
      success: true,
      message: 'All notifications marked as read',
    });
  },

  // Delete notification
  delete: async (req, res) => {
    const { notificationId } = req.params;

    const result = await query(
      'DELETE FROM notification WHERE id = $1 AND user_id = $2 RETURNING id',
      [notificationId, req.user.id],
    );

    if (result.rows.length === 0) {
      throw new AppError('Notification not found', 404);
    }

    res.json({
      success: true,
      message: 'Notification deleted successfully',
    });
  },

  // Get unread count
  getUnreadCount: async (req, res) => {
    const result = await query(
      'SELECT COUNT(*) as count FROM notification WHERE user_id = $1 AND is_read = false',
      [req.user.id],
    );

    res.json({
      success: true,
      data: {
        unread_count: parseInt(result.rows[0].count),
      },
    });
  },
};

// ============================================================================
// USER MANAGEMENT CONTROLLER (Admin)
// ============================================================================

const userController = {
  // Get all users (admin only)
  getAll: async (req, res) => {
    const { role, is_active, page = 1, limit = 50, q, state } = req.query;
    const offset = (page - 1) * limit;
    const actorIsProtectedSuperAdmin = isProtectedSuperAdminEmail(req.user?.email);

    let queryText = `
      SELECT u.id,
             u.email,
             u.full_name,
             u.phone,
             u.role,
             u.created_at,
             u.last_login,
             u.is_active,
             latest_promotion.previous_admin_role,
             latest_request.type AS latest_request_type,
             latest_account_state.account_state
      FROM "user" u
      LEFT JOIN LATERAL (
        SELECT al.old_values->>'role' AS previous_admin_role
        FROM audit_log al
        WHERE al.entity_type = 'user'
          AND al.entity_id = u.id
          AND al.action_type = 'update'
          AND al.new_values->>'role' = 'admin'
          AND al.old_values->>'role' IN ('viewer', 'contributor')
        ORDER BY al.created_at DESC
         LIMIT 1
      ) latest_promotion ON TRUE
      LEFT JOIN LATERAL (
        SELECT n.type
        FROM notification n
        WHERE n.user_id = u.id
          AND n.type IN ('contributor_request', 'contributor_rejected', 'contributor_approved')
        ORDER BY n.created_at DESC
        LIMIT 1
      ) latest_request ON TRUE
      LEFT JOIN LATERAL (
        SELECT al.new_values->>'account_state' AS account_state
        FROM audit_log al
        WHERE al.entity_type = 'user'
          AND al.entity_id = u.id
          AND al.action_type = 'update'
          AND al.new_values ? 'account_state'
        ORDER BY al.created_at DESC
        LIMIT 1
      ) latest_account_state ON TRUE
      WHERE 1=1
    `;

    const params: unknown[] = [];
    let paramIndex = 1;

    if (!actorIsProtectedSuperAdmin) {
      queryText += ` AND u.role IN ('viewer', 'contributor')`;
    }

    if (role) {
      queryText += ` AND role = $${paramIndex}`;
      params.push(role);
      paramIndex++;
    }

    if (is_active !== undefined) {
      queryText += ` AND is_active = $${paramIndex}`;
      params.push(is_active === 'true');
      paramIndex++;
    }

    if (q) {
      queryText += ` AND (u.full_name ILIKE $${paramIndex} OR u.email ILIKE $${paramIndex} OR COALESCE(u.phone, '') ILIKE $${paramIndex})`;
      params.push(`%${String(q).trim()}%`);
      paramIndex++;
    }

    if (state) {
      const normalizedState = String(state);
      if (normalizedState === 'blocked') {
        queryText += ` AND u.is_active = FALSE AND latest_account_state.account_state = 'blocked'`;
      } else if (normalizedState === 'pending') {
        queryText += ` AND u.role = 'contributor' AND u.is_active = FALSE AND COALESCE(latest_request.type, 'contributor_request') = 'contributor_request' AND COALESCE(latest_account_state.account_state, 'active') <> 'blocked'`;
      } else if (normalizedState === 'rejected') {
        queryText += ` AND u.role = 'contributor' AND u.is_active = FALSE AND latest_request.type = 'contributor_rejected' AND COALESCE(latest_account_state.account_state, 'active') <> 'blocked'`;
      } else if (normalizedState === 'active') {
        queryText += ` AND u.is_active = TRUE`;
      }
    }

    queryText += ` ORDER BY created_at DESC LIMIT $${paramIndex} OFFSET $${paramIndex + 1}`;
    params.push(limit, offset);

    const result = await query(queryText, params);

    res.json({
      success: true,
      data: result.rows.map((row) => ({
        ...row,
        is_protected_super_admin: isProtectedSuperAdminEmail(row.email),
        account_state:
          row.is_active === true
            ? 'active'
            : row.account_state === 'blocked'
              ? 'blocked'
              : row.role === 'contributor' &&
                  row.latest_request_type === 'contributor_rejected'
                ? 'rejected'
                : row.role === 'contributor'
                  ? 'pending'
                  : 'inactive',
        is_blocked: row.account_state === 'blocked',
        can_toggle_admin_role:
          !isProtectedSuperAdminEmail(row.email) &&
          (row.role === 'viewer' ||
            row.role === 'contributor' ||
            (row.role === 'admin' && Boolean(row.previous_admin_role))),
      })),
      pagination: {
        page: parseInt(page),
        limit: parseInt(limit),
      },
    });
  },

  // Get single user (admin only)
  getOne: async (req, res) => {
    const { userId } = req.params;

    const result = await query(
      `SELECT id, email, full_name, phone, role, created_at, last_login, is_active,
              profile_picture_url
       FROM "user"
       WHERE id = $1`,
      [userId],
    );

    if (result.rows.length === 0) {
      throw new AppError('User not found', 404);
    }

    res.json({
      success: true,
      data: result.rows[0],
    });
  },

  // Update user (admin only)
  updateUser: async (req, res) => {
    const { userId } = req.params;
    const { full_name, phone, role, is_active } = req.body;
    const currentUser = await getUserForAdminMutation(userId);

    assertAdminManagementAllowed({
      actorEmail: req.user?.email,
      targetEmail: currentUser.email,
      targetRole: currentUser.role,
      nextRole: role,
      nextIsActive: is_active,
    });

    const updates: string[] = [];
    const params: unknown[] = [];
    let paramIndex = 1;

    if (full_name) {
      updates.push(`full_name = $${paramIndex}`);
      params.push(full_name);
      paramIndex++;
    }
    if (phone !== undefined) {
      updates.push(`phone = $${paramIndex}`);
      params.push(phone);
      paramIndex++;
    }
    if (role) {
      updates.push(`role = $${paramIndex}`);
      params.push(role);
      paramIndex++;
    }
    if (is_active !== undefined) {
      updates.push(`is_active = $${paramIndex}`);
      params.push(is_active);
      paramIndex++;
    }

    if (updates.length === 0) {
      throw new AppError('No fields to update', 400);
    }

    params.push(userId);
    const result = await query(
      `UPDATE "user" SET ${updates.join(', ')} WHERE id = $${paramIndex} RETURNING id, email, full_name, phone, role, is_active`,
      params,
    );

    if (result.rows.length === 0) {
      throw new AppError('User not found', 404);
    }

    logger.info('User updated by admin:', { userId, adminId: req.user.id });

    res.json({
      success: true,
      message: 'User updated successfully',
      data: result.rows[0],
    });
  },

  blockUser: async (req, res) => {
    const { userId } = req.params;
    const targetUser = await getUserForAdminMutation(userId);
    const accessState = await getUserAccessState(query, {
      userId,
      role: targetUser.role,
      isActive: targetUser.is_active,
    });

    if (accessState === 'blocked') {
      throw new AppError('User account is already blocked.', 409);
    }
    if (!targetUser.is_active) {
      throw new AppError(
        'Only active accounts can be blocked. Use approval flows for pending or rejected contributors.',
        409,
      );
    }

    assertAdminManagementAllowed({
      actorEmail: req.user?.email,
      targetEmail: targetUser.email,
      targetRole: targetUser.role,
      nextIsActive: false,
    });

    const result = await query(
      `UPDATE "user"
       SET is_active = FALSE
       WHERE id = $1
       RETURNING id, email, full_name, phone, role, is_active`,
      [userId],
    );

    res.json({
      success: true,
      message: 'User blocked successfully',
      data: {
        ...result.rows[0],
        account_state: 'blocked',
        is_blocked: true,
      },
    });
  },

  unblockUser: async (req, res) => {
    const { userId } = req.params;
    const targetUser = await getUserForAdminMutation(userId);
    const latestAccountState = await getLatestAccountState(query, userId);

    if (latestAccountState !== 'blocked') {
      throw new AppError('Only blocked users can be unblocked through this action.', 409);
    }

    assertAdminManagementAllowed({
      actorEmail: req.user?.email,
      targetEmail: targetUser.email,
      targetRole: targetUser.role,
      nextIsActive: true,
    });

    const result = await query(
      `UPDATE "user"
       SET is_active = TRUE
       WHERE id = $1
       RETURNING id, email, full_name, phone, role, is_active`,
      [userId],
    );

    res.json({
      success: true,
      message: 'User unblocked successfully',
      data: {
        ...result.rows[0],
        account_state: 'active',
        is_blocked: false,
      },
    });
  },

  toggleAdminRole: async (req, res) => {
    if (!isProtectedSuperAdminEmail(req.user?.email)) {
      throw new AppError(
        'Only the protected super administrator can change admin privileges.',
        403,
      );
    }

    const { userId } = req.params;
    const currentUser = await getUserForAdminMutation(userId);

    if (isProtectedSuperAdminEmail(currentUser.email)) {
      throw new AppError(
        'The protected super administrator cannot be modified through this action.',
        403,
      );
    }

    const previousRoleResult =
      currentUser.role === 'admin'
        ? await query(
            `SELECT al.old_values->>'role' AS previous_role
             FROM audit_log al
             WHERE al.entity_type = 'user'
               AND al.entity_id = $1
               AND al.action_type = 'update'
               AND al.new_values->>'role' = 'admin'
               AND al.old_values->>'role' IN ('viewer', 'contributor')
             ORDER BY al.created_at DESC
             LIMIT 1`,
            [userId],
          )
        : { rows: [] };

    const previousRole = previousRoleResult.rows[0]?.previous_role as string | undefined;
    const nextRole =
      currentUser.role === 'admin'
        ? previousRole
        : currentUser.role === 'viewer' || currentUser.role === 'contributor'
          ? 'admin'
          : null;

    if (!nextRole) {
      throw new AppError('This user role cannot be changed through the admin toggle.', 400);
    }

    if (currentUser.role === 'admin' && !previousRole) {
      throw new AppError(
        'This admin account is fixed and cannot be reverted through the runtime toggle.',
        400,
      );
    }

    const result = await transaction(async (client) => {
      const updated = await client.query(
        `UPDATE "user"
         SET role = $1
         WHERE id = $2
         RETURNING id, email, full_name, phone, role, is_active`,
        [nextRole, userId],
      );

      await client.query(
        `INSERT INTO audit_log (user_id, action_type, entity_type, entity_id, old_values, new_values, ip_address)
         VALUES ($1, 'update', 'user', $2, $3::jsonb, $4::jsonb, $5::inet)`,
        [
          req.user?.id ?? null,
          userId,
          JSON.stringify({ role: currentUser.role }),
          JSON.stringify({
            role: nextRole,
            previous_admin_role: currentUser.role === 'admin' ? previousRole : currentUser.role,
          }),
          req.ip ?? null,
        ],
      );

      return updated.rows[0];
    });

    res.json({
      success: true,
      message:
        nextRole === 'admin'
          ? 'User promoted to admin successfully'
          : `Admin reverted to ${nextRole} successfully`,
      data: {
        ...result,
        is_protected_super_admin: false,
        previous_admin_role: nextRole === 'admin' ? currentUser.role : (previousRole ?? null),
        can_toggle_admin_role: true,
      },
    });
  },

  // Deactivate user (admin only)
  deactivate: async (req, res) => {
    const { userId } = req.params;
    const targetUser = await getUserForAdminMutation(userId);

    assertAdminManagementAllowed({
      actorEmail: req.user?.email,
      targetEmail: targetUser.email,
      targetRole: targetUser.role,
      nextIsActive: false,
    });

    const result = await query('UPDATE "user" SET is_active = false WHERE id = $1 RETURNING id', [
      userId,
    ]);

    if (result.rows.length === 0) {
      throw new AppError('User not found', 404);
    }

    logger.info('User deactivated:', { userId, deactivatedBy: req.user.id });

    res.json({
      success: true,
      message: 'User deactivated successfully',
    });
  },

  // Get user productivity stats
  getUserStats: async (req, res) => {
    const { userId } = req.params;

    const result = await query('SELECT * FROM user_productivity WHERE user_id = $1', [userId]);

    if (result.rows.length === 0) {
      throw new AppError('User not found or no activity', 404);
    }

    res.json({
      success: true,
      data: {
        ...result.rows[0],
        is_protected_super_admin: isProtectedSuperAdminEmail(result.rows[0].email),
      },
    });
  },

  getContributorRequests: async (req, res) => {
    const { status = 'pending', page = 1, limit = 50 } = req.query;
    const offset = (page - 1) * limit;

    if (!['pending', 'rejected'].includes(String(status))) {
      throw new AppError('status must be pending or rejected', 400);
    }

    const result = await query(
      `SELECT u.id,
              u.email,
              u.full_name,
              u.phone,
              u.role,
              u.created_at,
              u.last_login,
              u.is_active,
              latest_request.type AS latest_request_type,
              latest_request.created_at AS latest_request_at
       FROM "user" u
       LEFT JOIN LATERAL (
         SELECT n.type, n.created_at
         FROM notification n
         WHERE n.user_id = u.id
           AND n.type IN ('contributor_request', 'contributor_rejected', 'contributor_approved')
         ORDER BY n.created_at DESC
         LIMIT 1
       ) latest_request ON TRUE
       WHERE u.role = 'contributor'
         AND u.is_active = FALSE
         AND (
           ($1 = 'pending' AND COALESCE(latest_request.type, 'contributor_request') = 'contributor_request')
           OR ($1 = 'rejected' AND latest_request.type = 'contributor_rejected')
         )
       ORDER BY u.created_at DESC
       LIMIT $2 OFFSET $3`,
      [status, limit, offset],
    );

    res.json({
      success: true,
      data: result.rows.map((row) => ({
        ...row,
        request_status: row.latest_request_type === 'contributor_rejected' ? 'rejected' : 'pending',
        is_protected_super_admin: isProtectedSuperAdminEmail(row.email),
      })),
      pagination: {
        page: parseInt(page),
        limit: parseInt(limit),
      },
    });
  },

  createAdmin: async (req, res) => {
    if (!isProtectedSuperAdminEmail(req.user?.email)) {
      throw new AppError('Only the protected super administrator can create admin users.', 403);
    }

    const { email, password, full_name, phone } = req.body;
    const normalizedEmail = normalizeEmail(email);

    const existing = await query('SELECT id FROM "user" WHERE LOWER(email) = $1', [
      normalizedEmail,
    ]);
    if (existing.rows.length > 0) {
      throw new AppError('Email already registered', 409);
    }

    const passwordHash = await bcrypt.hash(password, 12);
    const result = await query(
      `INSERT INTO "user" (email, password_hash, full_name, phone, role, is_active)
       VALUES ($1, $2, $3, $4, 'admin', TRUE)
       RETURNING id, email, full_name, phone, role, is_active, created_at`,
      [normalizedEmail, passwordHash, full_name, phone ?? null],
    );

    logger.info('Admin user created by protected super administrator', {
      createdUserId: result.rows[0].id,
      createdBy: req.user?.id,
    });

    res.status(201).json({
      success: true,
      message: 'Admin user created successfully',
      data: {
        ...result.rows[0],
        is_protected_super_admin: false,
      },
    });
  },

  approveContributor: async (req, res) => {
    const { userId } = req.params;
    const targetUser = await getUserForAdminMutation(userId);

    if (targetUser.role !== 'contributor') {
      throw new AppError('Only contributor accounts can be approved through this action.', 409);
    }
    if (targetUser.is_active) {
      throw new AppError('Contributor account is already active.', 409);
    }

    const approvedUser = await transaction(async (client) => {
      const result = await client.query(
        `UPDATE "user"
         SET is_active = TRUE
         WHERE id = $1
         RETURNING id, email, full_name, phone, role, is_active, created_at`,
        [userId],
      );

      await createNotification(client, {
        userId,
        type: 'contributor_approved',
        title: 'Contributor access approved',
        message: 'Your contributor access request has been approved. You can now log in.',
        metadata: {
          user_id: userId,
          approved_by_user_id: req.user?.id,
        },
      });

      return result.rows[0];
    });

    logger.info('Contributor access approved', {
      userId,
      approvedBy: req.user?.id,
    });

    res.json({
      success: true,
      message: 'Contributor request approved successfully',
      data: approvedUser,
    });
  },

  rejectContributor: async (req, res) => {
    const { userId } = req.params;
    const targetUser = await getUserForAdminMutation(userId);

    if (targetUser.role !== 'contributor') {
      throw new AppError('Only contributor accounts can be rejected through this action.', 409);
    }
    if (targetUser.is_active) {
      throw new AppError(
        'Approved contributor accounts cannot be rejected through this action.',
        409,
      );
    }

    const rejectedUser = await transaction(async (client) => {
      const result = await client.query(
        `UPDATE "user"
         SET is_active = FALSE
         WHERE id = $1
         RETURNING id, email, full_name, phone, role, is_active, created_at`,
        [userId],
      );

      await createNotification(client, {
        userId,
        type: 'contributor_rejected',
        title: 'Contributor request rejected',
        message:
          'Your contributor request was rejected. You cannot log in with contributor access.',
        metadata: {
          user_id: userId,
          rejected_by_user_id: req.user?.id,
          request_status: 'rejected',
        },
      });

      return result.rows[0];
    });

    logger.info('Contributor access rejected', {
      userId,
      rejectedBy: req.user?.id,
    });

    res.json({
      success: true,
      message: 'Contributor request rejected successfully',
      data: rejectedUser,
    });
  },
};

module.exports = {
  categoryController,
  notificationController,
  userController,
};

export {};
