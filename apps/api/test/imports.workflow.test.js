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

    await request(app)
      .get(`${API_PREFIX}/imports/${importId}/download`)
      .set(authHeader(contributorLogin.token))
      .expect(403);

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

  test('duplicate warnings apply only to matching staged features', async () => {
    const admin = await createAdminUser({
      fullName: 'Import Duplicate Admin',
      emailPrefix: 'import-duplicate-admin',
    });
    const contributorRegistration = await registerUser({
      role: 'contributor',
      fullName: 'Import Duplicate Contributor',
      emailPrefix: 'import-duplicate-contributor',
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
      name: 'Import Duplicate Category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Import Duplicate Project',
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

    await pool.query(
      `INSERT INTO spatial_feature (
         project_id,
         collected_by_user_id,
         geom,
         attributes,
         status,
         submitted_at,
         reviewed_by_user_id,
         reviewed_at,
         collected_offline
       ) VALUES (
         $1,
         $2,
         ST_SetSRID(ST_GeomFromGeoJSON($3), 4326),
         $4::jsonb,
         'approved',
         CURRENT_TIMESTAMP,
         $2,
         CURRENT_TIMESTAMP,
         FALSE
       )`,
      [
        project.id,
        admin.user.id,
        JSON.stringify({
          type: 'Point',
          coordinates: [35.5001, 33.9001],
        }),
        JSON.stringify({ feature_type: 'olive' }),
      ],
    );

    const geojsonPath = await createTempGeoJsonFile('import-duplicate-warnings', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: { feature_type: 'olive' },
          geometry: {
            type: 'Point',
            coordinates: [35.5001, 33.9001],
          },
        },
        {
          type: 'Feature',
          properties: { feature_type: 'cedar' },
          geometry: {
            type: 'Point',
            coordinates: [35.5201, 33.9201],
          },
        },
      ],
    });

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', geojsonPath)
      .expect(202);

    const detailsResponse = await waitForImportStatus({
      importId: uploadResponse.body.data.id,
      token: admin.token,
      expectedStatuses: ['pending_review'],
    });

    expect(detailsResponse.body.data.job.warning_count).toBe(1);
    expect(detailsResponse.body.data.job.validation_summary.top_warnings).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          message: 'Geometry matches an approved feature already present in this project.',
          count: 1,
        }),
      ]),
    );

    const warningCheck = await pool.query(
      `SELECT source_index, validation_warnings
       FROM gis_import_feature
       WHERE import_job_id = $1
       ORDER BY source_index ASC`,
      [uploadResponse.body.data.id],
    );

    expect(warningCheck.rows).toHaveLength(2);
    expect(warningCheck.rows[0].validation_warnings).toEqual(
      expect.arrayContaining([
        'Geometry matches an approved feature already present in this project.',
      ]),
    );
    expect(warningCheck.rows[1].validation_warnings).not.toEqual(
      expect.arrayContaining([
        'Geometry matches an approved feature already present in this project.',
      ]),
    );
  });

  test('import map data stays separated from official project features', async () => {
    const admin = await createAdminUser({
      fullName: 'Import Map Admin',
      emailPrefix: 'import-map-admin',
    });
    const contributorRegistration = await registerUser({
      role: 'contributor',
      fullName: 'Import Map Contributor',
      emailPrefix: 'import-map-contributor',
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
      name: 'Import Map Category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Import Map Project',
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

    const geojsonPath = await createTempGeoJsonFile('import-map-separation', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: { feature_type: 'olive', name: 'Pending import feature' },
          geometry: {
            type: 'Point',
            coordinates: [35.5001, 33.9001],
          },
        },
        {
          type: 'Feature',
          properties: { feature_type: 'cedar', name: 'Approved import feature' },
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
      .attach('file', geojsonPath)
      .expect(202);

    const importId = uploadResponse.body.data.id;
    const detailsResponse = await waitForImportStatus({
      importId,
      token: admin.token,
      expectedStatuses: ['pending_review'],
    });
    const featureIds = detailsResponse.body.data.preview_features.map((item) => item.id);

    await request(app)
      .post(`${API_PREFIX}/imports/${importId}/review`)
      .set(authHeader(admin.token))
      .send({
        status: 'approved',
        feature_ids: [featureIds[1]],
      })
      .expect(200);

    const importMapResponse = await request(app)
      .get(
        `${API_PREFIX}/imports/${importId}/map?minLon=35.094&minLat=33.045&maxLon=36.645&maxLat=34.695&zoom=8`,
      )
      .set(authHeader(admin.token))
      .expect(200);

    expect(importMapResponse.body.data.staged_features).toHaveLength(2);
    expect(importMapResponse.body.data.staged_features.map((item) => item.status)).toEqual(
      expect.arrayContaining(['pending_review', 'approved']),
    );
    expect(importMapResponse.body.data.approved_project_features).toHaveLength(1);

    const projectMapResponse = await request(app)
      .get(`${API_PREFIX}/projects/${project.id}/features?limit=100`)
      .set(authHeader(admin.token))
      .expect(200);

    expect(projectMapResponse.body.data).toHaveLength(1);
    expect(projectMapResponse.body.data[0].status).toBe('approved');
  });

  test('approved staged features can be rejected later and are removed from official project features', async () => {
    const admin = await createAdminUser({
      fullName: 'Import Reversal Admin',
      emailPrefix: 'import-reversal-admin',
    });
    const contributorRegistration = await registerUser({
      role: 'contributor',
      fullName: 'Import Reversal Contributor',
      emailPrefix: 'import-reversal-contributor',
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
      name: 'Import Reversal Category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Import Reversal Project',
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

    const geojsonPath = await createTempGeoJsonFile('import-approved-rejected', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: { feature_type: 'olive', name: 'Reversible feature' },
          geometry: {
            type: 'Point',
            coordinates: [35.5001, 33.9001],
          },
        },
      ],
    });

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', geojsonPath)
      .expect(202);

    const importId = uploadResponse.body.data.id;
    const detailsResponse = await waitForImportStatus({
      importId,
      token: admin.token,
      expectedStatuses: ['pending_review'],
    });
    const featureId = detailsResponse.body.data.preview_features[0].id;

    await request(app)
      .post(`${API_PREFIX}/imports/${importId}/review`)
      .set(authHeader(admin.token))
      .send({ status: 'approved', feature_ids: [featureId] })
      .expect(200);

    const approvedFeatures = await pool.query(
      `SELECT id
       FROM spatial_feature
       WHERE project_id = $1`,
      [project.id],
    );
    expect(approvedFeatures.rows).toHaveLength(1);

    const rejectResponse = await request(app)
      .post(`${API_PREFIX}/imports/${importId}/review`)
      .set(authHeader(admin.token))
      .send({
        status: 'rejected',
        feature_ids: [featureId],
        reason: 'Boundary correction required.',
      })
      .expect(200);

    expect(rejectResponse.body.data.status).toBe('rejected');

    const finalOfficialFeatures = await pool.query(
      `SELECT id
       FROM spatial_feature
       WHERE project_id = $1`,
      [project.id],
    );
    expect(finalOfficialFeatures.rows).toHaveLength(0);

    const stagedFeature = await pool.query(
      `SELECT status, approved_feature_id, review_reason
       FROM gis_import_feature
       WHERE id = $1`,
      [featureId],
    );
    expect(stagedFeature.rows[0].status).toBe('rejected');
    expect(stagedFeature.rows[0].approved_feature_id).toBeNull();
    expect(stagedFeature.rows[0].review_reason).toBe('Boundary correction required.');
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
    expect(detailResponse.body.data.job.validation_summary.top_errors).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          message: 'Missing required attribute: feature_type',
          count: 1,
        }),
      ]),
    );
    expect(detailResponse.body.data.preview_features[0].validation_errors).toEqual(
      expect.arrayContaining(['Missing required attribute: feature_type']),
    );

    const issueFilteredResponse = await request(app)
      .get(
        `${API_PREFIX}/imports/${uploadResponse.body.data.id}/features?page=1&limit=20&issue=${encodeURIComponent(
          'Missing required attribute: feature_type',
        )}`,
      )
      .set(authHeader(contributorLogin.token))
      .expect(200);

    expect(issueFilteredResponse.body.pagination.total).toBe(1);
    expect(issueFilteredResponse.body.data).toHaveLength(1);
    expect(issueFilteredResponse.body.data[0].validation_errors).toEqual(
      expect.arrayContaining(['Missing required attribute: feature_type']),
    );
  });

  test('contributors can only list and open their own import jobs', async () => {
    const admin = await createAdminUser({
      fullName: 'Import Visibility Admin',
      emailPrefix: 'import-visibility-admin',
    });
    const contributorA = await registerUser({
      role: 'contributor',
      fullName: 'Import Owner Contributor',
      emailPrefix: 'import-owner-contributor',
    });
    const contributorB = await registerUser({
      role: 'contributor',
      fullName: 'Second Contributor',
      emailPrefix: 'import-second-contributor',
    });
    await approveContributorRequest({
      token: admin.token,
      userId: contributorA.user.id,
    });
    await approveContributorRequest({
      token: admin.token,
      userId: contributorB.user.id,
    });
    const contributorALogin = await loginUser({
      email: contributorA.email,
      password: contributorA.password,
    });
    const contributorBLogin = await loginUser({
      email: contributorB.email,
      password: contributorB.password,
    });

    const category = await createCategory({
      token: admin.token,
      name: 'Import Visibility Category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Import Visibility Project',
      visibleToContributors: true,
    });
    await request(app)
      .put(`${API_PREFIX}/projects/${project.id}`)
      .set(authHeader(admin.token))
      .send({ status: 'active' })
      .expect(200);

    for (const userId of [contributorA.user.id, contributorB.user.id]) {
      const assignment = await createAssignment({
        token: admin.token,
        projectId: project.id,
        userId,
      });
      await updateAssignmentStatus({
        token: admin.token,
        assignmentId: assignment.id,
        status: 'approved',
      });
    }

    const geojsonPath = await createTempGeoJsonFile('import-own-history', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: { feature_type: 'olive', name: 'Owner import' },
          geometry: {
            type: 'Point',
            coordinates: [35.501, 33.901],
          },
        },
      ],
    });

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorALogin.token))
      .attach('file', geojsonPath)
      .expect(202);

    const importId = uploadResponse.body.data.id;
    await waitForImportStatus({
      importId,
      token: admin.token,
      expectedStatuses: ['pending_review'],
    });

    const listForContributorB = await request(app)
      .get(`${API_PREFIX}/imports?page=1&limit=20`)
      .set(authHeader(contributorBLogin.token))
      .expect(200);
    expect(listForContributorB.body.data).toEqual([]);
    expect(listForContributorB.body.pagination.total).toBe(0);

    await request(app)
      .get(`${API_PREFIX}/imports/${importId}`)
      .set(authHeader(contributorBLogin.token))
      .expect(403);
  });

  test('admin-submitted imports require protected super admin review and support download/comments', async () => {
    const previousProtectedEmail = process.env.SUPER_ADMIN_EMAIL;
    const protectedAdmin = await createAdminUser({
      fullName: 'Protected Import Admin',
      emailPrefix: 'protected-import-admin',
    });
    process.env.SUPER_ADMIN_EMAIL = protectedAdmin.email;

    try {
      const standardAdmin = await createAdminUser({
        fullName: 'Standard Import Admin',
        emailPrefix: 'standard-import-admin',
      });

      const category = await createCategory({
        token: protectedAdmin.token,
        name: 'Admin Import Category',
      });
      const project = await createProject({
        token: protectedAdmin.token,
        categoryId: category.id,
        name: 'Admin Import Project',
        visibleToContributors: true,
      });
      await request(app)
        .put(`${API_PREFIX}/projects/${project.id}`)
        .set(authHeader(protectedAdmin.token))
        .send({ status: 'active' })
        .expect(200);

      const geojsonPath = await createTempGeoJsonFile('admin-import-review-scope', {
        type: 'FeatureCollection',
        features: [
          {
            type: 'Feature',
            properties: { feature_type: 'olive', name: 'Admin import feature' },
            geometry: {
              type: 'Point',
              coordinates: [35.5004, 33.9004],
            },
          },
        ],
      });

      await request(app)
        .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
        .set(authHeader(protectedAdmin.token))
        .attach('file', geojsonPath)
        .expect(403);

      const uploadResponse = await request(app)
        .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
        .set(authHeader(standardAdmin.token))
        .attach('file', geojsonPath)
        .expect(202);

      const importId = uploadResponse.body.data.id;
      const detailResponse = await waitForImportStatus({
        importId,
        token: protectedAdmin.token,
        expectedStatuses: ['pending_review'],
      });
      expect(detailResponse.body.data.job.review_scope).toBe('protected_super_admin');

      await request(app)
        .post(`${API_PREFIX}/imports/${importId}/review`)
        .set(authHeader(standardAdmin.token))
        .send({ status: 'approved' })
        .expect(403);

      await request(app)
        .get(`${API_PREFIX}/imports/${importId}/download`)
        .set(authHeader(standardAdmin.token))
        .expect(403);

      await request(app)
        .post(`${API_PREFIX}/imports/${importId}/comments`)
        .set(authHeader(protectedAdmin.token))
        .send({ comment: 'Please verify the imported admin dataset naming.' })
        .expect(201);

      const commentAuditCheck = await pool.query(
        `SELECT action_type, entity_type, entity_id
         FROM audit_log
         WHERE action_type = 'comment'
           AND entity_type = 'gis_import_job'
           AND entity_id = $1`,
        [importId],
      );
      expect(commentAuditCheck.rows).toHaveLength(1);

      const commentNotificationCheck = await pool.query(
        `SELECT type, title, metadata
         FROM notification
         WHERE user_id = $1
           AND type = 'import_event'
         ORDER BY created_at DESC`,
        [standardAdmin.user.id],
      );
      expect(commentNotificationCheck.rows).toHaveLength(1);
      expect(commentNotificationCheck.rows[0].title).toContain('Import comment added');

      const commentVisibleToUploader = await request(app)
        .get(`${API_PREFIX}/imports/${importId}`)
        .set(authHeader(standardAdmin.token))
        .expect(200);
      expect(commentVisibleToUploader.body.data.comments).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            comment_text: 'Please verify the imported admin dataset naming.',
          }),
        ]),
      );

      const downloadResponse = await request(app)
        .get(`${API_PREFIX}/imports/${importId}/download`)
        .set(authHeader(protectedAdmin.token))
        .expect(200);
      expect(downloadResponse.headers['content-disposition']).toContain(
        'admin-import-review-scope',
      );

      await request(app)
        .post(`${API_PREFIX}/imports/${importId}/review`)
        .set(authHeader(protectedAdmin.token))
        .send({ status: 'approved' })
        .expect(200);
    } finally {
      process.env.SUPER_ADMIN_EMAIL = previousProtectedEmail;
    }
  });

  test('accepts MultiPolygon geometries for staged review', async () => {
    const admin = await createAdminUser({
      fullName: 'Import Multipolygon Admin',
      emailPrefix: 'import-multipolygon-admin',
    });
    const contributorRegistration = await registerUser({
      role: 'contributor',
      fullName: 'Import Multipolygon Contributor',
      emailPrefix: 'import-multipolygon-contributor',
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
      name: 'Import Multipolygon Category',
    });
    const project = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: 'Import Multipolygon Project',
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

    const geojsonPath = await createTempGeoJsonFile('import-multipolygon', {
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: { feature_type: 'cedar', name: 'MultiPolygon cedar area' },
          geometry: {
            type: 'MultiPolygon',
            coordinates: [
              [
                [
                  [35.48, 33.89],
                  [35.49, 33.89],
                  [35.49, 33.90],
                  [35.48, 33.90],
                  [35.48, 33.89],
                ],
              ],
            ],
          },
        },
      ],
    });

    const uploadResponse = await request(app)
      .post(`${API_PREFIX}/imports/project/${project.id}/upload`)
      .set(authHeader(contributorLogin.token))
      .attach('file', geojsonPath)
      .expect(202);

    const detailResponse = await waitForImportStatus({
      importId: uploadResponse.body.data.id,
      token: admin.token,
      expectedStatuses: ['pending_review'],
    });

    expect(detailResponse.body.data.job.pending_feature_count).toBe(1);
    expect(detailResponse.body.data.job.failed_feature_count).toBe(0);
    expect(detailResponse.body.data.preview_features[0].geometry_type).toBe(
      'MultiPolygon',
    );
    expect(detailResponse.body.data.preview_features[0].validation_errors).toEqual(
      expect.not.arrayContaining(['Geometry is missing or unsupported.']),
    );
  }, 15000);

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
