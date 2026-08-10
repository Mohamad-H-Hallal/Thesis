const bcrypt = require('bcryptjs');
const { query, transaction } = require('../config/database');
const { AppError } = require('../middleware/error');
const logger = require('../utils/logger');
import {
  createNotification,
  getLatestAccountState,
  getProtectedSuperAdminEmail,
  isProtectedSuperAdminEmail,
  getUserAccessState,
} from '../lib/userWorkflow';
import { isPlatformPushEnabled, isPushDeliveryConfigured } from '../lib/firebasePush';
import { notifyAccountAccessChanged } from '../lib/workflowNotifications';
import { categoryIconsDir } from '../config/upload';
import { type MemoryPhotoFile } from '../services/featurePhotoSecurity.service';
import {
  prepareQuarantinedImage,
  releaseQuarantinedImages,
} from '../services/secureImageIntake.service';
import {
  normalizeEmailAddress,
  normalizeLebaneseMobile,
} from '../services/contactIdentity.service';
import { assertPhoneAccountCapacity } from '../services/phoneAccountLimit.service';
import { isContactAssuranceSatisfied } from '../services/contactAssurancePolicy.service';

const getSupportSettingsRow = async () => {
  await query(`
    CREATE TABLE IF NOT EXISTS app_support_settings (
      id SMALLINT PRIMARY KEY CHECK (id = 1),
      support_email TEXT,
      support_phone TEXT,
      office_hours TEXT,
      help_text TEXT,
      updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_by_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL
    )
  `);

  const result = await query(
    `SELECT id, support_email, support_phone, office_hours, help_text, updated_at, updated_by_user_id
     FROM app_support_settings
     WHERE id = 1`,
  );

  if (result.rows.length > 0) {
    return result.rows[0];
  }

  const inserted = await query(
    `INSERT INTO app_support_settings (id)
     VALUES (1)
     ON CONFLICT (id) DO UPDATE SET id = EXCLUDED.id
     RETURNING id, support_email, support_phone, office_hours, help_text, updated_at, updated_by_user_id`,
  );

  return inserted.rows[0];
};

