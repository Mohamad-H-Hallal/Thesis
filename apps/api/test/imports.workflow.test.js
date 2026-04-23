const fs = require('fs').promises;
const path = require('path');

const {
  app,
  API_PREFIX,
  request,
  authHeader,
  pool,
  resetDb,
  shutdown,
  registerUser,
  createAdminUser,
  approveContributorRequest,
  createCategory,
  createProject,
  createAssignment,
  updateAssignmentStatus,
  loginUser,
} = require('./helpers/api-test-helpers');

const tempFiles = [];

const createTempGeoJsonFile = async (name, payload) => {
  const filePath = path.join(__dirname, `${name}-${Date.now()}-${Math.random().toString(16).slice(2)}.geojson`);
  await fs.writeFile(filePath, JSON.stringify(payload, null, 2), 'utf8');
  tempFiles.push(filePath);
  return filePath;
};

describe('GIS import workflow', () => {
  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    for (const filePath of tempFiles) {
      try {
        await fs.unlink(filePath);
      } catch (_error) {
        // ignore missing temp files
      }
    }
    await shutdown();
  });

  test('stages uploaded GeoJSON and supports selected approve/reject review', async () => {
    const admin = await createAdminUser({
      fullName: 'Import Admin',
      emailPrefix: 'import-admin',
    });
    const contributorRegistration = await registerUser({
      role: 'contributor',
      fullName: 'Import Contributor',
      emailPrefix: 'import-contributor',
    });
    await approveContributorRequest({
      token: admin.token,
      userId: contributorRegistration.user.id,
    });
    const contributorLogin = await loginUser({
      email: contributorRegistration.email,
      password: contributorRegistration.password,
    });

    const category = await createCategory({
      token: admin.token,
      name: 'Import Category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Import Project',
      visibleToContributors: true,
    });
    await request(app)
      .put(`${API_PREFIX}/projects/${project.id}`)
      .set(authHeader(admin.token))
      .send({ status: 'active' })
      .expect(200);
    const assignment = await createAssignment({
      token: admin.token,
      projectId: project.id,
      userId: contributorRegistration.user.id,
    });
    await updateAssignmentStatus({
      token: admin.token,
      assignmentId: assignment.id,
      status: 'approved',
    });

    const geojsonPath = await createTempGeoJsonFile('import-selected-review', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: { feature_type: 'olive', name: 'Olive parcel' },
          geometry: {
            type: 'Point',
            coordinates: [35.5001, 33.9001],
          },
        },
        {
          type: 'Feature',
          properties: { feature_type: 'cedar', name: 'Cedar grove' },
          geometry: {
            type: 'Point',
            coordinates: [35.5015, 33.9015],
          },
        },
      ],
    });

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', geojsonPath);

    expect(uploadResponse.status).toBe(202);
    expect(uploadResponse.body.data.status).toBe('pending_review');
    expect(uploadResponse.body.data.pending_feature_count).toBe(2);

    const importId = uploadResponse.body.data.id;
    const detailsResponse = await request(app)
      .get(`${API_PREFIX}/imports/${importId}`)
      .set(authHeader(admin.token));

    expect(detailsResponse.status).toBe(200);
    expect(detailsResponse.body.data.preview_features).toHaveLength(2);
    const featureIds = detailsResponse.body.data.preview_features.map((item) => item.id);

    const approveResponse = await request(app)
      .post(`${API_PREFIX}/imports/${importId}/review`)
      .set(authHeader(admin.token))
      .send({
        status: 'approved',
        feature_ids: [featureIds[0]],
      });

    expect(approveResponse.status).toBe(200);

    const rejectResponse = await request(app)
      .post(`${API_PREFIX}/imports/${importId}/review`)
      .set(authHeader(admin.token))
      .send({
        status: 'rejected',
        feature_ids: [featureIds[1]],
        reason: 'Duplicate field survey already exists.',
      });

    expect(rejectResponse.status).toBe(200);
    expect(rejectResponse.body.data.status).toBe('partially_approved');
    expect(rejectResponse.body.data.approved_feature_count).toBe(1);
    expect(rejectResponse.body.data.rejected_feature_count).toBe(1);

    const officialFeatures = await pool.query(
      `SELECT id, status
       FROM spatial_feature
       WHERE project_id = $1`,
      [project.id],
    );
    expect(officialFeatures.rows).toHaveLength(1);
    expect(officialFeatures.rows[0].status).toBe('approved');

    const notificationCheck = await pool.query(
      `SELECT type, title, message
       FROM notification
       WHERE user_id = $1
         AND type = 'import_event'
       ORDER BY created_at DESC`,
      [contributorRegistration.user.id],
    );
    expect(notificationCheck.rows.length).toBeGreaterThan(0);
    expect(notificationCheck.rows[0].title.toLowerCase()).toContain('import');
  });

  test('marks import as failed when staged features cannot pass required validation', async () => {
    const admin = await createAdminUser({
      fullName: 'Import Failure Admin',
      emailPrefix: 'import-failure-admin',
    });
    const contributorRegistration = await registerUser({
      role: 'contributor',
      fullName: 'Import Failure Contributor',
      emailPrefix: 'import-failure-contributor',
    });
    await approveContributorRequest({
      token: admin.token,
      userId: contributorRegistration.user.id,
    });
    const contributorLogin = await loginUser({
      email: contributorRegistration.email,
      password: contributorRegistration.password,
    });

    const category = await createCategory({
      token: admin.token,
      name: 'Import Failure Category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Import Failure Project',
      visibleToContributors: true,
    });
    await request(app)
      .put(`${API_PREFIX}/projects/${project.id}`)
      .set(authHeader(admin.token))
      .send({ status: 'active' })
      .expect(200);
    const assignment = await createAssignment({
      token: admin.token,
      projectId: project.id,
      userId: contributorRegistration.user.id,
    });
    await updateAssignmentStatus({
      token: admin.token,
      assignmentId: assignment.id,
      status: 'approved',
    });

    const geojsonPath = await createTempGeoJsonFile('import-failed-validation', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: { name: 'Unnamed geometry without feature type' },
          geometry: {
            type: 'Point',
            coordinates: [35.505, 33.905],
          },
        },
      ],
    });

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', geojsonPath);

    expect(uploadResponse.status).toBe(202);
    expect(uploadResponse.body.data.status).toBe('failed');
    expect(uploadResponse.body.data.failed_feature_count).toBe(1);
    expect(uploadResponse.body.data.pending_feature_count).toBe(0);

    const detailResponse = await request(app)
      .get(`${API_PREFIX}/imports/${uploadResponse.body.data.id}`)
      .set(authHeader(contributorLogin.token));
    expect(detailResponse.status).toBe(200);
    expect(detailResponse.body.data.preview_features[0].validation_errors).toEqual(
      expect.arrayContaining(['Missing required attribute: feature_type']),
    );
  });
});
