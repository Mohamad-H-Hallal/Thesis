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
  const filePath = path.join(
    __dirname,
    `${name}-${Date.now()}-${Math.random().toString(16).slice(2)}.geojson`,
  );
  await fs.writeFile(filePath, JSON.stringify(payload, null, 2), 'utf8');
  tempFiles.push(filePath);
  return filePath;
};

const waitForImportStatus = async ({
  importId,
  token,
  expectedStatuses,
  attempts = 40,
  delayMs = 250,
}) => {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const response = await request(app)
      .get(`${API_PREFIX}/imports/${importId}`)
      .set(authHeader(token));

    if (response.status !== 200) {
      throw new Error(`Unable to load import ${importId}: ${response.status}`);
    }

    const status = response.body.data?.job?.status;
    if (expectedStatuses.includes(status)) {
      return response;
    }

    await new Promise((resolve) => setTimeout(resolve, delayMs));
  }

  throw new Error(
    `Import ${importId} did not reach one of [${expectedStatuses.join(', ')}] in time.`,
  );
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
    expect(uploadResponse.body.data.status).toBe('uploaded');

    const importId = uploadResponse.body.data.id;
    const detailsResponse = await waitForImportStatus({
      importId,
      token: admin.token,
      expectedStatuses: ['pending_review'],
    });

    expect(detailsResponse.status).toBe(200);
    expect(detailsResponse.body.data.job.pending_feature_count).toBe(2);
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
    expect(approveResponse.body.data.status).toBe('pending_review');
    expect(approveResponse.body.data.approved_feature_count).toBe(1);
    expect(approveResponse.body.data.pending_feature_count).toBe(1);

    const interimNotificationCheck = await pool.query(
      `SELECT type, title, message
       FROM notification
       WHERE user_id = $1
         AND type = 'import_event'
       ORDER BY created_at DESC`,
      [contributorRegistration.user.id],
    );
    expect(interimNotificationCheck.rows).toHaveLength(0);

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
    expect(notificationCheck.rows).toHaveLength(1);
    expect(notificationCheck.rows[0].title).toContain('Import partially approved');
    expect(notificationCheck.rows[0].message).toContain('Duplicate field survey already exists.');
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
    expect(uploadResponse.body.data.status).toBe('uploaded');

    const detailResponse = await waitForImportStatus({
      importId: uploadResponse.body.data.id,
      token: contributorLogin.token,
      expectedStatuses: ['failed'],
    });
    expect(detailResponse.status).toBe(200);
    expect(detailResponse.body.data.job.failed_feature_count).toBe(1);
    expect(detailResponse.body.data.job.pending_feature_count).toBe(0);
    expect(detailResponse.body.data.preview_features[0].validation_errors).toEqual(
      expect.arrayContaining(['Missing required attribute: feature_type']),
    );
  });

  test('accepts larger imports beyond the old 2000-feature cap', async () => {
    const admin = await createAdminUser({
      fullName: 'Import Batch Admin',
      emailPrefix: 'import-batch-admin',
    });
    const contributorRegistration = await registerUser({
      role: 'contributor',
      fullName: 'Import Batch Contributor',
      emailPrefix: 'import-batch-contributor',
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
      name: 'Import Batch Category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Import Batch Project',
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

    const features = Array.from({ length: 2105 }, (_, index) => ({
      type: 'Feature',
      properties: {
        feature_type: index % 2 === 0 ? 'olive' : 'cedar',
        name: `Imported feature ${index + 1}`,
      },
      geometry: {
        type: 'Point',
        coordinates: [35.2 + index * 0.0001, 33.1 + index * 0.0001],
      },
    }));

    const geojsonPath = await createTempGeoJsonFile('import-large-batch', {
      type: 'FeatureCollection',
      features,
    });

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', geojsonPath);

    expect(uploadResponse.status).toBe(202);
    expect(uploadResponse.body.data.status).toBe('uploaded');

    const detailsResponse = await waitForImportStatus({
      importId: uploadResponse.body.data.id,
      token: admin.token,
      expectedStatuses: ['pending_review'],
      attempts: 80,
      delayMs: 250,
    });

    expect(detailsResponse.body.data.job.geometry_count).toBe(2105);
    expect(detailsResponse.body.data.job.pending_feature_count).toBe(2105);

    const featuresPage1 = await request(app)
      .get(`${API_PREFIX}/imports/${uploadResponse.body.data.id}/features?page=1&limit=20`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(featuresPage1.body.data).toHaveLength(20);
    expect(featuresPage1.body.pagination.total).toBe(2105);
    expect(featuresPage1.body.pagination.has_more).toBe(true);

    const featuresPage2 = await request(app)
      .get(`${API_PREFIX}/imports/${uploadResponse.body.data.id}/features?page=2&limit=20`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(featuresPage2.body.data).toHaveLength(20);
    expect(featuresPage2.body.pagination.total).toBe(2105);
    expect(featuresPage2.body.pagination.has_more).toBe(true);

    const importsPage = await request(app)
      .get(`${API_PREFIX}/imports?page=1&limit=20&project_id=${project.id}`)
      .set(authHeader(admin.token))
      .expect(200);
    expect(importsPage.body.data).toHaveLength(1);
    expect(importsPage.body.pagination.total).toBe(1);
    expect(importsPage.body.pagination.has_more).toBe(false);
  }, 20000);

  test('rejects GeoJSON uploads with unsupported CRS before staging', async () => {
    const admin = await createAdminUser({
      fullName: 'Import CRS Admin',
      emailPrefix: 'import-crs-admin',
    });
    const contributorRegistration = await registerUser({
      role: 'contributor',
      fullName: 'Import CRS Contributor',
      emailPrefix: 'import-crs-contributor',
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
      name: 'Import CRS Category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Import CRS Project',
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

    const geojsonPath = await createTempGeoJsonFile('import-unsupported-crs', {
      type: 'FeatureCollection',
      crs: {
        type: 'name',
        properties: {
          name: 'EPSG:9999',
        },
      },
      features: [
        {
          type: 'Feature',
          properties: { feature_type: 'olive', name: 'Unsupported CRS feature' },
          geometry: {
            type: 'Point',
            coordinates: [35.51, 33.91],
          },
        },
      ],
    });

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', geojsonPath);

    expect(uploadResponse.status).toBe(202);
    expect(uploadResponse.body.data.status).toBe('uploaded');

    const detailsResponse = await waitForImportStatus({
      importId: uploadResponse.body.data.id,
      token: contributorLogin.token,
      expectedStatuses: ['failed'],
    });

    expect(detailsResponse.body.data.job.processing_message).toContain(
      'Unsupported coordinate reference system "EPSG:9999"',
    );

    const importJobs = await pool.query(
      `SELECT COUNT(*)::int AS total
       FROM gis_import_job
       WHERE status = 'failed'`,
    );
    expect(importJobs.rows[0].total).toBe(1);

    const stagedFeatures = await pool.query(
      `SELECT COUNT(*)::int AS total FROM gis_import_feature`,
    );
    expect(stagedFeatures.rows[0].total).toBe(0);
  });
});
