const bcrypt = require('bcryptjs');
const crypto = require('crypto');
const jwt = require('jsonwebtoken');
const { query, transaction } = require('../config/database');
const { AppError, permanentOfflineSyncError } = require('../middleware/error');
const logger = require('../utils/logger');
import {
  createAuthenticatedSession,
  replaceCurrentSessionAfterSecurityChange,
  revokeAllUserSessions,
  revokeSession,
  rotateRefreshToken,
} from '../services/authSession.service';
import { tokenAlgorithm, tokenAudience, tokenIssuer } from '../services/authToken.service';
import {
  getUserAccessState,
  isProtectedSuperAdminEmail,
  normalizeEmail,
  notifyActiveAdminsAboutContributorRequest,
  notifyContributorRequestSubmitted,
} from '../lib/userWorkflow';
import {
  normalizeEmailAddress,
  normalizeLebaneseMobile,
} from '../services/contactIdentity.service';
import {
  confirmEmailChallenge,
  confirmPhoneChallenge,
  cancelPendingSignup,
  createVerificationSessionToken,
  loadUser,
  requestPhoneChange,
  sendEmailChallenge,
  sendPhoneChallenge,
  validatePhoneFormat,
  verificationPurposeForUser,
  verificationState,
} from '../services/contactVerification.service';
import { getPhoneAssuranceMode } from '../services/phoneAssurance.service';
import { assertPhoneAccountCapacity } from '../services/phoneAccountLimit.service';
import { isContactAssuranceSatisfied } from '../services/contactAssurancePolicy.service';

const verificationContext = (req: any) => ({
  ip: req.ip ?? null,
  fingerprint:
    typeof req.headers?.['x-device-fingerprint'] === 'string'
      ? req.headers['x-device-fingerprint']
      : null,
});

const publicUser = (user: any) => ({
  id: user.id,
  email: user.email_original ?? user.email,
  full_name: user.full_name,
  phone: user.phone_e164 ?? user.phone,
  role: user.role,
  is_active: user.is_active,
  account_status: user.account_status,
  email_verified_at: user.email_verified_at,
  phone_verified_at: user.phone_verified_at,
  phone_format_validated_at: user.phone_format_validated_at,
  phone_assurance_level:
    user.phone_verified_at != null
      ? 'ownership_verified'
      : user.phone_format_validated_at != null
        ? 'format_validated'
        : 'unvalidated',
  is_protected_super_admin: isProtectedSuperAdminEmail(user.email_canonical ?? user.email),
});

const passwordResetExpiryMinutes = Number(process.env.PASSWORD_RESET_TOKEN_EXPIRY_MINUTES || 15);
const passwordResetSessionExpiryMinutes = 10;

const hashResetToken = (token: string) => crypto.createHash('sha256').update(token).digest('hex');

const getPasswordResetSessionSecret = (): string => {
  const baseSecret = process.env.JWT_SECRET_CURRENT || process.env.JWT_SECRET;
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
    {
      algorithm: tokenAlgorithm,
      expiresIn: `${passwordResetSessionExpiryMinutes}m`,
      issuer: tokenIssuer(),
      audience: `${tokenAudience()}:password-reset`,
      subject: userId,
    },
  );

