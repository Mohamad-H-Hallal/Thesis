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
  approveContributorRequest,
  createCategory,
  createProject,
  createAssignment,
  updateAssignmentStatus,
  pool,
} = require('./helpers/api-test-helpers');

describe('Project workflow access and feature visibility', () => {
  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    await resetDb();
    await shutdown();
  });

  test('only approved contributors can request project access and pending requests become manageable', async () => {
    const admin = await createAdminUser({
      fullName: 'Workflow Admin',
      emailPrefix: 'workflow-admin',
    });
    const viewer = await registerUser({
      role: 'viewer',
      fullName: 'Workflow Viewer',
      emailPrefix: 'workflow-viewer',
    });
    const contributor = await registerUser({
      role: 'contributor',
      fullName: 'Workflow Contributor',
      emailPrefix: 'workflow-contributor',
    });

    await approveContributorRequest({
      token: admin.token,
      userId: contributor.user.id,
    });

    const category = await createCategory({
      token: admin.token,
      name: `Workflow Category ${Date.now()}`,
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `Workflow Project ${Date.now()}`,
      visibleToViewers: false,
      visibleToContributors: true,
    });

    await request(app)
      .put(`${API_PREFIX}/projects/${project.id}`)
      .set(authHeader(admin.token))
      .send({
        status: 'draft',
        visible_to_viewers: false,
        visible_to_contributors: true,
      })
      .expect(200);

    const viewerLogin = await loginUser({
      email: viewer.email,
      password: viewer.password,
    });
    const contributorLogin = await loginUser({
      email: contributor.email,
      password: contributor.password,
    });

    const viewerJoinAttempt = await request(app)
      .post(`${API_PREFIX}/assignments/join/${project.id}`)
      .set(authHeader(viewerLogin.token));

    expect(viewerJoinAttempt.status).toBe(403);
    expect(viewerJoinAttempt.body.message).toBe(
      'Only approved contributors can request project access',
    );

    const contributorJoinAttempt = await request(app)
      .post(`${API_PREFIX}/assignments/join/${project.id}`)
      .set(authHeader(contributorLogin.token));

    expect(contributorJoinAttempt.status).toBe(201);
    expect(contributorJoinAttempt.body.data.status).toBe('pending');

    const managedAssignments = await request(app)
      .get(`${API_PREFIX}/assignments/managed`)
      .set(authHeader(admin.token));

    expect(managedAssignments.status).toBe(200);
    expect(
      managedAssignments.body.data.some(
        (item) =>
          item.project_id === project.id &&
          item.user_id === contributor.user.id &&
          item.status === 'pending',
      ),
    ).toBe(true);
  });

  test('project feature list is filtered by role and ownership', async () => {
    const admin = await createAdminUser({
      fullName: 'Feature Admin',
      emailPrefix: 'feature-admin',
    });
    const viewer = await registerUser({
      role: 'viewer',
      fullName: 'Feature Viewer',
      emailPrefix: 'feature-viewer',
    });
    const contributorA = await registerUser({
      role: 'contributor',
      fullName: 'Feature Contributor A',
      emailPrefix: 'feature-contributor-a',
    });
    const contributorB = await registerUser({
      role: 'contributor',
      fullName: 'Feature Contributor B',
      emailPrefix: 'feature-contributor-b',
    });

    await approveContributorRequest({
      token: admin.token,
      userId: contributorA.user.id,
    });
    await approveContributorRequest({
      token: admin.token,
      userId: contributorB.user.id,
    });

    const category = await createCategory({
      token: admin.token,
      name: `Feature Category ${Date.now()}`,
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `Feature Project ${Date.now()}`,
      visibleToViewers: true,
    });

    await request(app)
      .put(`${API_PREFIX}/projects/${project.id}`)
      .set(authHeader(admin.token))
      .send({ status: 'active', visible_to_viewers: true })
      .expect(200);

    const assignmentA = await createAssignment({
      token: admin.token,
      projectId: project.id,
      userId: contributorA.user.id,
      role: 'contributor',
    });
    await updateAssignmentStatus({
      token: admin.token,
      assignmentId: assignmentA.id,
      status: 'approved',
    });

    const assignmentB = await createAssignment({
      token: admin.token,
      projectId: project.id,
      userId: contributorB.user.id,
      role: 'contributor',
    });
    await updateAssignmentStatus({
      token: admin.token,
      assignmentId: assignmentB.id,
      status: 'approved',
    });

    const insertFeature = async ({
      featureId,
      status,
      collectedBy,
      reviewedBy = null,
      reviewNotes = null,
    }) => {
      await pool.query(
        `INSERT INTO spatial_feature (
          id,
          project_id,
          collected_by_user_id,
          geom,
          attributes,
          status,
          submitted_at,
          reviewed_at,
          reviewed_by_user_id,
          review_notes,
          accuracy_meters,
          collected_offline,
          version
        ) VALUES (
          $1,
          $2,
          $3,
          ST_SetSRID(ST_GeomFromText('POINT(35.5 33.9)'), 4326),
          $4::jsonb,
          $5::feature_status,
          CASE WHEN $5::feature_status IN ('pending_review', 'approved', 'rejected') THEN NOW() ELSE NULL END,
          CASE WHEN $5::feature_status IN ('approved', 'rejected') THEN NOW() ELSE NULL END,
          $6,
          $7,
          4.2,
          FALSE,
          1
        )`,
        [
          featureId,
          project.id,
          collectedBy,
          JSON.stringify({ tree_type: 'olive', condition: status }),
          status,
          reviewedBy,
          reviewNotes,
        ],
      );
    };

    const approvedId = '11111111-1111-4111-8111-111111111111';
    const pendingId = '22222222-2222-4222-8222-222222222222';
    const rejectedOwnId = '33333333-3333-4333-8333-333333333333';
    const rejectedOtherId = '44444444-4444-4444-8444-444444444444';
    const draftOtherId = '55555555-5555-4555-8555-555555555555';
    const pendingOtherId = '66666666-6666-4666-8666-666666666666';

    await insertFeature({
      featureId: approvedId,
      status: 'approved',
      collectedBy: contributorA.user.id,
      reviewedBy: admin.user.id,
      reviewNotes: 'Approved for publication',
    });
    await insertFeature({
      featureId: pendingId,
      status: 'pending_review',
      collectedBy: contributorA.user.id,
    });
    await insertFeature({
      featureId: rejectedOwnId,
      status: 'rejected',
      collectedBy: contributorA.user.id,
      reviewedBy: admin.user.id,
      reviewNotes: 'Needs better geometry',
    });
    await insertFeature({
      featureId: rejectedOtherId,
      status: 'rejected',
      collectedBy: contributorB.user.id,
      reviewedBy: admin.user.id,
      reviewNotes: 'Rejected from contributor B',
    });
    await insertFeature({
      featureId: pendingOtherId,
      status: 'pending_review',
      collectedBy: contributorB.user.id,
    });
    await insertFeature({
      featureId: draftOtherId,
      status: 'draft',
      collectedBy: contributorB.user.id,
    });

    const viewerLogin = await loginUser({
      email: viewer.email,
      password: viewer.password,
    });
    const contributorALogin = await loginUser({
      email: contributorA.email,
      password: contributorA.password,
    });

    const viewerResponse = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/features`)
      .set(authHeader(viewerLogin.token));
    const contributorResponse = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/features`)
      .set(authHeader(contributorALogin.token));
    const contributorGlobalResponse = await request(app)
      .get(`${API_PREFIX}/features`)
      .query({ project_id: project.id })
      .set(authHeader(contributorALogin.token));
    const adminResponse = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/features`)
      .set(authHeader(admin.token));
    const contributorApprovedFeature = await request(app)
      .get(`${API_PREFIX}/features/${approvedId}`)
      .set(authHeader(contributorALogin.token));
    const contributorOwnRejectedFeature = await request(app)
      .get(`${API_PREFIX}/features/${rejectedOwnId}`)
      .set(authHeader(contributorALogin.token));
    const contributorOtherPendingFeature = await request(app)
      .get(`${API_PREFIX}/features/${pendingOtherId}`)
      .set(authHeader(contributorALogin.token));
    const contributorOtherRejectedFeature = await request(app)
      .get(`${API_PREFIX}/features/${rejectedOtherId}`)
      .set(authHeader(contributorALogin.token));

    expect(viewerResponse.status).toBe(200);
    expect(viewerResponse.body.data.map((item) => item.id)).toEqual([approvedId]);

    expect(contributorResponse.status).toBe(200);
    expect(contributorResponse.body.data.map((item) => item.id)).toEqual(
      expect.arrayContaining([approvedId, pendingId, rejectedOwnId]),
    );
    expect(contributorResponse.body.data.map((item) => item.id)).not.toEqual(
      expect.arrayContaining([pendingOtherId, rejectedOtherId, draftOtherId]),
    );
    expect(contributorGlobalResponse.status).toBe(200);
    expect(contributorGlobalResponse.body.data.map((item) => item.id)).toEqual(
      expect.arrayContaining([approvedId, pendingId, rejectedOwnId]),
    );
    expect(
      contributorGlobalResponse.body.data.map((item) => item.id),
    ).not.toEqual(
      expect.arrayContaining([pendingOtherId, rejectedOtherId, draftOtherId]),
    );
    expect(contributorApprovedFeature.status).toBe(200);
    expect(contributorOwnRejectedFeature.status).toBe(200);
    expect(contributorOtherPendingFeature.status).toBe(403);
    expect(contributorOtherRejectedFeature.status).toBe(403);

    expect(adminResponse.status).toBe(200);
    expect(adminResponse.body.data).toHaveLength(6);
  });
});
