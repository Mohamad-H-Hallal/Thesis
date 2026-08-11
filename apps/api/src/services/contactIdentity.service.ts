import { domainToASCII } from 'node:url';
import { parsePhoneNumberFromString } from 'libphonenumber-js/max';
import validator from 'validator';

export interface NormalizedEmailAddress {
  original: string;
  canonical: string;
  delivery: string;
}

export interface NormalizedLebaneseMobile {
  e164: string;
  national: string;
  display: string;
}

// The fallback ranges are intentionally narrow and centralized. They cover
// Lebanon ranges announced by the Ministry of Telecommunications in ITU-T
// Operational Bulletins 1318 (26 May 2025) and 1325 (16 September 2025) in
// case a deployed libphonenumber metadata snapshot predates those notices.
// libphonenumber-js/max remains the primary validator and type detector.
export const LEBANON_SUPPLEMENTAL_NUMBERING_PLAN_VERSION = 'ITU-2025-09-16';

const easternArabicDigitMap: Readonly<Record<string, string>> = Object.freeze({
  '٠': '0',
  '١': '1',
  '٢': '2',
  '٣': '3',
  '٤': '4',
  '٥': '5',
  '٦': '6',
  '٧': '7',
  '٨': '8',
  '٩': '9',
  '۰': '0',
  '۱': '1',
  '۲': '2',
  '۳': '3',
  '۴': '4',
  '۵': '5',
  '۶': '6',
  '۷': '7',
  '۸': '8',
  '۹': '9',
});

const normalizeUnicodeDigits = (value: string): string =>
  Array.from(value, (character) => easternArabicDigitMap[character] ?? character).join('');

const normalizePhoneInput = (value: unknown): string => {
  const normalizedDigits = normalizeUnicodeDigits(String(value ?? '').trim());
  if (normalizedDigits.startsWith('00')) {
    return `+${normalizedDigits.slice(2)}`;
  }
  return normalizedDigits;
};

const localNationalNumber = (input: string): string | null => {
  const compact = input.replace(/[^+\d]/g, '');
  if (compact.startsWith('+961')) {
    return compact.slice(4).replace(/^0/, '');
  }
  if (compact.startsWith('961')) {
    return compact.slice(3).replace(/^0/, '');
  }
  return compact.replace(/^0/, '');
};

const isSupplementalAllocatedLebaneseMobile = (national: string): boolean => {
  if (!/^\d{8}$/.test(national)) {
    return false;
  }
  const subscriber = Number.parseInt(national.slice(2), 10);
  if (national.startsWith('78')) {
    return subscriber >= 700000 && subscriber <= 999999;
  }
  if (national.startsWith('79')) {
    return (
      (subscriber >= 0 && subscriber <= 199999) || (subscriber >= 300000 && subscriber <= 499999)
    );
  }
  return false;
};

const normalizeEmailAddress = (value: unknown): NormalizedEmailAddress | null => {
  const original = String(value ?? '').trim();
  if (original.length === 0 || original.length > 320) {
    return null;
  }

  const atIndex = original.lastIndexOf('@');
  if (atIndex <= 0 || atIndex === original.length - 1) {
    return null;
  }
  const localPart = original.slice(0, atIndex);
  const rawDomain = original.slice(atIndex + 1).normalize('NFC');
  const asciiDomain = domainToASCII(rawDomain).toLowerCase();
  if (!asciiDomain) {
    return null;
  }

  const delivery = `${localPart}@${asciiDomain}`;
  if (
    !validator.isEmail(delivery, {
      allow_display_name: false,
      allow_utf8_local_part: true,
      require_tld: true,
      ignore_max_length: false,
    })
  ) {
    return null;
  }

  return {
    original,
    delivery,
    canonical: `${localPart.normalize('NFC').toLowerCase()}@${asciiDomain}`,
  };
};

const normalizeLebaneseMobile = (value: unknown): NormalizedLebaneseMobile | null => {
  const input = normalizePhoneInput(value);
  if (!input) {
    return null;
  }

  const parsed = parsePhoneNumberFromString(input, 'LB');
  if (
    parsed?.country === 'LB' &&
    parsed.countryCallingCode === '961' &&
    parsed.isPossible() &&
    parsed.isValid() &&
    parsed.getType() === 'MOBILE'
  ) {
    const national = parsed.nationalNumber;
    return {
      e164: parsed.number,
      national,
      display: formatLebaneseMobile(parsed.number),
    };
  }

  const national = localNationalNumber(input);
  if (!national || !isSupplementalAllocatedLebaneseMobile(national)) {
    return null;
  }
  const e164 = `+961${national}`;
  return { e164, national, display: formatLebaneseMobile(e164) };
};

const formatLebaneseMobile = (value: string): string => {
  const national = localNationalNumber(normalizePhoneInput(value)) ?? '';
  if (national.length === 7 && national.startsWith('3')) {
    return `+961 3 ${national.slice(1, 4)} ${national.slice(4)}`;
  }
  if (national.length === 8) {
    return `+961 ${national.slice(0, 2)} ${national.slice(2, 5)} ${national.slice(5)}`;
  }
  return value.trim();
};

const maskEmail = (email: string): string => {
  const normalized = normalizeEmailAddress(email);
  if (!normalized) {
    return '***';
  }
  const [local, domain] = normalized.original.split('@');
  return `${local.slice(0, 1)}***@${domain}`;
};

const maskLebaneseMobile = (phoneE164: string): string => {
  const normalized = normalizeLebaneseMobile(phoneE164);
  if (!normalized) {
    return '+961 ** *** ***';
  }
  if (normalized.national.length === 7) {
    return `+961 ${normalized.national[0]} *** ***`;
  }
  return `+961 ${normalized.national.slice(0, 2)} *** ***`;
};

export {
  formatLebaneseMobile,
  maskEmail,
  maskLebaneseMobile,
  normalizeEmailAddress,
  normalizeLebaneseMobile,
  normalizeUnicodeDigits,
};
