const {
  API_PREFIX,
  app,
  authHeader,
  pool,
  request,
  resetDb,
  shutdown,
  createAdminUser,
} = require('./helpers/api-test-helpers');

describe('Notification pagination', () => {
  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    await resetDb();
    await shutdown();
  });

  test('returns notifications in 20-item pages with total and has_more metadata', async () => {
    const admin = await createAdminUser({
      fullName: 'Notifications Admin',
      emailPrefix: 'notifications-admin',
    });

    for (let index = 0; index < 45; index += 1) {
      await pool.query(
        `INSERT INTO notification (user_id, type, title, message, metadata, created_at)
         VALUES (
           $1,
           'assignment',
           $2,
           $3,
           jsonb_build_object('project_id', $5::text),
           CURRENT_TIMESTAMP - ($4 || ' minutes')::interval
         )`,
        [
          admin.user.id,
          `Notification ${index + 1}`,
          `Body ${index + 1}`,
          index,
          `project-${index + 1}`,
        ],
      );
    }

    const firstPage = await request(app)
      .get(`${API_PREFIX}/notifications?page=1&limit=20`)
      .set(authHeader(admin.token))
      .expect(200);

    expect(firstPage.body.data).toHaveLength(20);
    expect(firstPage.body.pagination).toMatchObject({
      page: 1,
      limit: 20,
      total: 45,
      has_more: true,
    });

    const secondPage = await request(app)
      .get(`${API_PREFIX}/notifications?page=2&limit=20`)
      .set(authHeader(admin.token))
      .expect(200);

    expect(secondPage.body.data).toHaveLength(20);
    expect(secondPage.body.pagination).toMatchObject({
      page: 2,
      limit: 20,
      total: 45,
      has_more: true,
    });

    const thirdPage = await request(app)
      .get(`${API_PREFIX}/notifications?page=3&limit=20`)
      .set(authHeader(admin.token))
      .expect(200);

    expect(thirdPage.body.data).toHaveLength(5);
    expect(thirdPage.body.pagination).toMatchObject({
      page: 3,
      limit: 20,
      total: 45,
      has_more: false,
    });
  });
});
