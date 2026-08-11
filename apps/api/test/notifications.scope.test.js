const {
  API_PREFIX,
  app,
  request,
  authHeader,
  resetDb,
  shutdown,
  registerUser,
  createAdminUser,
  loginUser,
  pool,
} = require('./helpers/api-test-helpers');

jest.setTimeout(30000);

describe('Notifications scoping', () => {
  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    await resetDb();
    await shutdown();
  });

  test('each authenticated user only sees their own notifications', async () => {
    const admin = await createAdminUser({
      fullName: 'Scoped Admin',
      emailPrefix: 'scoped-admin',
    });
    const viewerA = await registerUser({
      role: 'viewer',
      fullName: 'Viewer A',
      emailPrefix: 'viewer-a',
    });
    const viewerB = await registerUser({
      role: 'viewer',
      fullName: 'Viewer B',
      emailPrefix: 'viewer-b',
    });

    const viewerALogin = await loginUser({
      email: viewerA.email,
      password: viewerA.password,
    });
    const viewerBLogin = await loginUser({
      email: viewerB.email,
      password: viewerB.password,
    });

    await pool.query(
      `INSERT INTO notification (user_id, type, title, message, metadata)
       VALUES
        ($1, 'assignment', 'Viewer A only', 'Scoped message A', '{"user_id":"a"}'::jsonb),
        ($2, 'assignment', 'Viewer B only', 'Scoped message B', '{"user_id":"b"}'::jsonb)`,
      [viewerA.user.id, viewerB.user.id],
    );

    const viewerAResponse = await request(app)
      .get(`${API_PREFIX}/notifications`)
      .set(authHeader(viewerALogin.token));
    const viewerBResponse = await request(app)
      .get(`${API_PREFIX}/notifications`)
      .set(authHeader(viewerBLogin.token));
    const adminResponse = await request(app)
      .get(`${API_PREFIX}/notifications`)
      .set(authHeader(admin.token));

    expect(viewerAResponse.status).toBe(200);
    expect(viewerBResponse.status).toBe(200);
    expect(adminResponse.status).toBe(200);

    const viewerATitles = viewerAResponse.body.data.map((item) => item.title);
    const viewerBTitles = viewerBResponse.body.data.map((item) => item.title);
    const adminTitles = adminResponse.body.data.map((item) => item.title);

    expect(viewerATitles).toContain('Viewer A only');
    expect(viewerATitles).not.toContain('Viewer B only');
    expect(viewerBTitles).toContain('Viewer B only');
    expect(viewerBTitles).not.toContain('Viewer A only');
    expect(adminTitles).not.toContain('Viewer A only');
    expect(adminTitles).not.toContain('Viewer B only');
  });
});
