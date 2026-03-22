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
    const response = await request(app).post(`${API_PREFIX}/auth/register`).send({
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

    const requestNotifications = await pool.query(
      `SELECT type FROM notification WHERE user_id = $1 ORDER BY created_at DESC`,
      [contributor.user.id],
    );
    expect(requestNotifications.rows[0]?.type).toBe('contributor_request');

    const pendingLogin = await request(app).post(`${API_PREFIX}/auth/login`).send({
      email: contributor.email,
      password: contributor.password,
    });

    expect(pendingLogin.status).toBe(403);
    expect(pendingLogin.body.message).toBe(
      'Your contributor request is still pending approval. You cannot log in yet.',
    );
    expect(pendingLogin.body.data).toBeUndefined();

    await approveContributorRequest({
      token: admin.token,
      userId: contributor.user.id,
    });

    const approvedLogin = await request(app).post(`${API_PREFIX}/auth/login`).send({
      email: contributor.email,
      password: contributor.password,
    });

    expect(approvedLogin.status).toBe(200);
    expect(approvedLogin.body.data.user.role).toBe('contributor');
  });

  test('rejected contributor remains blocked from login', async () => {
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
    expect(rejectResponse.body.data.role).toBe('contributor');
    expect(rejectResponse.body.data.is_active).toBe(false);

    const rejectionNotifications = await pool.query(
      `SELECT type FROM notification WHERE user_id = $1 ORDER BY created_at DESC`,
      [contributor.user.id],
    );
    expect(rejectionNotifications.rows[0]?.type).toBe('contributor_rejected');

    const rejectedLogin = await request(app).post(`${API_PREFIX}/auth/login`).send({
      email: contributor.email,
      password: contributor.password,
    });

    expect(rejectedLogin.status).toBe(403);
    expect(rejectedLogin.body.message).toBe(
      'Your contributor request was rejected. You cannot log in with contributor access.',
    );
    expect(rejectedLogin.body.data).toBeUndefined();
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
    expect(allowedCreate.body.data.is_protected_super_admin).toBe(false);

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

  test('protected super admin can promote and revert eligible users through the runtime toggle', async () => {
    const superAdmin = await createAdminUser({
      email: 'superadmin@gov.lb',
      fullName: 'Protected Super Admin',
    });
    const viewer = await registerUser({
      role: 'viewer',
      fullName: 'Viewer Candidate',
      emailPrefix: 'viewer-candidate',
    });

    const promote = await request(app)
      .post(`${API_PREFIX}/users/${viewer.user.id}/toggle-admin-role`)
      .set(authHeader(superAdmin.token));

    expect(promote.status).toBe(200);
    expect(promote.body.data.role).toBe('admin');
    expect(promote.body.data.previous_admin_role).toBe('viewer');

    const revert = await request(app)
      .post(`${API_PREFIX}/users/${viewer.user.id}/toggle-admin-role`)
      .set(authHeader(superAdmin.token));

    expect(revert.status).toBe(200);
    expect(revert.body.data.role).toBe('viewer');

    const fixedAdmin = await createAdminUser({
      fullName: 'Fixed Admin',
      emailPrefix: 'fixed-admin',
    });

    const denyFixedRevert = await request(app)
      .post(`${API_PREFIX}/users/${fixedAdmin.user.id}/toggle-admin-role`)
      .set(authHeader(superAdmin.token));

    expect(denyFixedRevert.status).toBe(400);
  });
});
