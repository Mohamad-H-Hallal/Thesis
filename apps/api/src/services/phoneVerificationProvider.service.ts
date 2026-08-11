import crypto from 'node:crypto';
import { getPhoneAssuranceMode } from './phoneAssurance.service';

export type PhoneVerificationPurpose = 'signup' | 'change_phone' | 'invite' | 'recovery';

export interface PhoneVerificationSendResult {
  providerReference: string | null;
}

export interface PhoneVerificationProvider {
  sendCode(
    phoneE164: string,
    purpose: PhoneVerificationPurpose,
  ): Promise<PhoneVerificationSendResult>;
  verifyCode(phoneE164: string, code: string, purpose: PhoneVerificationPurpose): Promise<boolean>;
}

class PhoneVerificationProviderError extends Error {
  constructor(message = 'SMS verification is temporarily unavailable.') {
    super(message);
    this.name = 'PhoneVerificationProviderError';
  }
}

type MockEntry = { hash: string; expiresAt: number };
const mockCodes = new Map<string, MockEntry>();
const mockTestOutbox = new Map<string, string>();

const mockKey = (phoneE164: string, purpose: PhoneVerificationPurpose): string =>
  `${purpose}:${phoneE164}`;

const mockHash = (key: string, code: string): string =>
  crypto
    .createHmac('sha256', process.env.VERIFICATION_HMAC_SECRET || 'test-only-verification-secret')
    .update(`${key}:${code}`)
    .digest('hex');

class MockPhoneVerificationProvider implements PhoneVerificationProvider {
  async sendCode(
    phoneE164: string,
    purpose: PhoneVerificationPurpose,
  ): Promise<PhoneVerificationSendResult> {
    if (process.env.NODE_ENV === 'production') {
      throw new PhoneVerificationProviderError('Mock SMS verification is disabled in production.');
    }
    const code = crypto.randomInt(0, 1_000_000).toString().padStart(6, '0');
    const key = mockKey(phoneE164, purpose);
    mockCodes.set(key, {
      hash: mockHash(key, code),
      expiresAt: Date.now() + 5 * 60 * 1000,
    });
    if (process.env.NODE_ENV === 'test') {
      mockTestOutbox.set(key, code);
    }
    return { providerReference: `mock:${crypto.randomUUID()}` };
  }

  async verifyCode(
    phoneE164: string,
    code: string,
    purpose: PhoneVerificationPurpose,
  ): Promise<boolean> {
    const key = mockKey(phoneE164, purpose);
    const current = mockCodes.get(key);
    if (!current || current.expiresAt < Date.now()) {
      mockCodes.delete(key);
      mockTestOutbox.delete(key);
      return false;
    }
    const valid = crypto.timingSafeEqual(
      Buffer.from(current.hash, 'hex'),
      Buffer.from(mockHash(key, code), 'hex'),
    );
    if (valid) {
      mockCodes.delete(key);
      mockTestOutbox.delete(key);
    }
    return valid;
  }
}

const twilioRequest = async (
  path: string,
  body: URLSearchParams,
): Promise<Record<string, unknown>> => {
  const accountSid = process.env.TWILIO_ACCOUNT_SID?.trim() ?? '';
  const authToken = process.env.TWILIO_AUTH_TOKEN ?? '';
  if (!accountSid || !authToken) {
    throw new PhoneVerificationProviderError();
  }
  const response = await fetch(`https://verify.twilio.com/v2/${path}`, {
    method: 'POST',
    headers: {
      Authorization: `Basic ${Buffer.from(`${accountSid}:${authToken}`).toString('base64')}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body,
    signal: AbortSignal.timeout(Number(process.env.VERIFICATION_PROVIDER_TIMEOUT_MS || 10000)),
  });
  let payload: Record<string, unknown> = {};
  try {
    payload = (await response.json()) as Record<string, unknown>;
  } catch {
    // Provider response bodies are intentionally not exposed or logged.
  }
  if (!response.ok) {
    throw new PhoneVerificationProviderError();
  }
  return payload;
};

class TwilioVerifyPhoneVerificationProvider implements PhoneVerificationProvider {
  private get serviceSid(): string {
    const value = process.env.TWILIO_VERIFY_SERVICE_SID?.trim() ?? '';
    if (!value) {
      throw new PhoneVerificationProviderError();
    }
    return value;
  }

  async sendCode(
    phoneE164: string,
    _purpose: PhoneVerificationPurpose,
  ): Promise<PhoneVerificationSendResult> {
    const payload = await twilioRequest(
      `Services/${encodeURIComponent(this.serviceSid)}/Verifications`,
      new URLSearchParams({ To: phoneE164, Channel: 'sms' }),
    );
    return {
      providerReference: typeof payload.sid === 'string' ? payload.sid : null,
    };
  }

  async verifyCode(
    phoneE164: string,
    code: string,
    _purpose: PhoneVerificationPurpose,
  ): Promise<boolean> {
    const payload = await twilioRequest(
      `Services/${encodeURIComponent(this.serviceSid)}/VerificationCheck`,
      new URLSearchParams({ To: phoneE164, Code: code }),
    );
    return payload.status === 'approved' || payload.valid === true;
  }
}

let provider: PhoneVerificationProvider | null = null;

const getPhoneVerificationProvider = (): PhoneVerificationProvider => {
  if (getPhoneAssuranceMode() !== 'sms_otp') {
    throw new PhoneVerificationProviderError(
      'SMS ownership verification is not enabled by the current assurance policy.',
    );
  }
  if (provider) {
    return provider;
  }
  const mode = process.env.PHONE_VERIFICATION_PROVIDER?.trim() || 'mock';
  provider =
    mode === 'twilio_verify'
      ? new TwilioVerifyPhoneVerificationProvider()
      : new MockPhoneVerificationProvider();
  return provider;
};

const getMockPhoneVerificationCodeForTest = (
  phoneE164: string,
  purpose: PhoneVerificationPurpose,
): string => {
  if (process.env.NODE_ENV !== 'test') {
    throw new Error(
      'Mock verification codes are accessible only in the automated test environment.',
    );
  }
  const code = mockTestOutbox.get(mockKey(phoneE164, purpose));
  if (!code) {
    throw new Error('No pending mock SMS verification code exists for this target and purpose.');
  }
  return code;
};

const resetPhoneVerificationProviderForTest = (): void => {
  if (process.env.NODE_ENV !== 'test') {
    return;
  }
  provider = null;
  mockCodes.clear();
  mockTestOutbox.clear();
};

export {
  PhoneVerificationProviderError,
  getMockPhoneVerificationCodeForTest,
  getPhoneVerificationProvider,
  resetPhoneVerificationProviderForTest,
};
