import crypto from 'node:crypto';
import jwt, { type JwtPayload } from 'jsonwebtoken';
import type { PoolClient } from 'pg';
import { query, transaction } from '../config/database';
import { AppError } from '../middleware/error';
import { tokenAlgorithm, tokenAudience, tokenIssuer } from './authToken.service';
import { sendContactVerificationCodeEmail } from '../lib/mailer';
import {
  maskEmail,
  maskLebaneseMobile,
  normalizeEmailAddress,
  normalizeLebaneseMobile,
} from './contactIdentity.service';
import {
  PhoneVerificationProviderError,
  getPhoneVerificationProvider,
  type PhoneVerificationPurpose,
} from './phoneVerificationProvider.service';
import {
  getPhoneAssuranceMode,
  isPhoneAssuranceSatisfied,
  isPhoneOwnershipVerificationRequired,
  phoneAssuranceLevel,
} from './phoneAssurance.service';
import {
  PhoneFormatValidationProviderError,
  validateLebaneseMobileFormat,
} from './phoneFormatValidationProvider.service';
import { assertPhoneAccountCapacity } from './phoneAccountLimit.service';

export type VerificationChannel = 'email' | 'phone' | 'sms';
export type VerificationPurpose =
  | 'signup'
  | 'change_email'
  | 'change_phone'
  | 'invite'
  | 'recovery';

export interface VerificationRequestContext {
  ip?: string | null;
  fingerprint?: string | null;
}

interface VerificationTokenPayload extends JwtPayload {
  sub?: string;
  purpose: 'contact_verification';
  userId: string;
  authVersion: number;
}

interface ContactUserRow {
  id: string;
  email: string;
  email_original: string;
  email_canonical: string;
  email_verified_at: Date | string | null;
  phone: string | null;
  phone_e164: string | null;
  phone_verified_at: Date | string | null;
  phone_format_validated_at: Date | string | null;
  phone_validation_method: string | null;
  pending_email_original: string | null;
  pending_email_canonical: string | null;
  pending_phone_e164: string | null;
  full_name: string;
  role: 'admin' | 'contributor' | 'viewer';
  is_active: boolean;
  account_status: string;
  auth_version: number;
}

interface ChallengeRow {
  id: string;
  user_id: string;
  channel: VerificationChannel;
  purpose: VerificationPurpose;
  target: string;
  secret_hash: string | null;
  expires_at: Date | string;
  consumed_at: Date | string | null;
  invalidated_at: Date | string | null;
  attempt_count: number;
  max_attempts: number;
  blocked_until: Date | string | null;
}

const emailTestOutbox = new Map<string, string>();

const integerSetting = (name: string, fallback: number): number => {
  const parsed = Number.parseInt(process.env[name] ?? '', 10);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
};

const hmacSecret = (): string => {
  const value = process.env.VERIFICATION_HMAC_SECRET?.trim() ?? '';
  if (value.length < 32) {
    throw new AppError('Contact verification is temporarily unavailable.', 503, {
      code: 'VERIFICATION_CONFIGURATION_ERROR',
      disposition: 'retry',
      retryable: true,
    });
  }
  return value;
};

const challengeHash = ({
  id,
  channel,
  purpose,
  target,
  code,
}: {
  id: string;
  channel: VerificationChannel;
  purpose: VerificationPurpose;
  target: string;
  code: string;
}): string =>
  crypto
    .createHmac('sha256', hmacSecret())
    .update(`${id}:${channel}:${purpose}:${target}:${code}`)
    .digest('hex');

const safeFingerprintHash = (value?: string | null): string | null => {
  const normalized = value?.trim() ?? '';
  if (!normalized) {
    return null;
  }
  return crypto.createHmac('sha256', hmacSecret()).update(normalized).digest('hex');
};

const getVerificationSessionSecret = (): string => {
  const base = process.env.JWT_SECRET_CURRENT || process.env.JWT_SECRET;
  if (!base) {
    throw new AppError('Contact verification is temporarily unavailable.', 503);
  }
  return `${base}:contact-verification`;
};

const createVerificationSessionToken = (
  user: Pick<ContactUserRow, 'id' | 'auth_version'>,
): string =>
  jwt.sign(
    {
      purpose: 'contact_verification',
      userId: user.id,
      authVersion: user.auth_version,
    },
    getVerificationSessionSecret(),
    {
      algorithm: tokenAlgorithm,
      expiresIn: `${integerSetting('CONTACT_VERIFICATION_TOKEN_EXPIRY_MINUTES', 30)}m`,
      issuer: tokenIssuer(),
      audience: `${tokenAudience()}:contact-verification`,
      subject: user.id,
    },
  );

const verifyVerificationSessionToken = (token: string): VerificationTokenPayload => {
  try {
    const decoded = jwt.verify(token, getVerificationSessionSecret(), {
      algorithms: [tokenAlgorithm],
      issuer: tokenIssuer(),
      audience: `${tokenAudience()}:contact-verification`,
    }) as VerificationTokenPayload;
    if (
      decoded.purpose !== 'contact_verification' ||
      typeof decoded.userId !== 'string' ||
      decoded.sub !== decoded.userId ||
      !Number.isSafeInteger(decoded.authVersion)
    ) {
      throw new Error('Invalid verification token scope');
    }
    return decoded;
  } catch {
    throw new AppError('Your verification session is invalid or expired. Sign in again.', 401, {
      code: 'VERIFICATION_SESSION_EXPIRED',
      disposition: 'retry',
      retryable: false,
    });
  }
};

