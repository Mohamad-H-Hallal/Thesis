const {
  API_PREFIX,
  app,
  request,
  authHeader,
  resetDb,
  cleanupExportFiles,
  shutdown,
  createAdminUser,
  registerUser,
  loginUser,
  approveContributorRequest,
  createCategory,
  createProject,
  createAssignment,
  updateAssignmentStatus,
  waitForExportCompletion,
} = require('./helpers/api-test-helpers');

jest.setTimeout(90000);

describe('Phase 10 E2E workflow', () => {
  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    await cleanupExportFiles();
    await resetDb();
    await shutdown();
  });

  test('auth -> project -> assignment -> feature review -> export download', async () => {
    const admin = await createAdminUser({
      fullName: 'Phase10 Admin',
      emailPrefix: 'phase10-admin',
    });

    const contributor = await registerUser({
      role: 'contributor',
      fullName: 'Phase10 Contributor',
      emailPrefix: 'phase10-contributor',
    });

    await approveContributorRequest({
      token: admin.token,
      userId: contributor.user.id,
    });

    const category = await createCategory({
      token: admin.token,
      name: `Fruit Trees ${Date.now()}`,
    });

    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `Bekaa Field Census ${Date.now()}`,
    });

    const assignment = await createAssignment({
      token: admin.token,
      projectId: project.id,
      userId: contributor.user.id,
      role: 'contributor',
    });

    await updateAssignmentStatus({
      token: admin.token,
      assignmentId: assignment.id,
      status: 'approved',
    });

    const contributorLogin = await loginUser({
      email: contributor.email,
      password: contributor.password,
    });

    const createFeatureResponse = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(authHeader(contributorLogin.token))
      .send({
        project_id: project.id,
        geom: {
          type: 'Point',
          coordinates: [35.5018, 33.8938],
        },
        attributes: {
          tree_type: 'olive',
          condition: 'good',
        },
        accuracy_meters: 4.2,
      });

    expect(createFeatureResponse.status).toBe(201);
    expect(createFeatureResponse.body.success).toBe(true);
    const featureId = createFeatureResponse.body.data.id;
    expect(featureId).toBeTruthy();

    const submitResponse = await request(app)
      .post(`${API_PREFIX}/features/${featureId}/submit`)
      .set(authHeader(contributorLogin.token))
      .send();
    expect(submitResponse.status).toBe(200);

    const reviewResponse = await request(app)
      .post(`${API_PREFIX}/features/${featureId}/review`)
      .set(authHeader(admin.token))
      .send({
        status: 'approved',
        review_notes: 'Geometry and attributes validated.',
      });
    expect(reviewResponse.status).toBe(200);

    const exportRequestResponse = await request(app)
      .post(`${API_PREFIX}/exports/project/${project.id}`)
      .set(authHeader(contributorLogin.token))
      .send({
        status_filter: ['approved'],
        format: 'geojson',
      });

    expect(exportRequestResponse.status).toBe(202);
    const exportId = exportRequestResponse.body?.data?.export_id;
    expect(exportId).toBeTruthy();

    const completedExport = await waitForExportCompletion({
      token: contributorLogin.token,
      exportId,
      timeoutMs: 45000,
    });

    expect(completedExport.status).toBe('completed');
    expect(completedExport.feature_count).toBeGreaterThanOrEqual(1);
    expect(completedExport.file_path).toBeTruthy();
    expect(Number(completedExport.file_size_bytes)).toBeGreaterThan(0);

    const downloadResponse = await request(app)
      .get(`${API_PREFIX}/exports/${exportId}/download`)
      .set(authHeader(contributorLogin.token));

    expect(downloadResponse.status).toBe(200);
    expect(downloadResponse.headers['content-type']).toMatch(/zip|octet-stream/i);
  });
});
