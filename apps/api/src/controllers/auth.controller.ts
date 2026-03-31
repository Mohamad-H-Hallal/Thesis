const bcrypt = require('bcryptjs');
const crypto = require('crypto');
const jwt = require('jsonwebtoken');
const { query, transaction } = require('../config/database');
const { generateToken, generateRefreshToken } = require('../middleware/auth');
const { AppError } = require('../middleware/error');
const logger = require('../utils/logger');
import {
  getUserAccessState,
  isProtectedSuperAdminEmail,
  normalizeEmail,
  notifyActiveAdminsAboutContributorRequest,
  notifyContributorRequestSubmitted,
} from '../lib/userWorkflow';
import { sendPasswordResetOtpEmail } from '../lib/mailer';

const passwordResetExpiryMinutes = Number(
  process.env.PASSWORD_RESET_TOKEN_EXPIRY_MINUTES || 15,
);
const passwordResetSessionExpiryMinutes = 10;

const hashResetToken = (token: string) =>
  crypto.createHash('sha256').update(token).digest('hex');

const generateResetToken = () =>
  crypto.randomInt(0, 1000000).toString().padStart(6, '0');

const getPasswordResetSessionSecret = (): string => {
  const baseSecret =
    process.env.JWT_SECRET_CURRENT || process.env.JWT_SECRET;
  if (!baseSecret) {
    throw new AppError(
      'Password reset service is unavailable right now. Please contact support.',
      503,
    );
  }
  return `${baseSecret}:password-reset`;
};

const generatePasswordResetSessionToken = ({
  resetRequestId,
  userId,
  email,
}: {
  resetRequestId: string;
  userId: string;
  email: string;
}): string =>
  jwt.sign(
    {
      purpose: 'password_reset',
      resetRequestId,
      userId,
      email,
    },
    getPasswordResetSessionSecret(),
    { expiresIn: `${passwordResetSessionExpiryMinutes}m` },
  );

const verifyPasswordResetSessionToken = (
  resetToken: string,
): { resetRequestId: string; userId: string; email: string } => {
  let decoded: any;
  try {
    decoded = jwt.verify(resetToken, getPasswordResetSessionSecret());
  } catch (_error) {
    throw new AppError(
      'Password reset session is invalid or expired. Please request a new verification code.',
      400,
    );
  }

  if (
    !decoded ||
    typeof decoded !== 'object' ||
    decoded.purpose !== 'password_reset' ||
    typeof decoded.resetRequestId !== 'string' ||
    typeof decoded.userId !== 'string' ||
    typeof decoded.email !== 'string'
  ) {
    throw new AppError(
      'Password reset session is invalid or expired. Please request a new verification code.',
      400,
    );
  }

  return {
    resetRequestId: decoded.resetRequestId,
    userId: decoded.userId,
    email: decoded.email,
  };
};

// Register new user
const register = async (req, res) => {
  const { email, password, full_name, phone, role } = req.body;
  const normalizedEmail = normalizeEmail(email);
  const publicRole = role === 'viewer' ? 'viewer' : 'contributor';
  const isActive = publicRole === 'viewer';

  // Check if user already exists
  const existingUser = await query('SELECT id FROM "user" WHERE LOWER(email) = $1', [
    normalizedEmail,
  ]);

  if (existingUser.rows.length > 0) {
    throw new AppError('Email already registered', 409);
  }

  // Hash password
  const salt = await bcrypt.genSalt(12);
  const password_hash = await bcrypt.hash(password, salt);

  const user = await transaction(async (client) => {
    const result = await client.query(
      `INSERT INTO "user" (email, password_hash, full_name, phone, role, is_active)
       VALUES ($1, $2, $3, $4, $5::user_role, $6)
       RETURNING id, email, full_name, phone, role, is_active, created_at`,
      [normalizedEmail, password_hash, full_name, phone, publicRole, isActive]
    );

    const createdUser = result.rows[0];

    if (publicRole === 'contributor') {
      await notifyActiveAdminsAboutContributorRequest(client, {
        userId: createdUser.id,
        fullName: createdUser.full_name,
        email: createdUser.email,
      });
      await notifyContributorRequestSubmitted(client, {
        userId: createdUser.id,
        fullName: createdUser.full_name,
        email: createdUser.email,
      });
    }

    return createdUser;
  });

  logger.info('User registered:', { userId: user.id, email: user.email });

  res.status(201).json({
    success: true,
    message:
      publicRole === 'contributor'
        ? 'Account created successfully. Your contributor request is pending admin approval.'
        : 'Account created successfully. You can log in now.',
    data: {
      user: {
        id: user.id,
        email: user.email,
        full_name: user.full_name,
        phone: user.phone,
        role: user.role,
        is_active: user.is_active,
        created_at: user.created_at,
      },
    },
  });
};

