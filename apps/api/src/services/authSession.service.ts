import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';
import type { QueryResult, QueryResultRow } from 'pg';
import { query, transaction } from '../config/database';
import type { user_role } from '../types/roles';
import { isContactAssuranceSatisfied } from './contactAssurancePolicy.service';
import {
  generateRefreshToken,
  generateToken,
  tokenExpiresAt,
  verifyRefreshToken,
} from './authToken.service';

interface QueryExecutor {
  query<T extends QueryResultRow = QueryResultRow>(
    text: string,
    params?: unknown[],
  ): Promise<QueryResult<T>>;
}

interface SessionUser {
  id: string;
  email: string;
  email_original?: string | null;
  email_canonical?: string | null;
  email_verified_at?: Date | string | null;
  full_name: string;
  phone?: string | null;
  phone_e164?: string | null;
  phone_verified_at?: Date | string | null;
  phone_format_validated_at?: Date | string | null;
  contact_verification_exempted_at?: Date | string | null;
  role: user_role;
  is_active: boolean;
  account_status?: string;
  auth_version: number;
}

interface SessionTokens {
  token: string;
  refreshToken: string;
  sessionId: string;
}

const hashToken = (token: string): string => createHash('sha256').update(token).digest('hex');

const safeHashEqual = (left: string, right: string): boolean => {
  const leftBuffer = Buffer.from(left, 'hex');
  const rightBuffer = Buffer.from(right, 'hex');
  return leftBuffer.length === rightBuffer.length && timingSafeEqual(leftBuffer, rightBuffer);
};

const buildSessionTokens = (user: SessionUser, sessionId: string): SessionTokens => {
  const authVersion = Number(user.auth_version);
  return {
    token: generateToken(user.id, user.role, authVersion, sessionId),
    refreshToken: generateRefreshToken(user.id, authVersion, sessionId),
    sessionId,
  };
};

const writeSessionToken = async (
  executor: QueryExecutor,
  user: SessionUser,
  tokens: SessionTokens,
  create: boolean,
): Promise<void> => {
  const refreshHash = hashToken(tokens.refreshToken);
  const refreshExpiresAt = tokenExpiresAt(tokens.refreshToken);
  if (create) {
    await executor.query(
      `INSERT INTO auth_session
         (id, user_id, refresh_token_hash, refresh_expires_at, auth_version)
       VALUES ($1, $2, $3, $4, $5)`,
      [tokens.sessionId, user.id, refreshHash, refreshExpiresAt, Number(user.auth_version)],
    );
    return;
  }
  const result = await executor.query(
    `UPDATE auth_session
     SET refresh_token_hash = $1,
         refresh_expires_at = $2,
         auth_version = $3,
         last_rotated_at = CURRENT_TIMESTAMP,
         revoked_at = NULL,
         revocation_reason = NULL
     WHERE id = $4 AND user_id = $5`,
    [refreshHash, refreshExpiresAt, Number(user.auth_version), tokens.sessionId, user.id],
  );
  if (result.rowCount !== 1) {
    throw new Error('Authenticated session no longer exists');
  }
};

const createAuthenticatedSession = async (user: SessionUser): Promise<SessionTokens> =>
  transaction(async (client) => {
    await client.query(
      `DELETE FROM auth_session
       WHERE user_id = $1
         AND (
           refresh_expires_at < CURRENT_TIMESTAMP
           OR revoked_at < CURRENT_TIMESTAMP - INTERVAL '30 days'
         )`,
      [user.id],
    );
    const tokens = buildSessionTokens(user, randomUUID());
    await writeSessionToken(client, user, tokens, true);
    return tokens;
  });

const revokeSession = async (
  sessionId: string,
  userId: string,
  reason: string,
  executor: QueryExecutor = { query },
): Promise<void> => {
  await executor.query(
    `UPDATE auth_session
     SET revoked_at = COALESCE(revoked_at, CURRENT_TIMESTAMP),
         revocation_reason = COALESCE(revocation_reason, $3)
     WHERE id = $1 AND user_id = $2`,
    [sessionId, userId, reason],
  );
};

