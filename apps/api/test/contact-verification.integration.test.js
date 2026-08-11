const {
  app,
  API_PREFIX,
  pool,
  request,
  authHeader,
  resetDb,
  shutdown,
  registerUser,
  createAdminUser,
  loginUser,
} = require('./helpers/api-test-helpers');
const {
  normalizeEmailAddress,
  normalizeLebaneseMobile,
} = require('../src/services/contactIdentity.service');
const {
  getMockEmailVerificationCodeForTest,
} = require('../src/services/contactVerification.service');
const {
  getMockPhoneVerificationCodeForTest,
} = require('../src/services/phoneVerificationProvider.service');
const {
  validateLebaneseMobileFormat,
} = require('../src/services/phoneFormatValidationProvider.service');

describe('contact identity validation', () => {
  test.each([
    ['03 123 456', '+9613123456'],
    ['70-123-456', '+96170123456'],
    ['+961 71 123 456', '+96171123456'],
    ['٧٦ ١٢٣ ٤٥٦', '+96176123456'],
    ['81 123 456', '+96181123456'],
  ])('normalizes %s to %s', (input, expected) => {
    expect(normalizeLebaneseMobile(input)?.e164).toBe(expected);
  });

  test.each(['12 345 678', '01 234 567', '+33 6 12 34 56 78', '70 12'])(
    'rejects non-Lebanese-mobile input %s',
    (input) => expect(normalizeLebaneseMobile(input)).toBeNull(),
  );

  test('retains display email and canonicalizes comparison key', () => {
    expect(normalizeEmailAddress('  User.Name+tag@EXAMPLE.COM  ')).toEqual({
      original: 'User.Name+tag@EXAMPLE.COM',
      delivery: 'User.Name+tag@example.com',
      canonical: 'user.name+tag@example.com',
    });
    expect(normalizeEmailAddress('not-an-email')).toBeNull();
  });

  test('keeps authenticated Twilio Basic Lookup available as an optional format provider', async () => {
    const originalProvider = process.env.PHONE_FORMAT_VALIDATION_PROVIDER;
    const originalAccountSid = process.env.TWILIO_ACCOUNT_SID;
    const originalAuthToken = process.env.TWILIO_AUTH_TOKEN;
    const originalFetch = global.fetch;
    try {
      process.env.PHONE_FORMAT_VALIDATION_PROVIDER = 'twilio_lookup_basic';
      process.env.TWILIO_ACCOUNT_SID = 'AC1234567890abcdef1234567890abcd';
      process.env.TWILIO_AUTH_TOKEN = 'test-lookup-auth-token';
      global.fetch = jest.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          valid: true,
          country_code: 'LB',
          phone_number: '+96170123456',
        }),
      });

      await expect(validateLebaneseMobileFormat('+96170123456')).resolves.toMatchObject({
        valid: true,
        phoneE164: '+96170123456',
        method: 'twilio_lookup_basic',
      });
      const requestedUrl = global.fetch.mock.calls[0][0];
      expect(requestedUrl).toContain('/v2/PhoneNumbers/%2B96170123456');
      expect(requestedUrl).not.toContain('Fields');
    } finally {
      if (originalProvider == null) delete process.env.PHONE_FORMAT_VALIDATION_PROVIDER;
      else process.env.PHONE_FORMAT_VALIDATION_PROVIDER = originalProvider;
      if (originalAccountSid == null) delete process.env.TWILIO_ACCOUNT_SID;
      else process.env.TWILIO_ACCOUNT_SID = originalAccountSid;
      if (originalAuthToken == null) delete process.env.TWILIO_AUTH_TOKEN;
      else process.env.TWILIO_AUTH_TOKEN = originalAuthToken;
      global.fetch = originalFetch;
    }
  });
});