const ensureCurrentOfflineMapRow = async () => {
  const currentResult = await query(
    `SELECT id, version, zoom_level_min, zoom_level_max, downloaded_at,
            last_updated_at, tile_count, size_bytes, tile_source, is_current
     FROM lebanon_offline_map
     WHERE is_current = TRUE
     ORDER BY last_updated_at DESC
     LIMIT 1`,
  );

  if (currentResult.rows.length > 0) {
    return currentResult.rows[0];
  }

  const inserted = await query(
    `INSERT INTO lebanon_offline_map (
       version,
       zoom_level_min,
       zoom_level_max,
       tile_source,
       is_current
     )
     VALUES ($1, $2, $3, $4, TRUE)
     RETURNING id, version, zoom_level_min, zoom_level_max, downloaded_at,
               last_updated_at, tile_count, size_bytes, tile_source, is_current`,
    ['lebanon-satellite-v1', 7, 18, 'esri_world_imagery'],
  );

  return inserted.rows[0];
};

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
    const requestedPage = Number.parseInt(String(req.query.page ?? '1'), 10);
    const requestedLimit = Number.parseInt(String(req.query.limit ?? '20'), 10);
    const page = Number.isFinite(requestedPage) && requestedPage > 0 ? requestedPage : 1;
    const limit =
      Number.isFinite(requestedLimit) && requestedLimit > 0 ? Math.min(requestedLimit, 100) : 20;
    const offset = (page - 1) * limit;
    const searchQuery = String(req.query.q ?? '').trim();

    let whereClause = '';
    const params: unknown[] = [];
    let paramIndex = 1;
    if (searchQuery.length > 0) {
      whereClause = ` WHERE name ILIKE $${paramIndex} OR COALESCE(description, '') ILIKE $${paramIndex}`;
      params.push(`%${searchQuery}%`);
      paramIndex++;
    }

    const dataSql = `SELECT * FROM project_category${whereClause} ORDER BY name ASC LIMIT $${paramIndex} OFFSET $${paramIndex + 1}`;
    const countSql = `SELECT COUNT(*)::int AS total FROM project_category${whereClause}`;

    const [result, countResult] = await Promise.all([
      query(dataSql, [...params, limit, offset]),
      query(countSql, params),
    ]);
    const total = countResult.rows[0]?.total ?? 0;

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

  uploadIcon: async (req, res) => {
    const file = req.file as MemoryPhotoFile | undefined;

    if (!file) {
      throw new AppError('Category icon image is required', 400);
    }

    const prepared = await prepareQuarantinedImage(req, file, {
      kind: 'category_icon',
      uploadedByUserId: req.user.id,
    });
    const [released] = await releaseQuarantinedImages([prepared], categoryIconsDir);
    const iconUrl = `/uploads/category-icons/${released.filename}`;

    res.status(201).json({
      success: true,
      message: 'Category icon uploaded successfully',
      data: {
        icon_url: iconUrl,
        original_name: file.originalname,
        file_size_bytes: released.size,
      },
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

const settingsController = {
  getSupport: async (_req, res) => {
    const settings = await getSupportSettingsRow();

    res.json({
      success: true,
      data: settings,
      meta: {
        push_notifications: isPushDeliveryConfigured(),
        push_notifications_android: isPlatformPushEnabled('android'),
        push_notifications_ios: isPlatformPushEnabled('ios'),
        email_notifications: false,
        persisted_in_app_notifications: true,
      },
    });
  },

  updateSupport: async (req, res) => {
    if (!isProtectedSuperAdminEmail(req.user?.email)) {
      throw new AppError(
        'Only the protected super administrator can update support settings.',
        403,
      );
    }

    const { support_email, support_phone, office_hours, help_text } = req.body;
    await getSupportSettingsRow();

    const result = await query(
      `INSERT INTO app_support_settings (
         id, support_email, support_phone, office_hours, help_text, updated_at, updated_by_user_id
       )
       VALUES (1, $1, $2, $3, $4, CURRENT_TIMESTAMP, $5)
       ON CONFLICT (id) DO UPDATE
         SET support_email = EXCLUDED.support_email,
             support_phone = EXCLUDED.support_phone,
             office_hours = EXCLUDED.office_hours,
             help_text = EXCLUDED.help_text,
             updated_at = CURRENT_TIMESTAMP,
             updated_by_user_id = EXCLUDED.updated_by_user_id
       RETURNING id, support_email, support_phone, office_hours, help_text, updated_at, updated_by_user_id`,
      [
        support_email ?? null,
        support_phone ?? null,
        office_hours ?? null,
        help_text ?? null,
        req.user?.id ?? null,
      ],
    );

    res.json({
      success: true,
      message: 'Support settings updated successfully',
      data: result.rows[0],
    });
  },
};

const offlineMapController = {
  getCurrent: async (_req, res) => {
    const row = await ensureCurrentOfflineMapRow();

    res.json({
      success: true,
      data: row,
    });
  },
};

// ============================================================================
// NOTIFICATION CONTROLLER
// ============================================================================

const notificationController = {
  // Get user notifications
  getAll: async (req, res) => {
    const isReadFilter = req.query.is_read;
    const requestedPage = Number.parseInt(String(req.query.page ?? '1'), 10);
    const requestedLimit = Number.parseInt(String(req.query.limit ?? '20'), 10);
    const page = Number.isFinite(requestedPage) && requestedPage > 0 ? requestedPage : 1;
    const limit =
      Number.isFinite(requestedLimit) && requestedLimit > 0 ? Math.min(requestedLimit, 100) : 20;
    const offset = (page - 1) * limit;

    let whereClause = `
      WHERE user_id = $1
    `;

    const params = [req.user.id];
    let paramIndex = 2;

    if (isReadFilter !== undefined) {
      whereClause += ` AND is_read = $${paramIndex}`;
      params.push(isReadFilter === 'true');
      paramIndex++;
    }

    const notificationsQuery = `
      SELECT *
      FROM notification
      ${whereClause}
      ORDER BY created_at DESC
      LIMIT $${paramIndex}
      OFFSET $${paramIndex + 1}
    `;
    const countQuery = `
      SELECT COUNT(*)::int AS total
      FROM notification
      ${whereClause}
    `;

    const [result, countResultRaw] = await Promise.all([
      query(notificationsQuery, [...params, limit, offset]),
      query(countQuery, params),
    ]);
    const countResult = countResultRaw as { rows: Array<{ total?: number }> };
    const total = countResult.rows[0]?.total ?? 0;

    res.json({
      success: true,
      data: result.rows,
      pagination: {
        page,
        limit,
        total,
        has_more: offset + result.rows.length < total,
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

  markAsUnread: async (req, res) => {
    const { notificationId } = req.params;

    const result = await query(
      `UPDATE notification
       SET is_read = false
       WHERE id = $1 AND user_id = $2
       RETURNING *`,
      [notificationId, req.user.id],
    );

    if (result.rows.length === 0) {
      throw new AppError('Notification not found', 404);
    }

    res.json({
      success: true,
      message: 'Notification marked as unread',
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

  registerDevice: async (req, res) => {
    const token = String(req.body?.token ?? '').trim();
    const platform = String(req.body?.platform ?? '')
      .trim()
      .toLowerCase();
    const deviceLabel = String(req.body?.device_label ?? '').trim();
    const appVersion = String(req.body?.app_version ?? '').trim();

    const result = await query(
      `INSERT INTO push_device_registration (
         user_id,
         token,
         platform,
         device_label,
         app_version,
         notifications_enabled,
         invalidated_at,
         last_seen_at,
         updated_at
       )
       VALUES ($1, $2, $3::push_notification_platform, $4, $5, TRUE, NULL, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
       ON CONFLICT (token) DO UPDATE
       SET user_id = EXCLUDED.user_id,
           platform = EXCLUDED.platform,
           device_label = EXCLUDED.device_label,
           app_version = EXCLUDED.app_version,
           notifications_enabled = TRUE,
           invalidated_at = NULL,
           last_seen_at = CURRENT_TIMESTAMP,
           updated_at = CURRENT_TIMESTAMP
       RETURNING id, token, platform, device_label, app_version, notifications_enabled, last_seen_at`,
      [
        req.user.id,
        token,
        platform,
        deviceLabel.length > 0 ? deviceLabel : null,
        appVersion.length > 0 ? appVersion : null,
      ],
    );

    res.status(201).json({
      success: true,
      message: 'Push notifications enabled on this device.',
      data: result.rows[0],
    });
  },

  unregisterDevice: async (req, res) => {
    const token = String(req.body?.token ?? '').trim();

    const result = await query(
      `UPDATE push_device_registration
       SET notifications_enabled = FALSE,
           invalidated_at = CURRENT_TIMESTAMP,
           updated_at = CURRENT_TIMESTAMP
       WHERE user_id = $1
         AND token = $2
         AND notifications_enabled = TRUE
       RETURNING id`,
      [req.user.id, token],
    );

    res.json({
      success: true,
      message:
        result.rows.length > 0
          ? 'Push notifications disabled on this device.'
          : 'This device was already disconnected from push notifications.',
    });
  },
};

// ============================================================================
// USER MANAGEMENT CONTROLLER (Admin)
// ============================================================================

const userController = {
  getDashboardSummary: async (req, res) => {
    const actorIsProtectedSuperAdmin = isProtectedSuperAdminEmail(req.user?.email);
    const protectedEmail = getProtectedSuperAdminEmail();

    const userSummaryResult = await query(
      `SELECT COUNT(*)::integer AS total_users,
              COUNT(*) FILTER (WHERE u.role = 'admin')::integer AS admin_count,
              COUNT(*) FILTER (WHERE u.role = 'viewer')::integer AS viewer_count,
              COUNT(*) FILTER (
                WHERE u.role = 'contributor'
                  AND u.is_active = TRUE
              )::integer AS active_contributor_count,
              COUNT(*) FILTER (
                WHERE latest_account_state.account_state = 'blocked'
              )::integer AS blocked_count
       FROM "user" u
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
       WHERE LOWER(u.email) <> $1
         AND ($2::boolean = TRUE OR u.role IN ('viewer', 'contributor'))`,
      [protectedEmail, actorIsProtectedSuperAdmin],
    );

    const contributorRequestSummaryResult = await query(
      `SELECT COUNT(*) FILTER (
                WHERE COALESCE(latest_request.type, 'contributor_request') = 'contributor_request'
              )::integer AS pending_contributor_requests,
              COUNT(*) FILTER (
                WHERE latest_request.type = 'contributor_rejected'
              )::integer AS rejected_contributor_requests
       FROM "user" u
       LEFT JOIN LATERAL (
         SELECT n.type
         FROM notification n
         WHERE n.user_id = u.id
           AND n.type IN ('contributor_request', 'contributor_rejected', 'contributor_approved')
         ORDER BY n.created_at DESC
         LIMIT 1
       ) latest_request ON TRUE
       WHERE u.role = 'contributor'
         AND LOWER(u.email) <> $1
         AND u.is_active = FALSE`,
      [protectedEmail],
    );

    const [projectCountResult, pendingAssignmentsResult] = await Promise.all([
      query(`SELECT COUNT(*)::integer AS total_projects FROM project`),
      query(
        `SELECT COUNT(*)::integer AS pending_assignments
         FROM project_assignment
         WHERE status = 'pending'`,
      ),
    ]);

    res.json({
      success: true,
      data: {
        total_users: userSummaryResult.rows[0]?.total_users ?? 0,
        admin_count: userSummaryResult.rows[0]?.admin_count ?? 0,
        viewer_count: userSummaryResult.rows[0]?.viewer_count ?? 0,
        active_contributor_count: userSummaryResult.rows[0]?.active_contributor_count ?? 0,
        blocked_count: userSummaryResult.rows[0]?.blocked_count ?? 0,
        pending_contributor_requests:
          contributorRequestSummaryResult.rows[0]?.pending_contributor_requests ?? 0,
        rejected_contributor_requests:
          contributorRequestSummaryResult.rows[0]?.rejected_contributor_requests ?? 0,
        total_projects: projectCountResult.rows[0]?.total_projects ?? 0,
        pending_assignments: pendingAssignmentsResult.rows[0]?.pending_assignments ?? 0,
      },
    });
  },

  // Get all users (admin only)
  getAll: async (req, res) => {
    const { role, is_active, page = 1, limit = 50, q, state } = req.query;
    const offset = (page - 1) * limit;
    const actorIsProtectedSuperAdmin = isProtectedSuperAdminEmail(req.user?.email);
    const protectedEmail = getProtectedSuperAdminEmail();

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
             latest_account_state.account_state,
             approved_assignment_summary.approved_assignment_count
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
      LEFT JOIN LATERAL (
        SELECT COUNT(*)::integer AS approved_assignment_count
        FROM project_assignment pa
        WHERE pa.user_id = u.id
          AND pa.role = 'contributor'
          AND pa.status = 'approved'
      ) approved_assignment_summary ON TRUE
      WHERE 1=1
    `;

    const params: unknown[] = [];
    let paramIndex = 1;

    if (protectedEmail) {
      queryText += ` AND LOWER(u.email) <> $${paramIndex}`;
      params.push(protectedEmail);
      paramIndex++;
    }

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
      } else if (normalizedState === 'inactive') {
        queryText += ` AND u.is_active = FALSE AND latest_account_state.account_state = 'inactive'`;
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

    let countQuery = `
      SELECT COUNT(*)::int AS total
      FROM "user" u
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

    const countParams: unknown[] = [];
    let countParamIndex = 1;

    if (protectedEmail) {
      countQuery += ` AND LOWER(u.email) <> $${countParamIndex}`;
      countParams.push(protectedEmail);
      countParamIndex++;
    }

    if (!actorIsProtectedSuperAdmin) {
      countQuery += ` AND u.role IN ('viewer', 'contributor')`;
    }

    if (role) {
      countQuery += ` AND role = $${countParamIndex}`;
      countParams.push(role);
      countParamIndex++;
    }

    if (is_active !== undefined) {
      countQuery += ` AND is_active = $${countParamIndex}`;
      countParams.push(is_active === 'true');
      countParamIndex++;
    }

    if (q) {
      countQuery += ` AND (u.full_name ILIKE $${countParamIndex} OR u.email ILIKE $${countParamIndex} OR COALESCE(u.phone, '') ILIKE $${countParamIndex})`;
      countParams.push(`%${String(q).trim()}%`);
      countParamIndex++;
    }

    if (state) {
      const normalizedState = String(state);
      if (normalizedState === 'blocked') {
        countQuery += ` AND u.is_active = FALSE AND latest_account_state.account_state = 'blocked'`;
      } else if (normalizedState === 'inactive') {
        countQuery += ` AND u.is_active = FALSE AND latest_account_state.account_state = 'inactive'`;
      } else if (normalizedState === 'pending') {
        countQuery += ` AND u.role = 'contributor' AND u.is_active = FALSE AND COALESCE(latest_request.type, 'contributor_request') = 'contributor_request' AND COALESCE(latest_account_state.account_state, 'active') <> 'blocked'`;
      } else if (normalizedState === 'rejected') {
        countQuery += ` AND u.role = 'contributor' AND u.is_active = FALSE AND latest_request.type = 'contributor_rejected' AND COALESCE(latest_account_state.account_state, 'active') <> 'blocked'`;
      } else if (normalizedState === 'active') {
        countQuery += ` AND u.is_active = TRUE`;
      }
    }

    const countResult = await query(countQuery, countParams);
    const total = countResult.rows[0]?.total ?? 0;

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
              : row.account_state === 'inactive'
                ? 'inactive'
                : row.role === 'contributor' && row.latest_request_type === 'contributor_rejected'
                  ? 'rejected'
                  : row.role === 'contributor'
                    ? 'pending'
                    : 'inactive',
        is_blocked: row.account_state === 'blocked',
        approved_assignment_count: row.approved_assignment_count ?? 0,
        can_toggle_admin_role:
          !isProtectedSuperAdminEmail(row.email) &&
          (row.is_active === true || row.account_state === 'active') &&
          (row.role === 'viewer' ||
            row.role === 'contributor' ||
            (row.role === 'admin' && Boolean(row.previous_admin_role))),
      })),
      pagination: {
        page: parseInt(page),
        limit: parseInt(limit),
        total,
        totalPages: Math.max(1, Math.ceil(total / limit)),
        has_more: offset + result.rows.length < total,
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

    if (isProtectedSuperAdminEmail(result.rows[0].email)) {
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
      throw new AppError(
        "An administrator cannot mark another user's mobile number as verified. The user must change and verify it through their account.",
        400,
        {
          code: 'CONTACT_CHANGE_VERIFICATION_REQUIRED',
          disposition: 'permanent_rejection',
          retryable: false,
        },
      );
    }
    if (role) {
      updates.push(`role = $${paramIndex}`);
      params.push(role);
      paramIndex++;
    }
    if (is_active !== undefined) {
      if (is_active === true) {
        const verification = await query(
          `SELECT role, email_verified_at, phone_verified_at, phone_format_validated_at,
                  contact_verification_exempted_at
           FROM "user" WHERE id = $1`,
          [userId],
        );
        if (!verification.rows[0] || !isContactAssuranceSatisfied(verification.rows[0])) {
          throw new AppError(
            'Required contact assurance must be completed before activation.',
            409,
            {
              code: 'CONTACT_VERIFICATION_REQUIRED',
              disposition: 'permanent_rejection',
              retryable: false,
            },
          );
        }
      }
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

    await notifyAccountAccessChanged(query, {
      userId,
      eventKey: `account:${userId}:blocked:${Date.now()}`,
      title: 'Account access blocked',
      message:
        'An administrator blocked your TerraLeb account. Contact support if you believe this was unexpected.',
      accountState: 'blocked',
      role: targetUser.role,
      changedByUserId: req.user?.id,
    });

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

    const verification = await query(
      `SELECT role, email_verified_at, phone_verified_at, phone_format_validated_at,
              contact_verification_exempted_at
       FROM "user"
       WHERE id = $1`,
      [userId],
    );
    if (!verification.rows[0] || !isContactAssuranceSatisfied(verification.rows[0])) {
      throw new AppError(
        'Required contact assurance must be completed before the account can be unblocked.',
        409,
        {
          code: 'CONTACT_VERIFICATION_REQUIRED',
          disposition: 'permanent_rejection',
          retryable: false,
        },
      );
    }

    const result = await query(
      `UPDATE "user"
       SET is_active = TRUE, account_status = 'active'
       WHERE id = $1
       RETURNING id, email, full_name, phone, role, is_active`,
      [userId],
    );

    await notifyAccountAccessChanged(query, {
      userId,
      eventKey: `account:${userId}:unblocked:${Date.now()}`,
      title: 'Account access restored',
      message: 'An administrator restored access to your TerraLeb account.',
      accountState: 'active',
      role: targetUser.role,
      changedByUserId: req.user?.id,
    });

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

    const accessState = await getUserAccessState(query, {
      userId,
      role: currentUser.role,
      isActive: currentUser.is_active,
    });
    const forceUnassign = req.body?.force_unassign === true;
    if (accessState === 'blocked') {
      throw new AppError('Blocked users must be unblocked before changing roles.', 409);
    }
    if (accessState === 'rejected') {
      throw new AppError('Rejected contributors cannot be promoted until re-approved.', 409);
    }
    if (accessState === 'inactive') {
      throw new AppError('Deactivated users must reactivate before changing roles.', 409);
    }
    if (accessState === 'pending') {
      throw new AppError('Pending contributors cannot be promoted until approved.', 409);
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

    const approvedAssignmentCountResult = await query(
      `SELECT COUNT(*)::integer AS approved_assignment_count
       FROM project_assignment
       WHERE user_id = $1
         AND role = 'contributor'
         AND status = 'approved'`,
      [userId],
    );
    const approvedAssignmentCount =
      approvedAssignmentCountResult.rows[0]?.approved_assignment_count ?? 0;

    if (
      currentUser.role === 'contributor' &&
      nextRole === 'admin' &&
      approvedAssignmentCount > 0 &&
      !forceUnassign
    ) {
      throw new AppError(
        `This contributor is assigned to ${approvedAssignmentCount} project(s). Confirm promotion to admin to unassign them first.`,
        409,
      );
    }

    const result = await transaction(async (client) => {
      let removedAssignmentCount = 0;
      if (currentUser.role === 'contributor' && nextRole === 'admin') {
        const removedAssignments = await client.query(
          `DELETE FROM project_assignment
           WHERE user_id = $1
             AND role = 'contributor'
             AND status = 'approved'
           RETURNING id`,
          [userId],
        );
        removedAssignmentCount = removedAssignments.rowCount ?? 0;
      }

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

      await notifyAccountAccessChanged(client, {
        userId,
        eventKey: `account:${userId}:role:${currentUser.role}:${nextRole}:${Date.now()}`,
        title: 'Account role changed',
        message: `Your TerraLeb account role changed from ${currentUser.role} to ${nextRole}.`,
        accountState: 'active',
        role: nextRole,
        changedByUserId: req.user?.id,
      });

      return {
        ...updated.rows[0],
        approved_assignment_count: 0,
        unassigned_assignment_count: removedAssignmentCount,
      };
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
        approved_assignment_count: result.approved_assignment_count ?? 0,
        unassigned_assignment_count: result.unassigned_assignment_count ?? 0,
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

    await notifyAccountAccessChanged(query, {
      userId,
      eventKey: `account:${userId}:deactivated:${Date.now()}`,
      title: 'Account deactivated',
      message: 'An administrator deactivated your TerraLeb account.',
      accountState: 'inactive',
      role: targetUser.role,
      changedByUserId: req.user?.id,
    });

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
    const { status = 'pending', q, page = 1, limit = 50 } = req.query;
    const offset = (page - 1) * limit;

    if (!['pending', 'rejected'].includes(String(status))) {
      throw new AppError('status must be pending or rejected', 400);
    }

    const whereClauses = [
      `u.role = 'contributor'`,
      `LOWER(u.email) <> $2`,
      `u.is_active = FALSE`,
      `(
        ($1 = 'pending' AND COALESCE(latest_request.type, 'contributor_request') = 'contributor_request')
        OR ($1 = 'rejected' AND latest_request.type = 'contributor_rejected')
      )`,
    ];
    const queryParams: unknown[] = [status, getProtectedSuperAdminEmail()];
    let queryParamIndex = 3;

    if (q) {
      whereClauses.push(`(
        u.full_name ILIKE $${queryParamIndex}
        OR COALESCE(u.email, '') ILIKE $${queryParamIndex}
        OR COALESCE(u.phone, '') ILIKE $${queryParamIndex}
      )`);
      queryParams.push(`%${String(q).trim()}%`);
      queryParamIndex++;
    }

    const baseSql = `FROM "user" u
       LEFT JOIN LATERAL (
         SELECT n.type, n.created_at
         FROM notification n
         WHERE n.user_id = u.id
           AND n.type IN ('contributor_request', 'contributor_rejected', 'contributor_approved')
         ORDER BY n.created_at DESC
         LIMIT 1
       ) latest_request ON TRUE
       WHERE ${whereClauses.join('\n         AND ')}`;

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
       ${baseSql}
       ORDER BY u.created_at DESC
       LIMIT $${queryParamIndex} OFFSET $${queryParamIndex + 1}`,
      [...queryParams, limit, offset],
    );

    const countResult = await query(
      `SELECT COUNT(*)::int AS total
       ${baseSql}`,
      queryParams,
    );
    const total = countResult.rows[0]?.total ?? 0;

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
        total,
        totalPages: Math.max(1, Math.ceil(total / limit)),
        has_more: offset + result.rows.length < total,
      },
    });
  },

  createAdmin: async (req, res) => {
    if (!isProtectedSuperAdminEmail(req.user?.email)) {
      throw new AppError('Only the protected super administrator can create admin users.', 403);
    }

    const { email, password, full_name, phone } = req.body;
    const normalizedEmail = normalizeEmailAddress(email);
    const normalizedPhone = phone == null ? null : normalizeLebaneseMobile(phone);
    if (!normalizedEmail || (phone != null && !normalizedPhone)) {
      throw new AppError('Enter valid account contact details.', 400);
    }

    const existing = await query(
      `SELECT id FROM "user"
       WHERE email_canonical = $1
       LIMIT 1`,
      [normalizedEmail.canonical],
    );
    if (existing.rows.length > 0) {
      throw new AppError('An account already uses this email address.', 409, {
        code: 'EMAIL_ALREADY_IN_USE',
        disposition: 'permanent_rejection',
        retryable: false,
      });
    }

    const passwordHash = await bcrypt.hash(password, 12);
    const result = await transaction(async (client) => {
      if (normalizedPhone) {
        await assertPhoneAccountCapacity(client, normalizedPhone.e164);
      }
      return client.query(
        `INSERT INTO "user"
           (email, email_original, email_canonical, password_hash, full_name,
            phone, phone_e164, phone_format_validated_at, phone_validation_method,
            role, is_active, account_status, verification_required_at,
            contact_verification_exempted_at, contact_verification_exempted_by)
         VALUES ($1, $1, $2, $3, $4, $5::text, $5::text,
                 CASE WHEN $5::text IS NULL THEN NULL ELSE CURRENT_TIMESTAMP END,
                 CASE WHEN $5::text IS NULL THEN NULL ELSE 'libphonenumber_max' END,
                 'admin', TRUE, 'active', NULL, CURRENT_TIMESTAMP, $6)
         RETURNING id, email, email_original, email_canonical, email_verified_at,
                   full_name, phone, phone_e164, phone_verified_at, role, is_active,
                   account_status, auth_version, created_at,
                   contact_verification_exempted_at, contact_verification_exempted_by`,
        [
          normalizedEmail.original,
          normalizedEmail.canonical,
          passwordHash,
          full_name,
          normalizedPhone?.e164 ?? null,
          req.user.id,
        ],
      );
    });

    logger.info('Admin user created by protected super administrator', {
      createdUserId: result.rows[0].id,
      createdBy: req.user?.id,
    });

    res.status(201).json({
      success: true,
      message: 'Admin account created and activated.',
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

    const verification = await query(
      `SELECT role, email_verified_at, phone_verified_at, phone_format_validated_at,
              contact_verification_exempted_at
       FROM "user" WHERE id = $1`,
      [userId],
    );
    if (!verification.rows[0] || !isContactAssuranceSatisfied(verification.rows[0])) {
      throw new AppError(
        'The contributor must complete the configured contact assurance before approval.',
        409,
        {
          code: 'CONTACT_VERIFICATION_REQUIRED',
          disposition: 'permanent_rejection',
          retryable: false,
        },
      );
    }

    const approvedUser = await transaction(async (client) => {
      const result = await client.query(
        `UPDATE "user"
         SET is_active = TRUE, account_status = 'active'
         WHERE id = $1
         RETURNING id, email, full_name, phone, role, is_active, created_at`,
        [userId],
      );

      await createNotification(client, {
        userId,
        type: 'contributor_approved',
        title: 'Contributor access approved',
        message:
          'Your contributor access request was approved. You can now sign in and use contributor tools.',
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
          'Your contributor request was rejected. Contributor login stays unavailable until an administrator changes this decision.',
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
  offlineMapController,
  settingsController,
  userController,
};

export {};
