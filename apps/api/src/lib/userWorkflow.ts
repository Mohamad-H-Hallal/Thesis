import type { PoolClient, QueryResult, QueryResultRow } from 'pg';
import bcrypt from 'bcryptjs';
import type { EnvConfig } from '../config/env';
import { query } from '../config/database';
import { isPhoneAssuranceSatisfied } from '../services/phoneAssurance.service';
const logger = require('../utils/logger');

type QueryExecutor = Pick<PoolClient, 'query'> | typeof query;

const passwordStrengthPattern = /^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[^A-Za-z\d]).{8,}$/;

const normalizeEmail = (value: string): string => value.trim().toLowerCase();

const getProtectedSuperAdminEmail = (): string =>
  normalizeEmail(String(process.env.SUPER_ADMIN_EMAIL ?? ''));

const isProtectedSuperAdminEmail = (email?: string | null): boolean => {
  if (!email) {
    return false;
  }
  const configuredEmail = getProtectedSuperAdminEmail();
  if (!configuredEmail) {
    return false;
  }
  return normalizeEmail(email) === configuredEmail;
};

const assertStrongPassword = (password: string, label = 'Password'): void => {
  if (!passwordStrengthPattern.test(password)) {
    throw new Error(
      `${label} must be at least 8 characters and include uppercase, lowercase, number, and special character`,
    );
  }
};

const runQuery = async <T extends QueryResultRow = QueryResultRow>(
  executor: QueryExecutor,
  text: string,
  params: unknown[] = [],
): Promise<QueryResult<T>> => {
  if (typeof executor === 'function') {
    return executor<T>(text, params);
  }
  return executor.query<T>(text, params);
};

const createNotification = async (
  executor: QueryExecutor,
  {
    userId,
    type,
    title,
    message,
    metadata,
  }: {
    userId: string;
    type: string;
    title: string;
    message: string;
    metadata: Record<string, unknown>;
  },
): Promise<void> => {
  await runQuery(
    executor,
    `INSERT INTO notification (user_id, type, title, message, metadata)
     VALUES ($1, $2::notification_type, $3, $4, $5::jsonb)`,
    [userId, type, title, message, JSON.stringify(metadata)],
  );
};

const getActiveAdminUsers = async (
  executor: QueryExecutor,
): Promise<Array<{ id: string; email: string; full_name: string }>> => {
  const result = await runQuery<{ id: string; email: string; full_name: string }>(
    executor,
    `SELECT id, email, full_name
     FROM "user"
     WHERE role = 'admin' AND is_active = TRUE
     ORDER BY created_at ASC`,
  );
  return result.rows;
};

const notifyActiveAdminsAboutContributorRequest = async (
  executor: QueryExecutor,
  {
    userId,
    fullName,
    email,
  }: {
    userId: string;
    fullName: string;
    email: string;
  },
): Promise<void> => {
  const admins = await getActiveAdminUsers(executor);
  for (const admin of admins) {
    await createNotification(executor, {
      userId: admin.id,
      type: 'contributor_request',
      title: 'Contributor approval pending',
      message: `${fullName} (${email}) submitted a contributor access request and is waiting for approval.`,
      metadata: {
        user_id: userId,
        requester_name: fullName,
        requester_email: email,
      },
    });
  }
};

const notifyContributorRequestSubmitted = async (
  executor: QueryExecutor,
  {
    userId,
    fullName,
    email,
  }: {
    userId: string;
    fullName: string;
    email: string;
  },
): Promise<void> => {
  await createNotification(executor, {
    userId,
    type: 'contributor_request',
    title: 'Contributor request submitted',
    message:
      'Your contributor request was submitted successfully and is awaiting admin approval before you can log in.',
    metadata: {
      user_id: userId,
      requester_name: fullName,
      requester_email: email,
      request_status: 'pending',
    },
  });
};

const getContributorAccessState = async (
  executor: QueryExecutor,
  userId: string,
): Promise<'pending' | 'rejected'> => {
  const result = await runQuery<{ type: string }>(
    executor,
    `SELECT type
     FROM notification
     WHERE user_id = $1
       AND type IN ('contributor_request', 'contributor_rejected', 'contributor_approved')
     ORDER BY created_at DESC
     LIMIT 1`,
    [userId],
  );

  const latest = result.rows[0]?.type;
  if (latest === 'contributor_rejected') {
    return 'rejected';
  }
  return 'pending';
};

