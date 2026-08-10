export type PhoneAssuranceMode = 'format_only' | 'sms_otp';

export interface PhoneAssuranceRow {
  phone_verified_at?: Date | string | null;
  phone_format_validated_at?: Date | string | null;
}

const getPhoneAssuranceMode = (): PhoneAssuranceMode =>
  process.env.PHONE_ASSURANCE_MODE?.trim() === 'sms_otp' ? 'sms_otp' : 'format_only';

const isPhoneOwnershipVerificationRequired = (): boolean => getPhoneAssuranceMode() === 'sms_otp';

const isPhoneAssuranceSatisfied = (user: PhoneAssuranceRow): boolean => {
  if (user.phone_verified_at != null) {
    return true;
  }
  return getPhoneAssuranceMode() === 'format_only' && user.phone_format_validated_at != null;
};

const phoneAssuranceLevel = (
  user: PhoneAssuranceRow,
): 'ownership_verified' | 'format_validated' | 'unvalidated' => {
  if (user.phone_verified_at != null) {
    return 'ownership_verified';
  }
  if (user.phone_format_validated_at != null) {
    return 'format_validated';
  }
  return 'unvalidated';
};

export {
  getPhoneAssuranceMode,
  isPhoneAssuranceSatisfied,
  isPhoneOwnershipVerificationRequired,
  phoneAssuranceLevel,
};
