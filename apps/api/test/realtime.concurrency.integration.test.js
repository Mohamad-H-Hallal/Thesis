const {
  API_PREFIX,
  app,
  request,
  authHeader,
  resetDb,
  shutdown,
  createAdminUser,
  createCategory,
  createProject,
} = require('./helpers/api-test-helpers');

describe('mutable form optimistic concurrency', () => {
  let admin;

  beforeEach(async () => {
    await resetDb();
    admin = await createAdminUser({ emailPrefix: 'realtime-concurrency' });
  });

  afterAll(async () => {
    await resetDb();
    await shutdown();
  });

  test('rejects a stale category form without overwriting the newer value', async () => {
    const category = await createCategory({
      token: admin.token,
      name: `Concurrency category ${Date.now()}`,
    });

    const first = await request(app)
      .put(`${API_PREFIX}/categories/${category.id}`)
      .set(authHeader(admin.token))
      .send({ name: 'First category edit', expected_version: category.version });
    expect(first.status).toBe(200);
    expect(Number(first.body.data.version)).toBe(Number(category.version) + 1);

    const stale = await request(app)
      .put(`${API_PREFIX}/categories/${category.id}`)
      .set(authHeader(admin.token))
      .send({ name: 'Stale category edit', expected_version: category.version });
    expect(stale.status).toBe(409);
    expect(stale.body.error).toMatchObject({
      code: 'ENTITY_VERSION_CONFLICT',
      disposition: 'conflict',
      retryable: false,
      current_version: Number(category.version) + 1,
    });
  });

  test('rejects a stale project form without overwriting the newer value', async () => {
    const category = await createCategory({
      token: admin.token,
      name: `Project concurrency category ${Date.now()}`,
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `Concurrency project ${Date.now()}`,
    });

    const first = await request(app)
      .put(`${API_PREFIX}/projects/${project.id}`)
      .set(authHeader(admin.token))
      .send({ name: 'First project edit', expected_version: project.version });
    expect(first.status).toBe(200);
    expect(Number(first.body.data.version)).toBe(Number(project.version) + 1);

    const stale = await request(app)
      .put(`${API_PREFIX}/projects/${project.id}`)
      .set(authHeader(admin.token))
      .send({ name: 'Stale project edit', expected_version: project.version });
    expect(stale.status).toBe(409);
    expect(stale.body.error).toMatchObject({
      code: 'ENTITY_VERSION_CONFLICT',
      disposition: 'conflict',
      retryable: false,
      current_version: Number(project.version) + 1,
    });
  });
});