// Login user
const login = async (req, res) => {
  const { email, password } = req.body;

  // Get user
  const result = await query(
    `SELECT id, email, password_hash, full_name, phone, role, is_active 
     FROM "user" WHERE LOWER(email) = $1`,
    [normalizeEmail(email)]
  );

  if (result.rows.length === 0) {
    throw new AppError('This account does not exist.', 404);
  }

  const user = result.rows[0];

  // Verify password
  const isMatch = await bcrypt.compare(password, user.password_hash);

  if (!isMatch) {
    throw new AppError('Wrong email or password.', 401);
  }

  if (!user.is_active) {
    const accessState = await getUserAccessState(query, {
      userId: user.id,
      role: user.role,
      isActive: user.is_active,
    });
    if (accessState === 'blocked') {
      throw new AppError('Your account has been blocked.', 403);
    }
    if (accessState === 'rejected') {
      throw new AppError(
        'Your contributor request was rejected. You cannot log in with contributor access.',
        403
      );
    }
    if (accessState === 'pending') {
      throw new AppError(
        'Your contributor request is still pending approval. You cannot log in yet.',
        403
      );
    }
    if (accessState === 'inactive' && user.role === 'contributor') {
      throw new AppError(
        'Your contributor account is deactivated. Activate it to continue logging in.',
        403
      );
    }
    throw new AppError('This account is inactive.', 403);
  }

  // Update last login
  await query('UPDATE "user" SET last_login = CURRENT_TIMESTAMP WHERE id = $1', [
    user.id,
  ]);

  // Generate tokens
  const token = generateToken(user.id, user.role);
  const refreshToken = generateRefreshToken(user.id);

  logger.info('User logged in:', { userId: user.id, email: user.email });

  res.json({
    success: true,
    message: 'Login successful',
    data: {
      user: {
        id: user.id,
        email: user.email,
        full_name: user.full_name,
        phone: user.phone,
        role: user.role,
        is_protected_super_admin: isProtectedSuperAdminEmail(user.email),
      },
      token,
      refreshToken,
    },
  });
};

// Get current user profile
const getMe = async (req, res) => {
  const result = await query(
    `SELECT id, email, full_name, phone, role, created_at, last_login, profile_picture_url
     FROM "user" WHERE id = $1`,
    [req.user.id]
  );

  res.json({
    success: true,
    data: {
      ...result.rows[0],
      is_protected_super_admin: isProtectedSuperAdminEmail(req.user?.email),
    },
  });
};

// Update current user profile
const updateMe = async (req, res) => {
  const { full_name, phone } = req.body;

  const result = await query(
    `UPDATE "user" 
     SET full_name = COALESCE($1, full_name),
         phone = COALESCE($2, phone)
     WHERE id = $3
     RETURNING id, email, full_name, phone, role, profile_picture_url`,
    [full_name, phone, req.user.id]
  );

  logger.info('User profile updated:', { userId: req.user.id });

  res.json({
    success: true,
    message: 'Profile updated successfully',
    data: result.rows[0],
  });
};

