const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { query } = require('../config/database');
const { generateToken, generateRefreshToken } = require('../middleware/auth');
const { AppError } = require('../middleware/error');
const logger = require('../utils/logger');

// Register new user
const register = async (req, res) => {
  const { email, password, full_name, phone } = req.body;
  const publicRole = 'contributor';

  // Check if user already exists
  const existingUser = await query('SELECT id FROM "user" WHERE email = $1', [email]);

  if (existingUser.rows.length > 0) {
    throw new AppError('Email already registered', 409);
  }

  // Hash password
  const salt = await bcrypt.genSalt(12);
  const password_hash = await bcrypt.hash(password, salt);

  // Insert user
  const result = await query(
    `INSERT INTO "user" (email, password_hash, full_name, phone, role)
     VALUES ($1, $2, $3, $4, $5)
     RETURNING id, email, full_name, phone, role, created_at`,
    [email, password_hash, full_name, phone || null, publicRole]
  );

  const user = result.rows[0];

  // Generate tokens
  const token = generateToken(user.id, user.role);
  const refreshToken = generateRefreshToken(user.id);

  logger.info('User registered:', { userId: user.id, email: user.email });

  res.status(201).json({
    success: true,
    message: 'User registered successfully',
    data: {
      user: {
        id: user.id,
        email: user.email,
        full_name: user.full_name,
        phone: user.phone,
        role: user.role,
        created_at: user.created_at,
      },
      token,
      refreshToken,
    },
  });
};

// Login user
const login = async (req, res) => {
  const { email, password } = req.body;

  // Get user
  const result = await query(
    `SELECT id, email, password_hash, full_name, phone, role, is_active 
     FROM "user" WHERE email = $1`,
    [email]
  );

  if (result.rows.length === 0) {
    throw new AppError('Invalid credentials', 401);
  }

  const user = result.rows[0];

  // Check if user is active
  if (!user.is_active) {
    throw new AppError('Account is inactive', 401);
  }

  // Verify password
  const isMatch = await bcrypt.compare(password, user.password_hash);

  if (!isMatch) {
    throw new AppError('Invalid credentials', 401);
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
    data: result.rows[0],
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
    throw new AppError('User not found', 401);
  }

  const user = result.rows[0];
  if (!user.is_active) {
    throw new AppError('Account is inactive', 401);
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
    },
  });
};

module.exports = {
  register,
  login,
  getMe,
  updateMe,
  changePassword,
  logout,
  refreshToken,
};

export {};