describe('contact ownership verification API', () => {
  beforeEach(resetDb);
  afterAll(shutdown);

  test('blocks full access until email and SMS ownership are confirmed', async () => {
    const email = `ownership-${Date.now()}@example.com`;
    const phone = '71123456';
    const password = 'Passw0rd!123';
    const registration = await request(app).post(`${API_PREFIX}/auth/register`).send({
      email,
      phone,
      password,
      full_name: 'Ownership Test',
      role: 'viewer',
    });

    expect(registration.status).toBe(201);
    expect(registration.body.data.token).toBeUndefined();
    expect(registration.body.data.user.email_verified_at).toBeNull();
    expect(registration.body.data.user.phone_verified_at).toBeNull();
    let verificationToken = registration.body.data.verification_token;

    const earlyLogin = await request(app)
      .post(`${API_PREFIX}/auth/login`)
      .send({ email, password });
    expect(earlyLogin.status).toBe(403);
    expect(earlyLogin.body.error.code).toBe('CONTACT_VERIFICATION_REQUIRED');

    const resendTooSoon = await request(app)
      .post(`${API_PREFIX}/auth/verification/email/send`)
      .set(authHeader(verificationToken))
      .send({});
    expect(resendTooSoon.status).toBe(429);
    expect(resendTooSoon.headers['retry-after']).toBeDefined();

    const emailCode = getMockEmailVerificationCodeForTest(email, 'signup');
    const emailConfirmation = await request(app)
      .post(`${API_PREFIX}/auth/verification/email/confirm`)
      .set(authHeader(verificationToken))
      .send({ code: emailCode });
    expect(emailConfirmation.status).toBe(200);
    expect(emailConfirmation.body.data.verification.next_step).toBe('phone');
    verificationToken = emailConfirmation.body.data.verification_token;

    const smsSend = await request(app)
      .post(`${API_PREFIX}/auth/verification/phone/send`)
      .set(authHeader(verificationToken))
      .send({});
    expect(smsSend.status).toBe(200);
    const smsCode = getMockPhoneVerificationCodeForTest('+96171123456', 'signup');
    const [first, concurrentReplay] = await Promise.all([
      request(app)
        .post(`${API_PREFIX}/auth/verification/phone/confirm`)
        .set(authHeader(verificationToken))
        .send({ code: smsCode }),
      request(app)
        .post(`${API_PREFIX}/auth/verification/phone/confirm`)
        .set(authHeader(verificationToken))
        .send({ code: smsCode }),
    ]);
    expect([first.status, concurrentReplay.status].sort()).toEqual([200, 400]);
    const successfulConfirmation = [first, concurrentReplay].find(
      (response) => response.status === 200,
    );
    expect(successfulConfirmation.body.data.token).toBeUndefined();
    expect(successfulConfirmation.body.data.refreshToken).toBeUndefined();

    const authenticated = await loginUser({ email, password });
    expect(authenticated.token).toBeTruthy();
    const stored = await pool.query(
      `SELECT email_canonical, email_verified_at, phone_e164, phone_verified_at,
              account_status
       FROM "user" WHERE email_canonical = $1`,
      [email],
    );
    expect(stored.rows[0]).toMatchObject({
      email_canonical: email,
      phone_e164: '+96171123456',
      account_status: 'active',
    });
    expect(stored.rows[0].email_verified_at).not.toBeNull();
    expect(stored.rows[0].phone_verified_at).not.toBeNull();
    const challenge = await pool.query(
      `SELECT secret_hash, consumed_at FROM contact_verification_challenge
       WHERE channel = 'email' ORDER BY created_at DESC LIMIT 1`,
    );
    expect(challenge.rows[0].secret_hash).not.toContain(emailCode);
    expect(challenge.rows[0].consumed_at).not.toBeNull();
  });

  test('provider-free validation grants format assurance without claiming ownership and promotes safely to SMS policy', async () => {
    const originalMode = process.env.PHONE_ASSURANCE_MODE;
    const originalFormatProvider = process.env.PHONE_FORMAT_VALIDATION_PROVIDER;
    const originalFetch = global.fetch;
    const email = `format-${Date.now()}@example.com`;
    const password = 'Passw0rd!123';

    try {
      process.env.PHONE_ASSURANCE_MODE = 'format_only';
      process.env.PHONE_FORMAT_VALIDATION_PROVIDER = 'libphonenumber';
      global.fetch = jest.fn(() => {
        throw new Error('Provider-free validation must not make a network request.');
      });

      const registration = await request(app).post(`${API_PREFIX}/auth/register`).send({
        email,
        phone: '70 123 456',
        password,
        full_name: 'Format Assurance Test',
        role: 'viewer',
      });
      const verificationToken = registration.body.data.verification_token;
      const emailCode = getMockEmailVerificationCodeForTest(email, 'signup');
      expect(registration.body.data.verification).toMatchObject({
        next_step: 'email',
        phone_format_validated: true,
        phone_verified: false,
      });

      const emailConfirmation = await request(app)
        .post(`${API_PREFIX}/auth/verification/email/confirm`)
        .set(authHeader(verificationToken))
        .send({ code: emailCode });
      expect(emailConfirmation.status).toBe(200);
      expect(emailConfirmation.body.data.verification).toMatchObject({
        next_step: 'complete',
        phone_assurance_mode: 'format_only',
        phone_ownership_required: false,
        phone_format_validated: true,
      });
      expect(emailConfirmation.body.data.token).toBeUndefined();
      expect(emailConfirmation.body.data.refreshToken).toBeUndefined();
      expect(emailConfirmation.body.data.user).toMatchObject({
        phone: '+96170123456',
        phone_verified_at: null,
        phone_assurance_level: 'format_validated',
      });
      expect(global.fetch).not.toHaveBeenCalled();

      const stored = await pool.query(
        `SELECT phone_e164, phone_verified_at, phone_format_validated_at,
                phone_validation_method
         FROM "user" WHERE email_canonical = $1`,
        [email],
      );
      expect(stored.rows[0]).toMatchObject({
        phone_e164: '+96170123456',
        phone_verified_at: null,
        phone_validation_method: 'libphonenumber_max',
      });
      expect(stored.rows[0].phone_format_validated_at).not.toBeNull();

      const formatAssuredLogin = await request(app)
        .post(`${API_PREFIX}/auth/login`)
        .send({ email, password });
      expect(formatAssuredLogin.status).toBe(200);

      process.env.PHONE_ASSURANCE_MODE = 'sms_otp';
      const promotedLogin = await request(app)
        .post(`${API_PREFIX}/auth/login`)
        .send({ email, password });
      expect(promotedLogin.status).toBe(403);
      expect(promotedLogin.body.error.code).toBe('CONTACT_VERIFICATION_REQUIRED');
      expect(promotedLogin.body.data.verification).toMatchObject({
        next_step: 'phone',
        phone_verified: false,
        phone_format_validated: true,
        phone_ownership_required: true,
      });
    } finally {
      if (originalMode == null) delete process.env.PHONE_ASSURANCE_MODE;
      else process.env.PHONE_ASSURANCE_MODE = originalMode;
      if (originalFormatProvider == null) delete process.env.PHONE_FORMAT_VALIDATION_PROVIDER;
      else process.env.PHONE_FORMAT_VALIDATION_PROVIDER = originalFormatProvider;
      global.fetch = originalFetch;
    }
  });

  test('limits attempts and invalidates replacement challenges', async () => {
    const email = `limits-${Date.now()}@example.com`;
    const registration = await request(app).post(`${API_PREFIX}/auth/register`).send({
      email,
      phone: '71234567',
      password: 'Passw0rd!123',
      full_name: 'Limits Test',
      role: 'viewer',
    });
    const token = registration.body.data.verification_token;
    const firstCode = getMockEmailVerificationCodeForTest(email, 'signup');
    await pool.query(
      `UPDATE contact_verification_challenge
       SET created_at = created_at - INTERVAL '20 seconds',
           last_sent_at = last_sent_at - INTERVAL '20 seconds'
       WHERE channel = 'email' AND purpose = 'signup'`,
    );
    const replacement = await request(app)
      .post(`${API_PREFIX}/auth/verification/email/send`)
      .set(authHeader(token))
      .send({});
    expect(replacement.status).toBe(200);
    const replaced = await request(app)
      .post(`${API_PREFIX}/auth/verification/email/confirm`)
      .set(authHeader(token))
      .send({ code: firstCode });
    expect(replaced.status).toBe(400);

    for (let attempt = 1; attempt <= 4; attempt += 1) {
      const wrong = await request(app)
        .post(`${API_PREFIX}/auth/verification/email/confirm`)
        .set(authHeader(token))
        .send({ code: '000000' });
      expect(wrong.status).toBe(attempt === 4 ? 429 : 400);
    }
  });

  test('rejects an expired email challenge without verifying ownership', async () => {
    const email = `expired-${Date.now()}@example.com`;
    const registration = await request(app).post(`${API_PREFIX}/auth/register`).send({
      email,
      phone: '71678901',
      password: 'Passw0rd!123',
      full_name: 'Expired Test',
      role: 'viewer',
    });
    const code = getMockEmailVerificationCodeForTest(email, 'signup');
    await pool.query(
      `UPDATE contact_verification_challenge
       SET created_at = CURRENT_TIMESTAMP - INTERVAL '10 minutes',
           expires_at = CURRENT_TIMESTAMP - INTERVAL '1 second'
       WHERE user_id = $1 AND channel = 'email' AND purpose = 'signup'`,
      [registration.body.data.user.id],
    );
    const confirmation = await request(app)
      .post(`${API_PREFIX}/auth/verification/email/confirm`)
      .set(authHeader(registration.body.data.verification_token))
      .send({ code });
    expect(confirmation.status).toBe(400);
    expect(confirmation.body.error.code).toBe('VERIFICATION_CODE_EXPIRED');
    const stored = await pool.query(`SELECT email_verified_at FROM "user" WHERE id = $1`, [
      registration.body.data.user.id,
    ]);
    expect(stored.rows[0].email_verified_at).toBeNull();
  });

  test('keeps email unique and allows at most three accounts per normalized phone', async () => {
    const account = await registerUser({
      role: 'viewer',
      emailPrefix: 'canonical-identity',
      phone: '71789012',
    });
    const duplicateEmail = await request(app).post(`${API_PREFIX}/auth/register`).send({
      email: account.email.toUpperCase(),
      phone: '71890123',
      password: 'Passw0rd!123',
      full_name: 'Duplicate Email',
      role: 'viewer',
    });
    expect(duplicateEmail.status).toBe(409);
    expect(duplicateEmail.body.error.code).toBe('EMAIL_ALREADY_IN_USE');

    const signupWithSharedPhone = (suffix) =>
      request(app)
        .post(`${API_PREFIX}/auth/register`)
        .send({
          email: `shared-phone-${suffix}-${Date.now()}@example.com`,
          phone: '+961 71 789 012',
          password: 'Passw0rd!123',
          full_name: `Shared Phone ${suffix}`,
          role: 'viewer',
        });

    const secondAccount = await signupWithSharedPhone('second');
    expect(secondAccount.status).toBe(201);

    const contenders = await Promise.all([
      signupWithSharedPhone('third'),
      signupWithSharedPhone('fourth'),
    ]);
    expect(contenders.map((response) => response.status).sort()).toEqual([201, 409]);
    const overLimit = contenders.find((response) => response.status === 409);
    expect(overLimit).toBeDefined();
    expect(overLimit.status).toBe(409);
    expect(overLimit.body.error.code).toBe('PHONE_ACCOUNT_LIMIT_REACHED');
    expect(overLimit.body.message).toContain('maximum of 3 accounts');

    await expect(
      pool.query(
        `INSERT INTO "user"
           (email, email_original, email_canonical, password_hash, full_name,
            phone, phone_e164, role, is_active, account_status, verification_required_at)
         VALUES ($1, $1, $1, 'not-a-real-password-hash', 'Direct DB Fourth',
                 $2, $2, 'viewer', FALSE, 'pending_verification', CURRENT_TIMESTAMP)`,
        [`direct-fourth-${Date.now()}@example.com`, '+96171789012'],
      ),
    ).rejects.toMatchObject({
      code: '23514',
      constraint: 'user_phone_account_limit',
    });

    await request(app)
      .delete(`${API_PREFIX}/auth/verification/pending-signup`)
      .set(authHeader(secondAccount.body.data.verification_token))
      .expect(200);

    const releasedSlot = await signupWithSharedPhone('replacement');
    expect(releasedSlot.status).toBe(201);

    const stored = await pool.query(
      `SELECT COUNT(*)::int AS account_count FROM "user" WHERE phone_e164 = $1`,
      ['+96171789012'],
    );
    expect(stored.rows[0].account_count).toBe(3);
  });

  test('keeps account email immutable after registration', async () => {
    const account = await registerUser({ role: 'viewer', phone: '71345678' });
    const session = await loginUser({ email: account.email, password: account.password });
    const newEmail = `changed-${Date.now()}@example.com`;

    const removedRoute = await request(app)
      .post(`${API_PREFIX}/auth/me/email-change/request`)
      .set(authHeader(session.token))
      .send({ email: newEmail, current_password: account.password });
    expect(removedRoute.status).toBe(404);

    const directProfileUpdate = await request(app)
      .put(`${API_PREFIX}/auth/me`)
      .set(authHeader(session.token))
      .send({ email: newEmail });
    expect(directProfileUpdate.status).toBe(400);
    expect(directProfileUpdate.body.error.code).toBe('ACCOUNT_EMAIL_IMMUTABLE');

    expect(
      (await loginUser({ email: account.email, password: account.password })).token,
    ).toBeTruthy();
  });

  test('cancels only an unfinished self-signup and releases its contacts', async () => {
    const originalMode = process.env.PHONE_ASSURANCE_MODE;
    process.env.PHONE_ASSURANCE_MODE = 'format_only';
    const email = `cancel-${Date.now()}@example.com`;
    const phone = '70345678';
    try {
      const registration = await request(app).post(`${API_PREFIX}/auth/register`).send({
        email,
        phone,
        password: 'Passw0rd!123',
        full_name: 'Cancelled Signup',
        role: 'viewer',
      });
      const cancelled = await request(app)
        .delete(`${API_PREFIX}/auth/verification/pending-signup`)
        .set(authHeader(registration.body.data.verification_token));
      expect(cancelled.status).toBe(200);

      const removed = await pool.query(`SELECT id FROM "user" WHERE email_canonical = $1`, [email]);
      expect(removed.rowCount).toBe(0);
      const audit = await pool.query(
        `SELECT event_type, user_id, masked_target
         FROM contact_verification_audit_event
         WHERE event_type = 'pending_signup_cancelled'
         ORDER BY created_at DESC LIMIT 1`,
      );
      expect(audit.rows[0]).toMatchObject({
        event_type: 'pending_signup_cancelled',
        user_id: null,
        masked_target: 'c***@example.com',
      });

      const retry = await request(app).post(`${API_PREFIX}/auth/register`).send({
        email,
        phone,
        password: 'Passw0rd!123',
        full_name: 'Signup Retried',
        role: 'viewer',
      });
      expect(retry.status).toBe(201);
    } finally {
      if (originalMode == null) delete process.env.PHONE_ASSURANCE_MODE;
      else process.env.PHONE_ASSURANCE_MODE = originalMode;
    }
  });

  test('requires re-authentication and keeps the old phone until SMS confirmation', async () => {
    const account = await registerUser({ role: 'viewer', phone: '71456789' });
    const session = await loginUser({ email: account.email, password: account.password });
    const newPhone = '+961 76 123 457';

    const denied = await request(app)
      .post(`${API_PREFIX}/auth/me/phone-change/request`)
      .set(authHeader(session.token))
      .send({ phone: newPhone, current_password: 'wrong-password' });
    expect(denied.status).toBe(401);

    const requested = await request(app)
      .post(`${API_PREFIX}/auth/me/phone-change/request`)
      .set(authHeader(session.token))
      .send({ phone: newPhone, current_password: account.password });
    expect(requested.status).toBe(200);
    const before = await pool.query(`SELECT phone_e164 FROM "user" WHERE id = $1`, [
      account.user.id,
    ]);
    expect(before.rows[0].phone_e164).toBe('+96171456789');

    const code = getMockPhoneVerificationCodeForTest('+96176123457', 'change_phone');
    const confirmed = await request(app)
      .post(`${API_PREFIX}/auth/me/phone-change/confirm`)
      .set(authHeader(session.token))
      .send({ code });
    expect(confirmed.status).toBe(200);
    expect(confirmed.body.data.user.phone).toBe('+96176123457');

    const oldTokenUse = await request(app)
      .get(`${API_PREFIX}/auth/me`)
      .set(authHeader(session.token));
    expect(oldTokenUse.status).toBe(401);
  });

  test('password recovery is anti-enumerating, single-use, and revokes old sessions', async () => {
    const account = await registerUser({ role: 'viewer', phone: '71567890' });
    const oldSession = await loginUser({ email: account.email, password: account.password });

    const unknown = await request(app)
      .post(`${API_PREFIX}/auth/forgot-password`)
      .send({ email: `missing-${Date.now()}@example.com` });
    expect(unknown.status).toBe(200);
    expect(unknown.body.data.email).toBeUndefined();

    const requested = await request(app)
      .post(`${API_PREFIX}/auth/forgot-password`)
      .send({ email: account.email });
    expect(requested.status).toBe(200);
    expect(requested.body.message).toBe(unknown.body.message);
    const code = getMockEmailVerificationCodeForTest(account.email, 'recovery');
    const verified = await request(app)
      .post(`${API_PREFIX}/auth/verify-reset-otp`)
      .send({ email: account.email, otp: code });
    expect(verified.status).toBe(200);

    const replay = await request(app)
      .post(`${API_PREFIX}/auth/verify-reset-otp`)
      .send({ email: account.email, otp: code });
    expect(replay.status).toBe(400);

    const reset = await request(app).post(`${API_PREFIX}/auth/reset-password`).send({
      reset_token: verified.body.data.reset_token,
      new_password: 'N3wPassw0rd!456',
    });
    expect(reset.status).toBe(200);
    const oldTokenUse = await request(app)
      .get(`${API_PREFIX}/auth/me`)
      .set(authHeader(oldSession.token));
    expect(oldTokenUse.status).toBe(401);
    expect(
      (await loginUser({ email: account.email, password: 'N3wPassw0rd!456' })).token,
    ).toBeTruthy();
  });

  test('protected-super-admin-created admins are active through an explicit exemption', async () => {
    const protectedAdmin = await createAdminUser({
      email: process.env.SUPER_ADMIN_EMAIL,
      phone: '71901234',
    });
    const invitedEmail = `invited-admin-${Date.now()}@example.com`;
    const created = await request(app)
      .post(`${API_PREFIX}/users/admin`)
      .set(authHeader(protectedAdmin.token))
      .send({
        email: invitedEmail,
        phone: '76123456',
        password: 'Passw0rd!123',
        full_name: 'Invited Admin',
      });
    expect(created.status).toBe(201);
    expect(created.body.data).toMatchObject({
      is_active: true,
      account_status: 'active',
      email_verified_at: null,
      phone_verified_at: null,
    });
    expect(created.body.data.contact_verification_exempted_at).toBeTruthy();
    expect(created.body.data.contact_verification_exempted_by).toBe(protectedAdmin.user.id);

    const login = await request(app)
      .post(`${API_PREFIX}/auth/login`)
      .send({ email: invitedEmail, password: 'Passw0rd!123' });
    expect(login.status).toBe(200);
    expect(login.body.data.token).toBeTruthy();
    const challenges = await pool.query(
      `SELECT COUNT(*)::int AS count
       FROM contact_verification_challenge
       WHERE user_id = $1`,
      [created.body.data.id],
    );
    expect(challenges.rows[0].count).toBe(0);
  });
});
