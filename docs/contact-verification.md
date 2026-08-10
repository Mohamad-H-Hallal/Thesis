# TerraLeb contact assurance

## Trust model

TerraLeb always distinguishes structural validation from ownership:

- Email ownership is proven only by a successful single-use email challenge.
- `PHONE_ASSURANCE_MODE=format_only` validates and normalizes a Lebanese mobile
  number but does not claim that it is assigned, reachable, or owned by the
  user. It records `phone_format_validated_at` and a validation method; it never
  records `phone_verified_at`.
- `PHONE_ASSURANCE_MODE=sms_otp` proves possession through the configured SMS
  verification provider. Only successful OTP confirmation records
  `phone_verified_at`.

Account identity contacts use this policy. Support settings and third-party
contacts captured in project data receive syntax/structure validation and
normalization without incorrectly forcing the signed-in user to prove
ownership.

Completing signup verification never signs the user in automatically. Signup
verification endpoints do not issue full-access or refresh tokens; the mobile
client clears the limited verification session and returns to the sign-in
screen. The user must then enter their credentials explicitly.

The protected super administrator's dedicated admin-creation endpoint is the
only account-creation exemption. It creates an active administrator without
sending ownership challenges, records the granting super administrator and
exemption timestamp, and deliberately leaves `email_verified_at` and
`phone_verified_at` empty so the database does not falsely claim ownership
verification. Public signup, contributor signup, recovery, and ordinary
account changes remain subject to their configured verification policies.

Email remains a unique login identity. A normalized Lebanese mobile number may
be associated with at most three user accounts. The limit counts active,
inactive, invited, and unfinished pending accounts so changing account state
cannot bypass it. Cancelling an eligible unfinished signup deletes that pending
account and releases its slot. The API returns `PHONE_ACCOUNT_LIMIT_REACHED`
when a fourth account is attempted, and the database enforces the same hard cap
under concurrent requests.

The account email is fixed after registration. It is displayed read-only in
the profile, rejected by direct profile-update requests, and there are no
email-change API routes. During an unfinished self-signup, **Back to signup**
atomically removes only that unverified pending account and invalidates its
challenges so the person can correct every signup field and register again.
Verified, invited, administrator, and migrated accounts cannot use this
cancellation path.

## Default provider-free policy

Lebanon is not currently listed among Twilio's supported trial countries. A
Twilio Basic Lookup request may have a zero per-request price, but it remains an
authenticated API and therefore cannot be used from a new Lebanon-region
account without upgrading. TerraLeb does not require that account for its
default path.

The production-capable no-payment configuration is:

```dotenv
PHONE_ASSURANCE_MODE=format_only
PHONE_FORMAT_VALIDATION_PROVIDER=libphonenumber
PHONE_ACCOUNT_REUSE_LIMIT=3

# Inactive until the policy is deliberately promoted to SMS ownership checks.
PHONE_VERIFICATION_PROVIDER=twilio_verify
TWILIO_ACCOUNT_SID=
TWILIO_AUTH_TOKEN=
TWILIO_VERIFY_SERVICE_SID=
```

This path requires no external account, card, API key, network call, trial, or
per-validation fee. The API remains authoritative and uses
`libphonenumber-js/max`. Flutter uses `phone_numbers_parser` for immediate
feedback. Both require Lebanon (`LB`, `+961`) and mobile number type.

Accepted account input includes local `03`, `70`, `71`, `76`, allocated `78`
and `79`, and `81` mobile formats, as well as `+961` forms and punctuation.
Arabic-Indic and Eastern Arabic-Indic digits are converted. Storage is E.164;
for example, `03 123 456` becomes `+9613123456`. Inputs such as `12 345 678`,
Lebanese landlines, foreign numbers, and wrong lengths are rejected.

Google's libphonenumber metadata validates whether a documented numbering
range can be assigned. It cannot determine whether a particular number is
currently assigned or reachable. TerraLeb communicates that limitation in the
UI and reserves ownership claims for OTP.

## Lebanese numbering metadata

A narrowly scoped fallback exists only for newly announced 78 and 79 ranges in
case a deployed library snapshot is stale. Its version is `ITU-2025-09-16`,
defined once in `contactIdentity.service.ts`, based on Lebanese Ministry of
Telecommunications changes published through ITU-T Operational Bulletins 1318
(26 May 2025) and 1325 (16 September 2025).

Update `libphonenumber-js` and `phone_numbers_parser` metadata first. Update the
fallback and its tests only when a newer official Lebanese plan requires it.

## Optional Twilio Basic Lookup