// Change password
const changePassword = async (req, res) => {
  const { current_password, new_password } = req.body;

  // Get user with password
  const result = await query(
    'SELECT password_hash FROM "user" WHERE id = $1',
    [req.user.id]
  );

  const user = result.rows[0];

  // Verify current password
  const isMatch = await bcrypt.compare(current_password, user.password_hash);

  if (!isMatch) {
    throw new AppError('Current password is incorrect', 401);
  }

  // Hash new password
  const salt = await bcrypt.genSalt(12);
  const password_hash = await bcrypt.hash(new_password, salt);

  // Update password
  await query('UPDATE "user" SET password_hash = $1 WHERE id = $2', [
    password_hash,
    req.user.id,
  ]);

  logger.info('Password changed:', { userId: req.user.id });

  res.json({
    success: true,
    message: 'Password changed successfully',
  });
};

const reactivateContributorLogin = async (req, res) => {
  const { email, password } = req.body;

  const result = await query(
    `SELECT id, email, password_hash, full_name, phone, role, is_active
     FROM "user"
     WHERE LOWER(email) = $1`,
    [normalizeEmail(email)]
  );

  if (result.rows.length === 0) {
    throw new AppError('This account does not exist.', 404);
  }

  const user = result.rows[0];
  const isMatch = await bcrypt.compare(password, user.password_hash);

  if (!isMatch) {
    throw new AppError('Wrong email or password.', 401);
  }

  if (user.role !== 'contributor') {
    throw new AppError(
      'Only contributor accounts can use this reactivation flow.',
      403
    );
  }

  const accessState = await getUserAccessState(query, {
    userId: user.id,
    role: user.role,
    isActive: user.is_active,
  });

  if (accessState === 'blocked') {
    throw new AppError('Your account has been blocked.', 403);
  }
  if (accessState === 'rejected') {
    throw new AppError(
      'Your contributor request was rejected. You cannot log in with contributor access.',
      403
    );
  }
  if (accessState === 'pending') {
    throw new AppError(
      'Your contributor request is still pending approval. You cannot log in yet.',
      403
    );
  }

  if (accessState === 'inactive') {
    await query(
      `UPDATE "user"
       SET is_active = TRUE,
           last_login = CURRENT_TIMESTAMP
       WHERE id = $1`,
      [user.id],
    );
  } else {
    await query(
      'UPDATE "user" SET last_login = CURRENT_TIMESTAMP WHERE id = $1',
      [user.id],
    );
  }

  const token = generateToken(user.id, user.role);
  const refreshToken = generateRefreshToken(user.id);

  logger.info('Contributor account reactivated through login flow', {
    userId: user.id,
    email: user.email,
    wasInactive: accessState === 'inactive',
  });

  res.json({
    success: true,
    message:
      accessState === 'inactive'
        ? 'Account reactivated and login successful'
        : 'Login successful',
    data: {
      user: {
        id: user.id,
        email: user.email,
        full_name: user.full_name,
        phone: user.phone,
        role: user.role,
        is_protected_super_admin: isProtectedSuperAdminEmail(user.email),
      },
      token,
      refreshToken,
    },
  });
};

const requestPasswordReset = async (req, res) => {
  const normalizedEmail = normalizeEmail(req.body?.email);

  const result = await query(
    `SELECT id, email, full_name
     FROM "user"
     WHERE LOWER(email) = $1
     LIMIT 1`,
    [normalizedEmail],
  );

  if (result.rows.length === 0) {
    throw new AppError('This account does not exist.', 404);
  }

  const user = result.rows[0];
  const resetToken = generateResetToken();
  const expiresAt = new Date(Date.now() + passwordResetExpiryMinutes * 60 * 1000);

  await transaction(async (client) => {
    await client.query(
      `UPDATE password_reset_request
       SET used_at = CURRENT_TIMESTAMP
       WHERE user_id = $1
         AND used_at IS NULL`,
      [user.id],
    );

    await client.query(
      `INSERT INTO password_reset_request (user_id, token_hash, expires_at, requested_from_ip)
       VALUES ($1, $2, $3, $4::inet)`,
      [user.id, hashResetToken(resetToken), expiresAt, req.ip ?? null],
    );
    await sendPasswordResetOtpEmail({
      toEmail: user.email,
      recipientName: user.full_name ?? 'User',
      otp: resetToken,
      expiresInMinutes: passwordResetExpiryMinutes,
    });
  });

  logger.info('Password reset requested', {
    userId: user.id,
    email: user.email,
    expiresAt: expiresAt.toISOString(),
  });

  res.json({
    success: true,
    message: 'A verification code has been sent to your email.',
    data: {
      delivery: 'email',
      expires_at: expiresAt.toISOString(),
      email: user.email,
    },
  });
};