const loadUser = async (userId: string, client?: PoolClient): Promise<ContactUserRow> => {
  const executor = client ?? { query };
  const result = await executor.query<ContactUserRow>(
    `SELECT id, email, email_original, email_canonical, email_verified_at,
            phone, phone_e164, phone_verified_at, phone_format_validated_at,
            phone_validation_method, pending_email_original,
            pending_email_canonical, pending_phone_e164, full_name, role,
            is_active, account_status, auth_version
     FROM "user"
     WHERE id = $1`,
    [userId],
  );
  if (!result.rows[0]) {
    throw new AppError('Verification session is no longer available.', 401, {
      code: 'VERIFICATION_SESSION_EXPIRED',
      disposition: 'retry',
      retryable: false,
    });
  }
  return result.rows[0];
};

const assertVerificationTokenCurrent = async (
  payload: VerificationTokenPayload,
): Promise<ContactUserRow> => {
  const user = await loadUser(payload.userId);
  if (user.auth_version !== payload.authVersion) {
    throw new AppError('Your verification session has been replaced. Sign in again.', 401, {
      code: 'VERIFICATION_SESSION_REPLACED',
      disposition: 'retry',
      retryable: false,
    });
  }
  return user;
};

const verificationPurposeForUser = (user: ContactUserRow): 'signup' | 'invite' =>
  user.account_status === 'invited' ? 'invite' : 'signup';

const writeAudit = async (
  client: PoolClient,
  values: {
    userId: string;
    challengeId?: string | null;
    eventType:
      | 'send_requested'
      | 'send_succeeded'
      | 'send_failed'
      | 'verification_failed'
      | 'verification_succeeded'
      | 'challenge_blocked'
      | 'contact_change_requested'
      | 'contact_change_succeeded'
      | 'validation_requested'
      | 'validation_succeeded'
      | 'validation_failed'
      | 'pending_signup_cancelled';
    channel: VerificationChannel;
    purpose: VerificationPurpose;
    target: string;
    ip?: string | null;
    metadata?: Record<string, unknown>;
  },
): Promise<void> => {
  const maskedTarget =
    values.channel === 'email' ? maskEmail(values.target) : maskLebaneseMobile(values.target);
  await client.query(
    `INSERT INTO contact_verification_audit_event
       (user_id, challenge_id, event_type, channel, purpose, masked_target, request_ip, metadata)
     VALUES ($1, $2, $3, $4, $5, $6, $7::inet, $8::jsonb)`,
    [
      values.userId,
      values.challengeId ?? null,
      values.eventType,
      values.channel,
      values.purpose,
      maskedTarget,
      values.ip ?? null,
      JSON.stringify(values.metadata ?? {}),
    ],
  );
};

const throwRateLimit = (retryAfterSeconds: number): never => {
  throw new AppError('Too many verification requests. Please try again later.', 429, {
    code: 'CONTACT_VERIFICATION_RATE_LIMITED',
    disposition: 'retry',
    retryable: true,
    retryAfterSeconds: Math.max(1, retryAfterSeconds),
  });
};

const assertSendAllowed = async (
  client: PoolClient,
  values: {
    userId: string;
    channel: VerificationChannel;
    purpose: VerificationPurpose;
    target: string;
    context: VerificationRequestContext;
  },
): Promise<void> => {
  const latest = await client.query<{
    created_at: Date | string;
    blocked_until: Date | string | null;
  }>(
    `SELECT created_at, blocked_until
     FROM contact_verification_challenge
     WHERE user_id = $1 AND channel = $2 AND purpose = $3
     ORDER BY created_at DESC
     LIMIT 1`,
    [values.userId, values.channel, values.purpose],
  );
  const current = latest.rows[0];
  const now = Date.now();
  if (current?.blocked_until && new Date(current.blocked_until).getTime() > now) {
    throwRateLimit(Math.ceil((new Date(current.blocked_until).getTime() - now) / 1000));
  }
  const cooldown = integerSetting('VERIFICATION_RESEND_COOLDOWN_SECONDS', 60);
  if (current) {
    const retryAt = new Date(current.created_at).getTime() + cooldown * 1000;
    if (retryAt > now) {
      throwRateLimit(Math.ceil((retryAt - now) / 1000));
    }
  }

  const counts = await client.query<{
    target_count: number;
    account_count: number;
    ip_count: number;
    device_count: number;
  }>(
    `SELECT
       COUNT(*) FILTER (WHERE channel = $2 AND target = $3)::integer AS target_count,
       COUNT(*) FILTER (WHERE user_id = $1)::integer AS account_count,
       COUNT(*) FILTER (WHERE requested_from_ip = $4::inet)::integer AS ip_count,
       COUNT(*) FILTER (WHERE request_fingerprint_hash = $5)::integer AS device_count
     FROM contact_verification_challenge
     WHERE created_at >= CURRENT_TIMESTAMP - INTERVAL '24 hours'`,
    [
      values.userId,
      values.channel,
      values.target,
      values.context.ip ?? null,
      safeFingerprintHash(values.context.fingerprint),
    ],
  );
  const count = counts.rows[0] ?? {
    target_count: 0,
    account_count: 0,
    ip_count: 0,
    device_count: 0,
  };
  if (
    count.target_count >= integerSetting('VERIFICATION_DAILY_TARGET_CAP', 10) ||
    count.account_count >= integerSetting('VERIFICATION_DAILY_ACCOUNT_CAP', 20) ||
    (values.context.ip && count.ip_count >= integerSetting('VERIFICATION_DAILY_IP_CAP', 50)) ||
    (values.context.fingerprint &&
      count.device_count >= integerSetting('VERIFICATION_DAILY_DEVICE_CAP', 30))
  ) {
    throwRateLimit(3600);
  }
};

