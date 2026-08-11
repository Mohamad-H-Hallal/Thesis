import type { PoolClient } from 'pg';
import { AppError } from '../middleware/error';

const MAX_SUPPORTED_PHONE_ACCOUNT_REUSE = 3;

const getPhoneAccountReuseLimit = (): number => {
  const configured = Number.parseInt(process.env.PHONE_ACCOUNT_REUSE_LIMIT ?? '3', 10);
  if (!Number.isFinite(configured)) {
    return MAX_SUPPORTED_PHONE_ACCOUNT_REUSE;
  }
  return Math.min(MAX_SUPPORTED_PHONE_ACCOUNT_REUSE, Math.max(1, configured));
};

const phoneAccountLimitMessage = (limit = getPhoneAccountReuseLimit()): string =>
  `This mobile number is already used by the maximum of ${limit} accounts. Use another Lebanese mobile number.`;

const assertPhoneAccountCapacity = async (
  client: PoolClient,
  phoneE164: string,
  excludeUserId?: string | null,
): Promise<void> => {
  const limit = getPhoneAccountReuseLimit();

  // The matching database trigger uses the same transaction-scoped lock. It
  // prevents two simultaneous signups from both claiming the final slot.
  await client.query(
    `SELECT pg_advisory_xact_lock(hashtextextended('user-phone-account:' || $1, 0))`,
    [phoneE164],
  );

  const usage = await client.query<{ account_count: number }>(
    `SELECT COUNT(DISTINCT id)::int AS account_count
     FROM "user"
     WHERE ($2::uuid IS NULL OR id <> $2::uuid)
       AND (phone_e164 = $1 OR pending_phone_e164 = $1)`,
    [phoneE164, excludeUserId ?? null],
  );

  if (Number(usage.rows[0]?.account_count ?? 0) >= limit) {
    throw new AppError(phoneAccountLimitMessage(limit), 409, {
      code: 'PHONE_ACCOUNT_LIMIT_REACHED',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }
};

export {
  MAX_SUPPORTED_PHONE_ACCOUNT_REUSE,
  assertPhoneAccountCapacity,
  getPhoneAccountReuseLimit,
  phoneAccountLimitMessage,
};