const verifyPasswordResetSessionToken = (
  resetToken: string,
): { resetRequestId: string; userId: string; email: string } => {
  let decoded: any;
  try {
    decoded = jwt.verify(resetToken, getPasswordResetSessionSecret(), {
      algorithms: [tokenAlgorithm],
      issuer: tokenIssuer(),
      audience: `${tokenAudience()}:password-reset`,
    });
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
    typeof decoded.email !== 'string' ||
    decoded.sub !== decoded.userId
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
  const normalizedEmail = normalizeEmailAddress(email);
  const normalizedPhone = normalizeLebaneseMobile(phone);
  if (!normalizedEmail) {
    throw new AppError('Enter a valid email address.', 400, {
      code: 'INVALID_EMAIL',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }
  if (!normalizedPhone) {
    throw new AppError('Enter a valid Lebanese mobile number.', 400, {
      code: 'INVALID_LEBANESE_MOBILE',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }
  const publicRole = role === 'viewer' ? 'viewer' : 'contributor';

  const existingEmail = await query(
    `SELECT id FROM "user"
     WHERE email_canonical = $1
     LIMIT 1`,
    [normalizedEmail.canonical],
  );

  if (existingEmail.rows.length > 0) {
    throw new AppError('An account already uses this email address.', 409, {
      code: 'EMAIL_ALREADY_IN_USE',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }

  // Hash password
  const salt = await bcrypt.genSalt(12);
  const password_hash = await bcrypt.hash(password, salt);

  const user = await transaction(async (client) => {
    await assertPhoneAccountCapacity(client, normalizedPhone.e164);
    const result = await client.query(
      `INSERT INTO "user"
         (email, email_original, email_canonical, password_hash, full_name,
          phone, phone_e164, phone_format_validated_at, phone_validation_method,
          role, is_active, account_status, verification_required_at)
       VALUES ($1, $1, $2, $3, $4, $5, $5, $6, $7, $8::user_role, FALSE,
               'pending_verification', CURRENT_TIMESTAMP)
       RETURNING id, email, email_original, email_canonical, email_verified_at,
                 full_name, phone, phone_e164, phone_verified_at,
                 phone_format_validated_at, role, is_active,
                 account_status, auth_version, created_at`,
      [
        normalizedEmail.original,
        normalizedEmail.canonical,
        password_hash,
        full_name,
        normalizedPhone.e164,
        getPhoneAssuranceMode() === 'format_only' ? new Date() : null,
        getPhoneAssuranceMode() === 'format_only' ? 'libphonenumber_max' : null,
        publicRole,
      ],
    );

    return result.rows[0];
  });

  let delivery: Awaited<ReturnType<typeof sendEmailChallenge>>;
  try {
    delivery = await sendEmailChallenge({
      userId: user.id,
      purpose: 'signup',
      context: verificationContext(req),
    });
  } catch (error) {
    await query(
      `DELETE FROM "user"
       WHERE id = $1
         AND account_status = 'pending_verification'
         AND email_verified_at IS NULL`,
      [user.id],
    );
    throw error;
  }
  const verificationToken = createVerificationSessionToken(user);

  logger.info('Pending user registration created', { userId: user.id });

  res.status(201).json({
    success: true,
    message: 'Account created. Verify your email to continue.',
    data: {
      user: publicUser(user),
      verification_token: verificationToken,
      verification: {
        ...verificationState(user),
        delivery: 'email',
        expires_at: delivery.expiresAt.toISOString(),
        resend_after_seconds: delivery.resendAfterSeconds,
      },
    },
  });
};

// Login user
const login = async (req, res) => {
  const { email, password } = req.body;
  const normalizedEmail = normalizeEmailAddress(email);
  if (!normalizedEmail) {
    throw new AppError('Wrong email or password.', 401);
  }

  // Get user
  const result = await query(
    `SELECT id, email, email_original, email_canonical, email_verified_at,
            password_hash, full_name, phone, phone_e164, phone_verified_at,
            phone_format_validated_at, contact_verification_exempted_at,
            role, is_active, account_status, auth_version
     FROM "user" WHERE email_canonical = $1`,
    [normalizedEmail.canonical],
  );

  if (result.rows.length === 0) {
    throw new AppError('Wrong email or password.', 401);
  }

  const user = result.rows[0];

  // Verify password
  const isMatch = await bcrypt.compare(password, user.password_hash);

  if (!isMatch) {
    throw new AppError('Wrong email or password.', 401);
  }

  if (!isContactAssuranceSatisfied(user)) {
    const verificationToken = createVerificationSessionToken(user);
    return res.status(403).json({
      success: false,
      message: 'Contact verification is required before you can enter TerraLeb.',
      error: {
        code: 'CONTACT_VERIFICATION_REQUIRED',
        disposition: 'retry',
        retryable: false,
      },
      data: {
        verification_token: verificationToken,
        verification: verificationState(user),
      },
    });
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
        403,
      );
    }
    if (accessState === 'pending') {
      throw new AppError(
        'Your contributor request is still pending approval. You cannot log in yet.',
        403,
      );
    }
    if (accessState === 'inactive' && user.role === 'contributor') {
      throw new AppError(
        'Your contributor account is deactivated. Activate it to continue logging in.',
        403,
      );
    }
    throw new AppError('This account is inactive.', 403);
  }

  // Update last login
  await query('UPDATE "user" SET last_login = CURRENT_TIMESTAMP WHERE id = $1', [user.id]);

  const { token, refreshToken } = await createAuthenticatedSession(user);

  logger.info('User logged in', { userId: user.id });

  res.json({
    success: true,
    message: 'Login successful',
    data: {
      user: publicUser(user),
      token,
      refreshToken,
    },
  });
};

// Get current user profile
const getMe = async (req, res) => {
  const result = await query(
    `SELECT id, email, email_original, email_verified_at, full_name, phone,
            phone_e164, phone_verified_at, phone_format_validated_at,
            role, account_status, created_at,
            last_login, profile_picture_url
     FROM "user" WHERE id = $1`,
    [req.user.id],
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
  const { full_name } = req.body;

  if (req.body.email != null) {
    throw new AppError('Your account email address is fixed after registration.', 400, {
      code: 'ACCOUNT_EMAIL_IMMUTABLE',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }

  if (req.body.phone != null) {
    throw new AppError('Use the mobile-number change flow to update your phone number.', 400, {
      code: 'CONTACT_CHANGE_VERIFICATION_REQUIRED',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }

  const result = await query(
    `UPDATE "user" 
     SET full_name = COALESCE($1, full_name)
     WHERE id = $2
     RETURNING id, email, email_original, email_verified_at, full_name, phone,
               phone_e164, phone_verified_at, phone_format_validated_at,
               role, account_status, profile_picture_url`,
    [full_name, req.user.id],
  );

  logger.info('User profile updated:', { userId: req.user.id });

  res.json({
    success: true,
    message: 'Profile updated successfully',
    data: {
      ...result.rows[0],
      is_protected_super_admin: isProtectedSuperAdminEmail(result.rows[0].email),
    },
  });
};

// Change password
const changePassword = async (req, res) => {
  const { current_password, new_password } = req.body;
  const salt = await bcrypt.genSalt(12);
  const password_hash = await bcrypt.hash(new_password, salt);
  const tokens = await transaction(async (client) => {
    const current = await client.query(
      `SELECT password_hash
       FROM "user"
       WHERE id = $1
       FOR UPDATE`,
      [req.user.id],
    );
    const user = current.rows[0];
    if (!user || !(await bcrypt.compare(current_password, user.password_hash))) {
      throw new AppError('Current password is incorrect', 401);
    }

    const updated = await client.query(
      `UPDATE "user"
       SET password_hash = $1, auth_version = auth_version + 1
       WHERE id = $2
       RETURNING id, email, email_original, email_canonical, email_verified_at,
                 full_name, phone, phone_e164, phone_verified_at,
                 phone_format_validated_at, contact_verification_exempted_at,
                 role, is_active, account_status, auth_version`,
      [password_hash, req.user.id],
    );
    return replaceCurrentSessionAfterSecurityChange(
      client,
      updated.rows[0],
      req.authSessionId,
      'password_changed',
    );
  });

  logger.info('Password changed:', { userId: req.user.id });

  res.json({
    success: true,
    message: 'Password changed successfully',
    data: {
      token: tokens.token,
      refreshToken: tokens.refreshToken,
    },
  });
};

const requireCurrentPassword = async (userId: string, password: string): Promise<void> => {
  const result = await query('SELECT password_hash FROM "user" WHERE id = $1', [userId]);
  const matches = result.rows[0] && (await bcrypt.compare(password, result.rows[0].password_hash));
  if (!matches) {
    throw new AppError('Current password is incorrect.', 401, {
      code: 'REAUTHENTICATION_FAILED',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }
};

const getVerificationStatus = async (req, res) => {
  const user = await loadUser(req.verificationUserId);
  res.json({ success: true, data: { verification: verificationState(user) } });
};

const sendSignupEmailVerification = async (req, res) => {
  const user = await loadUser(req.verificationUserId);
  if (user.email_verified_at != null && req.body?.email == null) {
    throw new AppError('This email address is already verified.', 409, {
      code: 'CONTACT_ALREADY_VERIFIED',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }
  const purpose = verificationPurposeForUser(user);
  const delivery = await sendEmailChallenge({
    userId: user.id,
    purpose,
    email: req.body?.email,
    context: verificationContext(req),
  });
  const updated = await loadUser(user.id);
  res.json({
    success: true,
    message: 'A verification code has been sent.',
    data: {
      verification: {
        ...verificationState(updated),
        expires_at: delivery.expiresAt.toISOString(),
        resend_after_seconds: delivery.resendAfterSeconds,
      },
    },
  });
};

const confirmSignupEmailVerification = async (req, res) => {
  const current = await loadUser(req.verificationUserId);
  const user = await confirmEmailChallenge({
    userId: current.id,
    purpose: verificationPurposeForUser(current),
    code: req.body.code,
    context: verificationContext(req),
  });

  const verification = verificationState(user);
  const emailOnlyFlowComplete = verification.next_step === 'complete';
  if (emailOnlyFlowComplete && user.role === 'contributor' && !user.is_active) {
    await transaction(async (client) => {
      await notifyActiveAdminsAboutContributorRequest(client, {
        userId: user.id,
        fullName: user.full_name,
        email: user.email_original,
      });
      await notifyContributorRequestSubmitted(client, {
        userId: user.id,
        fullName: user.full_name,
        email: user.email_original,
      });
    });
  }

  if (emailOnlyFlowComplete) {
    const activated = user.is_active && user.account_status === 'active';
    return res.json({
      success: true,
      message: activated
        ? 'Your email is verified and your account is active. Sign in to continue.'
        : 'Your email is verified. Your contributor request is pending approval.',
      data: {
        user: publicUser(user),
        verification,
      },
    });
  }

  res.json({
    success: true,
    message: 'Email verified. Verify ownership of your Lebanese mobile number to continue.',
    data: {
      verification_token: createVerificationSessionToken(user),
      verification,
    },
  });
};

const cancelSignupVerification = async (req, res) => {
  await cancelPendingSignup({
    userId: req.verificationUserId,
    context: verificationContext(req),
  });
  res.json({
    success: true,
    message: 'The unfinished signup was removed. You can create the account again.',
  });
};

const validateSignupPhoneFormat = async (req, res) => {
  const current = await loadUser(req.verificationUserId);
  if (current.email_verified_at == null) {
    throw new AppError('Verify your email before validating your mobile number.', 409, {
      code: 'EMAIL_VERIFICATION_REQUIRED',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }

  const user = await validatePhoneFormat({
    userId: current.id,
    purpose: verificationPurposeForUser(current),
    phone: req.body?.phone,
    context: verificationContext(req),
  });

  if (user.role === 'contributor' && !user.is_active) {
    await transaction(async (client) => {
      await notifyActiveAdminsAboutContributorRequest(client, {
        userId: user.id,
        fullName: user.full_name,
        email: user.email_original,
      });
      await notifyContributorRequestSubmitted(client, {
        userId: user.id,
        fullName: user.full_name,
        email: user.email_original,
      });
    });
  }

  const activated = user.is_active && user.account_status === 'active';
  res.json({
    success: true,
    message: activated
      ? 'Mobile-number format validated. Ownership was not verified under the current policy. Sign in to continue.'
      : 'Mobile-number format validated without an ownership check. Your contributor request is pending approval.',
    data: {
      user: publicUser(user),
      verification: verificationState(user),
    },
  });
};

const sendSignupPhoneVerification = async (req, res) => {
  const user = await loadUser(req.verificationUserId);
  if (user.email_verified_at == null) {
    throw new AppError('Verify your email before requesting an SMS code.', 409, {
      code: 'EMAIL_VERIFICATION_REQUIRED',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }
  const delivery = await sendPhoneChallenge({
    userId: user.id,
    purpose: verificationPurposeForUser(user),
    phone: req.body?.phone,
    context: verificationContext(req),
  });
  const updated = await loadUser(user.id);
  res.json({
    success: true,
    message: 'An SMS verification code has been sent.',
    data: {
      verification: {
        ...verificationState(updated),
        expires_at: delivery.expiresAt.toISOString(),
        resend_after_seconds: delivery.resendAfterSeconds,
      },
    },
  });
};

const confirmSignupPhoneVerification = async (req, res) => {
  const current = await loadUser(req.verificationUserId);
  if (current.email_verified_at == null) {
    throw new AppError('Verify your email before confirming your mobile number.', 409, {
      code: 'EMAIL_VERIFICATION_REQUIRED',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }
  const user = await confirmPhoneChallenge({
    userId: current.id,
    purpose: verificationPurposeForUser(current),
    code: req.body.code,
    context: verificationContext(req),
  });

  if (user.role === 'contributor' && !user.is_active) {
    await transaction(async (client) => {
      await notifyActiveAdminsAboutContributorRequest(client, {
        userId: user.id,
        fullName: user.full_name,
        email: user.email_original,
      });
      await notifyContributorRequestSubmitted(client, {
        userId: user.id,
        fullName: user.full_name,
        email: user.email_original,
      });
    });
  }

  const activated = user.is_active && user.account_status === 'active';
  res.json({
    success: true,
    message: activated
      ? 'Your account is verified and active. Sign in to continue.'
      : 'Your contacts are verified. Your contributor request is pending approval.',
    data: {
      user: publicUser(user),
      verification: verificationState(user),
    },
  });
};

const requestMyPhoneChange = async (req, res) => {
  await requireCurrentPassword(req.user.id, req.body.current_password);
  const result = await requestPhoneChange({
    userId: req.user.id,
    newPhone: req.body.phone,
    context: verificationContext(req),
  });
  if (result.mode === 'format_only') {
    const user = result.user;
    const tokens = await transaction((client) =>
      replaceCurrentSessionAfterSecurityChange(
        client,
        user,
        req.authSessionId,
        'phone_changed',
      ),
    );
    return res.json({
      success: true,
      message:
        'Your mobile number was changed after a successful format validation. Ownership was not verified under the current policy.',
      data: {
        completed: true,
        user: publicUser(user),
        token: tokens.token,
        refreshToken: tokens.refreshToken,
      },
    });
  }
  res.json({
    success: true,
    message: 'Verify ownership of the new mobile number before it replaces your current number.',
    data: {
      completed: false,
      masked_target: result.maskedTarget,
      expires_at: result.expiresAt.toISOString(),
      resend_after_seconds: result.resendAfterSeconds,
    },
  });
};

const confirmMyPhoneChange = async (req, res) => {
  const user = await confirmPhoneChallenge({
    userId: req.user.id,
    purpose: 'change_phone',
    code: req.body.code,
    context: verificationContext(req),
  });
  const tokens = await transaction((client) =>
    replaceCurrentSessionAfterSecurityChange(
      client,
      user,
      req.authSessionId,
      'phone_changed',
    ),
  );
  res.json({
    success: true,
    message: 'Your mobile number was changed and verified.',
    data: {
      user: publicUser(user),
      token: tokens.token,
      refreshToken: tokens.refreshToken,
    },
  });
};

const reactivateContributorLogin = async (req, res) => {
  const { email, password } = req.body;
  const normalizedEmail = normalizeEmailAddress(email);
  if (!normalizedEmail) {
    throw new AppError('Wrong email or password.', 401);
  }

  const result = await query(
    `SELECT id, email, email_original, email_canonical, email_verified_at,
            password_hash, full_name, phone, phone_e164, phone_verified_at,
            phone_format_validated_at, contact_verification_exempted_at,
            role, is_active, account_status, auth_version
     FROM "user"
     WHERE email_canonical = $1`,
    [normalizedEmail.canonical],
  );

  if (result.rows.length === 0) {
    throw new AppError('Wrong email or password.', 401);
  }

  const user = result.rows[0];
  const isMatch = await bcrypt.compare(password, user.password_hash);

  if (!isMatch) {
    throw new AppError('Wrong email or password.', 401);
  }

  if (!isContactAssuranceSatisfied(user)) {
    return res.status(403).json({
      success: false,
      message: 'Contact verification is required before reactivation.',
      error: {
        code: 'CONTACT_VERIFICATION_REQUIRED',
        disposition: 'retry',
        retryable: false,
      },
      data: {
        verification_token: createVerificationSessionToken(user),
        verification: verificationState(user),
      },
    });
  }

  if (user.role !== 'contributor') {
    throw new AppError('Only contributor accounts can use this reactivation flow.', 403);
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
      403,
    );
  }
  if (accessState === 'pending') {
    throw new AppError(
      'Your contributor request is still pending approval. You cannot log in yet.',
      403,
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
    await query('UPDATE "user" SET last_login = CURRENT_TIMESTAMP WHERE id = $1', [user.id]);
  }

  const { token, refreshToken } = await createAuthenticatedSession(user);

  logger.info('Contributor account reactivated through login flow', {
    userId: user.id,
    wasInactive: accessState === 'inactive',
  });

  res.json({
    success: true,
    message:
      accessState === 'inactive' ? 'Account reactivated and login successful' : 'Login successful',
    data: {
      user: publicUser(user),
      token,
      refreshToken,
    },
  });
};

const requestPasswordReset = async (req, res) => {
  const normalizedEmail = normalizeEmailAddress(req.body?.email);

  const result = await query(
    `SELECT id
     FROM "user"
     WHERE email_canonical = $1
     LIMIT 1`,
    [normalizedEmail?.canonical ?? ''],
  );

  const expiresAt = new Date(Date.now() + passwordResetExpiryMinutes * 60 * 1000);
  const userId = result.rows[0]?.id;
  if (userId) {
    try {
      await sendEmailChallenge({
        userId,
        purpose: 'recovery',
        context: verificationContext(req),
      });
      logger.info('Password reset verification requested', { userId });
    } catch (error) {
      logger.warn('Password reset delivery was not completed', {
        userId,
        errorName: error instanceof Error ? error.name : 'UnknownError',
      });
    }
  }

  res.json({
    success: true,
    message: 'If an account matches that email, a verification code has been sent.',
    data: {
      delivery: 'email',
      expires_at: expiresAt.toISOString(),
    },
  });
};

const verifyPasswordResetOtp = async (req, res) => {
  const { email, otp } = req.body;
  const normalizedEmail = normalizeEmailAddress(email);

  const userResult = await query(
    `SELECT id, email_original
     FROM "user"
     WHERE email_canonical = $1
     LIMIT 1`,
    [normalizedEmail?.canonical ?? ''],
  );

  if (userResult.rows.length === 0) {
    throw new AppError('Verification code is invalid or expired.', 400);
  }
  const user = userResult.rows[0];
  try {
    await confirmEmailChallenge({
      userId: user.id,
      purpose: 'recovery',
      code: otp,
      context: verificationContext(req),
    });
  } catch (error) {
    if (error instanceof AppError) {
      throw error;
    }
    throw new AppError('Verification code is invalid or expired.', 400);
  }
  const resetRequestResult = await transaction(async (client) => {
    await client.query(
      `UPDATE password_reset_request
       SET used_at = CURRENT_TIMESTAMP
       WHERE user_id = $1 AND used_at IS NULL`,
      [user.id],
    );
    return client.query(
      `INSERT INTO password_reset_request (user_id, token_hash, expires_at, requested_from_ip)
       VALUES ($1, $2, CURRENT_TIMESTAMP + INTERVAL '10 minutes', $3::inet)
       RETURNING id, user_id`,
      [user.id, hashResetToken(crypto.randomBytes(32).toString('hex')), req.ip ?? null],
    );
  });
  const resetRequest = resetRequestResult.rows[0];
  const sessionToken = generatePasswordResetSessionToken({
    resetRequestId: resetRequest.id,
    userId: resetRequest.user_id,
    email: user.email_original,
  });

  logger.info('Password reset OTP verified', { userId: resetRequest.user_id });

  res.json({
    success: true,
    message: 'Verification code confirmed.',
    data: {
      reset_token: sessionToken,
      email: user.email_original,
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
    [verifiedSession.resetRequestId, verifiedSession.userId, normalizeEmail(verifiedSession.email)],
  );

  if (resetRequestResult.rows.length === 0) {
    throw new AppError(
      'Password reset session is invalid or expired. Please request a new verification code.',
      400,
    );
  }

  const resetRequest = resetRequestResult.rows[0];
  if (resetRequest.used_at != null || new Date(resetRequest.expires_at).getTime() < Date.now()) {
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
       SET password_hash = $1, auth_version = auth_version + 1
       WHERE id = $2`,
      [password_hash, resetRequest.user_id],
    );

    await revokeAllUserSessions(resetRequest.user_id, 'password_reset', client);

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
  });

  res.json({
    success: true,
    message: 'Password has been changed successfully.',
  });
};

const logout = async (req, res) => {
  await revokeSession(req.authSessionId, req.user.id, 'logout');
  logger.info('User logged out:', { userId: req.user.id });

  res.json({
    success: true,
    message: 'Logout successful',
  });
};

// Refresh token
const refreshToken = async (req, res) => {
  const { refresh_token } = req.body;
  let refreshResult;
  try {
    refreshResult = await rotateRefreshToken(refresh_token);
  } catch (_error) {
    throw new AppError('Invalid or expired refresh token', 401);
  }
  if (refreshResult.status === 'inactive') {
    throw permanentOfflineSyncError(
      'This account is no longer active.',
      'OFFLINE_SYNC_ACCOUNT_INACTIVE',
    );
  }
  if (refreshResult.status === 'replayed') {
    logger.warn('Refresh token replay detected; user sessions revoked');
    throw new AppError('Invalid or expired refresh token', 401, {
      code: 'AUTH_REFRESH_REPLAYED',
      disposition: 'retry',
      retryable: false,
    });
  }
  if (refreshResult.status !== 'ok') {
    throw new AppError('Invalid or expired refresh token', 401);
  }

  const { token, refreshToken: newRefreshToken } = refreshResult.tokens;
  const user = refreshResult.user;

  logger.info('Token refreshed:', { userId: user.id });

  res.json({
    success: true,
    message: 'Token refreshed',
    data: {
      token,
      refreshToken: newRefreshToken,
      user: publicUser(user),
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

  await transaction(async (client) => {
    await client.query(
      `UPDATE "user"
       SET is_active = FALSE
       WHERE id = $1`,
      [req.user.id],
    );
    await revokeAllUserSessions(req.user.id, 'self_deactivated', client);
  });

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
  getVerificationStatus,
  sendSignupEmailVerification,
  confirmSignupEmailVerification,
  cancelSignupVerification,
  validateSignupPhoneFormat,
  sendSignupPhoneVerification,
  confirmSignupPhoneVerification,
  requestMyPhoneChange,
  confirmMyPhoneChange,
  requestPasswordReset,
  verifyPasswordResetOtp,
  resetPassword,
  reactivateContributorLogin,
  logout,
  selfDeactivate,
  refreshToken,
};

export {};
