import { isPhoneAssuranceSatisfied, type PhoneAssuranceRow } from './phoneAssurance.service';

interface ContactAssuranceRow extends PhoneAssuranceRow {
  role?: string | null;
  email_verified_at?: Date | string | null;
  contact_verification_exempted_at?: Date | string | null;
}

const isContactVerificationExempt = (user: ContactAssuranceRow): boolean =>
  user.role === 'admin' && user.contact_verification_exempted_at != null;

const isEmailAssuranceSatisfied = (user: ContactAssuranceRow): boolean =>
  user.email_verified_at != null || isContactVerificationExempt(user);

const isContactAssuranceSatisfied = (user: ContactAssuranceRow): boolean =>
  isContactVerificationExempt(user) ||
  (isEmailAssuranceSatisfied(user) && isPhoneAssuranceSatisfied(user));

export { isContactAssuranceSatisfied, isContactVerificationExempt, isEmailAssuranceSatisfied };
export type { ContactAssuranceRow };
