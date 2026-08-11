import { normalizeLebaneseMobile } from './contactIdentity.service';

type PhoneFormatValidationMethod = 'libphonenumber_max' | 'twilio_lookup_basic';

interface PhoneFormatValidationResult {
  valid: boolean;
  phoneE164: string | null;
  method: PhoneFormatValidationMethod;
  providerReference: string;
}

class PhoneFormatValidationProviderError extends Error {
  constructor(message = 'Phone-number validation is temporarily unavailable.') {
    super(message);
    this.name = 'PhoneFormatValidationProviderError';
  }
}

const validateWithLocalMetadata = (phoneE164: string): PhoneFormatValidationResult => {
  const normalized = normalizeLebaneseMobile(phoneE164);
  return {
    valid: normalized != null,
    phoneE164: normalized?.e164 ?? null,
    method: 'libphonenumber_max',
    providerReference: 'libphonenumber-js/max',
  };
};

const validateWithTwilioLookupBasic = async (
  phoneE164: string,
): Promise<PhoneFormatValidationResult> => {
  const locallyValidated = validateWithLocalMetadata(phoneE164);
  if (!locallyValidated.valid || !locallyValidated.phoneE164) {
    return {
      ...locallyValidated,
      method: 'twilio_lookup_basic',
      providerReference: 'twilio_lookup_basic',
    };
  }

  const accountSid = process.env.TWILIO_ACCOUNT_SID?.trim() ?? '';
  const authToken = process.env.TWILIO_AUTH_TOKEN ?? '';
  if (!accountSid || !authToken) {
    throw new PhoneFormatValidationProviderError();
  }

  let response: Response;
  try {
    response = await fetch(
      `https://lookups.twilio.com/v2/PhoneNumbers/${encodeURIComponent(locallyValidated.phoneE164)}`,
      {
        method: 'GET',
        headers: {
          Authorization: `Basic ${Buffer.from(`${accountSid}:${authToken}`).toString('base64')}`,
          Accept: 'application/json',
        },
        signal: AbortSignal.timeout(Number(process.env.VERIFICATION_PROVIDER_TIMEOUT_MS || 10000)),
      },
    );
  } catch {
    throw new PhoneFormatValidationProviderError();
  }

  let payload: Record<string, unknown> = {};
  try {
    payload = (await response.json()) as Record<string, unknown>;
  } catch {
    // Provider bodies are intentionally never logged or returned to callers.
  }
  if (!response.ok) {
    throw new PhoneFormatValidationProviderError();
  }

  const remotePhone =
    typeof payload.phone_number === 'string' ? normalizeLebaneseMobile(payload.phone_number) : null;
  const valid =
    payload.valid === true &&
    payload.country_code === 'LB' &&
    remotePhone?.e164 === locallyValidated.phoneE164;

  return {
    valid,
    phoneE164: valid ? locallyValidated.phoneE164 : null,
    method: 'twilio_lookup_basic',
    providerReference: 'twilio_lookup_basic',
  };
};

const validateLebaneseMobileFormat = async (
  phoneE164: string,
): Promise<PhoneFormatValidationResult> => {
  const provider = process.env.PHONE_FORMAT_VALIDATION_PROVIDER?.trim();
  if (provider === 'twilio_lookup_basic') {
    return validateWithTwilioLookupBasic(phoneE164);
  }
  return validateWithLocalMetadata(phoneE164);
};

export {
  PhoneFormatValidationProviderError,
  validateLebaneseMobileFormat,
  type PhoneFormatValidationMethod,
  type PhoneFormatValidationResult,
};