const revokeAllUserSessions = async (
  userId: string,
  reason: string,
  executor: QueryExecutor = { query },
  exceptSessionId?: string,
): Promise<void> => {
  await executor.query(
    `UPDATE auth_session
     SET revoked_at = COALESCE(revoked_at, CURRENT_TIMESTAMP),
         revocation_reason = COALESCE(revocation_reason, $2)
     WHERE user_id = $1
       AND ($3::uuid IS NULL OR id <> $3::uuid)`,
    [userId, reason, exceptSessionId ?? null],
  );
};

const replaceCurrentSessionAfterSecurityChange = async (
  executor: QueryExecutor,
  user: SessionUser,
  sessionId: string,
  reason: string,
): Promise<SessionTokens> => {
  await revokeAllUserSessions(user.id, reason, executor, sessionId);
  const tokens = buildSessionTokens(user, sessionId);
  await writeSessionToken(executor, user, tokens, false);
  return tokens;
};

type RefreshResult =
  | { status: 'ok'; tokens: SessionTokens; user: SessionUser }
  | { status: 'invalid' | 'inactive' | 'replayed' };

const rotateRefreshToken = async (refreshToken: string): Promise<RefreshResult> => {
  const decoded = verifyRefreshToken(refreshToken);
  return transaction(async (client) => {
    const result = await client.query<SessionUser & {
      session_user_id: string;
      refresh_token_hash: string;
      refresh_expires_at: Date | string;
      session_auth_version: number;
      revoked_at: Date | string | null;
    }>(
      `SELECT u.id, u.email, u.email_original, u.email_canonical, u.email_verified_at,
              u.full_name, u.phone, u.phone_e164, u.phone_verified_at,
              u.phone_format_validated_at, u.contact_verification_exempted_at,
              u.role, u.is_active, u.account_status, u.auth_version,
              s.user_id AS session_user_id, s.refresh_token_hash, s.refresh_expires_at,
              s.auth_version AS session_auth_version, s.revoked_at
       FROM auth_session s
       JOIN "user" u ON u.id = s.user_id
       WHERE s.id = $1
       FOR UPDATE OF s, u`,
      [decoded.sessionId],
    );
    const row = result.rows[0];
    if (!row || row.id !== decoded.userId || row.session_user_id !== decoded.userId) {
      return { status: 'invalid' } as const;
    }

    const presentedHash = hashToken(refreshToken);
    if (!safeHashEqual(presentedHash, row.refresh_token_hash)) {
      await client.query(
        `UPDATE "user" SET auth_version = auth_version + 1 WHERE id = $1`,
        [row.id],
      );
      await revokeAllUserSessions(row.id, 'refresh_token_replay', client);
      return { status: 'replayed' } as const;
    }

    if (
      row.revoked_at != null ||
      new Date(row.refresh_expires_at).getTime() <= Date.now() ||
      decoded.authVersion !== Number(row.auth_version) ||
      Number(row.session_auth_version) !== Number(row.auth_version)
    ) {
      return { status: 'invalid' } as const;
    }
    if (!row.is_active || !isContactAssuranceSatisfied(row)) {
      return { status: 'inactive' } as const;
    }

    const tokens = buildSessionTokens(row, decoded.sessionId);
    await writeSessionToken(client, row, tokens, false);
    return { status: 'ok', tokens, user: row } as const;
  });
};

const isSessionCurrent = async ({
  sessionId,
  userId,
  authVersion,
}: {
  sessionId: string;
  userId: string;
  authVersion: number;
}): Promise<boolean> => {
  const result = await query(
    `SELECT u.role, u.email_verified_at, u.phone_verified_at,
            u.phone_format_validated_at, u.contact_verification_exempted_at
     FROM auth_session s
     JOIN "user" u ON u.id = s.user_id
     WHERE s.id = $1
       AND s.user_id = $2
       AND s.revoked_at IS NULL
       AND s.refresh_expires_at > CURRENT_TIMESTAMP
       AND s.auth_version = $3
       AND u.auth_version = $3
       AND u.is_active = TRUE`,
    [sessionId, userId, authVersion],
  );
  return result.rows.length === 1 && isContactAssuranceSatisfied(result.rows[0]);
};

export {
  createAuthenticatedSession,
  isSessionCurrent,
  replaceCurrentSessionAfterSecurityChange,
  revokeAllUserSessions,
  revokeSession,
  rotateRefreshToken,
};
export type { SessionTokens, SessionUser };
