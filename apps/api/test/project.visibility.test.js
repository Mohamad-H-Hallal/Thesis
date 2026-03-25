const {
  API_PREFIX,
  app,
  request,
  authHeader,
  resetDb,
  shutdown,
  createAdminUser,
  registerUser,
  loginUser,
  approveContributorRequest,
  createCategory,
  createProject,
  createAssignment,
  updateAssignmentStatus,
} = require('./helpers/api-test-helpers');

describe('Project visibility by role', () => {
  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    await resetDb();
    await shutdown();
  });

  test('viewer sees only admin-published active/completed projects and contributor can query public and assigned scopes separately', async () => {
    const admin = await createAdminUser({
      fullName: 'Visibility Admin',
      emailPrefix: 'visibility-admin',
    });
    const viewer = await registerUser({
      role: 'viewer',
      fullName: 'Visibility Viewer',
      emailPrefix: 'visibility-viewer',
    });
    const contributor = await registerUser({
      role: 'contributor',
      fullName: 'Visibility Contributor',
      emailPrefix: 'visibility-contributor',
    });

    await approveContributorRequest({
      token: admin.token,
      userId: contributor.user.id,
    });

    const category = await createCategory({
      token: admin.token,
      name: `Visibility Category ${Date.now()}`,
    });

    const publicProject = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `Public Project ${Date.now()}`,
      visibleToViewers: true,
    });
    await request(app)
      .put(`${API_PREFIX}/projects/${publicProject.id}`)
      .set(authHeader(admin.token))
      .send({ status: 'active', visible_to_viewers: true })
      .expect(200);

    const privateProject = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `Private Project ${Date.now()}`,
      visibleToViewers: false,
    });
    await request(app)
      .put(`${API_PREFIX}/projects/${privateProject.id}`)
      .set(authHeader(admin.token))
      .send({ status: 'active', visible_to_viewers: false })
      .expect(200);

    const hiddenDraftProject = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `Draft Viewer Project ${Date.now()}`,
      visibleToViewers: true,
      status: 'draft',
    });
    expect(hiddenDraftProject.status).toBe('draft');

    const assignment = await createAssignment({
      token: admin.token,
      projectId: privateProject.id,
      userId: contributor.user.id,
      role: 'contributor',
    });
    await updateAssignmentStatus({
      token: admin.token,
      assignmentId: assignment.id,
      status: 'approved',
    });

    const viewerLogin = await loginUser({
      email: viewer.email,
      password: viewer.password,
    });
    const contributorLogin = await loginUser({
      email: contributor.email,
      password: contributor.password,
    });

    const viewerProjects = await request(app)
      .get(`${API_PREFIX}/projects`)
      .set(authHeader(viewerLogin.token));
    expect(viewerProjects.status).toBe(200);
    expect(viewerProjects.body.data).toHaveLength(1);
    expect(viewerProjects.body.data[0].id).toBe(publicProject.id);

    const contributorAssignedProjects = await request(app)
      .get(`${API_PREFIX}/projects`)
      .set(authHeader(contributorLogin.token));
    expect(contributorAssignedProjects.status).toBe(200);
    expect(contributorAssignedProjects.body.access_scope).toBe('assigned');
    expect(contributorAssignedProjects.body.data).toHaveLength(1);
    expect(contributorAssignedProjects.body.data[0].id).toBe(privateProject.id);

    const contributorPublicProjects = await request(app)
      .get(`${API_PREFIX}/projects`)
      .query({ access_scope: 'public' })
      .set(authHeader(contributorLogin.token));
    expect(contributorPublicProjects.status).toBe(200);
    expect(contributorPublicProjects.body.access_scope).toBe('public');
    expect(contributorPublicProjects.body.data).toHaveLength(1);
    expect(contributorPublicProjects.body.data[0].id).toBe(publicProject.id);

    await request(app)
      .get(`${API_PREFIX}/projects/${publicProject.id}`)
      .set(authHeader(contributorLogin.token))
      .expect(200);

    await request(app)
      .get(`${API_PREFIX}/projects/${privateProject.id}`)
      .set(authHeader(viewerLogin.token))
      .expect(403);

    await request(app)
      .put(`${API_PREFIX}/projects/${privateProject.id}`)
      .set(authHeader(admin.token))
      .send({ visible_to_viewers: true })
      .expect(200);

    const viewerProjectsAfterToggle = await request(app)
      .get(`${API_PREFIX}/projects`)
      .set(authHeader(viewerLogin.token));
    expect(viewerProjectsAfterToggle.status).toBe(200);
    expect(viewerProjectsAfterToggle.body.data).toHaveLength(2);

    const contributorPublicProjectsAfterToggle = await request(app)
      .get(`${API_PREFIX}/projects`)
      .query({ access_scope: 'public' })
      .set(authHeader(contributorLogin.token));
    expect(contributorPublicProjectsAfterToggle.status).toBe(200);
    expect(contributorPublicProjectsAfterToggle.body.data).toHaveLength(2);
  });
});
