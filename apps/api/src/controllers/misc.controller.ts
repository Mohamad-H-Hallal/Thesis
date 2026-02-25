const { query } = require('../config/database');
const { AppError } = require('../middleware/error');
const logger = require('../utils/logger');

// ============================================================================
// CATEGORY CONTROLLER
// ============================================================================

const categoryController = {
  // Get all categories
  getAll: async (req, res) => {
    const result = await query(
      'SELECT * FROM project_category ORDER BY name ASC'
    );

    res.json({
      success: true,
      data: result.rows,
    });
  },

  // Get single category
  getOne: async (req, res) => {
    const { categoryId } = req.params;

    const result = await query(
      'SELECT * FROM project_category WHERE id = $1',
      [categoryId]
    );

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
      [name, description, icon_url]
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
      params
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

    const result = await query(
      'DELETE FROM project_category WHERE id = $1 RETURNING id',
      [categoryId]
    );

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
      [notificationId, req.user.id]
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
    await query(
      'UPDATE notification SET is_read = true WHERE user_id = $1 AND is_read = false',
      [req.user.id]
    );

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
      [notificationId, req.user.id]
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
      [req.user.id]
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
    const { role, is_active, page = 1, limit = 50 } = req.query;
    const offset = (page - 1) * limit;

    let queryText = `
      SELECT id, email, full_name, phone, role, created_at, last_login, is_active
      FROM "user"
      WHERE 1=1
    `;

    const params: unknown[] = [];
    let paramIndex = 1;

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

  // Get single user (admin only)
  getOne: async (req, res) => {
    const { userId } = req.params;

    const result = await query(
      `SELECT id, email, full_name, phone, role, created_at, last_login, is_active,
              profile_picture_url
       FROM "user"
       WHERE id = $1`,
      [userId]
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
      params
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

  // Deactivate user (admin only)
  deactivate: async (req, res) => {
    const { userId } = req.params;

    const result = await query(
      'UPDATE "user" SET is_active = false WHERE id = $1 RETURNING id',
      [userId]
    );

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

    const result = await query(
      'SELECT * FROM user_productivity WHERE user_id = $1',
      [userId]
    );

    if (result.rows.length === 0) {
      throw new AppError('User not found or no activity', 404);
    }

    res.json({
      success: true,
      data: result.rows[0],
    });
  },
};

module.exports = {
  categoryController,
  notificationController,
  userController,
};

export {};
