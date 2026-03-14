const {
  API_PREFIX,
  app,
  pool,
  request,
  authHeader,
  resetDb,
  shutdown,
  registerUser,
  createAdminUser,
  loginUser,
  approveContributorRequest,
} = require('./helpers/api-test-helpers');

describe('Security: registration, contributor approval, and protected super admin controls', () => {
  beforeEach(async () => {
    await resetDb();
    process.env.SUPER_ADMIN_EMAIL = 'superadmin@gov.lb';
  });

  afterAll(async () => {
    await resetDb();
    delete process.env.SUPER_ADMIN_EMAIL;
    await shutdown();
  });

  test('public register rejects admin role request', async () => {
    const email = `security-${Date.now()}@example.com`;
    const response = await request(app)
      .post(`${API_PREFIX}/auth/register`)
      .send({
        email,
        password: 'Passw0rd!123',
        full_name: 'Security Candidate',
        phone: '+96170000000',
        role: 'admin',
      });

    expect(response.status).toBe(400);
    expect(response.body.success).toBe(false);

    const check = await pool.query('SELECT role FROM "user" WHERE email = $1', [email]);
    expect(check.rows).toHaveLength(0);
  });

  test('pending contributor cannot login until approved by admin', async () => {
    const admin = await createAdminUser({
      fullName: 'Security Admin',
      emailPrefix: 'security-admin',
    });
    const contributor = await registerUser({
      role: 'contributor',
      fullName: 'Pending Contributor',
      emailPrefix: 'pending-contributor',
    });

    expect(contributor.message).toBe('Your contributor request is pending admin approval.');

    const pendingLogin = await request(app)
      .post(`${API_PREFIX}/auth/login`)
      .send({
        email: contributor.email,
        password: contributor.password,
      });

    expect(pendingLogin.status).toBe(403);
    expect(pendingLogin.body.message).toBe('Your contributor request is still pending approval.');

    await approveContributorRequest({
      token: admin.token,
      userId: contributor.user.id,
    });

    const approvedLogin = await request(app)
      .post(`${API_PREFIX}/auth/login`)
      .send({
        email: contributor.email,
        password: contributor.password,
      });

    expect(approvedLogin.status).toBe(200);
    expect(approvedLogin.body.data.user.role).toBe('contributor');
  });

  test('rejected contributor is downgraded to viewer and can login', async () => {
    const admin = await createAdminUser({
      fullName: 'Security Admin',
      emailPrefix: 'security-admin',
    });
    const contributor = await registerUser({
      role: 'contributor',
      fullName: 'Rejected Contributor',
      emailPrefix: 'rejected-contributor',
    });

    const rejectResponse = await request(app)
      .post(`${API_PREFIX}/users/${contributor.user.id}/reject-contributor`)
      .set(authHeader(admin.token));

    expect(rejectResponse.status).toBe(200);
    expect(rejectResponse.body.data.role).toBe('viewer');
    expect(rejectResponse.body.data.is_active).toBe(true);

    const viewerLogin = await loginUser({
      email: contributor.email,
      password: contributor.password,
    });

    expect(viewerLogin.user.role).toBe('viewer');
  });

  test('only protected super admin can create admin users or manage protected super admin account', async () => {
    const superAdmin = await createAdminUser({
      email: 'superadmin@gov.lb',
      fullName: 'Protected Super Admin',
    });
    const standardAdmin = await createAdminUser({
      fullName: 'Standard Admin',
      emailPrefix: 'standard-admin',
    });

    const forbiddenCreate = await request(app)
      .post(`${API_PREFIX}/users/admin`)
      .set(authHeader(standardAdmin.token))
      .send({
        email: `forbidden-${Date.now()}@gov.lb`,
        password: 'Passw0rd!123',
        full_name: 'Forbidden Admin',
        phone: '+96170000000',
      });

    expect(forbiddenCreate.status).toBe(403);

    const allowedCreate = await request(app)
      .post(`${API_PREFIX}/users/admin`)
      .set(authHeader(superAdmin.token))
      .send({
        email: `allowed-${Date.now()}@gov.lb`,
        password: 'Passw0rd!123',
        full_name: 'Allowed Admin',
        phone: '+96170000000',
      });

    expect(allowedCreate.status).toBe(201);
    expect(allowedCreate.body.data.role).toBe('admin');

    const protectedDeactivate = await request(app)
      .post(`${API_PREFIX}/users/${superAdmin.user.id}/deactivate`)
      .set(authHeader(standardAdmin.token));

    expect(protectedDeactivate.status).toBe(403);

    const protectedUpdate = await request(app)
      .put(`${API_PREFIX}/users/${superAdmin.user.id}`)
      .set(authHeader(standardAdmin.token))
      .send({ role: 'viewer' });

    expect(protectedUpdate.status).toBe(403);
  });
});