const verifyPasswordResetOtp = async (req, res) => {
  const { email, otp } = req.body;
  const normalizedEmail = normalizeEmail(email);

  const resetRequestResult = await query(
    `SELECT prr.id, prr.user_id, u.email
     FROM password_reset_request prr
     JOIN "user" u ON u.id = prr.user_id
     WHERE LOWER(u.email) = $1
       AND prr.token_hash = $2
       AND prr.used_at IS NULL
       AND prr.expires_at >= CURRENT_TIMESTAMP
     ORDER BY prr.created_at DESC
     LIMIT 1`,
    [normalizedEmail, hashResetToken(otp)],
  );

  if (resetRequestResult.rows.length === 0) {
    throw new AppError('Verification code is invalid or expired.', 400);
  }

  const resetRequest = resetRequestResult.rows[0];
  const sessionToken = generatePasswordResetSessionToken({
    resetRequestId: resetRequest.id,
    userId: resetRequest.user_id,
    email: resetRequest.email,
  });

  logger.info('Password reset OTP verified', {
    userId: resetRequest.user_id,
    email: resetRequest.email,
  });

  res.json({
    success: true,
    message: 'Verification code confirmed.',
    data: {
      reset_token: sessionToken,
      email: resetRequest.email,
    },
  });
};

const resetPassword = async (req, res) => {
  const { reset_token, new_password } = req.body;
  const verifiedSession = verifyPasswordResetSessionToken(reset_token);

  const resetRequestResult = await query(
    `SELECT prr.id, prr.user_id, prr.used_at, prr.expires_at, u.email
     FROM password_reset_request prr
     JOIN "user" u ON u.id = prr.user_id
     WHERE prr.id = $1
       AND prr.user_id = $2
       AND LOWER(u.email) = $3
     LIMIT 1`,
    [
      verifiedSession.resetRequestId,
      verifiedSession.userId,
      normalizeEmail(verifiedSession.email),
    ],
  );

  if (resetRequestResult.rows.length === 0) {
    throw new AppError(
      'Password reset session is invalid or expired. Please request a new verification code.',
      400,
    );
  }

  const resetRequest = resetRequestResult.rows[0];
  if (
    resetRequest.used_at != null ||
    new Date(resetRequest.expires_at).getTime() < Date.now()
  ) {
    throw new AppError(
      'Password reset session is invalid or expired. Please request a new verification code.',
      400,
    );
  }

  const salt = await bcrypt.genSalt(12);
  const password_hash = await bcrypt.hash(new_password, salt);

  await transaction(async (client) => {
    await client.query(
      `UPDATE "user"
       SET password_hash = $1
       WHERE id = $2`,
      [password_hash, resetRequest.user_id],
    );

    await client.query(
      `UPDATE password_reset_request
       SET used_at = CURRENT_TIMESTAMP
       WHERE user_id = $1
         AND used_at IS NULL`,
      [resetRequest.user_id],
    );
  });

  logger.info('Password reset completed', {
    userId: resetRequest.user_id,
    email: resetRequest.email,
  });

  res.json({
    success: true,
    message: 'Password has been changed successfully.',
  });
};

// Logout (client-side token deletion, but we log it)
const logout = async (req, res) => {
  logger.info('User logged out:', { userId: req.user.id });

  res.json({
    success: true,
    message: 'Logout successful',
  });
};

