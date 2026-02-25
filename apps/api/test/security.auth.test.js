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
} = require('./helpers/api-test-helpers');

describe('Security: registration and admin role controls', () => {
  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    await resetDb();
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
        role: 'admin',
      });

    expect(response.status).toBe(400);
    expect(response.body.success).toBe(false);

    const check = await pool.query('SELECT role FROM "user" WHERE email = $1', [email]);
    expect(check.rows).toHaveLength(0);
  });

  test('only admin can promote user to admin via protected endpoint', async () => {
    const admin = await createAdminUser({
      fullName: 'Security Admin',
      emailPrefix: 'security-admin',
    });
    const contributor = await registerUser({
      fullName: 'Security Contributor',
      emailPrefix: 'security-contributor',
    });
    const target = await registerUser({
      fullName: 'Security Target',
      emailPrefix: 'security-target',
    });

    const contributorLogin = await loginUser({
      email: contributor.email,
      password: contributor.password,
    });

    const forbidden = await request(app)
      .put(`${API_PREFIX}/users/${target.user.id}`)
      .set(authHeader(contributorLogin.token))
      .send({ role: 'admin' });

    expect(forbidden.status).toBe(403);

    const promoted = await request(app)
      .put(`${API_PREFIX}/users/${target.user.id}`)
      .set(authHeader(admin.token))
      .send({ role: 'admin' });

    expect(promoted.status).toBe(200);
    expect(promoted.body.success).toBe(true);
    expect(promoted.body.data.role).toBe('admin');
  });
});
