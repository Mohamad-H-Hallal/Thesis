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
  createCategory,
  createProject,
  createAssignment,
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
      phone: '70123456',
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

    expect(contributor.message).toBe(
      'Account created successfully. Your contributor request is pending admin approval.',
    );

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
        phone: '70123456',
      });

    expect(forbiddenCreate.status).toBe(403);

    const allowedCreate = await request(app)
      .post(`${API_PREFIX}/users/admin`)
      .set(authHeader(superAdmin.token))
      .send({
        email: `allowed-${Date.now()}@gov.lb`,
        password: 'Passw0rd!123',
        full_name: 'Allowed Admin',
        phone: '70123456',
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

  test('promoting a contributor to admin removes assignments but keeps historical features intact', async () => {
    const superAdmin = await createAdminUser({
      email: 'superadmin@gov.lb',
      fullName: 'Protected Super Admin',
    });
    const contributor = await registerUser({
      role: 'contributor',
      fullName: 'Field Contributor',
      emailPrefix: 'field-contributor',
    });

    await approveContributorRequest({
      token: superAdmin.token,
      userId: contributor.user.id,
    });

    const category = await createCategory({
      token: superAdmin.token,
      name: `Integrity Category ${Date.now()}`,
    });
    const project = await createProject({
      token: superAdmin.token,
      categoryId: category.id,
      name: `Integrity Project ${Date.now()}`,
    });

    const activateProject = await request(app)
      .put(`${API_PREFIX}/projects/${project.id}`)
      .set(authHeader(superAdmin.token))
      .send({ status: 'active' });
    expect(activateProject.status).toBe(200);

    await createAssignment({
      token: superAdmin.token,
      projectId: project.id,
      userId: contributor.user.id,
    });

    const contributorLogin = await loginUser({
      email: contributor.email,
      password: contributor.password,
    });

    const createFeature = await request(app)
      .post(`${API_PREFIX}/features`)
      .set(authHeader(contributorLogin.token))
      .send({
        project_id: project.id,
        geom: {
          type: 'Point',
          coordinates: [35.5, 33.9],
        },
        attributes: {
          tree_type: 'oak',
          condition: 'healthy',
        },
      });
    expect(createFeature.status).toBe(201);

    const featureId = createFeature.body.data.id;

    const submitFeature = await request(app)
      .post(`${API_PREFIX}/features/${featureId}/submit`)
      .set(authHeader(contributorLogin.token));
    expect(submitFeature.status).toBe(200);

    const approveFeature = await request(app)
      .post(`${API_PREFIX}/features/${featureId}/review`)
      .set(authHeader(superAdmin.token))
      .send({ status: 'approved' });
    expect(approveFeature.status).toBe(200);

    const promote = await request(app)
      .post(`${API_PREFIX}/users/${contributor.user.id}/toggle-admin-role`)
      .set(authHeader(superAdmin.token))
      .send({ force_unassign: true });

    expect(promote.status).toBe(200);
    expect(promote.body.data.role).toBe('admin');
    expect(promote.body.data.unassigned_assignment_count).toBe(1);

    const assignmentsAfter = await pool.query(
      `SELECT COUNT(*)::int AS count
       FROM project_assignment
       WHERE user_id = $1`,
      [contributor.user.id],
    );
    expect(assignmentsAfter.rows[0].count).toBe(0);

    const featureAfter = await pool.query(
      `SELECT id, project_id, collected_by_user_id, status
       FROM spatial_feature
       WHERE id = $1`,
      [featureId],
    );

    expect(featureAfter.rows).toHaveLength(1);
    expect(featureAfter.rows[0].project_id).toBe(project.id);
    expect(featureAfter.rows[0].collected_by_user_id).toBe(contributor.user.id);
    expect(featureAfter.rows[0].status).toBe('approved');
  });

  test('blocked account cannot log in until unblocked', async () => {
    const superAdmin = await createAdminUser({
      email: 'superadmin@gov.lb',
      fullName: 'Protected Super Admin',
    });
    const viewer = await registerUser({
      role: 'viewer',
      fullName: 'Blocked Viewer',
      emailPrefix: 'blocked-viewer',
    });

    const blockResponse = await request(app)
      .post(`${API_PREFIX}/users/${viewer.user.id}/block`)
      .set(authHeader(superAdmin.token));

    expect(blockResponse.status).toBe(200);
    expect(blockResponse.body.data.is_blocked).toBe(true);
    expect(blockResponse.body.data.account_state).toBe('blocked');

    const blockedLogin = await request(app).post(`${API_PREFIX}/auth/login`).send({
      email: viewer.email,
      password: viewer.password,
    });

    expect(blockedLogin.status).toBe(403);
    expect(blockedLogin.body.message).toBe('Your account has been blocked.');
    expect(blockedLogin.body.data).toBeUndefined();

    const unblockResponse = await request(app)
      .post(`${API_PREFIX}/users/${viewer.user.id}/unblock`)
      .set(authHeader(superAdmin.token));

    expect(unblockResponse.status).toBe(200);
    expect(unblockResponse.body.data.is_blocked).toBe(false);

    const unblockedLogin = await request(app).post(`${API_PREFIX}/auth/login`).send({
      email: viewer.email,
      password: viewer.password,
    });

    expect(unblockedLogin.status).toBe(200);
    expect(unblockedLogin.body.data.user.role).toBe('viewer');
  });

  test('blocked users cannot be promoted until unblocked', async () => {
    const superAdmin = await createAdminUser({
      email: 'superadmin@gov.lb',
      fullName: 'Protected Super Admin',
    });
    const viewer = await registerUser({
      role: 'viewer',
      fullName: 'Blocked Promotion Candidate',
      emailPrefix: 'blocked-promotion',
    });

    const blockResponse = await request(app)
      .post(`${API_PREFIX}/users/${viewer.user.id}/block`)
      .set(authHeader(superAdmin.token));

    expect(blockResponse.status).toBe(200);
    expect(blockResponse.body.data.is_blocked).toBe(true);

    const toggleWhileBlocked = await request(app)
      .post(`${API_PREFIX}/users/${viewer.user.id}/toggle-admin-role`)
      .set(authHeader(superAdmin.token));

    expect(toggleWhileBlocked.status).toBe(409);
    expect(toggleWhileBlocked.body.message).toBe(
      'Blocked users must be unblocked before changing roles.',
    );

    const userListing = await request(app)
      .get(`${API_PREFIX}/users`)
      .set(authHeader(superAdmin.token));

    const listedUser = userListing.body.data.find((item) => item.id === viewer.user.id);
    expect(listedUser.can_toggle_admin_role).toBe(false);
  });
});