// Refresh token
const refreshToken = async (req, res) => {
  const { refresh_token } = req.body;

  let decoded: any;
  const refreshSecrets = [
    process.env.JWT_REFRESH_SECRET_CURRENT || process.env.JWT_REFRESH_SECRET,
    ...((process.env.JWT_REFRESH_SECRET_PREVIOUS || '')
      .split(',')
      .map((value: string) => value.trim())
      .filter(Boolean)),
  ].filter(Boolean) as string[];

  try {
    let lastError: unknown = null;
    for (const secret of refreshSecrets) {
      try {
        decoded = jwt.verify(refresh_token, secret);
        break;
      } catch (error) {
        lastError = error;
      }
    }
    if (!decoded) {
      throw lastError ?? new Error('refresh token verification failed');
    }
  } catch (_error) {
    throw new AppError('Invalid or expired refresh token', 401);
  }

  const result = await query(
    `SELECT id, email, full_name, phone, role, is_active
     FROM "user" WHERE id = $1`,
    [decoded.userId]
  );

  if (result.rows.length === 0) {
    throw new AppError('This account does not exist.', 404);
  }

  const user = result.rows[0];
  if (!user.is_active) {
    const accessState = await getUserAccessState(query, {
      userId: user.id,
      role: user.role,
      isActive: user.is_active,
    });
    if (accessState === 'blocked') {
      throw new AppError('Your account has been blocked.', 403);
    }
    if (accessState === 'rejected') {
      throw new AppError(
        'Your contributor request was rejected. You cannot log in with contributor access.',
        403
      );
    }
    if (accessState === 'pending') {
      throw new AppError(
        'Your contributor request is still pending approval. You cannot log in yet.',
        403
      );
    }
    if (accessState === 'inactive' && user.role === 'contributor') {
      throw new AppError(
        'Your contributor account is deactivated. Activate it to continue logging in.',
        403
      );
    }
    throw new AppError('This account is inactive.', 403);
  }

  const token = generateToken(user.id, user.role);
  const newRefreshToken = generateRefreshToken(user.id);

  logger.info('Token refreshed:', { userId: user.id });

  res.json({
    success: true,
    message: 'Token refreshed',
    data: {
      token,
      refreshToken: newRefreshToken,
      user: {
        id: user.id,
        email: user.email,
        full_name: user.full_name,
        phone: user.phone,
        role: user.role,
        is_protected_super_admin: isProtectedSuperAdminEmail(user.email),
      },
    },
  });
};

const selfDeactivate = async (req, res) => {
  if (!req.user) {
    throw new AppError('Not authenticated', 401);
  }

  if (req.user.role !== 'contributor') {
    throw new AppError(
      'Only contributor accounts can self-deactivate through the mobile profile flow.',
      403,
    );
  }

  const blockingAssignments = await query(
    `SELECT pa.id
     FROM project_assignment pa
     JOIN project p ON p.id = pa.project_id
     WHERE pa.user_id = $1
       AND pa.role = 'contributor'
       AND pa.status = 'approved'
       AND p.status IN ('draft', 'active', 'paused')
     LIMIT 1`,
    [req.user.id],
  );

  if (blockingAssignments.rows.length > 0) {
    throw new AppError(
      'You cannot deactivate your account while you still have active project assignments.',
      409,
    );
  }

  await query(
    `UPDATE "user"
     SET is_active = FALSE
     WHERE id = $1`,
    [req.user.id],
  );

  logger.info('User self-deactivated account', { userId: req.user.id });

  res.json({
    success: true,
    message: 'Your account was deactivated successfully.',
  });
};

module.exports = {
  register,
  login,
  getMe,
  updateMe,
  changePassword,
  requestPasswordReset,
  verifyPasswordResetOtp,
  resetPassword,
  reactivateContributorLogin,
  logout,
  selfDeactivate,
  refreshToken,
};

export {};