The Twilio adapter remains available for a future organization-owned Twilio
account. It requests only Basic formatting/validation and does not request paid
`Fields` data packages:

```dotenv
PHONE_ASSURANCE_MODE=format_only
PHONE_FORMAT_VALIDATION_PROVIDER=twilio_lookup_basic
TWILIO_ACCOUNT_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_AUTH_TOKEN=provider-secret
```

This changes only the structural validation source. It still records
`phone_format_validated_at`, not `phone_verified_at`, and still does not prove
possession. Production startup requires safe Twilio credentials only when this
optional provider is selected.

Do not register with false regional information or use another person's
account. Use this option only if CNRS supplies an authorized organizational
account.

## Promoting to SMS ownership verification

When management approves phone-possession verification and its provider cost:

```dotenv
PHONE_ASSURANCE_MODE=sms_otp
PHONE_VERIFICATION_PROVIDER=twilio_verify
TWILIO_ACCOUNT_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_AUTH_TOKEN=provider-secret
TWILIO_VERIFY_SERVICE_SID=VAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Restart the API after changing the policy. Lookup- or locally-format-validated
accounts are then routed to SMS OTP automatically on their next login or token
refresh. User IDs, roles, projects, permissions, and contact values are not
rewritten. Production startup fails if SMS mode uses a mock provider or lacks
safe Verify credentials.

The existing `PhoneVerificationProvider` abstraction also permits a future
approved Lebanese SMS vendor without coupling controllers to Twilio.

## Existing-user and database migration

Migrations 0045 through 0052 preserve user IDs, passwords, roles, projects,
assignments, contributions, and relationships. Existing contacts are never
silently marked as verified.

Migration 0049 safely renames the Lookup-specific timestamp to
`phone_format_validated_at`, preserves any existing values, permits both local
and Twilio validation methods, and distinguishes phone-format audit events from
SMS events. Direct phone identity changes clear the assurance associated with
the previous value.

Migration 0050 adds the masked `pending_signup_cancelled` audit event required
by the safe return-to-signup flow. Challenge rows are deleted through the
existing user-scoped cascade; no verification token or code is retained.

Migration 0051 replaces single-owner phone uniqueness with indexed lookups and
a transaction-safe database trigger that permits no more than three accounts
per E.164 value. `PHONE_ACCOUNT_REUSE_LIMIT` may be reduced to one or two for a
stricter deployment, while the database remains a non-bypassable hard maximum
of three. Email uniqueness is unchanged.

Migration 0052 normalizes unambiguous legacy Lebanese mobile values that
predate `phone_e164`. If legacy data already contains more than three accounts
using one number, those accounts are preserved rather than rewritten or
deleted, but that number cannot be assigned to any additional account. Such a
grandfathered group can only shrink as accounts move to other phone numbers.

## Email and operational configuration

Email ownership delivery still requires the existing transactional SMTP
configuration: `MAIL_TRANSPORT=smtp`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURE`,
and, when required, `SMTP_USER`/`SMTP_PASS`.

Registration sends one email challenge. Opening the verification screen does
not send a duplicate challenge; a resend is explicit and cooldown-protected.
If initial SMTP submission fails, the new unverified pending account is rolled
back so its email and phone are not stranded. SMTP acceptance proves only that
the recipient server accepted the message; institutional spam/quarantine rules
can still delay or filter it.

Use a dedicated high-entropy `VERIFICATION_HMAC_SECRET`. Challenge validity,
attempt limits, cooldown, temporary blocks, daily per-target/account/IP/device
caps, and provider timeouts are configurable. Validation and verification
attempts are purpose-bound, rate-limited, transactionally consumed, and audited
with masked targets. Secrets, codes, verification URLs, and raw targets are not
logged.

Automated tests use local email/SMS providers and replace optional network
providers with stubs. Tests never send real email or SMS.

## Deployment sequence

1. Create and verify a PostgreSQL custom-format backup.
2. Keep the provider-free settings shown above unless management authorizes an
   external service.
3. Configure SMTP, HMAC, rate-limit, and Redis secrets.
4. Apply migrations normally; do not reset or reseed.
5. Deploy the API and Flutter client.
6. Smoke-test a valid and invalid Lebanese mobile number.
7. Confirm the UI says format validated and does not claim ownership.
8. Monitor masked validation audit events and rate limits.

Official references:

- [Twilio trial country availability](https://www.twilio.com/docs/usage/trials)
- [Twilio Lookup authentication](https://www.twilio.com/docs/lookup/quickstart)
- [Google libphonenumber validation FAQ](https://github.com/google/libphonenumber/blob/master/FAQ.md)