const getLatestAccountState = async (
  executor: QueryExecutor,
  userId: string,
): Promise<'blocked' | 'active' | 'inactive' | null> => {
  const result = await runQuery<{ account_state: string | null }>(
    executor,
    `SELECT new_values->>'account_state' AS account_state
     FROM audit_log
     WHERE entity_type = 'user'
       AND entity_id = $1
       AND action_type = 'update'
       AND new_values ? 'account_state'
     ORDER BY created_at DESC
     LIMIT 1`,
    [userId],
  );

  const state = result.rows[0]?.account_state;
  if (state === 'blocked' || state === 'active' || state === 'inactive') {
    return state;
  }
  return null;
};

const getUserAccessState = async (
  executor: QueryExecutor,
  {
    userId,
    role,
    isActive,
  }: {
    userId: string;
    role: string;
    isActive: boolean;
  },
): Promise<'active' | 'pending' | 'rejected' | 'blocked' | 'inactive'> => {
  if (isActive) {
    return 'active';
  }

  const latestAccountState = await getLatestAccountState(executor, userId);
  if (latestAccountState === 'blocked') {
    return 'blocked';
  }

  if (latestAccountState === 'inactive') {
    return 'inactive';
  }

  if (role === 'contributor') {
    return getContributorAccessState(executor, userId);
  }

  return 'inactive';
};

const ensureSuperAdminExists = async (env: EnvConfig): Promise<void> => {
  const email = normalizeEmail(env.SUPER_ADMIN_EMAIL);
  const password = String(env.SUPER_ADMIN_PASSWORD ?? '').trim();
  const fullName = String(env.SUPER_ADMIN_FULL_NAME ?? '').trim();

  if (!email || !password || !fullName) {
    if (env.NODE_ENV !== 'production') {
      logger.warn(
        'Super admin bootstrap skipped: SUPER_ADMIN_* variables are not fully configured',
      );
      return;
    }
    throw new Error('SUPER_ADMIN_* variables must be configured in production');
  }

  assertStrongPassword(password, 'SUPER_ADMIN_PASSWORD');

  const existing = await query<{
    id: string;
    email: string;
    password_hash: string | null;
    role: string;
    is_active: boolean;
    email_verified_at: Date | null;
    phone_verified_at: Date | null;
    phone_format_validated_at: Date | null;
  }>(
    `SELECT id, email, password_hash, role, is_active,
            email_verified_at, phone_verified_at, phone_format_validated_at
     FROM "user"
     WHERE email_canonical = $1 OR LOWER(email) = $1`,
    [email],
  );

  if (existing.rows.length === 0) {
    const passwordHash = await bcrypt.hash(password, 12);
    await query(
      `INSERT INTO "user"
         (email, email_original, email_canonical, password_hash, full_name,
          role, is_active, account_status, verification_required_at)
       VALUES ($1, $1, $1, $2, $3, 'admin', FALSE,
               'verification_required', CURRENT_TIMESTAMP)`,
      [email, passwordHash, fullName],
    );
    logger.info('Super admin bootstrap user created pending contact verification', { email });
    return;
  }

  const current = existing.rows[0];
  const contactsSatisfied = Boolean(
    current.email_verified_at && isPhoneAssuranceSatisfied(current),
  );
  const passwordMatchesEnv = current.password_hash
    ? await bcrypt.compare(password, current.password_hash)
    : false;

  if (current.role !== 'admin' || current.is_active !== contactsSatisfied || !passwordMatchesEnv) {
    const passwordHash =
      passwordMatchesEnv && current.password_hash
        ? current.password_hash
        : await bcrypt.hash(password, 12);
    await query(
      `UPDATE "user"
       SET role = 'admin',
           is_active = $1,
           account_status = CASE WHEN $1 THEN 'active' ELSE 'verification_required' END,
           verification_required_at = CASE
             WHEN $1 THEN verification_required_at
             ELSE COALESCE(verification_required_at, CURRENT_TIMESTAMP)
           END,
           password_hash = $2,
           full_name = COALESCE(NULLIF($3, ''), full_name)
       WHERE id = $4`,
      [contactsSatisfied, passwordHash, fullName, current.id],
    );
    logger.warn('Super admin bootstrap user corrected from configured environment', {
      email,
      roleCorrected: current.role !== 'admin',
      activeCorrected: current.is_active !== contactsSatisfied,
      passwordHashSynced: !passwordMatchesEnv,
      contactVerificationRequired: !contactsSatisfied,
    });
    return;
  }

  logger.info('Super admin bootstrap user already present', { email });
};

export {
  assertStrongPassword,
  createNotification,
  ensureSuperAdminExists,
  getActiveAdminUsers,
  getProtectedSuperAdminEmail,
  isProtectedSuperAdminEmail,
  normalizeEmail,
  notifyActiveAdminsAboutContributorRequest,
  notifyContributorRequestSubmitted,
  getContributorAccessState,
  getLatestAccountState,
  getUserAccessState,
};