const assertEmailAvailable = async (
  client: PoolClient,
  canonical: string,
  userId: string,
): Promise<void> => {
  const duplicate = await client.query(
    `SELECT id FROM "user"
     WHERE id <> $2
       AND (email_canonical = $1 OR pending_email_canonical = $1)
     LIMIT 1`,
    [canonical, userId],
  );
  if (duplicate.rows.length > 0) {
    throw new AppError('This email address cannot be used.', 409, {
      code: 'CONTACT_ALREADY_IN_USE',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }
};

const insertChallenge = async (
  client: PoolClient,
  values: {
    id: string;
    userId: string;
    channel: VerificationChannel;
    purpose: VerificationPurpose;
    target: string;
    secretHash?: string | null;
    context: VerificationRequestContext;
    auditEventType?: 'send_requested' | 'validation_requested';
  },
): Promise<Date> => {
  await assertSendAllowed(client, values);
  await client.query(
    `UPDATE contact_verification_challenge
     SET invalidated_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
     WHERE user_id = $1 AND channel = $2 AND purpose = $3
       AND consumed_at IS NULL AND invalidated_at IS NULL`,
    [values.userId, values.channel, values.purpose],
  );
  const expiresAt = new Date(
    Date.now() + integerSetting('VERIFICATION_CODE_EXPIRY_MINUTES', 5) * 60 * 1000,
  );
  await client.query(
    `INSERT INTO contact_verification_challenge
       (id, user_id, channel, purpose, target, secret_hash, expires_at,
        max_attempts, requested_from_ip, request_fingerprint_hash)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::inet, $10)`,
    [
      values.id,
      values.userId,
      values.channel,
      values.purpose,
      values.target,
      values.secretHash ?? null,
      expiresAt,
      integerSetting('VERIFICATION_MAX_ATTEMPTS', 5),
      values.context.ip ?? null,
      safeFingerprintHash(values.context.fingerprint),
    ],
  );
  await writeAudit(client, {
    userId: values.userId,
    challengeId: values.id,
    eventType: values.auditEventType ?? 'send_requested',
    channel: values.channel,
    purpose: values.purpose,
    target: values.target,
    ip: values.context.ip,
  });
  return expiresAt;
};

const sendEmailChallenge = async ({
  userId,
  purpose,
  email,
  context,
}: {
  userId: string;
  purpose: 'signup' | 'invite' | 'change_email' | 'recovery';
  email?: string | null;
  context: VerificationRequestContext;
}): Promise<{ maskedTarget: string; expiresAt: Date; resendAfterSeconds: number }> => {
  const prepared = await transaction(async (client) => {
    let user = await loadUser(userId, client);
    let delivery: string;
    let canonical: string;
    if (purpose === 'change_email') {
      if (!user.pending_email_original || !user.pending_email_canonical) {
        throw new AppError('No email change is pending.', 409, {
          code: 'NO_PENDING_CONTACT_CHANGE',
          disposition: 'permanent_rejection',
          retryable: false,
        });
      }
      const normalized = normalizeEmailAddress(user.pending_email_original);
      if (!normalized) {
        throw new AppError('The pending email address is invalid.', 400);
      }
      delivery = normalized.delivery;
      canonical = user.pending_email_canonical;
    } else if (email != null) {
      const normalized = normalizeEmailAddress(email);
      if (!normalized) {
        throw new AppError('Enter a valid email address.', 400, {
          code: 'INVALID_EMAIL',
          disposition: 'permanent_rejection',
          retryable: false,
        });
      }
      await assertEmailAvailable(client, normalized.canonical, userId);
      await client.query(
        `UPDATE "user"
         SET email = $1, email_original = $1, email_canonical = $2,
             email_verified_at = NULL, account_status = CASE
               WHEN account_status = 'invited' THEN 'invited' ELSE 'pending_verification' END
         WHERE id = $3`,
        [normalized.original, normalized.canonical, userId],
      );
      user = await loadUser(userId, client);
      delivery = normalized.delivery;
      canonical = normalized.canonical;
    } else {
      const normalized = normalizeEmailAddress(user.email_original);
      if (!normalized) {
        throw new AppError('Enter a valid email address.', 400);
      }
      delivery = normalized.delivery;
      canonical = normalized.canonical;
    }

    const id = crypto.randomUUID();
    const code = crypto.randomInt(0, 1_000_000).toString().padStart(6, '0');
    const expiresAt = await insertChallenge(client, {
      id,
      userId,
      channel: 'email',
      purpose,
      target: canonical,
      secretHash: challengeHash({ id, channel: 'email', purpose, target: canonical, code }),
      context,
    });
    return { id, code, expiresAt, delivery, canonical, user };
  });

  try {
    await sendContactVerificationCodeEmail({
      toEmail: prepared.delivery,
      recipientName: prepared.user.full_name,
      code: prepared.code,
      expiresInMinutes: integerSetting('VERIFICATION_CODE_EXPIRY_MINUTES', 5),
      purpose,
    });
    if (process.env.NODE_ENV === 'test') {
      emailTestOutbox.set(`${purpose}:${prepared.canonical}`, prepared.code);
    }
    await transaction(async (client) => {
      await writeAudit(client, {
        userId,
        challengeId: prepared.id,
        eventType: 'send_succeeded',
        channel: 'email',
        purpose,
        target: prepared.canonical,
        ip: context.ip,
      });
    });
  } catch (error) {
    await transaction(async (client) => {
      await client.query(
        `UPDATE contact_verification_challenge
         SET invalidated_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
         WHERE id = $1`,
        [prepared.id],
      );
      await writeAudit(client, {
        userId,
        challengeId: prepared.id,
        eventType: 'send_failed',
        channel: 'email',
        purpose,
        target: prepared.canonical,
        ip: context.ip,
      });
    });
    throw error;
  }

  return {
    maskedTarget: maskEmail(prepared.delivery),
    expiresAt: prepared.expiresAt,
    resendAfterSeconds: integerSetting('VERIFICATION_RESEND_COOLDOWN_SECONDS', 60),
  };
};

const sendPhoneChallenge = async ({
  userId,
  purpose,
  phone,
  context,
}: {
  userId: string;
  purpose: 'signup' | 'invite' | 'change_phone';
  phone?: string | null;
  context: VerificationRequestContext;
}): Promise<{ maskedTarget: string; expiresAt: Date; resendAfterSeconds: number }> => {
  if (getPhoneAssuranceMode() !== 'sms_otp') {
    throw new AppError(
      'SMS ownership verification is not enabled. Validate the mobile-number format instead.',
      409,
      {
        code: 'PHONE_LOOKUP_VALIDATION_REQUIRED',
        disposition: 'permanent_rejection',
        retryable: false,
      },
    );
  }
  const prepared = await transaction(async (client) => {
    let user = await loadUser(userId, client);
    let phoneE164: string;
    if (purpose === 'change_phone') {
      if (!user.pending_phone_e164) {
        throw new AppError('No mobile-number change is pending.', 409, {
          code: 'NO_PENDING_CONTACT_CHANGE',
          disposition: 'permanent_rejection',
          retryable: false,
        });
      }
      phoneE164 = user.pending_phone_e164;
    } else if (phone != null) {
      const normalized = normalizeLebaneseMobile(phone);
      if (!normalized) {
        throw new AppError('Enter a valid Lebanese mobile number.', 400, {
          code: 'INVALID_LEBANESE_MOBILE',
          disposition: 'permanent_rejection',
          retryable: false,
        });
      }
      await assertPhoneAccountCapacity(client, normalized.e164, userId);
      await client.query(
        `UPDATE "user"
         SET phone = $1, phone_e164 = $1, phone_verified_at = NULL,
             phone_format_validated_at = NULL, phone_validation_method = NULL,
             account_status = CASE
               WHEN account_status = 'invited' THEN 'invited' ELSE 'pending_verification' END
         WHERE id = $2`,
        [normalized.e164, userId],
      );
      user = await loadUser(userId, client);
      phoneE164 = normalized.e164;
    } else {
      const normalized = normalizeLebaneseMobile(user.phone_e164 ?? user.phone);
      if (!normalized) {
        throw new AppError('Enter a valid Lebanese mobile number.', 400, {
          code: 'INVALID_LEBANESE_MOBILE',
          disposition: 'permanent_rejection',
          retryable: false,
        });
      }
      await assertPhoneAccountCapacity(client, normalized.e164, userId);
      if (user.phone_e164 !== normalized.e164) {
        await client.query(`UPDATE "user" SET phone = $1, phone_e164 = $1 WHERE id = $2`, [
          normalized.e164,
          userId,
        ]);
        user = await loadUser(userId, client);
      }
      phoneE164 = normalized.e164;
    }

    const id = crypto.randomUUID();
    const expiresAt = await insertChallenge(client, {
      id,
      userId,
      channel: 'sms',
      purpose,
      target: phoneE164,
      context,
    });
    return { id, expiresAt, phoneE164, user };
  });

  try {
    const providerResult = await getPhoneVerificationProvider().sendCode(
      prepared.phoneE164,
      purpose as PhoneVerificationPurpose,
    );
    await transaction(async (client) => {
      await client.query(
        `UPDATE contact_verification_challenge
         SET provider_reference = $1, updated_at = CURRENT_TIMESTAMP
         WHERE id = $2 AND invalidated_at IS NULL`,
        [providerResult.providerReference, prepared.id],
      );
      await writeAudit(client, {
        userId,
        challengeId: prepared.id,
        eventType: 'send_succeeded',
        channel: 'sms',
        purpose,
        target: prepared.phoneE164,
        ip: context.ip,
      });
    });
  } catch (error) {
    await transaction(async (client) => {
      await client.query(
        `UPDATE contact_verification_challenge
         SET invalidated_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
         WHERE id = $1`,
        [prepared.id],
      );
      await writeAudit(client, {
        userId,
        challengeId: prepared.id,
        eventType: 'send_failed',
        channel: 'sms',
        purpose,
        target: prepared.phoneE164,
        ip: context.ip,
      });
    });
    if (error instanceof PhoneVerificationProviderError) {
      throw new AppError('SMS verification is temporarily unavailable.', 503, {
        code: 'SMS_VERIFICATION_PROVIDER_UNAVAILABLE',
        disposition: 'retry',
        retryable: true,
      });
    }
    throw error;
  }

  return {
    maskedTarget: maskLebaneseMobile(prepared.phoneE164),
    expiresAt: prepared.expiresAt,
    resendAfterSeconds: integerSetting('VERIFICATION_RESEND_COOLDOWN_SECONDS', 60),
  };
};

const validatePhoneFormat = async ({
  userId,
  purpose,
  phone,
  context,
}: {
  userId: string;
  purpose: 'signup' | 'invite' | 'change_phone';
  phone?: string | null;
  context: VerificationRequestContext;
}): Promise<ContactUserRow> => {
  if (getPhoneAssuranceMode() !== 'format_only') {
    throw new AppError('SMS ownership verification is required by the current policy.', 409, {
      code: 'SMS_OWNERSHIP_VERIFICATION_REQUIRED',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }

  const prepared = await transaction(async (client) => {
    let user = await loadUser(userId, client);
    let phoneE164: string;
    if (purpose === 'change_phone') {
      if (!user.pending_phone_e164) {
        throw new AppError('No mobile-number change is pending.', 409, {
          code: 'NO_PENDING_CONTACT_CHANGE',
          disposition: 'permanent_rejection',
          retryable: false,
        });
      }
      phoneE164 = user.pending_phone_e164;
    } else {
      const normalized = normalizeLebaneseMobile(phone ?? user.phone_e164 ?? user.phone);
      if (!normalized) {
        throw new AppError('Enter a valid Lebanese mobile number.', 400, {
          code: 'INVALID_LEBANESE_MOBILE',
          disposition: 'permanent_rejection',
          retryable: false,
        });
      }
      await assertPhoneAccountCapacity(client, normalized.e164, userId);
      phoneE164 = normalized.e164;
      if (user.phone_e164 !== phoneE164) {
        await client.query(
          `UPDATE "user"
           SET phone = $1, phone_e164 = $1, phone_verified_at = NULL,
               phone_format_validated_at = NULL, phone_validation_method = NULL
           WHERE id = $2`,
          [phoneE164, userId],
        );
        user = await loadUser(userId, client);
      }
    }

    const id = crypto.randomUUID();
    await insertChallenge(client, {
      id,
      userId,
      channel: 'phone',
      purpose,
      target: phoneE164,
      context,
      auditEventType: 'validation_requested',
    });
    return { id, phoneE164, user };
  });

  let validationResult: Awaited<ReturnType<typeof validateLebaneseMobileFormat>>;
  try {
    validationResult = await validateLebaneseMobileFormat(prepared.phoneE164);
  } catch (error) {
    await transaction(async (client) => {
      await client.query(
        `UPDATE contact_verification_challenge
         SET invalidated_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
         WHERE id = $1`,
        [prepared.id],
      );
      await writeAudit(client, {
        userId,
        challengeId: prepared.id,
        eventType: 'validation_failed',
        channel: 'phone',
        purpose,
        target: prepared.phoneE164,
        ip: context.ip,
        metadata: { provider_unavailable: true },
      });
    });
    if (error instanceof PhoneFormatValidationProviderError) {
      throw new AppError('Phone-number validation is temporarily unavailable.', 503, {
        code: 'PHONE_FORMAT_PROVIDER_UNAVAILABLE',
        disposition: 'retry',
        retryable: true,
      });
    }
    throw error;
  }

  if (!validationResult.valid || validationResult.phoneE164 !== prepared.phoneE164) {
    await transaction(async (client) => {
      await client.query(
        `UPDATE contact_verification_challenge
         SET invalidated_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
         WHERE id = $1`,
        [prepared.id],
      );
      await writeAudit(client, {
        userId,
        challengeId: prepared.id,
        eventType: 'validation_failed',
        channel: 'phone',
        purpose,
        target: prepared.phoneE164,
        ip: context.ip,
        metadata: { method: validationResult.method, provider_valid: false },
      });
    });
    throw new AppError('Enter a valid Lebanese mobile number.', 400, {
      code: 'PHONE_FORMAT_REJECTED',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }

  return transaction(async (client) => {
    const consumed = await client.query(
      `UPDATE contact_verification_challenge
       SET consumed_at = CURRENT_TIMESTAMP, provider_reference = $1,
           updated_at = CURRENT_TIMESTAMP
       WHERE id = $2 AND consumed_at IS NULL AND invalidated_at IS NULL
       RETURNING id`,
      [validationResult.providerReference, prepared.id],
    );
    if (consumed.rowCount !== 1) {
      throw new AppError('This phone validation request was replaced. Please retry.', 409, {
        code: 'PHONE_FORMAT_VALIDATION_REPLACED',
        disposition: 'retry',
        retryable: true,
      });
    }

    if (purpose === 'change_phone') {
      await client.query(
        `UPDATE "user"
         SET phone = pending_phone_e164,
             phone_e164 = pending_phone_e164,
             phone_verified_at = NULL,
             phone_format_validated_at = CURRENT_TIMESTAMP,
             phone_validation_method = $3,
             pending_phone_e164 = NULL,
             auth_version = auth_version + 1
         WHERE id = $1 AND pending_phone_e164 = $2`,
        [userId, prepared.phoneE164, validationResult.method],
      );
    } else {
      await client.query(
        `UPDATE "user"
         SET phone = $1,
             phone_e164 = $1,
             phone_verified_at = NULL,
             phone_format_validated_at = CURRENT_TIMESTAMP,
             phone_validation_method = $3,
             auth_version = auth_version + 1,
             is_active = CASE
               WHEN role IN ('viewer', 'admin') THEN TRUE
               ELSE is_active
             END,
             account_status = CASE
               WHEN email_verified_at IS NULL THEN account_status
               WHEN role = 'contributor' AND is_active = FALSE THEN 'pending_approval'
               ELSE 'active'
             END
         WHERE id = $2 AND phone_e164 = $1`,
        [prepared.phoneE164, userId, validationResult.method],
      );
    }

    const updated = await loadUser(userId, client);
    await writeAudit(client, {
      userId,
      challengeId: prepared.id,
      eventType: purpose === 'change_phone' ? 'contact_change_succeeded' : 'validation_succeeded',
      channel: 'phone',
      purpose,
      target: prepared.phoneE164,
      ip: context.ip,
      metadata: {
        method: validationResult.method,
        ownership_verified: false,
      },
    });
    return updated;
  });
};

type ConfirmResult = { ok: true; user: ContactUserRow } | { ok: false; error: AppError };

const challengeFailure = (code: string, message: string): AppError =>
  new AppError(message, 400, {
    code,
    disposition: 'permanent_rejection',
    retryable: false,
  });

const loadActiveChallengeForUpdate = async (
  client: PoolClient,
  values: {
    userId: string;
    channel: VerificationChannel;
    purpose: VerificationPurpose;
    target: string;
  },
): Promise<ChallengeRow | null> => {
  const result = await client.query<ChallengeRow>(
    `SELECT id, user_id, channel, purpose, target, secret_hash, expires_at,
            consumed_at, invalidated_at, attempt_count, max_attempts, blocked_until
     FROM contact_verification_challenge
     WHERE user_id = $1 AND channel = $2 AND purpose = $3 AND target = $4
       AND consumed_at IS NULL AND invalidated_at IS NULL
     ORDER BY created_at DESC
     LIMIT 1
     FOR UPDATE`,
    [values.userId, values.channel, values.purpose, values.target],
  );
  return result.rows[0] ?? null;
};

const recordFailedAttempt = async (
  client: PoolClient,
  challenge: ChallengeRow,
  context: VerificationRequestContext,
): Promise<AppError> => {
  const attempts = challenge.attempt_count + 1;
  const exhausted = attempts >= challenge.max_attempts;
  const blockedUntil = exhausted
    ? new Date(Date.now() + integerSetting('VERIFICATION_BLOCK_MINUTES', 15) * 60 * 1000)
    : null;
  await client.query(
    `UPDATE contact_verification_challenge
     SET attempt_count = $1,
         invalidated_at = CASE WHEN $2 THEN CURRENT_TIMESTAMP ELSE invalidated_at END,
         blocked_until = $3,
         updated_at = CURRENT_TIMESTAMP
     WHERE id = $4`,
    [attempts, exhausted, blockedUntil, challenge.id],
  );
  await writeAudit(client, {
    userId: challenge.user_id,
    challengeId: challenge.id,
    eventType: exhausted ? 'challenge_blocked' : 'verification_failed',
    channel: challenge.channel,
    purpose: challenge.purpose,
    target: challenge.target,
    ip: context.ip,
    metadata: { attempts, exhausted },
  });
  return exhausted
    ? new AppError('Too many incorrect codes. Request a new code later.', 429, {
        code: 'VERIFICATION_ATTEMPTS_EXHAUSTED',
        disposition: 'retry',
        retryable: true,
      })
    : challengeFailure('VERIFICATION_CODE_INVALID', 'The verification code is incorrect.');
};

const finalizeVerifiedUser = async (
  client: PoolClient,
  challenge: ChallengeRow,
): Promise<ContactUserRow> => {
  if (challenge.channel === 'email') {
    if (challenge.purpose === 'change_email') {
      await client.query(
        `UPDATE "user"
         SET email = pending_email_original,
             email_original = pending_email_original,
             email_canonical = pending_email_canonical,
             email_verified_at = CURRENT_TIMESTAMP,
             pending_email_original = NULL,
             pending_email_canonical = NULL,
             auth_version = auth_version + 1
         WHERE id = $1`,
        [challenge.user_id],
      );
    } else if (challenge.purpose !== 'recovery') {
      const current = await loadUser(challenge.user_id, client);
      const structurallyValidPhone = normalizeLebaneseMobile(current.phone_e164 ?? current.phone);
      if (getPhoneAssuranceMode() === 'format_only' && structurallyValidPhone) {
        await client.query(
          `UPDATE "user"
           SET email_verified_at = CURRENT_TIMESTAMP,
               phone = $2,
               phone_e164 = $2,
               phone_format_validated_at = COALESCE(
                 phone_format_validated_at,
                 CURRENT_TIMESTAMP
               ),
               phone_validation_method = COALESCE(
                 phone_validation_method,
                 'libphonenumber_max'
               ),
               is_active = CASE
                 WHEN role IN ('viewer', 'admin') THEN TRUE
                 ELSE is_active
               END,
               account_status = CASE
                 WHEN role = 'contributor' AND is_active = FALSE THEN 'pending_approval'
                 ELSE 'active'
               END
           WHERE id = $1`,
          [challenge.user_id, structurallyValidPhone.e164],
        );
      } else {
        await client.query(
          `UPDATE "user" SET email_verified_at = CURRENT_TIMESTAMP WHERE id = $1`,
          [challenge.user_id],
        );
      }
    }
  } else if (challenge.purpose === 'change_phone') {
    await client.query(
      `UPDATE "user"
       SET phone = pending_phone_e164,
           phone_e164 = pending_phone_e164,
           phone_verified_at = CURRENT_TIMESTAMP,
           pending_phone_e164 = NULL,
           auth_version = auth_version + 1
       WHERE id = $1`,
      [challenge.user_id],
    );
  } else {
    await client.query(
      `UPDATE "user"
       SET phone = $1,
           phone_e164 = $1,
           phone_verified_at = CURRENT_TIMESTAMP,
           is_active = CASE
             WHEN role IN ('viewer', 'admin') THEN TRUE
             ELSE is_active
           END,
           account_status = CASE
             WHEN email_verified_at IS NULL THEN account_status
             WHEN role = 'contributor' AND is_active = FALSE THEN 'pending_approval'
             ELSE 'active'
           END
       WHERE id = $2`,
      [challenge.target, challenge.user_id],
    );
  }
  return loadUser(challenge.user_id, client);
};

const confirmEmailChallenge = async ({
  userId,
  purpose,
  code,
  context,
}: {
  userId: string;
  purpose: 'signup' | 'invite' | 'change_email' | 'recovery';
  code: string;
  context: VerificationRequestContext;
}): Promise<ContactUserRow> => {
  const result = await transaction<ConfirmResult>(async (client) => {
    const user = await loadUser(userId, client);
    const target = purpose === 'change_email' ? user.pending_email_canonical : user.email_canonical;
    if (!target) {
      return {
        ok: false,
        error: challengeFailure(
          'VERIFICATION_CHALLENGE_MISSING',
          'Request a new verification code.',
        ),
      };
    }
    const challenge = await loadActiveChallengeForUpdate(client, {
      userId,
      channel: 'email',
      purpose,
      target,
    });
    if (!challenge) {
      return {
        ok: false,
        error: challengeFailure(
          'VERIFICATION_CHALLENGE_MISSING',
          'Request a new verification code.',
        ),
      };
    }
    if (new Date(challenge.expires_at).getTime() < Date.now()) {
      await client.query(
        `UPDATE contact_verification_challenge SET invalidated_at = CURRENT_TIMESTAMP WHERE id = $1`,
        [challenge.id],
      );
      return {
        ok: false,
        error: challengeFailure('VERIFICATION_CODE_EXPIRED', 'The verification code has expired.'),
      };
    }
    const expected = challengeHash({
      id: challenge.id,
      channel: 'email',
      purpose,
      target,
      code,
    });
    const valid =
      challenge.secret_hash != null &&
      crypto.timingSafeEqual(
        Buffer.from(challenge.secret_hash, 'hex'),
        Buffer.from(expected, 'hex'),
      );
    if (!valid) {
      return { ok: false, error: await recordFailedAttempt(client, challenge, context) };
    }
    await client.query(
      `UPDATE contact_verification_challenge
       SET consumed_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
       WHERE id = $1 AND consumed_at IS NULL`,
      [challenge.id],
    );
    const updated = await finalizeVerifiedUser(client, challenge);
    await writeAudit(client, {
      userId,
      challengeId: challenge.id,
      eventType: purpose === 'change_email' ? 'contact_change_succeeded' : 'verification_succeeded',
      channel: 'email',
      purpose,
      target,
      ip: context.ip,
    });
    return { ok: true, user: updated };
  });
  if (!result.ok) {
    throw result.error;
  }
  return result.user;
};

const confirmPhoneChallenge = async ({
  userId,
  purpose,
  code,
  context,
}: {
  userId: string;
  purpose: 'signup' | 'invite' | 'change_phone';
  code: string;
  context: VerificationRequestContext;
}): Promise<ContactUserRow> => {
  if (getPhoneAssuranceMode() !== 'sms_otp') {
    throw new AppError('SMS ownership verification is not enabled.', 409, {
      code: 'PHONE_LOOKUP_VALIDATION_REQUIRED',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }
  const user = await loadUser(userId);
  const target = purpose === 'change_phone' ? user.pending_phone_e164 : user.phone_e164;
  if (!target) {
    throw challengeFailure('VERIFICATION_CHALLENGE_MISSING', 'Request a new verification code.');
  }
  let providerApproved = false;
  try {
    providerApproved = await getPhoneVerificationProvider().verifyCode(
      target,
      code,
      purpose as PhoneVerificationPurpose,
    );
  } catch (error) {
    if (error instanceof PhoneVerificationProviderError) {
      throw new AppError('SMS verification is temporarily unavailable.', 503, {
        code: 'SMS_VERIFICATION_PROVIDER_UNAVAILABLE',
        disposition: 'retry',
        retryable: true,
      });
    }
    throw error;
  }
  const result = await transaction<ConfirmResult>(async (client) => {
    const challenge = await loadActiveChallengeForUpdate(client, {
      userId,
      channel: 'sms',
      purpose,
      target,
    });
    if (!challenge) {
      return {
        ok: false,
        error: challengeFailure(
          'VERIFICATION_CHALLENGE_MISSING',
          'Request a new verification code.',
        ),
      };
    }
    if (new Date(challenge.expires_at).getTime() < Date.now()) {
      await client.query(
        `UPDATE contact_verification_challenge SET invalidated_at = CURRENT_TIMESTAMP WHERE id = $1`,
        [challenge.id],
      );
      return {
        ok: false,
        error: challengeFailure('VERIFICATION_CODE_EXPIRED', 'The verification code has expired.'),
      };
    }
    if (!providerApproved) {
      return { ok: false, error: await recordFailedAttempt(client, challenge, context) };
    }
    const consumed = await client.query(
      `UPDATE contact_verification_challenge
       SET consumed_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
       WHERE id = $1 AND consumed_at IS NULL AND invalidated_at IS NULL
       RETURNING id`,
      [challenge.id],
    );
    if (consumed.rowCount !== 1) {
      return {
        ok: false,
        error: challengeFailure(
          'VERIFICATION_CODE_USED',
          'This verification code was already used.',
        ),
      };
    }
    const updated = await finalizeVerifiedUser(client, challenge);
    await writeAudit(client, {
      userId,
      challengeId: challenge.id,
      eventType: purpose === 'change_phone' ? 'contact_change_succeeded' : 'verification_succeeded',
      channel: 'sms',
      purpose,
      target,
      ip: context.ip,
    });
    return { ok: true, user: updated };
  });
  if (!result.ok) {
    throw result.error;
  }
  return result.user;
};

const requestPhoneChange = async ({
  userId,
  newPhone,
  context,
}: {
  userId: string;
  newPhone: string;
  context: VerificationRequestContext;
}): Promise<
  | {
      mode: 'sms_otp';
      maskedTarget: string;
      expiresAt: Date;
      resendAfterSeconds: number;
    }
  | { mode: 'format_only'; user: ContactUserRow }
> => {
  const normalized = normalizeLebaneseMobile(newPhone);
  if (!normalized) {
    throw new AppError('Enter a valid Lebanese mobile number.', 400, {
      code: 'INVALID_LEBANESE_MOBILE',
      disposition: 'permanent_rejection',
      retryable: false,
    });
  }
  await transaction(async (client) => {
    await assertPhoneAccountCapacity(client, normalized.e164, userId);
    await client.query(`UPDATE "user" SET pending_phone_e164 = $1 WHERE id = $2`, [
      normalized.e164,
      userId,
    ]);
    await client.query(
      `UPDATE contact_verification_challenge
       SET invalidated_at = CURRENT_TIMESTAMP
       WHERE user_id = $1 AND purpose = 'change_phone'
         AND consumed_at IS NULL AND invalidated_at IS NULL`,
      [userId],
    );
    await writeAudit(client, {
      userId,
      eventType: 'contact_change_requested',
      channel: 'sms',
      purpose: 'change_phone',
      target: normalized.e164,
      ip: context.ip,
    });
  });
  if (getPhoneAssuranceMode() === 'format_only') {
    const user = await validatePhoneFormat({
      userId,
      purpose: 'change_phone',
      context,
    });
    return { mode: 'format_only', user };
  }
  const delivery = await sendPhoneChallenge({ userId, purpose: 'change_phone', context });
  return { mode: 'sms_otp', ...delivery };
};

const cancelPendingSignup = async ({
  userId,
  context,
}: {
  userId: string;
  context: VerificationRequestContext;
}): Promise<void> => {
  await transaction(async (client) => {
    const result = await client.query<ContactUserRow>(
      `SELECT id, email, email_original, email_canonical, email_verified_at,
              full_name, phone, phone_e164, phone_verified_at,
              phone_format_validated_at, pending_email_original,
              pending_email_canonical, pending_phone_e164, role, is_active,
              account_status, auth_version
       FROM "user"
       WHERE id = $1
       FOR UPDATE`,
      [userId],
    );
    const user = result.rows[0];
    if (
      !user ||
      user.account_status !== 'pending_verification' ||
      user.email_verified_at != null ||
      !['viewer', 'contributor'].includes(user.role)
    ) {
      throw new AppError('This account cannot be returned to signup.', 409, {
        code: 'PENDING_SIGNUP_CANCELLATION_NOT_ALLOWED',
        disposition: 'permanent_rejection',
        retryable: false,
      });
    }

    await writeAudit(client, {
      userId,
      eventType: 'pending_signup_cancelled',
      channel: 'email',
      purpose: 'signup',
      target: user.email_canonical,
      ip: context.ip,
      metadata: { account_status: user.account_status },
    });
    await client.query(`DELETE FROM "user" WHERE id = $1`, [userId]);
  });
};

const verificationState = (user: ContactUserRow) => {
  const assuranceSatisfied = isPhoneAssuranceSatisfied(user);
  const mode = getPhoneAssuranceMode();
  return {
    user_id: user.id,
    account_status: user.account_status,
    email_verified: user.email_verified_at != null,
    phone_verified: user.phone_verified_at != null,
    phone_format_validated: user.phone_format_validated_at != null,
    phone_assurance_level: phoneAssuranceLevel(user),
    phone_assurance_mode: mode,
    phone_ownership_required: isPhoneOwnershipVerificationRequired(),
    next_step:
      user.email_verified_at == null
        ? 'email'
        : assuranceSatisfied
          ? 'complete'
          : mode === 'format_only'
            ? 'phone_format'
            : 'phone',
    masked_email: maskEmail(user.pending_email_original ?? user.email_original),
    masked_phone: maskLebaneseMobile(
      user.pending_phone_e164 ?? user.phone_e164 ?? user.phone ?? '',
    ),
  };
};

const getMockEmailVerificationCodeForTest = (
  targetEmail: string,
  purpose: 'signup' | 'invite' | 'change_email' | 'recovery',
): string => {
  if (process.env.NODE_ENV !== 'test') {
    throw new Error('Mock verification codes are accessible only in tests.');
  }
  const normalized = normalizeEmailAddress(targetEmail);
  const code = normalized ? emailTestOutbox.get(`${purpose}:${normalized.canonical}`) : null;
  if (!code) {
    throw new Error('No pending mock email verification code exists for this target and purpose.');
  }
  return code;
};

const clearVerificationTestOutboxes = (): void => {
  if (process.env.NODE_ENV === 'test') {
    emailTestOutbox.clear();
  }
};

export {
  assertVerificationTokenCurrent,
  clearVerificationTestOutboxes,
  cancelPendingSignup,
  confirmEmailChallenge,
  confirmPhoneChallenge,
  createVerificationSessionToken,
  getMockEmailVerificationCodeForTest,
  loadUser,
  requestPhoneChange,
  sendEmailChallenge,
  sendPhoneChallenge,
  validatePhoneFormat,
  verificationPurposeForUser,
  verificationState,
  verifyVerificationSessionToken,
};
